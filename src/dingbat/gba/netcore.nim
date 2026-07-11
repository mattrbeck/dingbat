# Transport-independent network-link state machine (phases 3a/3b of
# docs/multiplayer.md): the local core runs normally on its own scheduler
# and the remote peer appears through a RemoteSioDriver, with the wire
# protocol from common/linkproto (BGB-style timestamped bounded lead).
#
# This module is the ONE protocol implementation. It never blocks and never
# touches a transport: inbound bytes arrive through `feed`, outbound frames
# accumulate until the transport collects them with `take_outgoing`, and the
# emulated clock advances only inside `try_advance`, which returns instead
# of waiting whenever progress needs the peer. Both transports drive it:
#
#  - native TCP (gba/netlink.nim): a socket pump around feed/take_outgoing,
#    with blocking waits (and a timeout) wrapped around naStalled;
#  - the browser (src/dingbat_wasm.nim): a WebRTC DataChannel bridge in JS
#    feeds/drains around requestAnimationFrame ticks, and naStalled renders
#    a "waiting for peer" indicator while the RAF loop keeps running.
#
# Sync model — neither side ever drives the remote core:
#
#  - Each side free-runs, but never more than NETLINK_LEAD cycles ahead of
#    the newest clock the peer has reported (CLOCK beacons flow at least
#    once per frame and immediately when a side blocks). When a side would
#    exceed the lead its emulated clock STALLS — try_advance keeps
#    returning naStalled — until a newer peer clock arrives.
#  - SIO transfers are anchored to explicit emulated cycles. The initiating
#    unit (multi-mode parent = unit 0, or a normal-mode internal-clock
#    master) sends TRANSFER(clock=S, duration=D, data) and schedules its own
#    completion at S+D through the normal etSerial path — its timing and IRQ
#    are exactly single-core behavior. The responder answers with REPLY once
#    its clock reaches the exchange point; the initiator, if the reply has
#    not arrived when its completion fires, parks the emulated clock at S+D
#    (reply_wait) until the REPLY (or a BYE) shows up in feed — it never
#    free-runs past a pending exchange. Latency therefore slows emulation
#    during link activity but can never desync it.
#  - Responder skew tolerance: the responder can be up to NETLINK_LEAD
#    cycles past S when the TRANSFER arrives (that is what the lead bound
#    permits). It then samples/answers immediately and runs the busy window
#    from its own clock (still D cycles wide), so the games on both sides
#    always observe a hardware-plausible transfer; the two timelines differ
#    by at most the lead. If it is not yet at S, it schedules the exchange
#    for exactly cycle S — identical to the in-process lockstep semantics.
#
# STALL POINTS (frontends surface "waiting for peer" from `stalled`): the
# lead check at the top of try_advance, and the reply_wait park set inside
# the master's sio_complete dispatch. cpu.tick dispatches events after the
# instruction that crossed them, so try_advance observes reply_wait before
# any further instruction runs — the clock freezes at the completion point.
#
# The HELLO handshake is part of the same non-blocking flow: construction
# queues our HELLO, `hello` reports hsWait until the peer's arrives, and
# try_advance refuses to run the core before hsDone.

import ../common/[linkproto, scheduler, util]
import gba

export linkproto

const
  NETLINK_LEAD* = 16384
    ## Default max cycles a side may run past the newest peer clock report
    ## (~1 ms emulated). Right for transports that exchange bytes with
    ## sub-millisecond cadence (the native TCP pump services the socket
    ## every 4096-cycle slice). Bounds the responder's sampling skew.
  NETLINK_LEAD_RAF* = 842688  # 3 × 280896-cycle frames
    ## Lead for transports that only exchange bytes once per display frame
    ## (the browser: JS delivers DataChannel messages between
    ## requestAnimationFrame ticks, never mid-tick). The lead must
    ## comfortably exceed one RAF interval of emulated time (280896 cycles
    ## ≈ 16.7 ms) or it becomes the throttle: with a 1 ms lead each side
    ## may only advance 1 ms of emulated time per real frame (~6% speed).
    ## Three frames absorbs RAF jitter; transfers stay anchored to exact
    ## cycles, so the extra lead adds responder-side sampling skew (bounded
    ## by this constant) but can never desync.
  NETLINK_SLICE = 4096
    ## Local free-run granularity between lead checks: one try_advance
    ## progress step.
  CLOCK_INTERVAL = 4096
    ## Send a CLOCK beacon whenever our clock advanced this far since the
    ## last one (>= once per 280896-cycle frame by construction).

type
  NetPhase = enum
    npIdle
    npMasterWait    # local transfer scheduled; etSerial completes it (may
                    # park in reply_wait for the peer's REPLY)
    npSlaveSample   # etSerial at cycle S: sample SIOMLT_SEND, reply, busy
    npSlaveFinish   # etSerial at exchange end: latch data, busy-clear + IRQ

  HelloState* = enum
    hsWait    ## our HELLO is queued; the peer's has not arrived yet
    hsDone    ## handshake accepted on our side; emulation may run
    hsFailed  ## rejected (either direction) — see hello_error

  NetAdvance* = enum
    naHello     ## handshake incomplete: feed more bytes, don't emulate yet
    naProgress  ## advanced one slice; call again to continue the frame
    naFrame     ## a full video frame just completed
    naStalled   ## emulated clock is parked waiting for the peer

  NetCore* = ref object
    gba*: GBA
    id*: int              # 0 = host/listener (multi-mode unit 0), 1 = joiner
    rom_crc: uint32
    lead: int64           # bounded-lead window (see NETLINK_LEAD*)
    strict_crc: bool      # reject a ROM CRC mismatch (linktest harness);
                          # relaxed mode accepts and sets crc_mismatch
                          # (cross-version Pokémon trades have different
                          # CRCs but are fully link-compatible)
    # Global emulated clock = offset + scheduler.cycles (offset absorbs the
    # per-frame rebase, same discipline as link.nim).
    offset: int64
    dec: LinkDecoder
    outbox: seq[string]   # encoded frames awaiting the transport
    hello*: HelloState
    hello_error*: string
    crc_mismatch*: bool   # relaxed-mode CRC difference; frontends warn
    peer_clock: int64
    peer_mode: uint8      # peer's wire SIO mode from its last CLOCK; 0xFF unknown
    peer_so: bool         # peer's SO output level (normal-mode SI status)
    peer_done*: bool      # peer sent BYE
    last_clock_sent: int64
    # The in-flight exchange (master or slave role per round)
    phase: NetPhase
    round_cycle: int64    # transfer start S (master: ours; slave: from wire)
    round_duration: int
    round_mode: uint8     # wire transfer mode (LINK_MODE_*)
    round_out: uint32     # our sampled outgoing word
    round_in: uint32      # the peer's word
    round_listening: bool # peer was in a compatible mode (REPLY flag)
    got_reply: bool
    # STALL latches. reply_wait: our etSerial completion fired at S+D with
    # no REPLY yet — the clock parks until feed() delivers it. lead_wait:
    # the bounded lead is exceeded (re-checked each try_advance).
    reply_wait: bool
    lead_wait: bool
    # TRANSFERs that arrived while a round was still in flight locally (the
    # peer already started the next one); replayed when phase returns idle.
    pending_transfers: seq[LinkMsg]
    in_frame: bool        # a frame is underway (try_advance is resumable)
    # Stall telemetry for frontends ("waiting for peer") and tests
    stalled*: bool
    stall_count*: int

  RemoteSioDriver* = ref object of SioDriver
    core*: NetCore

# ---------------- clocks & wire helpers ----------------

proc now(nc: NetCore): int64 =
  nc.offset + int64(nc.gba.scheduler.cycles)

proc wire_mode(m: SioMode): uint8 =
  # Wire encoding is fixed by the protocol doc, independent of Nim enum order
  case m
  of smNormal8: LINK_MODE_NORMAL8
  of smNormal32: LINK_MODE_NORMAL32
  of smMulti: LINK_MODE_MULTI
  of smUart: LINK_MODE_UART
  of smGeneralPurpose: LINK_MODE_GPIO
  of smJoyBus: LINK_MODE_JOYBUS

const
  WIRE_MULTI = LINK_MODE_MULTI
  WIRE_NORMAL8 = LINK_MODE_NORMAL8
  WIRE_NORMAL32 = LINK_MODE_NORMAL32

proc peer_in_multi(nc: NetCore): bool = nc.peer_mode == WIRE_MULTI
proc peer_in_normal(nc: NetCore): bool =
  nc.peer_mode == WIRE_NORMAL8 or nc.peer_mode == WIRE_NORMAL32

proc send_msg(nc: NetCore; data: string) =
  nc.outbox.add data

proc take_outgoing*(nc: NetCore): seq[string] =
  ## Hand the queued wire frames (in order) to the transport.
  result = move(nc.outbox)
  nc.outbox = @[]

proc has_outgoing*(nc: NetCore): bool = nc.outbox.len > 0

proc send_clock(nc: NetCore; blocked = false) =
  if nc.peer_done: return  # a finished peer never stalls on our clock
  let serial = nc.gba.serial
  var flags = 0'u8
  if bit(serial.siocnt, 3): flags = flags or LINK_CLOCK_SO
  if blocked: flags = flags or LINK_CLOCK_BLOCKED
  nc.send_msg(encode_clock(nc.now(), wire_mode(serial.sio_mode()), flags))
  nc.last_clock_sent = nc.now()

proc send_bye*(nc: NetCore; reason = LINK_BYE_FINISHED) =
  nc.send_msg(encode_bye(reason))

# ---------------- stall latches ----------------

proc enter_stall(nc: NetCore) =
  if not nc.stalled:
    nc.stalled = true
    inc nc.stall_count

proc exit_stall(nc: NetCore) =
  nc.stalled = false

# ---------------- responder (slave) side ----------------

proc handle_remote_transfer(nc: NetCore; m: LinkMsg)

proc round_idle(nc: NetCore) =
  # A round just finished; if the peer already opened the next one while we
  # were mid-round, service it now.
  nc.phase = npIdle
  if nc.pending_transfers.len > 0:
    let m = nc.pending_transfers[0]
    nc.pending_transfers.delete(0)
    nc.handle_remote_transfer(m)

proc slave_finish(nc: NetCore) =
  ## The exchange point (initiator's S+D, or skew-shifted on our timeline)
  ## on the responding unit.
  let serial = nc.gba.serial
  case nc.round_mode
  of WIRE_MULTI:
    if serial.sio_mode() == smMulti:
      serial.multi_recv[nc.id] = uint16(nc.round_out and 0xFFFF)
      serial.multi_recv[1 - nc.id] = uint16(nc.round_in and 0xFFFF)
      serial.multi_recv[2] = 0xFFFF'u16
      serial.multi_recv[3] = 0xFFFF'u16
    # busy-clear + serial IRQ (if enabled) at the exchange point; if the
    # game switched modes mid-round this still clears the stale busy bit.
    serial.finish_sio_transfer()
  of WIRE_NORMAL8, WIRE_NORMAL32:
    # Normal mode: the whole full-duplex exchange happens at the master's
    # completion cycle (same as link.nim complete_normal): sample our
    # outgoing word now, hand it to the master, latch its word.
    let is32 = nc.round_mode == WIRE_NORMAL32
    let listening = serial.sio_mode() in {smNormal8, smNormal32}
    var mine = 0xFFFFFFFF'u32
    if listening:
      mine = if is32: serial.siodata32 else: uint32(serial.siodata8 and 0xFF)
    nc.send_msg(encode_reply(nc.now(), nc.round_cycle, nc.round_mode,
      (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))
    if listening:
      let started = bit(serial.siocnt, 7)
      if is32:
        serial.siodata32 = nc.round_in
      else:
        serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or
                          uint16(nc.round_in and 0xFF)
      # Per GBATEK the master's clock shifts both registers whether or not
      # the slave started; the slave only gets busy-clear/IRQ if it did.
      if started:
        serial.finish_sio_transfer()
  else:
    discard
  nc.round_idle()

proc slave_sample(nc: NetCore) =
  ## Multi-mode round start on the child: latch our SIOMLT_SEND for the
  ## round, answer the parent, and show busy for the round's duration.
  let serial = nc.gba.serial
  let listening = serial.sio_mode() == smMulti
  var mine = 0xFFFF'u32
  if listening:
    mine = uint32(serial.siodata8)
  nc.round_out = mine
  nc.send_msg(encode_reply(nc.now(), nc.round_cycle, nc.round_mode,
    (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))
  if listening:
    serial.siocnt = serial.siocnt or 0x0080'u16  # children show busy
    nc.phase = npSlaveFinish
    serial.schedule_sio_completion(nc.round_duration)
  else:
    nc.round_idle()

proc immediate_reply(nc: NetCore; m: LinkMsg) =
  # Degenerate overlap (e.g. both units master a normal transfer at once, or
  # we are parked inside our own completion): answer with our current data
  # without touching local transfer state — no core advancement, no deadlock.
  let serial = nc.gba.serial
  var mine = 0xFFFFFFFF'u32
  var listening = false
  case m.mode
  of WIRE_MULTI:
    listening = serial.sio_mode() == smMulti
    mine = if listening: uint32(serial.siodata8) else: 0xFFFF'u32
  of WIRE_NORMAL8, WIRE_NORMAL32:
    listening = serial.sio_mode() in {smNormal8, smNormal32}
    if listening:
      mine = if m.mode == WIRE_NORMAL32: serial.siodata32
             else: uint32(serial.siodata8 and 0xFF)
  else: discard
  nc.send_msg(encode_reply(nc.now(), m.clock, m.mode,
    (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))

proc handle_remote_transfer(nc: NetCore; m: LinkMsg) =
  if nc.phase == npMasterWait:
    # Cross-mastered normal transfers: each side answers the other's
    # TRANSFER directly; both complete with the peer's REPLY.
    nc.immediate_reply(m)
    return
  if nc.phase != npIdle:
    # Still mid-round locally; the peer has already opened the next one.
    # Queue it — round_idle replays it the moment this round closes.
    nc.pending_transfers.add(m)
    return
  nc.round_cycle = m.clock
  nc.round_duration = int(m.duration)
  nc.round_mode = m.mode
  nc.round_in = m.data
  case m.mode
  of WIRE_MULTI:
    let delta = nc.round_cycle - nc.now()
    if delta > 0:
      # We are behind the round's start: sample at exactly cycle S, like the
      # in-process lockstep.
      nc.phase = npSlaveSample
      nc.gba.serial.schedule_sio_completion(int(delta))
    else:
      # Bounded-lead skew: we are already past S. Sample now and run the
      # busy window from our own clock (still `duration` wide).
      nc.slave_sample()
  of WIRE_NORMAL8, WIRE_NORMAL32:
    let delta = (nc.round_cycle + int64(nc.round_duration)) - nc.now()
    nc.phase = npSlaveFinish
    if delta > 0:
      nc.gba.serial.schedule_sio_completion(int(delta))
    else:
      nc.slave_finish()
  else:
    nc.immediate_reply(m)

# ---------------- initiator (master) side ----------------

proc master_start(nc: NetCore; mode: uint8) =
  ## Local start-bit rising edge: open the exchange on the wire and schedule
  ## our own completion through the normal etSerial path, so the initiator's
  ## timing and IRQ are exactly the single-core behavior.
  let serial = nc.gba.serial
  let dur = if mode == WIRE_MULTI: serial.multi_transfer_cycles()
            else: serial.normal_transfer_cycles()
  nc.phase = npMasterWait
  nc.round_cycle = nc.now()
  nc.round_duration = dur
  nc.round_mode = mode
  nc.round_out = case mode
    of WIRE_MULTI: uint32(serial.siodata8)
    of WIRE_NORMAL32: serial.siodata32
    else: uint32(serial.siodata8 and 0xFF)
  nc.round_in = 0xFFFFFFFF'u32
  nc.round_listening = false
  nc.got_reply = false
  nc.send_msg(encode_transfer(nc.round_cycle, uint32(dur), mode, nc.round_out))
  serial.schedule_sio_completion(dur)

proc master_finish(nc: NetCore) =
  ## Latch the exchange on the initiator: runs from its etSerial dispatch
  ## when the REPLY already arrived, or from feed() the moment the REPLY
  ## (or a BYE) lands while the clock is parked in reply_wait at S+D.
  let serial = nc.gba.serial
  let listening = nc.got_reply and nc.round_listening
  case nc.round_mode
  of WIRE_MULTI:
    if serial.sio_mode() == smMulti:
      serial.multi_recv[nc.id] = uint16(nc.round_out and 0xFFFF)
      serial.multi_recv[1 - nc.id] =
        if listening: uint16(nc.round_in and 0xFFFF) else: 0xFFFF'u16
      serial.multi_recv[2] = 0xFFFF'u16
      serial.multi_recv[3] = 0xFFFF'u16
  of WIRE_NORMAL8:
    serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or
      (if listening: uint16(nc.round_in and 0xFF) else: 0x00FF'u16)
  of WIRE_NORMAL32:
    serial.siodata32 = if listening: nc.round_in else: 0xFFFFFFFF'u32
  else:
    discard
  serial.finish_sio_transfer()
  nc.round_idle()

proc master_complete(nc: NetCore) =
  ## Our etSerial fired at S+D. STALL POINT: if the peer's REPLY has not
  ## arrived yet, park the emulated clock right here (reply_wait) until it
  ## does — never free-run past a pending exchange. try_advance sees the
  ## latch before executing anything further.
  if nc.got_reply or nc.peer_done:
    nc.master_finish()
  else:
    nc.send_clock(blocked = true)
    nc.reply_wait = true
    nc.enter_stall()

# ---------------- handshake ----------------

proc reject_hello(nc: NetCore; why: string) =
  nc.send_bye(LINK_BYE_MISMATCH)
  nc.hello = hsFailed
  nc.hello_error = "link refused: " & why

proc handle_hello(nc: NetCore; m: LinkMsg) =
  if m.version != LINKPROTO_VERSION:
    nc.reject_hello("protocol version mismatch (ours " & $LINKPROTO_VERSION &
                    ", peer " & $m.version & ")")
  elif m.system != LINK_SYSTEM_GBA:
    nc.reject_hello("emulated-system mismatch (peer system " & $m.system & ")")
  elif int(m.unit) == nc.id:
    nc.reject_hello("both sides claim unit " & $nc.id &
                    " (one must host, the other join)")
  elif m.rom_crc != nc.rom_crc and nc.strict_crc:
    nc.reject_hello("ROM mismatch (our CRC32 " & $nc.rom_crc & ", peer " &
                    $m.rom_crc & ") — both sides must run the same ROM")
  else:
    nc.crc_mismatch = m.rom_crc != nc.rom_crc
    nc.hello = hsDone
    nc.send_clock()

# ---------------- message dispatch ----------------

proc handle_msg(nc: NetCore; m: LinkMsg) =
  if nc.hello == hsWait:
    case m.kind
    of lmHello:
      nc.handle_hello(m)
    of lmBye:
      nc.hello = hsFailed
      nc.hello_error = "peer refused the link (BYE reason " & $m.flags & ")"
      nc.peer_done = true
    else:
      nc.reject_hello("expected HELLO, got " & $m.kind)
    return
  case m.kind
  of lmClock:
    if m.clock > nc.peer_clock: nc.peer_clock = m.clock
    nc.peer_mode = m.mode
    nc.peer_so = (m.flags and LINK_CLOCK_SO) != 0
  of lmTransfer:
    if m.clock > nc.peer_clock: nc.peer_clock = m.clock
    nc.handle_remote_transfer(m)
  of lmReply:
    if m.clock > nc.peer_clock: nc.peer_clock = m.clock
    if nc.phase == npMasterWait and m.cycle == nc.round_cycle:
      nc.round_in = m.data
      nc.round_listening = (m.flags and LINK_REPLY_LISTENING) != 0
      nc.got_reply = true
      if nc.reply_wait:
        # The clock is parked at S+D waiting for exactly this reply: latch
        # and complete now, at the parked cycle.
        nc.reply_wait = false
        nc.exit_stall()
        nc.master_finish()
    # else: stale reply for an abandoned round; drop it
  of lmBye:
    nc.peer_done = true
    nc.peer_clock = high(int64) shr 2  # never lead-stall on a finished peer
    if nc.reply_wait:
      # No reply is coming; complete as a yanked cable (all-1s data).
      nc.reply_wait = false
      nc.exit_stall()
      nc.master_finish()
  of lmHello:
    discard  # post-handshake HELLO: ignore

proc feed*(nc: NetCore; data: openArray[char]) =
  ## Ingest transport bytes (any chunking) and dispatch every complete
  ## message. Raises LinkProtoError on a corrupt stream.
  nc.dec.feed(data)
  var m: LinkMsg
  while nc.dec.next(m):
    nc.handle_msg(m)

# ---------------- driver methods ----------------

method sio_siocnt_status*(drv: RemoteSioDriver; serial: Serial; mode: SioMode): uint16 =
  let nc = drv.core
  case mode
  of smMulti:
    # GBATEK: SI = 0 parent / 1 child (cable position), SD = 1 when every
    # unit on the bus is ready. The peer's readiness comes from its CLOCK
    # beacons (stale by at most a beacon interval + wire latency).
    var v = uint16(nc.id and 3) shl 4
    if nc.id != 0: v = v or 0x0004'u16
    if nc.peer_in_multi: v = v or 0x0008'u16
    v
  of smNormal8, smNormal32:
    # SI input mirrors the peer's SO output while the peer sits in a normal
    # serial mode (last reported level); otherwise the line floats high.
    if nc.peer_in_normal:
      if nc.peer_so: 0x0004'u16 else: 0x0000'u16
    else:
      0x0004'u16
  else:
    procCall sio_siocnt_status(SioDriver(drv), serial, mode)

method sio_start*(drv: RemoteSioDriver; serial: Serial; mode: SioMode) =
  let nc = drv.core
  case mode
  of smNormal8, smNormal32:
    if bit(serial.siocnt, 0):
      # Internal clock: we are the master and drive the exchange.
      if nc.phase == npIdle:
        nc.master_start(if mode == smNormal32: WIRE_NORMAL32 else: WIRE_NORMAL8)
    # External clock: the transfer runs when the remote master starts one.
  of smMulti:
    if nc.id == 0:
      if nc.phase == npIdle:  # hardware can't restart a round in flight
        nc.master_start(WIRE_MULTI)
    else:
      # Children can't initiate; their start bit is a read-only busy flag.
      serial.siocnt = serial.siocnt and not 0x0080'u16
  else:
    discard

method sio_complete*(drv: RemoteSioDriver; serial: Serial; mode: SioMode) =
  let nc = drv.core
  case nc.phase
  of npMasterWait: nc.master_complete()
  of npSlaveSample: nc.slave_sample()
  of npSlaveFinish: nc.slave_finish()
  of npIdle: serial.finish_sio_transfer()  # stray event (mode switched away)

method sio_mode_changed*(drv: RemoteSioDriver; serial: Serial;
                         old_mode, new_mode: SioMode) =
  # The peer's SD/SI status bits depend on our mode; tell it right away
  # rather than waiting for the next beacon.
  drv.core.send_clock()

# ---------------- the advance loop ----------------

proc try_advance*(nc: NetCore): NetAdvance =
  ## Advance the local core by up to one slice of emulated time, never
  ## blocking. Returns naFrame at each video-frame boundary, naProgress
  ## mid-frame (call again), naStalled with the emulated clock parked on
  ## the peer (feed() unblocks it), or naHello before the handshake is done.
  ## The frame loop is resumable: a stall inside a frame picks the frame
  ## back up on a later call.
  case nc.hello
  of hsWait: return naHello
  of hsFailed: return naHello
  of hsDone: discard
  if nc.reply_wait:
    return naStalled  # parked at S+D inside an exchange; feed() resolves it
  let gba = nc.gba
  if not nc.in_frame:
    gba.cpu.count_cycles = 0
    nc.in_frame = true
  # Bounded lead: we may not run further ahead of the peer's newest clock.
  if not nc.peer_done and nc.now() > nc.peer_clock + nc.lead:
    if not nc.lead_wait:
      nc.lead_wait = true
      nc.enter_stall()
      nc.send_clock(blocked = true)
    return naStalled
  if nc.lead_wait:
    nc.lead_wait = false
    nc.exit_stall()
  if nc.now() - nc.last_clock_sent >= CLOCK_INTERVAL:
    nc.send_clock()
  let target = gba.scheduler.cycles + CycleCount(NETLINK_SLICE)
  while gba.scheduler.cycles < target and not gba.ppu.frame:
    if gba.cpu.halted:
      gba.scheduler.fast_forward()
    else:
      gba.cpu.tick()
    if nc.reply_wait:
      return naStalled  # etSerial parked the clock mid-slice
  if gba.ppu.frame:
    nc.send_clock()
    nc.offset += int64(gba.end_frame())
    nc.in_frame = false
    return naFrame
  naProgress

# ---------------- construction ----------------

proc debug_state*(nc: NetCore): string =
  ## One-line state dump for frontends' diagnostics.
  "hello=" & $nc.hello & " phase=" & $nc.phase & " now=" & $nc.now() &
    " peer_clock=" & $nc.peer_clock & " reply_wait=" & $nc.reply_wait &
    " lead_wait=" & $nc.lead_wait & " got_reply=" & $nc.got_reply &
    " round_cycle=" & $nc.round_cycle & " pending=" & $nc.pending_transfers.len &
    " stalls=" & $nc.stall_count & " peer_mode=" & $nc.peer_mode &
    " peer_done=" & $nc.peer_done

proc new_net_core*(gba: GBA; id: int; rom_crc: uint32;
                   strict_crc = true; lead: int64 = NETLINK_LEAD): NetCore =
  ## Wire a post-init core to the protocol state machine and queue our
  ## HELLO. The transport must then shuttle bytes with feed/take_outgoing;
  ## try_advance reports naHello until the peer's HELLO validates.
  ## id 0 = host/listener = multi-mode unit 0. `lead` is this side's
  ## bounded-lead window — pick it to exceed the transport's byte-exchange
  ## cadence (NETLINK_LEAD for a pumped socket, NETLINK_LEAD_RAF for a
  ## browser RAF loop); the two sides need not agree.
  doAssert id in {0, 1}, "the network link is 2-player: unit id must be 0 or 1"
  result = NetCore(gba: gba, id: id, rom_crc: rom_crc, strict_crc: strict_crc,
                   lead: lead, peer_mode: 0xFF)
  result.send_msg(encode_hello(LINK_SYSTEM_GBA, uint8(id), rom_crc))
  gba.set_sio_driver(RemoteSioDriver(core: result))
