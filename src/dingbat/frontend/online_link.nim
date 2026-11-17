## Online link play, as the web (web/netplay.js) and iOS (NetLink.swift)
## do it, so a desktop links with a browser or an iPhone: both players type
## the same code, the signaling server pairs them, and a WebRTC data
## channel carries the game. Input rollback: each side runs both players'
## cores and only per-frame buttons cross (gba/rollback.nim,
## gb/rollback.nim). No SDL, ImGui or GL, so tests/desktop_online_link_test
## links two of these over a local signaling server.
##
## Wire protocol, first byte = kind, big-endian (web RB_*):
##   0 hello [epoch u32][romHash u32][len u32][crc32 u32][fnv u32]
##   1 input [frame i32][bits u16]
##   2 state-begin [len u32]            3 state-chunk [bytes]
##   4 rom-begin [len u32]              5 rom-chunk [bytes]
##   6 ready   7 speed [on u8][n u32]   8 pause [on u8][n u32]
##   9 have-rom   10 need-rom   11 away [on u8]
##   12 resume-info [sid u32][retry code]
##   13 resume [sid u32][last frame u32][flags u8]
##   14 bye [why u8] (0 left, 1 gave up)   15 ping
## Core 0 is the host's game, core 1 the guest's. When the ROMs differ (a
## cross-game trade) each side answers the friend's hello with have-rom (a
## copy is here) or need-rom, and a ROM goes over only on need-rom.
##
## Left out from iOS: the manual code exchange (no server), and the library
## search beyond the folder of this player's own ROM.

import std/[json, os, random, strutils, sysrand, tables, math, times]
import rtc
import ../common/[linkproto, serialize, rom_exts]
import ../gba/gba
import ../gba/link as gbalink
import ../gba/rollback as gbarb
import ../gb/gb
import ../gb/link as gblink
import ../gb/rollback as gbrb
import ../common/scheduler

export rtc.net_init

const
  SIGNAL_URL* = "wss://signal.dingbat.gg/signal"
  ICE_SERVERS = ["stun:stun.l.google.com:19302"]
  # web NET_* / NetLink.swift timings, ms
  DIAL_TIMEOUT = 4000
  RENDEZVOUS_TIMEOUT = 2000
  REDIAL_DELAYS = [1000, 2000, 4000]
  RTC_DEADLINE = 20000
  PING_INTERVAL = 20000
  RESUME_GIVE_UP* = 180_000
  RESUME_PAIR_DEADLINE = 20000
  RESUME_ANSWER_DEADLINE = 10000
  REWAIT_INTERVAL = 25000
  DISCONNECTED_GRACE = 10000
  AWAY_CARD_DELAY* = 1000
  AWAY_TOAST_AFTER = 5000
  LIVE_MAX_AGE = 600  # s: the server keeps a goodbye this long
  SENT_LOG_MAX = 128  # the friend's gap is at most ~2x the prediction window
  HELLO_LEN = 21      # with the whole-ROM identity
  CHUNK = 16384
  HIGH_WATER = 4 * 1024 * 1024
  ROM_MAX = 48 * 1024 * 1024
  LOOKUP_BUDGET_MS = 1500
  PREDICTION_WINDOW = 12
  SETUP_SILENCE_MS = 30000  # a friend mid-setup says something well within this
  SETUP_CHECK_MS = 5000
  CODE_MAX* = 12  ## the web's and iOS's code box hold this many

  K_HELLO = 0'u8
  K_INPUT = 1'u8
  K_STATE_BEGIN = 2'u8
  K_STATE_CHUNK = 3'u8
  K_ROM_BEGIN = 4'u8
  K_ROM_CHUNK = 5'u8
  K_READY = 6'u8
  K_SPEED = 7'u8
  K_PAUSE = 8'u8
  K_HAVE_ROM = 9'u8
  K_NEED_ROM = 10'u8
  K_AWAY = 11'u8
  K_RESUME_INFO = 12'u8
  K_RESUME = 13'u8
  K_BYE = 14'u8
  K_PING = 15'u8

type
  Timer = ref object
    due: int64
    fn: proc()
    dead: bool

  Peer = ref object
    pc, dc: int
    offerer, closed: bool
    on_desc: proc(sdp, typ: string)
    on_cand: proc(cand, mid: string)
    on_state: proc(st: string)
    on_open: proc()
    on_closed: proc()
    on_message: proc(data: string)
    on_low: proc()

  Sig = ref object
    id: int
    done: bool
    on_open: proc()
    on_close: proc(opened: bool)
    on_message: proc(msg: JsonNode)

  RomIdentity* = object
    len*, crc*, fnv*: uint32

  Press = object
    ## Pause and 2x are one value both sides share and either can change,
    ## so two presses can cross. Each is numbered one past the highest this
    ## side has seen; both keep the highest, the host's on a tie (web
    ## rbPress; formal/WebState/LinkResume.lean `presses_agree`).
    on: bool
    n: uint32
    host: bool

  RB = ref object
    local_player: int
    epoch: uint32
    ext, game_path: string
    rom_bytes: string
    rom_hash: uint32
    rom_id: RomIdentity
    remote_rom_id: RomIdentity
    has_remote_rom_id: bool
    local_state, state_buf: string
    remote_state: string
    has_remote_state: bool
    state_len: int
    remote_hello, need_rom, local_ready, remote_ready, inited: bool
    remote_rom_hash: uint32
    remote_rom_len: int
    rom_buf, remote_rom: string
    has_remote_rom: bool
    rom_sent: int
    rom_send_started: bool
    # Resume
    resume_sid: uint32
    resume_code: string
    resume_ok, bye_in, note_left: bool
    last_rx: int32
    last_msg_at: int64
    sent_frames: array[SENT_LOG_MAX, int32]
    sent_bits: array[SENT_LOG_MAX, uint16]
    sent_count: int
    reconnecting: bool
    reconnect_at: int64
    rs_ws: Sig
    rs_peer: Peer
    rs_open, rs_sdp_in: bool
    rs_early: seq[string]
    rs_flags: uint8
    pause_reg, speed_reg: Press
    rs_attempt: int
    rs_timer, rs_rewait, disc_timer, give_up: Timer

  Session = ref object
    code: string
    ws: Sig
    peer: Peer
    is_host: int  # -1 unknown, 0 guest, 1 host
    rtc_connected, sdp_in, rewaited, started: bool
    strikes, redials: int
    timer, ping, setup: Timer
    rb: RB

  OnlineHooks* = object
    ## What the app provides. `capture` freezes the solo game and returns
    ## its ROM file and a full state (empty on failure); `make_gba`/`make_gb`
    ## build a core for a ROM file as the app builds its solo one.
    now_ms*: proc(): int64
    log*: proc(s: string)
    capture*: proc(): tuple[rom_path, state: string]
    make_gba*: proc(rom: string): GBA
    make_gb*: proc(rom: string): GB
    started*: proc()                 ## the cores run: present the local one
    ended*: proc()                   ## the session is over: take back the solo core
    remote_pause*: proc(on: bool)
    remote_speed*: proc(on: bool)
    paused*: proc(): bool
    double*: proc(): bool
    away*: proc(): bool

  ReplayMute = ref object
    ## What a local core's dispatch wrapper reads: cursors, so the core's
    ## own closure owns nothing that owns the core (ARC has no cycle
    ## collector). The session fields are cleared before the session goes.
    gba_core {.cursor.}: GBA
    gb_core {.cursor.}: GB
    gba {.cursor.}: gbarb.RollbackSession
    gb {.cursor.}: gbrb.GbRollbackSession

  OnlineLink* = ref object
    hooks*: OnlineHooks
    signal_url*: string
    cache_dir*: string   ## where the friend's ROM goes
    live_path*: string   ## the relaunch goodbye's record
    status*: string
    status_error*: bool
    connecting*: bool
    linked*: bool
    toasts*: seq[string]
    peer_away_at*: int64      ## -1: here
    peer_away_shown*: bool
    reconnecting_since*: int64  ## -1: not reconnecting
    reconnect_away*: bool
    page_id: string
    session: Session
    timers: seq[Timer]
    away_card: Timer
    went_away_at: int64
    # The rollback session, once built
    rb_gba*: gbarb.RollbackSession
    rb_gb*: gbrb.GbRollbackSession
    rb_local*: int
    rb_paths: array[2, string]
    mute: ReplayMute
    resume_give_up*: int

# The network's objects by id, for every link in the process: the event
# queue (rtc_shim.c) is one for all.
var peers_pc, peers_dc: Table[int, Peer]
var sigs: Table[int, Sig]

proc now(ol: OnlineLink): int64 = ol.hooks.now_ms()
proc log(ol: OnlineLink; s: string) =
  if ol.hooks.log != nil: ol.hooks.log("netlink: " & s)

proc random_hex(n: int): string =
  var b = newSeq[byte](n)
  if not urandom(b):
    for i in 0 ..< n: b[i] = byte(rand(255))
  for x in b: result.add toHex(x, 2).toLowerAscii()

proc new_online_link*(hooks: OnlineHooks; cache_dir, live_path: string;
                      signal_url = SIGNAL_URL): OnlineLink =
  randomize()
  OnlineLink(hooks: hooks, signal_url: signal_url, cache_dir: cache_dir,
             live_path: live_path, page_id: random_hex(16),
             peer_away_at: -1, reconnecting_since: -1,
             resume_give_up: RESUME_GIVE_UP)

# ───────────────────────── timers ─────────────────────────

proc schedule(ol: OnlineLink; ms: int; fn: proc()): Timer =
  result = Timer(due: ol.now() + ms, fn: fn)
  ol.timers.add result

proc cancel(t: Timer) =
  if t != nil:
    t.dead = true
    t.fn = nil  # its closure may hold what holds the timer

proc run_timers(ol: OnlineLink) =
  let t = ol.now()
  var due: seq[Timer]
  var keep: seq[Timer]
  for x in ol.timers:
    if x.dead: continue
    if x.due <= t: due.add x else: keep.add x
  ol.timers = keep
  for x in due:
    if not x.dead:
      x.dead = true
      let fn = x.fn
      x.fn = nil
      fn()

# ───────────────────── network objects ─────────────────────

proc new_peer(ol: OnlineLink; offerer: bool): Peer =
  let pc = pc_create(ICE_SERVERS)
  if pc < 0: return nil
  result = Peer(pc: pc, dc: -1, offerer: offerer)
  peers_pc[pc] = result
  if offerer:
    let dc = dc_create(pc, "link")
    if dc < 0:
      peers_pc.del pc
      pc_free(pc)
      return nil
    result.dc = dc
    peers_dc[dc] = result

proc unwire(p: Peer) =
  p.on_desc = nil
  p.on_cand = nil
  p.on_state = nil
  p.on_open = nil
  p.on_closed = nil
  p.on_message = nil
  p.on_low = nil

proc unwire(s: Sig) =
  s.on_open = nil
  s.on_close = nil
  s.on_message = nil

proc close(ol: OnlineLink; p: Peer) =
  if p == nil or p.closed: return
  p.closed = true
  p.unwire()
  peers_pc.del p.pc
  if p.dc >= 0: peers_dc.del p.dc
  dc_free(p.dc)
  pc_free(p.pc)

proc is_open(p: Peer): bool = p != nil and not p.closed and dc_is_open(p.dc)

proc send(p: Peer; data: string): bool =
  p != nil and not p.closed and dc_send(p.dc, data)

proc new_sig(ol: OnlineLink; url = ""): Sig =
  let id = ws_open(if url.len > 0: url else: ol.signal_url)
  result = Sig(id: id)
  if id >= 0: sigs[id] = result
  else: result.done = true

proc send(s: Sig; obj: JsonNode) =
  if s != nil and not s.done: ws_send(s.id, $obj)

proc close(ol: OnlineLink; s: Sig) =
  if s == nil: return
  s.unwire()
  if s.done: return
  s.done = true
  sigs.del s.id
  ws_close(s.id)

proc state_name(a: int): string =
  case a
  of 1: "connecting"
  of RTC_CONNECTED: "connected"
  of RTC_DISCONNECTED: "disconnected"
  of RTC_FAILED: "failed"
  of RTC_CLOSED: "closed"
  else: "new"

proc dispatch(e: NetEvent) =
  case e.kind
  of evWsOpen:
    let s = sigs.getOrDefault(e.id)
    if s != nil and s.on_open != nil: s.on_open()
  of evWsClosed:
    let s = sigs.getOrDefault(e.id)
    if s != nil:
      s.done = true
      sigs.del e.id
      let f = s.on_close
      s.unwire()
      if f != nil: f(e.a == 1)
  of evWsMessage:
    let s = sigs.getOrDefault(e.id)
    if s != nil and s.on_message != nil:
      var j: JsonNode
      try: j = parseJson(e.s1)
      except CatchableError: return
      if j.kind == JObject: s.on_message(j)
  of evLocalDesc:
    let p = peers_pc.getOrDefault(e.id)
    if p != nil and p.on_desc != nil: p.on_desc(e.s1, e.s2)
  of evLocalCand:
    let p = peers_pc.getOrDefault(e.id)
    if p != nil and p.on_cand != nil: p.on_cand(e.s1, e.s2)
  of evState:
    let p = peers_pc.getOrDefault(e.id)
    if p != nil and p.on_state != nil: p.on_state(state_name(e.a))
  of evDataChannel:
    let p = peers_pc.getOrDefault(e.id)
    if p != nil and not p.offerer and p.dc < 0:
      p.dc = e.a
      peers_dc[e.a] = p
  of evDcOpen:
    let p = peers_dc.getOrDefault(e.id)
    if p != nil and p.on_open != nil: p.on_open()
  of evDcClosed:
    let p = peers_dc.getOrDefault(e.id)
    if p != nil and p.on_closed != nil: p.on_closed()
  of evDcMessage:
    let p = peers_dc.getOrDefault(e.id)
    if p != nil and p.on_message != nil: p.on_message(e.data)
  of evDcLow:
    let p = peers_dc.getOrDefault(e.id)
    if p != nil and p.on_low != nil: p.on_low()
  of evHttpDone:
    echo "netlink: goodbye note posted (HTTP ", e.a, ")"
  of evGathering, evNone: discard

# ───────────────────────── helpers ─────────────────────────

proc be32(v: uint32): string =
  result = newString(4)
  result[0] = char(v shr 24)
  result[1] = char((v shr 16) and 0xff)
  result[2] = char((v shr 8) and 0xff)
  result[3] = char(v and 0xff)

proc read32(d: string; at: int): uint32 =
  (uint32(uint8(d[at])) shl 24) or (uint32(uint8(d[at + 1])) shl 16) or
    (uint32(uint8(d[at + 2])) shl 8) or uint32(uint8(d[at + 3]))

proc msg(kind: uint8; rest = ""): string = char(kind) & rest

proc fnv_head(d: string): uint32 =
  ## The first 1 MB's FNV-1a: an older build's whole identity.
  result = 0x811c9dc5'u32
  for i in 0 ..< min(d.len, 1 shl 20):
    result = (result xor uint32(uint8(d[i]))) * 0x01000193'u32

proc rom_identity*(d: string): RomIdentity =
  RomIdentity(len: uint32(d.len), crc: crc32(d), fnv: fnv1a(d))

proc set_status(ol: OnlineLink; text: string; error = false) =
  ol.status = text
  ol.status_error = error
  if error: ol.connecting = false

proc toast(ol: OnlineLink; s: string) = ol.toasts.add s

proc fmt_away*(ms: int64): string =
  let s = ms div 1000
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

# Forward declarations (the flow is a web of callbacks, as in NetLink.swift)
proc fail(ol: OnlineLink; m: string)
proc peer_gone(ol: OnlineLink; m: string)
proc shutdown*(ol: OnlineLink; why = "left")
proc dial(ol: OnlineLink; s: Session)
proc start_rtc(ol: OnlineLink; s: Session)
proc wire(ol: OnlineLink; peer: Peer; s: Session)
proc rb_connect(ol: OnlineLink; s: Session)
proc rb_message(ol: OnlineLink; data: string; s: Session)
proc pump_rom(ol: OnlineLink; s: Session)
proc dropped(ol: OnlineLink; why, end_msg: string)
proc watch_disconnected(ol: OnlineLink; peer: Peer; st: string; s: Session)
proc can_resume(ol: OnlineLink): bool
proc peer_away(ol: OnlineLink; on: bool)
proc clear_peer_away(ol: OnlineLink)
proc send_pause*(ol: OnlineLink; on: bool)
proc start_if_ready(ol: OnlineLink; s: Session)

proc arm(ol: OnlineLink; s: Session; ms: int; fn: proc()) =
  ## One timer per session at a time (dial, rendezvous, redial, pairing).
  s.timer.cancel()
  s.timer = ol.schedule(ms, proc() =
    if ol.session == s: fn())

proc rendezvous(ol: OnlineLink; code: string): JsonNode =
  %*{"t": "rendezvous", "code": code, "id": ol.page_id}

# ───────────────────────── signaling ─────────────────────────

proc redial(ol: OnlineLink; s: Session) =
  let attempt = s.redials
  inc s.redials
  if attempt >= REDIAL_DELAYS.len:
    ol.fail("Couldn't reach the linking server - check your connection")
    return
  ol.set_status("Reconnecting to the linking server...")
  ol.arm(s, REDIAL_DELAYS[attempt], proc() =
    if ol.session == s and s.peer == nil and not s.started: ol.dial(s))

proc rewait(ol: OnlineLink; s: Session; why: string) =
  ## This pairing ended before linking but the friend may still come: drop
  ## it and rendezvous again on the same code (web sigRewait).
  if ol.session != s or s.rtc_connected or s.started: return
  ol.log(why & " - back to waiting")
  ol.close(s.peer)
  s.peer = nil
  s.is_host = -1
  s.sdp_in = false
  s.rewaited = true
  ol.close(s.ws)
  s.ws = nil
  if s.redials >= REDIAL_DELAYS.len:
    ol.fail("Couldn't reach the linking server - check your connection")
    return
  inc s.redials
  ol.set_status("Waiting for your friend...")
  ol.dial(s)

proc rtc_gave_up(ol: OnlineLink; s: Session; why: string) =
  ## Two crossed pairings that never opened are the NAT verdict; otherwise
  ## wait for the friend again.
  if ol.session != s or s.rtc_connected or s.started: return
  if s.sdp_in:
    inc s.strikes
    if s.strikes >= 2:
      ol.fail("Couldn't connect directly to your friend (a strict NAT on one side may be blocking it)")
      return
  ol.rewait(s, why)

proc on_signal(ol: OnlineLink; m: JsonNode; s: Session) =
  s.timer.cancel()  # any reply is proof of life
  s.redials = 0
  case m{"t"}.getStr()
  of "waiting":
    ol.set_status("Waiting for your friend...")
  of "paired":
    s.is_host = if m{"role"}.getStr() == "host": 1 else: 0
    ol.set_status("Friend found - connecting...")
    ol.start_rtc(s)
  of "sdp":
    let d = m{"d"}
    if s.peer == nil or d == nil: return
    s.sdp_in = true
    if not set_remote_description(s.peer.pc, d{"sdp"}.getStr(), d{"type"}.getStr()):
      ol.fail("Connection setup failed")
  of "ice":
    let c = m{"c"}
    if s.peer == nil or c == nil: return
    add_remote_candidate(s.peer.pc, c{"candidate"}.getStr(), c{"sdpMid"}.getStr())
  of "peer-closed":
    if s.rtc_connected: return
    # With the descriptions crossed the friend has most likely linked and
    # left the server a moment before our channel opens.
    if s.sdp_in: return
    ol.rewait(s, "friend left before pairing")
  of "error":
    ol.fail(m{"msg"}.getStr("Connection error"))
  else: discard

proc dial(ol: OnlineLink; s: Session) =
  let ws = ol.new_sig()
  s.ws = ws
  ws.on_open = proc() =
    if ol.session != s or s.ws != ws: return
    ws.send(ol.rendezvous(s.code))
    ol.arm(s, RENDEZVOUS_TIMEOUT, proc() =
      ol.fail("Couldn't connect - the linking server didn't respond"))
  ws.on_close = proc(opened: bool) =
    if ol.session != s or s.ws != ws: return
    s.ws = nil
    if not opened and s.redials == 0 and not s.rewaited:
      ol.fail("Couldn't reach the linking server - check your connection")
      return
    # A drop while waiting: the room died with it, so redial (a linked
    # session no longer needs the server; a pairing in flight is the
    # deadline's to resolve).
    if s.rtc_connected or s.started or s.peer != nil: return
    ol.redial(s)
  ws.on_message = proc(m: JsonNode) =
    if ol.session == s and s.ws == ws: ol.on_signal(m, s)
  if ws.done:
    ol.fail("Couldn't start the connection")
    return
  ol.arm(s, DIAL_TIMEOUT, proc() =
    ol.fail("Couldn't reach the linking server - check your connection"))

proc connect*(ol: OnlineLink; raw_code: string) =
  ## The Link Cable window's Connect.
  if ol.session != nil: ol.shutdown()
  var code = ""
  for c in raw_code.toUpperAscii():
    if c in {'A'..'Z', '0'..'9'} and code.len < CODE_MAX: code.add c
  if code.len < 3:
    ol.set_status("Pick a code of at least 3 letters/numbers", error = true)
    return
  let s = Session(code: code, is_host: -1)
  ol.session = s
  ol.connecting = true
  ol.set_status("Connecting...")
  ol.dial(s)

# ───────────────────────── WebRTC ─────────────────────────

proc start_rtc(ol: OnlineLink; s: Session) =
  let peer = if s.is_host >= 0: ol.new_peer(s.is_host == 1) else: nil
  if peer == nil:
    ol.fail("Couldn't start the connection")
    return
  s.peer = peer
  s.sdp_in = false
  ol.arm(s, RTC_DEADLINE, proc() =
    ol.rtc_gave_up(s, "no link " & $(RTC_DEADLINE div 1000) & " s after pairing"))
  peer.on_desc = proc(sdp, typ: string) =
    s.ws.send(%*{"t": "sdp", "d": {"type": typ, "sdp": sdp}})
  peer.on_cand = proc(cand, mid: string) =
    s.ws.send(%*{"t": "ice", "c": {"candidate": cand, "sdpMid": mid, "sdpMLineIndex": 0}})
  ol.wire(peer, s)

proc wire(ol: OnlineLink; peer: Peer; s: Session) =
  peer.on_state = proc(st: string) =
    if ol.session != s or s.peer != peer: return
    if s.started and ol.can_resume: ol.watch_disconnected(peer, st, s)
    if st == "failed":
      if s.started: ol.dropped("connection failed", "Lost the connection to your friend")
      elif s.rtc_connected: ol.fail("Lost the connection to your friend")
      else: ol.rtc_gave_up(s, "ICE failed")
    elif st == "disconnected" and s.started and ol.can_resume:
      ol.log("connection disconnected - waiting")
    elif st == "disconnected" and s.started and ol.peer_away_at >= 0:
      # A friend who said they're away may be suspended (iPhone Safari);
      # "disconnected" recovers if they wake before "failed".
      ol.log("connection disconnected while the friend is away - waiting")
    elif st == "connected" and s.started and ol.peer_away_at >= 0:
      ol.log("connection back while the friend is away")
    elif (st == "disconnected" or st == "closed") and s.started:
      ol.dropped("connection " & st, "Lost the connection to your friend")
    elif st == "closed" and s.rtc_connected:
      ol.fail("Connection lost during setup")
  peer.on_open = proc() =
    if ol.session != s or s.peer != peer or s.rtc_connected: return
    s.rtc_connected = true
    s.timer.cancel()
    # Linked: closing the socket releases our room on the server.
    ol.close(s.ws)
    s.ws = nil
    ol.set_status("Connected - linking...")
    ol.rb_connect(s)
  peer.on_closed = proc() =
    if ol.session != s or s.peer != peer: return
    if s.started: ol.dropped("channel closed", "Your friend disconnected")
    elif s.rb != nil: ol.fail("Connection lost during setup")
  peer.on_message = proc(data: string) =
    if ol.session == s: ol.rb_message(data, s)
  peer.on_low = proc() =
    if ol.session == s: ol.pump_rom(s)

# ───────────────────────── rollback setup ─────────────────────────

proc send(ol: OnlineLink; s: Session; data: string) =
  discard s.peer.send(data)

proc watch_setup(ol: OnlineLink; s: Session) =
  ## Linked but not started: a friend silent this long has gone (its own
  ## setup failed, or it quit) and nothing else would say so.
  s.setup = ol.schedule(SETUP_CHECK_MS, proc() =
    if ol.session != s or s.started or s.rb == nil: return
    if ol.now() - s.rb.last_msg_at > SETUP_SILENCE_MS:
      ol.fail("Your friend stopped answering - try again")
    else:
      ol.watch_setup(s))

proc rb_connect(ol: OnlineLink; s: Session) =
  let (rom_path, state) = ol.hooks.capture()
  var rom = ""
  if rom_path.len > 0:
    try: rom = readFile(rom_path)
    except CatchableError: discard
  if rom.len == 0 or state.len == 0:
    ol.fail("Couldn't start the session: no game to link")
    return
  let rb = RB(local_player: if s.is_host == 1: 0 else: 1, last_rx: -1,
              pause_reg: Press(host: true), speed_reg: Press(host: true))
  rb.epoch = if s.is_host == 1: uint32(epochTime().int64) else: 0'u32
  rb.ext = rom_path.splitFile().ext.toLowerAscii()
  rb.game_path = rom_path
  rb.rom_bytes = rom
  rb.rom_hash = fnv_head(rom)
  rb.rom_id = rom_identity(rom)
  rb.local_state = state
  rb.last_msg_at = ol.now()
  s.rb = rb
  ol.watch_setup(s)
  ol.set_status("Syncing...")
  ol.send(s, msg(K_HELLO, be32(rb.epoch) & be32(rb.rom_hash) & be32(rb.rom_id.len) &
                          be32(rb.rom_id.crc) & be32(rb.rom_id.fnv)))
  ol.send(s, msg(K_STATE_BEGIN, be32(uint32(state.len))))
  var off = 0
  while off < state.len:
    let e = min(off + CHUNK, state.len)
    ol.send(s, msg(K_STATE_CHUNK, state[off ..< e]))
    off = e

proc show_transfer(ol: OnlineLink; rb: RB) =
  if not rb.need_rom: return
  # The friend's ROM is estimated at ours until its rom-begin lands.
  let total = rb.rom_bytes.len + (if rb.remote_rom_len > 0: rb.remote_rom_len else: rb.rom_bytes.len)
  if total <= 0: return
  let pct = min(100, (rb.rom_sent + rb.rom_buf.len + rb.remote_rom.len) * 100 div total)
  ol.set_status("Transferring games... " & $pct & "%")

proc pump_rom(ol: OnlineLink; s: Session) =
  ## ROM streaming with backpressure (web rbSendRom): chunks while the send
  ## buffer is under the high water, the rest on the low-water callback.
  let rb = s.rb
  if rb == nil or not rb.rom_send_started or s.peer == nil or
     rb.rom_sent >= rb.rom_bytes.len: return
  while rb.rom_sent < rb.rom_bytes.len and dc_buffered(s.peer.dc) <= HIGH_WATER:
    let e = min(rb.rom_sent + CHUNK, rb.rom_bytes.len)
    if not s.peer.send(msg(K_ROM_CHUNK, rb.rom_bytes[rb.rom_sent ..< e])): return
    rb.rom_sent = e
  ol.show_transfer(rb)

proc send_our_rom(ol: OnlineLink; s: Session) =
  let rb = s.rb
  if rb == nil or rb.rom_send_started: return
  rb.rom_send_started = true
  dc_set_low_threshold(s.peer.dc, HIGH_WATER)
  ol.send(s, msg(K_ROM_BEGIN, be32(uint32(rb.rom_bytes.len))))
  ol.pump_rom(s)

proc find_local_rom(ol: OnlineLink; want: RomIdentity; near: string): string =
  ## A ROM in the folder of this player's own that is exactly `want`, or "".
  let t0 = ol.now()
  try:
    for kind, path in walkDir(near.parentDir()):
      if kind notin {pcFile, pcLinkToFile}: continue
      if ol.now() - t0 > LOOKUP_BUDGET_MS: break
      if getFileSize(path) != int64(want.len): continue
      let bytes = readFile(path)
      if rom_identity(bytes) == want: return bytes
  except CatchableError: discard
  ""

proc try_init(ol: OnlineLink; s: Session)

proc answer_rom(ol: OnlineLink; want: RomIdentity; rb: RB; s: Session) =
  let bytes = ol.find_local_rom(want, rb.game_path)
  if bytes.len > 0:
    rb.remote_rom = bytes
    rb.has_remote_rom = true
    rb.remote_rom_len = bytes.len
    ol.log("the friend's game is here - not transferred")
    ol.send(s, msg(K_HAVE_ROM))
  else:
    ol.send(s, msg(K_NEED_ROM))
  ol.show_transfer(rb)

# ───────────────────────── the cores ─────────────────────────

proc rb_active*(ol: OnlineLink): bool = ol.rb_gba != nil or ol.rb_gb != nil

proc local_gba*(ol: OnlineLink): GBA =
  if ol.rb_gba != nil: ol.rb_gba.link.cores[ol.rb_local] else: nil

proc local_gb*(ol: OnlineLink): GB =
  if ol.rb_gb != nil: ol.rb_gb.link.cores[ol.rb_local] else: nil

proc mute_replays(ol: OnlineLink; core: GBA) =
  ## A rolled-back frame was already heard: its re-simulation queues nothing
  ## (the mix itself still runs, so the core stays bit-identical).
  let m = ReplayMute(gba_core: core)
  ol.mute = m
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: EventType) =
    if kind == etAPUSample and m.gba != nil and m.gba.replaying:
      let apu = m.gba_core.apu
      let owned = apu.owns_audio
      apu.owns_audio = false
      orig(kind)
      apu.owns_audio = owned
    else:
      orig(kind)

proc mute_replays(ol: OnlineLink; core: GB) =
  let m = ReplayMute(gb_core: core)
  ol.mute = m
  let orig = core.scheduler.dispatch
  core.scheduler.dispatch = proc(kind: EventType) =
    if kind == etAPUSample and m.gb != nil and m.gb.replaying:
      let apu = m.gb_core.apu
      let owned = apu.owns_audio
      apu.owns_audio = false
      orig(kind)
      apu.owns_audio = owned
    else:
      orig(kind)

proc unmute(ol: OnlineLink) =
  ## Before the session goes: the wrapper (left on the core) passes through.
  if ol.mute != nil:
    ol.mute.gba = nil
    ol.mute.gb = nil
    ol.mute = nil

proc build_cores(ol: OnlineLink; rom0, rom1: string; local: int; epoch: int64): bool =
  ## Both players' cores, the friend's silent. The solo core is the app's
  ## until `started`.
  ol.rb_local = local
  ol.rb_paths = [rom0, rom1]
  try:
    if rom0.splitFile().ext.toLowerAscii() in GB_ROM_EXTS:
      enable_deterministic_gb_rtc(epoch)  # applies to the cart and state loads
      var cores: seq[GB]
      for p in [rom0, rom1]:
        let c = ol.hooks.make_gb(p)
        if c == nil: raise newException(CatchableError, "no core")
        cores.add c
      let rc = cores[1 - local]
      rc.apu.silent = true
      rc.apu.owns_audio = false
      ol.mute_replays(cores[local])
      ol.rb_gb = gbrb.new_gb_rollback_session(new_gb_link(cores), local, PREDICTION_WINDOW)
      ol.mute.gb = ol.rb_gb
    else:
      var cores: seq[GBA]
      for p in [rom0, rom1]:
        let c = ol.hooks.make_gba(p)
        if c == nil: raise newException(CatchableError, "no core")
        c.enable_deterministic_rtc(epoch)
        cores.add c
      let rc = cores[1 - local]
      rc.set_audio_silent(true)
      rc.apu.owns_audio = false
      ol.mute_replays(cores[local])
      ol.rb_gba = gbarb.new_rollback_session(new_link(cores), local, PREDICTION_WINDOW)
      ol.mute.gba = ol.rb_gba
  except CatchableError as e:
    ol.log("couldn't build the cores: " & e.msg)
    ol.unmute()
    ol.rb_gba = nil
    ol.rb_gb = nil
    gbRtcNowOverride = -1
    return false
  true

proc load_core_state(ol: OnlineLink; player: int; image: string; epoch: int64): bool =
  if ol.rb_gb != nil:
    enable_deterministic_gb_rtc(epoch)
    result = ol.rb_gb.link.cores[player].load_state_bytes(image)
  elif ol.rb_gba != nil:
    let core = ol.rb_gba.link.cores[player]
    # The state carries the solo wall clock: the shared one again after.
    result = core.load_state_bytes(image)
    if result: core.enable_deterministic_rtc(epoch)

proc drop_cores(ol: OnlineLink) =
  ## Both battery saves written, the session's cores gone.
  ol.unmute()
  if ol.rb_gba != nil:
    for c in ol.rb_gba.link.cores: c.storage.write_save()
  if ol.rb_gb != nil:
    for c in ol.rb_gb.link.cores: c.cartridge.mbc_save()
    gbRtcNowOverride = -1
  ol.rb_gba = nil
  ol.rb_gb = nil

proc take_solo*(ol: OnlineLink): tuple[gba: GBA, gb: GB] =
  ## Leave the session but keep playing: this player's core, with its
  ## progress, becomes the solo core with the cable unplugged; the friend's
  ## goes. Called by the app from `ended`.
  ol.unmute()
  if ol.rb_gba != nil:
    let c = ol.rb_gba.link.cores[ol.rb_local]
    c.storage.write_save()
    c.set_sio_driver(NullSioDriver())
    result.gba = c
  elif ol.rb_gb != nil:
    let c = ol.rb_gb.link.cores[ol.rb_local]
    c.cartridge.mbc_save()
    gbRtcNowOverride = -1
    c.set_serial_driver(GbSerialDriver())
    result.gb = c
  ol.rb_gba = nil
  ol.rb_gb = nil

proc try_init(ol: OnlineLink; s: Session) =
  ## The friend's hello, state and (cross-game) ROM in hand: build both
  ## cores, load each player's snapshot, say ready.
  let rb = s.rb
  if rb == nil or rb.inited or not rb.remote_hello or not rb.has_remote_state: return
  if rb.need_rom and not rb.has_remote_rom: return
  rb.inited = true
  # This player's core runs on the game's own file (its battery save is the
  # game's); the friend's on a copy in the cache.
  let remote = ol.cache_dir / ("rbrom" & $(1 - rb.local_player) & rb.ext)
  try:
    createDir(ol.cache_dir)
    removeFile(remote)
    removeFile(remote.changeFileExt(".sav"))
    writeFile(remote, if rb.need_rom: rb.remote_rom else: rb.rom_bytes)
  except CatchableError as e:
    ol.fail("Couldn't start the session: " & e.msg)
    return
  let rom0 = if rb.local_player == 0: rb.game_path else: remote
  let rom1 = if rb.local_player == 0: remote else: rb.game_path
  if not ol.build_cores(rom0, rom1, rb.local_player, int64(rb.epoch)):
    ol.fail("Couldn't start the link session")
    return
  let host = if rb.local_player == 0: rb.local_state else: rb.remote_state
  let guest = if rb.local_player == 0: rb.remote_state else: rb.local_state
  if not ol.load_core_state(0, host, int64(rb.epoch)) or
     not ol.load_core_state(1, guest, int64(rb.epoch)):
    ol.drop_cores()
    ol.fail("Couldn't sync game state - are you both on the latest dingbat?")
    return
  rb.local_ready = true
  ol.send(s, msg(K_READY))
  ol.set_status(if rb.need_rom: "Ready - waiting for your friend..." else: "Waiting for your friend...")
  ol.start_if_ready(s)

# ───────────────────────── resume info ─────────────────────────

const RETRY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

proc resume_info_msg(sid: uint32; code: string): string = msg(K_RESUME_INFO, be32(sid) & code)

proc mark_live(ol: OnlineLink; rb: RB) =
  ## A killed app runs nothing, so its friend would redial for the full
  ## 3 minutes: the retry code is kept here while a session that can resume
  ## is up, and a relaunch leaves the goodbye (web rbByeOnRelaunch).
  if rb.resume_code.len == 0 or ol.live_path.len == 0: return
  try:
    createDir(ol.live_path.parentDir())
    writeFile(ol.live_path, $(%*{"code": rb.resume_code, "id": ol.page_id,
                                 "at": epochTime()}))
  except CatchableError: discard

proc clear_live(ol: OnlineLink) =
  if ol.live_path.len > 0:
    try: removeFile(ol.live_path)
    except CatchableError: discard

proc offer_resume(ol: OnlineLink; rb: RB; s: Session) =
  # From the OS's random source: the code is all that guards a resume.
  var b = newSeq[byte](18)
  if not urandom(b):
    for i in 0 ..< b.len: b[i] = byte(rand(255))
  var sid = (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or uint32(b[3])
  if sid == 0: sid = 1
  rb.resume_sid = sid
  rb.resume_code = "RS"
  for i in 0 ..< 14: rb.resume_code.add RETRY_ALPHABET[int(b[4 + i]) mod 32]
  ol.send(s, resume_info_msg(rb.resume_sid, rb.resume_code))
  ol.mark_live(rb)

proc resume_info_in(ol: OnlineLink; data: string; rb: RB; s: Session) =
  if data.len < 8: return
  let sid = read32(data, 1)
  let code = data[5 .. ^1]
  if code.len < 8 or code.len > 32: return
  for c in code:
    if c notin {'A'..'Z', '0'..'9'}: return
  if rb.resume_code.len == 0:  # guest: take it and echo it
    rb.resume_sid = sid
    rb.resume_code = code
    rb.resume_ok = true
    ol.send(s, resume_info_msg(sid, code))
    ol.mark_live(rb)
  elif rb.resume_sid == sid and rb.resume_code == code:
    rb.resume_ok = true  # host: the guest has it

proc schedule_ping(ol: OnlineLink; s: Session) =
  s.ping = ol.schedule(PING_INTERVAL, proc() =
    if ol.session != s: return
    if s.rb != nil and not s.rb.reconnecting: ol.send(s, msg(K_PING))
    ol.schedule_ping(s))

proc start_if_ready(ol: OnlineLink; s: Session) =
  let rb = s.rb
  if rb == nil or not rb.inited or not rb.local_ready or not rb.remote_ready or s.started: return
  s.started = true
  s.setup.cancel()
  ol.linked = true
  ol.connecting = false
  ol.set_status("")
  ol.hooks.started()
  ol.toast(if s.is_host == 1: "Player 2 connected - full speed" else: "Connected - full speed")
  if s.is_host == 1: ol.offer_resume(rb, s)
  ol.schedule_ping(s)
  # The ROMs and states now live in the cores.
  rb.rom_bytes = ""
  rb.remote_rom = ""
  rb.rom_buf = ""
  rb.local_state = ""
  rb.remote_state = ""
  rb.state_buf = ""

# ───────────────────────── presses ─────────────────────────

proc beats(a, b: Press): bool = a.n > b.n or (a.n == b.n and a.host and not b.host)

proc press(ol: OnlineLink; kind: uint8; reg: var Press; on: bool; s: Session) =
  reg = Press(on: on, n: reg.n + 1, host: s.is_host == 1)
  ol.send(s, msg(kind, char(if on: 1 else: 0) & be32(reg.n)))

proc press_in(data: string; reg: var Press; s: Session): bool =
  ## The friend's press: taken only if it beats the one we hold.
  if data.len < 2: return false
  let on = data[1] == '\1'
  if data.len < 6:  # a build before the numbering: the last to arrive wins
    reg.on = on
    return true
  let cand = Press(on: on, n: read32(data, 2), host: s.is_host != 1)
  if not cand.beats(reg): return false
  reg = cand
  true

proc send_speed*(ol: OnlineLink; on: bool) =
  ## 2x and pause drive both sides (a one-sided one just stalls the friend
  ## at the prediction window).
  let s = ol.session
  if s == nil or not s.started or s.rb == nil or s.rb.reconnecting: return
  ol.press(K_SPEED, s.rb.speed_reg, on, s)

proc send_pause*(ol: OnlineLink; on: bool) =
  let s = ol.session
  if s == nil or not s.started or s.rb == nil or s.rb.reconnecting: return
  ol.press(K_PAUSE, s.rb.pause_reg, on, s)

# ───────────────────────── messages ─────────────────────────

proc resume_in(ol: OnlineLink; data: string; rb: RB; s: Session)

proc rb_message(ol: OnlineLink; data: string; s: Session) =
  let rb = s.rb
  if rb == nil or data.len == 0: return
  rb.last_msg_at = ol.now()
  let kind = uint8(data[0])
  case kind
  of K_INPUT:
    if not rb.inited or data.len < 7: return
    let frame = cast[int32](read32(data, 1))
    let bits = (uint16(uint8(data[5])) shl 8) or uint16(uint8(data[6]))
    if frame > rb.last_rx: rb.last_rx = frame
    if frame >= 0:
      if ol.rb_gb != nil: gbrb.feed_remote(ol.rb_gb, int(frame), bits)
      elif ol.rb_gba != nil: gbarb.feed_remote(ol.rb_gba, int(frame), bits)
    return
  of K_RESUME_INFO:
    ol.resume_info_in(data, rb, s)
    return
  of K_RESUME:
    ol.resume_in(data, rb, s)
    return
  of K_PING:
    return
  of K_BYE:
    # Why the friend ended: its own Disconnect, or a failure there
    # (formal/WebState/LinkResume.lean bye_reason_heard).
    rb.bye_in = true
    let gave_up = data.len >= 2 and data[1] == '\1'
    if s.started: ol.peer_gone(if gave_up: "Couldn't reconnect" else: "Your friend disconnected")
    return
  of K_READY:
    rb.remote_ready = true
    ol.start_if_ready(s)
    return
  of K_SPEED:
    if press_in(data, rb.speed_reg, s): ol.hooks.remote_speed(rb.speed_reg.on)
    return
  of K_PAUSE:
    if press_in(data, rb.pause_reg, s): ol.hooks.remote_pause(rb.pause_reg.on)
    return
  of K_HAVE_ROM:
    rb.rom_send_started = true
    rb.rom_sent = rb.rom_bytes.len
    ol.show_transfer(rb)
    return
  of K_NEED_ROM:
    ol.send_our_rom(s)
    return
  of K_AWAY:
    if data.len >= 2: ol.peer_away(data[1] == '\1')
    return
  of K_HELLO:
    if data.len < 9: return
    rb.remote_rom_hash = read32(data, 5)
    if s.is_host != 1: rb.epoch = read32(data, 1)  # the host's clock
    rb.remote_hello = true
    # A friend that names its whole ROM also answers for ours; both sides
    # then compare whole ROMs, an older build the first 1 MB.
    let answers = data.len >= HELLO_LEN
    if answers:
      rb.remote_rom_id = RomIdentity(len: read32(data, 9), crc: read32(data, 13),
                                     fnv: read32(data, 17))
      rb.has_remote_rom_id = true
    if (if answers: rb.remote_rom_id != rb.rom_id else: rb.remote_rom_hash != rb.rom_hash):
      rb.need_rom = true
      ol.show_transfer(rb)
      if answers: ol.answer_rom(rb.remote_rom_id, rb, s) else: ol.send_our_rom(s)
  of K_STATE_BEGIN:
    if data.len < 5: return
    rb.state_len = int(read32(data, 1))
    rb.state_buf = newStringOfCap(rb.state_len)
  of K_STATE_CHUNK:
    rb.state_buf.add data[1 .. ^1]
    if rb.state_buf.len >= rb.state_len:
      rb.remote_state = rb.state_buf
      rb.has_remote_state = true
  of K_ROM_BEGIN:
    if data.len < 5: return
    let n = int(read32(data, 1))
    if n <= 0 or n > ROM_MAX:
      ol.fail("Your friend's game looks invalid - try again")
      return
    rb.remote_rom_len = n
    rb.rom_buf = newStringOfCap(n)
    ol.show_transfer(rb)
  of K_ROM_CHUNK:
    if rb.remote_rom_len <= 0 or rb.has_remote_rom: return
    rb.rom_buf.add data[1 .. ^1]
    ol.show_transfer(rb)
    if rb.rom_buf.len >= rb.remote_rom_len:
      if fnv_head(rb.rom_buf) != rb.remote_rom_hash or
         (rb.has_remote_rom_id and rom_identity(rb.rom_buf) != rb.remote_rom_id):
        ol.fail("Game transfer was corrupted - try again")
        return
      rb.remote_rom = rb.rom_buf
      rb.has_remote_rom = true
      rb.rom_buf = ""
  else:
    return
  ol.try_init(s)

# ───────────────────────── the running session ─────────────────────────

proc log_sent(rb: RB; frame: int32; bits: uint16) =
  let i = rb.sent_count mod SENT_LOG_MAX
  rb.sent_frames[i] = frame
  rb.sent_bits[i] = bits
  inc rb.sent_count

proc send_input_wire(ol: OnlineLink; frame: int32; bits: uint16; s: Session) =
  ol.send(s, msg(K_INPUT, be32(cast[uint32](frame)) & char(bits shr 8) & char(bits and 0xff)))

proc started*(ol: OnlineLink): bool = ol.session != nil and ol.session.started

proc tick*(ol: OnlineLink; local_bits: uint16): int =
  ## One frame with this player's buttons and the friend's predicted ones.
  ## Returns the frame simulated, or -1 when stalled at the prediction
  ## window waiting for the friend.
  let s = ol.session
  if s == nil or not s.started: return -1
  var frame = -1
  if ol.rb_gb != nil:
    if gbrb.tick(ol.rb_gb, local_bits) == grbStalled: return -1
    frame = ol.rb_gb.head - 1
  elif ol.rb_gba != nil:
    if gbarb.tick(ol.rb_gba, local_bits) == rbStalled: return -1
    frame = ol.rb_gba.head - 1
  else:
    return -1
  let rb = s.rb
  log_sent(rb, int32(frame), local_bits)
  if not rb.reconnecting:  # else resent once the friend says what it has
    ol.send_input_wire(int32(frame), local_bits, s)
  frame

proc transfers*(ol: OnlineLink): int =
  ## Transfers on the emulated cable: a linked game keeps it moving.
  if ol.rb_gb != nil: ol.rb_gb.link.transfers
  elif ol.rb_gba != nil: ol.rb_gba.link.transfers
  else: 0

proc reconnecting*(ol: OnlineLink): bool =
  ol.session != nil and ol.session.rb != nil and ol.session.rb.reconnecting

proc checksum*(ol: OnlineLink): uint64 =
  ## Both cores' fingerprint (equal on both sides at the same confirmed
  ## frame, or the link has desynced).
  if ol.rb_gb != nil: gbrb.checksum(ol.rb_gb)
  elif ol.rb_gba != nil: gbarb.checksum(ol.rb_gba)
  else: 0

proc confirmed*(ol: OnlineLink): int =
  if ol.rb_gb != nil: ol.rb_gb.confirmed
  elif ol.rb_gba != nil: ol.rb_gba.confirmed
  else: -1

proc head*(ol: OnlineLink): int =
  if ol.rb_gb != nil: ol.rb_gb.head
  elif ol.rb_gba != nil: ol.rb_gba.head
  else: -1

# ───────────────────────── away ─────────────────────────

proc peer_is_away*(ol: OnlineLink): bool = ol.peer_away_at >= 0

proc went_away*(ol: OnlineLink) =
  ## This window stopped running the game (minimized): the friend waits at
  ## the prediction limit; say so.
  let s = ol.session
  if s == nil or not s.started or ol.went_away_at > 0: return
  ol.went_away_at = max(1'i64, ol.now())
  ol.log("away")
  ol.send(s, msg(K_AWAY, "\1"))
  if s.rb != nil: ol.mark_live(s.rb)

proc came_back*(ol: OnlineLink) =
  let s = ol.session
  if ol.went_away_at <= 0: return
  let away = ol.now() - ol.went_away_at
  ol.went_away_at = 0
  if s == nil or not s.started: return
  ol.send(s, msg(K_AWAY, "\0"))
  ol.log("back after " & fmt_away(away))
  if away >= AWAY_TOAST_AFTER:
    ol.toast("Your game was paused for " & fmt_away(away) & " - your friend waited")

proc peer_away(ol: OnlineLink; on: bool) =
  if on:
    if ol.peer_away_at >= 0: return
    ol.peer_away_at = ol.now()
    ol.log("friend switched away")
    ol.away_card.cancel()
    ol.away_card = ol.schedule(AWAY_CARD_DELAY, proc() = ol.peer_away_shown = true)
    return
  if ol.peer_away_at < 0: return
  let away = ol.now() - ol.peer_away_at
  ol.log("friend back after " & fmt_away(away))
  ol.clear_peer_away()
  if away >= AWAY_TOAST_AFTER: ol.toast("Friend's back - link resumed")

proc clear_peer_away(ol: OnlineLink) =
  ol.away_card.cancel()
  ol.away_card = nil
  ol.peer_away_at = -1
  ol.peer_away_shown = false

# ───────────────────────── resume ─────────────────────────
# A dropped connection needn't end the session: both games are frozen at
# the prediction limit, so the link picks up where it stopped. The host
# deals a retry code and a session id at the start; the guest echoes them.
# On a drop both rendezvous on the retry code, open a new connection and
# swap RESUME: each resends the inputs the other missed, then its pause
# and 2x state, and they play on (web "Resume" in netplay.js).

proc can_resume(ol: OnlineLink): bool =
  let s = ol.session
  s != nil and s.started and s.rb != nil and s.rb.resume_ok and not s.rb.bye_in

proc resume_state*(mine, theirs: uint8): tuple[paused, double: bool] =
  ## The pause and 2x both sides take after a resume, from the two RESUMEs'
  ## flags (1 away, 2 paused, 4 2x): running wins, except that a side
  ## paused and away keeps both paused; slow wins. Symmetric (web
  ## rbResumeState; formal/WebState/LinkResume.lean finalPause).
  let paused_away = proc(f: uint8): bool = (f and 3) == 3
  ((mine and theirs and 2) != 0 or paused_away(mine) or paused_away(theirs),
   (mine and theirs and 4) != 0)

proc rs_detach(ol: OnlineLink; rb: RB; s: Session) =
  ## Let go of the dead or half-made connection: the server socket, the
  ## pairing in flight, an adopted channel, and their timers.
  rb.rs_timer.cancel()
  rb.rs_rewait.cancel()
  rb.disc_timer.cancel()
  ol.close(rb.rs_ws)
  rb.rs_ws = nil
  let a = rb.rs_peer
  let b = s.peer
  rb.rs_peer = nil
  rb.rs_open = false
  rb.rs_sdp_in = false
  rb.rs_early = @[]
  s.peer = nil
  s.rtc_connected = false
  ol.close(a)
  if b != a: ol.close(b)

proc rs_dial(ol: OnlineLink; rb: RB; s: Session)

proc rs_again(ol: OnlineLink; rb: RB; s: Session; why: string; now = false) =
  ## This attempt is over: dial again, backing off within the server's
  ## rendezvous rate, until resumed or given up.
  if ol.session != s or not rb.reconnecting: return
  if ol.now() - rb.reconnect_at > ol.resume_give_up:
    ol.peer_gone("Couldn't reconnect")
    return
  ol.log("redial: " & why)
  ol.rs_detach(rb, s)
  let delay = if now: 0 else: int(min(2000.0 * pow(2.0, float(rb.rs_attempt)), 15000.0))
  if not now: inc rb.rs_attempt
  rb.rs_timer = ol.schedule(delay, proc() = ol.rs_dial(rb, s))

proc rs_stop(ol: OnlineLink; rb: RB) =
  ## Stop redialing (resumed, or ending). An adopted channel stays.
  rb.reconnecting = false
  ol.reconnecting_since = -1
  ol.reconnect_away = false
  rb.give_up.cancel()
  rb.rs_timer.cancel()
  rb.rs_rewait.cancel()
  rb.disc_timer.cancel()
  ol.close(rb.rs_ws)
  rb.rs_ws = nil
  if rb.rs_peer != nil and (ol.session == nil or rb.rs_peer != ol.session.peer):
    ol.close(rb.rs_peer)
  rb.rs_peer = nil

proc begin_resume(ol: OnlineLink; why: string) =
  let s = ol.session
  if s == nil or s.rb == nil: return
  let rb = s.rb
  if rb.reconnecting:
    ol.rs_again(rb, s, why)  # a new channel died before the friend's RESUME
    return
  if ol.now() - rb.last_msg_at > ol.resume_give_up:
    ol.log(why & " after a long silence - the friend has given up")
    ol.peer_gone("Lost the connection to your friend")
    return
  rb.reconnecting = true
  rb.rs_attempt = 0
  rb.reconnect_at = ol.now()
  ol.reconnect_away = ol.peer_away_at >= 0
  ol.reconnecting_since = rb.reconnect_at
  ol.mark_live(rb)
  ol.log(why & " - redialing on the retry code")
  ol.rs_detach(rb, s)
  rb.give_up.cancel()
  rb.give_up = ol.schedule(ol.resume_give_up, proc() =
    if ol.session == s and rb.reconnecting:
      ol.log("no reconnect in time - giving up")
      ol.peer_gone("Couldn't reconnect"))
  ol.rs_dial(rb, s)

proc dropped(ol: OnlineLink; why, end_msg: string) =
  ## The connection is gone: redial if both sides can, else end.
  if ol.can_resume: ol.begin_resume(why)
  else:
    let bye = ol.session != nil and ol.session.rb != nil and ol.session.rb.bye_in
    ol.peer_gone(if bye: "Your friend disconnected" else: end_msg)

proc watch_disconnected(ol: OnlineLink; peer: Peer; st: string; s: Session) =
  ## "disconnected" may recover; past the grace it redials.
  let rb = s.rb
  if rb == nil: return
  rb.disc_timer.cancel()
  rb.disc_timer = nil
  if st != "disconnected": return
  rb.disc_timer = ol.schedule(DISCONNECTED_GRACE, proc() =
    if ol.session == s and s.peer == peer:
      ol.dropped("disconnected for " & $(DISCONNECTED_GRACE div 1000) & " s",
                 "Lost the connection to your friend"))

proc rs_adopt(ol: OnlineLink; rb: RB; s: Session; peer: Peer) =
  ## The new channel is open: it becomes the session's and says what this
  ## side has. Inputs, pause and 2x stay held until the friend's RESUME.
  if s.peer == peer or (rb.rs_peer == peer and rb.rs_open): return
  if ol.session != s or not rb.reconnecting or rb.rs_peer != peer:
    ol.close(peer)
    return
  rb.rs_open = true
  rb.rs_timer.cancel()
  s.peer = peer
  s.rtc_connected = true
  peer.on_state = proc(st: string) =
    if ol.session != s or s.peer != peer: return
    ol.watch_disconnected(peer, st, s)
    if st == "failed" or st == "closed":
      ol.dropped("connection " & st, "Lost the connection to your friend")
    elif st == "disconnected": ol.log("connection disconnected - waiting")
  peer.on_closed = proc() =
    if ol.session == s and s.peer == peer and s.started:
      ol.dropped("channel closed", "Your friend disconnected")
  peer.on_low = proc() =
    if ol.session == s: ol.pump_rom(s)
  rb.rs_timer = ol.schedule(RESUME_ANSWER_DEADLINE, proc() =
    if s.peer == peer and rb.reconnecting: ol.rs_again(rb, s, "no RESUME from the friend"))
  let away = if ol.hooks.away(): 1'u8 else: 0'u8
  let flags = away or (if ol.hooks.paused(): 2'u8 else: 0) or (if ol.hooks.double(): 4'u8 else: 0)
  rb.rs_flags = flags  # the friend decides from these, and so must we
  ol.send(s, msg(K_RESUME, be32(rb.resume_sid) & be32(cast[uint32](rb.last_rx)) & char(flags)))
  ol.log("redial: channel open, last input from the friend " & $rb.last_rx)
  let early = rb.rs_early
  rb.rs_early = @[]
  for d in early: ol.rb_message(d, s)

proc rs_start_rtc(ol: OnlineLink; rb: RB; s: Session; ws: Sig; offerer: bool) =
  let peer = ol.new_peer(offerer)
  if peer == nil:
    ol.rs_again(rb, s, "no peer connection")
    return
  rb.rs_peer = peer
  rb.rs_open = false
  rb.rs_sdp_in = false
  rb.rs_timer.cancel()
  rb.rs_timer = ol.schedule(RESUME_PAIR_DEADLINE, proc() =
    if rb.rs_peer == peer and not rb.rs_open: ol.rs_again(rb, s, "no channel after pairing"))
  peer.on_desc = proc(sdp, typ: string) =
    ws.send(%*{"t": "sdp", "d": {"type": typ, "sdp": sdp}})
  peer.on_cand = proc(cand, mid: string) =
    ws.send(%*{"t": "ice", "c": {"candidate": cand, "sdpMid": mid, "sdpMLineIndex": 0}})
  peer.on_state = proc(st: string) =
    if rb.rs_peer == peer and not rb.rs_open and st == "failed":
      ol.rs_again(rb, s, "ICE failed")
  peer.on_open = proc() = ol.rs_adopt(rb, s, peer)
  # Wired from the start: a message can land before our open.
  peer.on_message = proc(data: string) =
    if ol.session != s: return
    if s.peer == peer: ol.rb_message(data, s)
    elif rb.rs_peer == peer: rb.rs_early.add data

proc rs_dial(ol: OnlineLink; rb: RB; s: Session) =
  ## One rendezvous on the retry code. The socket stays until the friend's
  ## RESUME: leaving at our own open would make the server close the
  ## friend's socket while its channel may still be opening.
  if ol.session != s or not rb.reconnecting: return
  let ws = ol.new_sig()
  rb.rs_ws = ws
  ws.on_open = proc() =
    if ol.session == s and rb.rs_ws == ws: ws.send(ol.rendezvous(rb.resume_code))
  ws.on_close = proc(opened: bool) =
    if rb.rs_ws != ws: return
    if rb.rs_open or rb.rs_sdp_in:
      rb.rs_ws = nil
      return
    ol.rs_again(rb, s, "server socket closed")
  ws.on_message = proc(m: JsonNode) =
    if ol.session != s or rb.rs_ws != ws: return
    case m{"t"}.getStr()
    of "waiting":
      ol.log("redial: waiting for the friend")
      rb.rs_attempt = 0
      rb.rs_rewait.cancel()
      rb.rs_rewait = ol.schedule(REWAIT_INTERVAL, proc() =
        if rb.rs_ws == ws and rb.rs_peer == nil:
          ol.rs_again(rb, s, "still waiting - rendezvous again", now = true))
    of "paired":
      ol.log("redial: paired " & m{"role"}.getStr("?"))
      rb.rs_rewait.cancel()
      ol.rs_start_rtc(rb, s, ws, offerer = m{"role"}.getStr() == "host")
    of "sdp":
      let d = m{"d"}
      if rb.rs_peer == nil or d == nil: return
      rb.rs_sdp_in = true
      if not set_remote_description(rb.rs_peer.pc, d{"sdp"}.getStr(), d{"type"}.getStr()):
        ol.rs_again(rb, s, "bad description")
    of "ice":
      let c = m{"c"}
      if rb.rs_peer == nil or c == nil: return
      add_remote_candidate(rb.rs_peer.pc, c{"candidate"}.getStr(), c{"sdpMid"}.getStr())
    of "peer-closed":
      if not rb.rs_open and not rb.rs_sdp_in: ol.rs_again(rb, s, "friend left the server")
    of "bye":
      # The friend ended the session while the link was down, and left a
      # goodbye on the code.
      rb.bye_in = true
      let gave_up = m{"why"}.getStr() == "gave-up"
      ol.log("redial: the friend " & (if gave_up: "gave up" else: "left"))
      ol.peer_gone(if gave_up: "Couldn't reconnect" else: "Your friend disconnected")
    of "error":
      ol.rs_again(rb, s, "server: " & m{"msg"}.getStr("error"))
    else: discard
  if ws.done: ol.rs_again(rb, s, "no socket")

proc resume_in(ol: OnlineLink; data: string; rb: RB; s: Session) =
  ## The friend's RESUME: resend what it missed (from the log, in order),
  ## take its state, play on. Both sides decide pause and 2x from the same
  ## two RESUMEs (`resume_state`), so they agree without another message.
  if not rb.reconnecting or not rb.rs_open or data.len < 10: return
  if read32(data, 1) != rb.resume_sid:
    ol.peer_gone("Couldn't resume the link")
    return
  let theirs = cast[int32](read32(data, 5))
  let flags = uint8(data[9])
  var gap: seq[int]
  for n in max(0, rb.sent_count - SENT_LOG_MAX) ..< rb.sent_count:
    let i = n mod SENT_LOG_MAX
    if rb.sent_frames[i] > theirs: gap.add i
  if gap.len > 0 and rb.sent_frames[gap[0]] > theirs + 1:
    ol.log("the friend's gap is older than the input log")
    ol.peer_gone("Couldn't resume the link")
    return
  let since = if ol.reconnecting_since >= 0: ol.reconnecting_since else: ol.now()
  ol.rs_stop(rb)
  ol.mark_live(rb)
  for i in gap: ol.send_input_wire(rb.sent_frames[i], rb.sent_bits[i], s)
  ol.log("resumed after " & fmt_away(ol.now() - since) & " (resent " & $gap.len &
         " inputs from frame " & $(theirs + 1) & ")")
  ol.toast("Reconnected - link resumed")
  if (flags and 1) != 0: ol.peer_away(true) else: ol.clear_peer_away()
  let want = resume_state(rb.rs_flags, flags)
  # Presses count again from this decision, which both sides hold as the
  # host's press 0.
  rb.pause_reg = Press(on: want.paused, host: true)
  rb.speed_reg = Press(on: want.double, host: true)
  let paused = ol.hooks.paused()
  if paused != ((rb.rs_flags and 2) != 0):
    # Paused or unpaused after our RESUME went out: newer than that
    # decision; it holds, and goes to the friend like any other.
    if paused != want.paused: ol.send_pause(paused)
  elif paused != want.paused:
    ol.hooks.remote_pause(want.paused)
  if ol.hooks.double() != want.double: ol.hooks.remote_speed(want.double)

# ───────────────────────── goodbyes ─────────────────────────

proc bye_url(ol: OnlineLink): string =
  ## The signaling server's /bye, from its WebSocket URL.
  var u = ol.signal_url
  if u.startsWith("wss://"): u = "https://" & u[6 .. ^1]
  elif u.startsWith("ws://"): u = "http://" & u[5 .. ^1]
  let scheme_end = u.find("://") + 3
  let slash = u.find('/', scheme_end)
  (if slash >= 0: u[0 ..< slash] else: u) & "/bye"

proc post_bye(ol: OnlineLink; code, id, why: string): bool =
  https_post(ol.bye_url(), $(%*{"code": code, "id": id, "why": why})) >= 0

proc leave_note(ol: OnlineLink; rb: RB; why: string): bool {.discardable.} =
  ## The session is ending here and the friend may be redialing: leave a
  ## goodbye on the retry code, so it ends at once instead of after its own
  ## give-up (web rbLeaveNote; formal/WebState/LinkRedial.lean).
  if rb.resume_code.len == 0 or rb.bye_in or rb.note_left: return false
  ol.log("goodbye note on the retry code (" & why & ")")
  if not ol.post_bye(rb.resume_code, ol.page_id, why): return false
  rb.note_left = true
  true

proc bye_on_relaunch*(ol: OnlineLink) =
  ## At launch: the last run's session never ended here.
  if ol.live_path.len == 0 or not fileExists(ol.live_path): return
  var j: JsonNode
  try: j = parseFile(ol.live_path)
  except CatchableError: discard
  ol.clear_live()
  if j == nil or j.kind != JObject: return
  let code = j{"code"}.getStr()
  let id = j{"id"}.getStr()
  let at = j{"at"}.getFloat()
  if code.len == 0 or id.len == 0 or epochTime() - at >= LIVE_MAX_AGE: return
  ol.log("the last session never ended: goodbye note on its retry code")
  discard ol.post_bye(code, id, "left")

proc quitting*(ol: OnlineLink) =
  ## The app is quitting: a deliberate end (BYE), so the friend mustn't
  ## redial, and the goodbye note given a moment: nothing runs after this.
  let s = ol.session
  if s == nil: return
  let noted = s.started and s.rb != nil and s.rb.resume_code.len > 0 and
              not s.rb.bye_in and not s.rb.note_left
  ol.shutdown()
  if noted:
    let t0 = ol.now()
    var e: NetEvent
    block wait:
      while ol.now() - t0 < 1500:
        while poll_event(e):
          dispatch(e)
          if e.kind == evHttpDone: break wait
        os.sleep(10)

# ───────────────────────── endings ─────────────────────────

proc fail(ol: OnlineLink; m: string) =
  ## Setup failed: say why in the window, which stays up for a retry.
  if ol.session != nil and ol.session.started:
    ol.peer_gone(m)
    return
  ol.log(m)
  ol.shutdown()
  ol.set_status(m, error = true)

proc peer_gone(ol: OnlineLink; m: string) =
  ## The friend is gone: this game keeps running with the cable pulled.
  let s = ol.session
  if s == nil: return
  let started = s.started
  ol.log(m)
  ol.shutdown(why = "gave-up")
  if started: ol.toast(m & " - your game keeps running")
  else: ol.set_status(m, error = true)

proc disconnect*(ol: OnlineLink) =
  ## The player's Disconnect (or Cancel before linking).
  let started = ol.started
  ol.log("disconnected by you")
  ol.shutdown()
  ol.set_status("")
  if started: ol.toast("Disconnected")

proc shutdown*(ol: OnlineLink; why = "left") =
  ## End everything. A session that built its cores hands this player's
  ## core back to the app (`ended`). `why` is the goodbye note's reason:
  ## "left" unless the session failed ("gave-up").
  let s = ol.session
  if s == nil:
    ol.connecting = false
    return
  if s.rb != nil:
    ol.rs_stop(s.rb)
    # A deliberate end: the friend mustn't redial. It says why.
    if s.started and not s.rb.bye_in:
      ol.send(s, msg(K_BYE, if why == "gave-up": "\1" else: "\0"))
    if s.started: ol.leave_note(s.rb, why)
    ol.clear_live()
  ol.session = nil
  ol.clear_peer_away()
  s.timer.cancel()
  s.ping.cancel()
  let had_cores = ol.rb_active
  ol.close(s.peer)
  s.peer = nil
  ol.close(s.ws)
  s.ws = nil
  s.setup.cancel()
  s.rb = nil  # the ROMs and states of a setup that never started
  ol.linked = false
  ol.connecting = false
  ol.went_away_at = 0
  if had_cores:
    if s.started: ol.hooks.ended()
    if ol.rb_active: ol.drop_cores()

proc pump_network*() =
  ## Every link's network events, in arrival order.
  var e: NetEvent
  while poll_event(e): dispatch(e)

proc service*(ol: OnlineLink) =
  ## Once per main-loop iteration: network events, then due timers.
  pump_network()
  ol.run_timers()

proc active*(ol: OnlineLink): bool = ol.session != nil

proc debug_drop*(ol: OnlineLink) =
  ## Tests: the connection dies under a running session, as a network
  ## would drop it.
  if ol.started: ol.dropped("connection dropped (test)", "Lost the connection to your friend")
