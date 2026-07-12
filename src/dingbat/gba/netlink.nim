# Network link between two dingbat processes (phase 3a of
# docs/multiplayer.md): the local core runs normally on its own scheduler
# and the remote peer appears through a RemoteSioDriver, with the wire
# protocol from common/linkproto (BGB-style timestamped bounded lead).
#
# Sync model — neither side ever drives the remote core:
#
#  - Each side free-runs, but never more than NETLINK_LEAD cycles ahead of
#    the newest clock the peer has reported (CLOCK beacons flow at least
#    once per frame and immediately when a side blocks). When a side would
#    exceed the lead it STALLS its emulated clock — a blocking socket wait
#    with the emulator frozen — until a newer peer clock arrives.
#  - SIO transfers are anchored to explicit emulated cycles. The initiating
#    unit (multi-mode parent = unit 0, or a normal-mode internal-clock
#    master) sends TRANSFER(clock=S, duration=D, data) and schedules its own
#    completion at S+D through the normal etSerial path — its timing and IRQ
#    are exactly single-core behavior. The responder answers with REPLY once
#    its clock reaches the exchange point; the initiator, if the reply has
#    not arrived when its completion fires, STALLS at S+D until it does.
#    Latency therefore slows emulation during link activity but can never
#    desync it.
#  - Responder skew tolerance: the responder can be up to NETLINK_LEAD
#    cycles past S when the TRANSFER arrives (that is what the lead bound
#    permits). It then samples/answers immediately and runs the busy window
#    from its own clock (still D cycles wide), so the games on both sides
#    always observe a hardware-plausible transfer; the two timelines differ
#    by at most the lead. If it is not yet at S, it schedules the exchange
#    for exactly cycle S — identical to the in-process lockstep semantics.
#
# STALL POINTS (frontends will want to surface "waiting for peer"): see
# stall_wait — every blocking wait funnels through it and sets `stalled`.

when defined(emscripten):
  {.error: "netlink needs std/net; the wasm build talks to a browser " &
           "bridge speaking the same linkproto wire format instead".}

import std/[net, nativesockets, monotimes, times, os]
when not defined(windows):
  from std/posix import EAGAIN, EWOULDBLOCK, EINTR, SHUT_WR
  from std/posix as posix import nil
import ../common/[linkproto, scheduler, util]
import gba

export linkproto

const
  NETLINK_LEAD* = 16384
    ## Max cycles a side may run past the newest peer clock report (~1 ms
    ## emulated). Bounds both the responder's sampling skew and the wire
    ## chatter; tune against real-network latency in phase 3b.
  NETLINK_SLICE = 4096
    ## Local free-run granularity between socket pumps / lead checks.
  CLOCK_INTERVAL = 4096
    ## Send a CLOCK beacon whenever our clock advanced this far since the
    ## last one (>= once per 280896-cycle frame by construction).
  STALL_TIMEOUT_MS = 30_000
    ## A single stall longer than this means the peer is gone; give up.
  HELLO_TIMEOUT_MS = 30_000

type
  NetLinkError* = object of CatchableError

  NetPhase = enum
    npIdle
    npMasterWait    # local transfer scheduled; etSerial completes it (may
                    # stall for the peer's REPLY)
    npSlaveSample   # etSerial at cycle S: sample SIOMLT_SEND, reply, busy
    npSlaveFinish   # etSerial at exchange end: latch data, busy-clear + IRQ

  NetLink* = ref object
    gba: GBA
    sock: Socket
    id*: int              # 0 = listener (multi-mode unit 0), 1 = connector
    # Global emulated clock = offset + scheduler.cycles (offset absorbs the
    # per-frame rebase, same discipline as link.nim).
    offset: int64
    dec: LinkDecoder
    peer_clock: int64
    peer_mode: uint8      # peer's wire SIO mode from its last CLOCK; 0xFF unknown
    peer_so: bool         # peer's SO output level (normal-mode SI status)
    peer_done*: bool      # peer sent BYE
    last_clock_sent: int64
    # Outgoing delay queue (--netlink-delay-ms latency simulation). Empty
    # and bypassed when delay_ms == 0.
    delay_ms: int
    outq: seq[tuple[due: MonoTime, data: string]]
    # Bytes released for sending but not yet accepted by the (nonblocking)
    # socket. We must NEVER block in send: with both sides emitting beacons,
    # two blocking sends into full kernel buffers deadlock the pair. Drained
    # opportunistically on every pump/flush.
    wire_out: string
    wire_pos: int
    # The in-flight exchange (master or slave role per round)
    phase: NetPhase
    round_cycle: int64    # transfer start S (master: ours; slave: from wire)
    round_duration: int
    round_mode: uint8     # wire transfer mode (LINK_XFER_*)
    round_out: uint32     # our sampled outgoing word
    round_in: uint32      # the peer's word
    round_listening: bool # peer was in a compatible mode (REPLY flag)
    got_reply: bool
    # TRANSFERs that arrived while a round was still in flight locally (the
    # peer already started the next one); replayed when phase returns idle.
    pending_transfers: seq[LinkMsg]
    # Stall telemetry for frontends ("waiting for peer") and tests
    stalled*: bool
    stall_count*: int

  RemoteSioDriver* = ref object of SioDriver
    link*: NetLink

# ---------------- clocks & wire helpers ----------------

proc now(nl: NetLink): int64 =
  nl.offset + int64(nl.gba.scheduler.cycles)

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

proc peer_in_multi(nl: NetLink): bool = nl.peer_mode == WIRE_MULTI
proc peer_in_normal(nl: NetLink): bool =
  nl.peer_mode == WIRE_NORMAL8 or nl.peer_mode == WIRE_NORMAL32

proc is_transient(err: OSErrorCode): bool =
  when defined(windows):
    err.int32 == 10035  # WSAEWOULDBLOCK
  else:
    err.int32 == EAGAIN.int32 or err.int32 == EWOULDBLOCK.int32

proc try_drain(nl: NetLink) =
  ## Push as much of wire_out into the socket as it will take right now.
  while nl.wire_pos < nl.wire_out.len:
    let n = nl.sock.send(addr nl.wire_out[nl.wire_pos],
                         nl.wire_out.len - nl.wire_pos)
    if n > 0:
      nl.wire_pos += n
    else:
      let err = osLastError()
      when not defined(windows):
        if err.int32 == EINTR.int32: continue
      if err.is_transient(): break  # kernel buffer full; retry on next flush
      raise newException(NetLinkError, "peer connection lost: " & osErrorMsg(err))
  if nl.wire_pos >= nl.wire_out.len:
    nl.wire_out.setLen(0)
    nl.wire_pos = 0
  elif nl.wire_pos > 65536:
    nl.wire_out = nl.wire_out[nl.wire_pos .. ^1]
    nl.wire_pos = 0

proc raw_send(nl: NetLink; data: string) =
  nl.wire_out.add data
  nl.try_drain()

proc flush_outgoing(nl: NetLink) =
  if nl.outq.len > 0:
    let t = getMonoTime()
    var i = 0
    while i < nl.outq.len and nl.outq[i].due <= t:
      nl.wire_out.add nl.outq[i].data
      inc i
    if i > 0:
      nl.outq = nl.outq[i .. ^1]
  nl.try_drain()

proc send_msg(nl: NetLink; data: string) =
  if nl.delay_ms <= 0:
    nl.raw_send(data)
  else:
    nl.outq.add((getMonoTime() + initDuration(milliseconds = nl.delay_ms), data))
    nl.flush_outgoing()

proc send_clock(nl: NetLink; blocked = false) =
  if nl.peer_done: return  # a finished peer never stalls on our clock
  let serial = nl.gba.serial
  var flags = 0'u8
  if bit(serial.siocnt, 3): flags = flags or LINK_CLOCK_SO
  if blocked: flags = flags or LINK_CLOCK_BLOCKED
  nl.send_msg(encode_clock(nl.now(), wire_mode(serial.sio_mode()), flags))
  nl.last_clock_sent = nl.now()

proc send_bye*(nl: NetLink; reason = LINK_BYE_FINISHED) =
  nl.send_msg(encode_bye(reason))

# ---------------- receive pump ----------------

proc poll_socket(nl: NetLink; timeout_ms: int): bool =
  ## Pull whatever bytes are available into the decoder, waiting up to
  ## timeout_ms for the first byte. Returns true if anything arrived.
  ## The per-slice pumps pass timeout_ms == 0 on the (post-handshake)
  ## nonblocking socket, so they skip the select() + fds allocation and let
  ## recv report emptiness via EWOULDBLOCK.
  if timeout_ms > 0:
    var fds = @[nl.sock.getFd()]
    if selectRead(fds, timeout_ms) <= 0: return false
  var buf: array[4096, char]
  let n = nl.sock.recv(addr buf[0], buf.len)
  if n < 0:
    if osLastError().is_transient(): return false  # nothing ready / select race
    raise newException(NetLinkError,
      "peer connection lost: " & osErrorMsg(osLastError()))
  if n == 0:
    if nl.peer_done: return false  # orderly close after BYE
    raise newException(NetLinkError, "peer disconnected")
  nl.dec.feed(buf.toOpenArray(0, n - 1))
  true

proc handle_msg(nl: NetLink; m: LinkMsg)

proc pump(nl: NetLink; timeout_ms = 0) =
  ## Nonblocking (timeout 0) or bounded-wait socket service: flush delayed
  ## sends, ingest bytes, dispatch every complete message.
  nl.flush_outgoing()
  discard nl.poll_socket(timeout_ms)
  var m: LinkMsg
  while nl.dec.next(m):
    nl.handle_msg(m)

# ---------------- stalls ----------------

proc stall_wait(nl: NetLink; ready: proc(): bool) =
  ## STALL POINT: the emulated clock is frozen here until `ready` — every
  ## "waiting for peer" in this module funnels through this proc, and
  ## `stalled` is the flag a frontend would surface to the user.
  if ready(): return
  nl.stalled = true
  inc nl.stall_count
  let deadline = getMonoTime() + initDuration(milliseconds = STALL_TIMEOUT_MS)
  while not ready():
    nl.pump(timeout_ms = 1)
    if getMonoTime() > deadline:
      nl.stalled = false
      raise newException(NetLinkError,
        "stalled waiting for peer for " & $STALL_TIMEOUT_MS & " ms (clock " &
        $nl.now() & ", peer clock " & $nl.peer_clock & ")")
  nl.stalled = false

proc lead_stall(nl: NetLink) =
  # Bounded lead exceeded: report our clock (so the peer can advance) and
  # freeze until the peer catches up enough.
  nl.send_clock(blocked = true)
  nl.stall_wait(proc(): bool =
    nl.peer_done or nl.now() <= nl.peer_clock + NETLINK_LEAD)

# ---------------- responder (slave) side ----------------

proc handle_remote_transfer(nl: NetLink; m: LinkMsg)

proc round_idle(nl: NetLink) =
  # A round just finished; if the peer already opened the next one while we
  # were mid-round, service it now.
  nl.phase = npIdle
  if nl.pending_transfers.len > 0:
    let m = nl.pending_transfers[0]
    nl.pending_transfers.delete(0)
    nl.handle_remote_transfer(m)

proc slave_finish(nl: NetLink) =
  ## The exchange point (initiator's S+D, or skew-shifted on our timeline)
  ## on the responding unit.
  let serial = nl.gba.serial
  case nl.round_mode
  of WIRE_MULTI:
    if serial.sio_mode() == smMulti:
      serial.multi_recv[nl.id] = uint16(nl.round_out and 0xFFFF)
      serial.multi_recv[1 - nl.id] = uint16(nl.round_in and 0xFFFF)
      serial.multi_recv[2] = 0xFFFF'u16
      serial.multi_recv[3] = 0xFFFF'u16
    # busy-clear + serial IRQ (if enabled) at the exchange point; if the
    # game switched modes mid-round this still clears the stale busy bit.
    serial.finish_sio_transfer()
  of WIRE_NORMAL8, WIRE_NORMAL32:
    # Normal mode: the whole full-duplex exchange happens at the master's
    # completion cycle (same as link.nim complete_normal): sample our
    # outgoing word now, hand it to the master, latch its word.
    let is32 = nl.round_mode == WIRE_NORMAL32
    let listening = serial.sio_mode() in {smNormal8, smNormal32}
    var mine = 0xFFFFFFFF'u32
    if listening:
      mine = if is32: serial.siodata32 else: uint32(serial.siodata8 and 0xFF)
    nl.send_msg(encode_reply(nl.now(), nl.round_cycle, nl.round_mode,
      (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))
    if listening:
      let started = bit(serial.siocnt, 7)
      if is32:
        serial.siodata32 = nl.round_in
      else:
        serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or
                          uint16(nl.round_in and 0xFF)
      # Per GBATEK the master's clock shifts both registers whether or not
      # the slave started; the slave only gets busy-clear/IRQ if it did.
      if started:
        serial.finish_sio_transfer()
  else:
    discard
  nl.round_idle()

proc slave_sample(nl: NetLink) =
  ## Multi-mode round start on the child: latch our SIOMLT_SEND for the
  ## round, answer the parent, and show busy for the round's duration.
  let serial = nl.gba.serial
  let listening = serial.sio_mode() == smMulti
  var mine = 0xFFFF'u32
  if listening:
    mine = uint32(serial.siodata8)
  nl.round_out = mine
  nl.send_msg(encode_reply(nl.now(), nl.round_cycle, nl.round_mode,
    (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))
  if listening:
    serial.siocnt = serial.siocnt or 0x0080'u16  # children show busy
    nl.phase = npSlaveFinish
    serial.schedule_sio_completion(nl.round_duration)
  else:
    nl.round_idle()

proc immediate_reply(nl: NetLink; m: LinkMsg) =
  # Degenerate overlap (e.g. both units master a normal transfer at once, or
  # we are stalled inside our own completion): answer with our current data
  # without touching local transfer state — no core advancement, no deadlock.
  let serial = nl.gba.serial
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
  nl.send_msg(encode_reply(nl.now(), m.clock, m.mode,
    (if listening: LINK_REPLY_LISTENING else: 0'u8), mine))

proc handle_remote_transfer(nl: NetLink; m: LinkMsg) =
  if nl.phase == npMasterWait:
    # Cross-mastered normal transfers: each side answers the other's
    # TRANSFER directly; both complete with the peer's REPLY.
    nl.immediate_reply(m)
    return
  if nl.phase != npIdle:
    # Still mid-round locally; the peer has already opened the next one.
    # Queue it — round_idle replays it the moment this round closes.
    nl.pending_transfers.add(m)
    return
  nl.round_cycle = m.clock
  nl.round_duration = int(m.duration)
  nl.round_mode = m.mode
  nl.round_in = m.data
  case m.mode
  of WIRE_MULTI:
    let delta = nl.round_cycle - nl.now()
    if delta > 0:
      # We are behind the round's start: sample at exactly cycle S, like the
      # in-process lockstep.
      nl.phase = npSlaveSample
      nl.gba.serial.schedule_sio_completion(int(delta))
    else:
      # Bounded-lead skew: we are already past S. Sample now and run the
      # busy window from our own clock (still `duration` wide).
      nl.slave_sample()
  of WIRE_NORMAL8, WIRE_NORMAL32:
    let delta = (nl.round_cycle + int64(nl.round_duration)) - nl.now()
    nl.phase = npSlaveFinish
    if delta > 0:
      nl.gba.serial.schedule_sio_completion(int(delta))
    else:
      nl.slave_finish()
  else:
    nl.immediate_reply(m)

# ---------------- initiator (master) side ----------------

proc master_start(nl: NetLink; mode: uint8) =
  ## Local start-bit rising edge: open the exchange on the wire and schedule
  ## our own completion through the normal etSerial path, so the initiator's
  ## timing and IRQ are exactly the single-core behavior.
  let serial = nl.gba.serial
  let dur = if mode == WIRE_MULTI: serial.multi_transfer_cycles()
            else: serial.normal_transfer_cycles()
  nl.phase = npMasterWait
  nl.round_cycle = nl.now()
  nl.round_duration = dur
  nl.round_mode = mode
  nl.round_out = case mode
    of WIRE_MULTI: uint32(serial.siodata8)
    of WIRE_NORMAL32: serial.siodata32
    else: uint32(serial.siodata8 and 0xFF)
  nl.round_in = 0xFFFFFFFF'u32
  nl.round_listening = false
  nl.got_reply = false
  nl.send_msg(encode_transfer(nl.round_cycle, uint32(dur), mode, nl.round_out))
  serial.schedule_sio_completion(dur)

proc master_complete(nl: NetLink) =
  ## Our etSerial fired at S+D. STALL POINT: if the peer's REPLY has not
  ## arrived yet, the emulated clock freezes right here until it does —
  ## never free-run past a pending exchange.
  let serial = nl.gba.serial
  if not nl.got_reply:
    nl.send_clock(blocked = true)
    nl.stall_wait(proc(): bool = nl.got_reply or nl.peer_done)
  let listening = nl.got_reply and nl.round_listening
  case nl.round_mode
  of WIRE_MULTI:
    if serial.sio_mode() == smMulti:
      serial.multi_recv[nl.id] = uint16(nl.round_out and 0xFFFF)
      serial.multi_recv[1 - nl.id] =
        if listening: uint16(nl.round_in and 0xFFFF) else: 0xFFFF'u16
      serial.multi_recv[2] = 0xFFFF'u16
      serial.multi_recv[3] = 0xFFFF'u16
  of WIRE_NORMAL8:
    serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or
      (if listening: uint16(nl.round_in and 0xFF) else: 0x00FF'u16)
  of WIRE_NORMAL32:
    serial.siodata32 = if listening: nl.round_in else: 0xFFFFFFFF'u32
  else:
    discard
  serial.finish_sio_transfer()
  nl.round_idle()

# ---------------- message dispatch ----------------

proc handle_msg(nl: NetLink; m: LinkMsg) =
  case m.kind
  of lmClock:
    if m.clock > nl.peer_clock: nl.peer_clock = m.clock
    nl.peer_mode = m.mode
    nl.peer_so = (m.flags and LINK_CLOCK_SO) != 0
  of lmTransfer:
    if m.clock > nl.peer_clock: nl.peer_clock = m.clock
    nl.handle_remote_transfer(m)
  of lmReply:
    if m.clock > nl.peer_clock: nl.peer_clock = m.clock
    if nl.phase == npMasterWait and m.cycle == nl.round_cycle:
      nl.round_in = m.data
      nl.round_listening = (m.flags and LINK_REPLY_LISTENING) != 0
      nl.got_reply = true
    # else: stale reply for an abandoned round; drop it
  of lmBye:
    nl.peer_done = true
    nl.peer_clock = high(int64) shr 2  # never lead-stall on a finished peer
  of lmHello:
    discard  # post-handshake HELLO: ignore

# ---------------- driver methods ----------------

method sio_siocnt_status*(drv: RemoteSioDriver; serial: Serial; mode: SioMode): uint16 =
  let nl = drv.link
  case mode
  of smMulti:
    # GBATEK: SI = 0 parent / 1 child (cable position), SD = 1 when every
    # unit on the bus is ready. The peer's readiness comes from its CLOCK
    # beacons (stale by at most a beacon interval + wire latency).
    var v = uint16(nl.id and 3) shl 4
    if nl.id != 0: v = v or 0x0004'u16
    if nl.peer_in_multi: v = v or 0x0008'u16
    v
  of smNormal8, smNormal32:
    # SI input mirrors the peer's SO output while the peer sits in a normal
    # serial mode (last reported level); otherwise the line floats high.
    if nl.peer_in_normal:
      if nl.peer_so: 0x0004'u16 else: 0x0000'u16
    else:
      0x0004'u16
  else:
    procCall sio_siocnt_status(SioDriver(drv), serial, mode)

method sio_start*(drv: RemoteSioDriver; serial: Serial; mode: SioMode) =
  let nl = drv.link
  case mode
  of smNormal8, smNormal32:
    if bit(serial.siocnt, 0):
      # Internal clock: we are the master and drive the exchange.
      if nl.phase == npIdle:
        nl.master_start(if mode == smNormal32: WIRE_NORMAL32 else: WIRE_NORMAL8)
    # External clock: the transfer runs when the remote master starts one.
  of smMulti:
    if nl.id == 0:
      if nl.phase == npIdle:  # hardware can't restart a round in flight
        nl.master_start(WIRE_MULTI)
    else:
      # Children can't initiate; their start bit is a read-only busy flag.
      serial.siocnt = serial.siocnt and not 0x0080'u16
  else:
    discard

method sio_complete*(drv: RemoteSioDriver; serial: Serial; mode: SioMode) =
  let nl = drv.link
  case nl.phase
  of npMasterWait: nl.master_complete()
  of npSlaveSample: nl.slave_sample()
  of npSlaveFinish: nl.slave_finish()
  of npIdle: serial.finish_sio_transfer()  # stray event (mode switched away)

method sio_mode_changed*(drv: RemoteSioDriver; serial: Serial;
                         old_mode, new_mode: SioMode) =
  # The peer's SD/SI status bits depend on our mode; tell it right away
  # rather than waiting for the next beacon.
  drv.link.send_clock()

# ---------------- frame loop ----------------

proc step_frame*(nl: NetLink) =
  ## Advance the local core one video frame in bounded slices, servicing the
  ## socket between slices and stalling whenever we would exceed the peer
  ## lead window. This is the netlink counterpart of Link.step_frame.
  let gba = nl.gba
  gba.cpu.count_cycles = 0
  while not gba.ppu.frame:
    nl.pump(0)
    if not nl.peer_done and nl.now() > nl.peer_clock + NETLINK_LEAD:
      nl.lead_stall()  # STALL POINT: we are too far ahead of the peer
    if nl.now() - nl.last_clock_sent >= CLOCK_INTERVAL:
      nl.send_clock()
    let target = gba.scheduler.cycles + CycleCount(NETLINK_SLICE)
    while gba.scheduler.cycles < target and not gba.ppu.frame:
      if gba.cpu.halted:
        gba.scheduler.fast_forward()
      else:
        gba.cpu.tick()
  nl.send_clock()
  nl.offset += int64(gba.end_frame())

# ---------------- construction & handshake ----------------

proc new_net_link*(gba: GBA; sock: Socket; id: int; rom_crc: uint32;
                   delay_ms = 0): NetLink =
  ## Wire a post-init core to a connected TCP socket and perform the HELLO
  ## handshake (blocking, not subject to the artificial delay — it is setup,
  ## not gameplay traffic). id 0 = listener = multi-mode unit 0.
  doAssert id in {0, 1}, "netlink is 2-player: unit id must be 0 or 1"
  sock.setSockOpt(OptNoDelay, true, level = cint(IPPROTO_TCP))
  result = NetLink(gba: gba, sock: sock, id: id, delay_ms: delay_ms,
                   peer_mode: 0xFF)
  result.raw_send(encode_hello(LINK_SYSTEM_GBA, uint8(id), rom_crc))
  var m: LinkMsg
  let deadline = getMonoTime() + initDuration(milliseconds = HELLO_TIMEOUT_MS)
  while not result.dec.next(m):
    discard result.poll_socket(50)
    if getMonoTime() > deadline:
      raise newException(NetLinkError, "timed out waiting for peer HELLO")
  template reject(why: string) =
    result.raw_send(encode_bye(LINK_BYE_MISMATCH))
    raise newException(NetLinkError, "link refused: " & why)
  if m.kind == lmBye:
    raise newException(NetLinkError, "peer refused the link (BYE reason " &
                       $m.flags & ")")
  if m.kind != lmHello: reject("expected HELLO, got " & $m.kind)
  if m.version != LINKPROTO_VERSION:
    reject("protocol version mismatch (ours " & $LINKPROTO_VERSION &
           ", peer " & $m.version & ")")
  if m.system != LINK_SYSTEM_GBA:
    reject("emulated-system mismatch (peer system " & $m.system & ")")
  if int(m.unit) == id:
    reject("both sides claim unit " & $id &
           " (one must listen, the other connect)")
  if m.rom_crc != rom_crc:
    reject("ROM mismatch (our CRC32 " & $rom_crc & ", peer " & $m.rom_crc &
           ") — both sides must run the same ROM")
  # Handshake done (blocking sends were fine for it); from here on sends must
  # never block — see wire_out.
  sock.getFd().setBlocking(false)
  gba.set_sio_driver(RemoteSioDriver(link: result))
  result.send_clock()

proc close*(nl: NetLink) =
  ## Graceful teardown. Flush our remaining bytes (the peer may still need
  ## our final BYE), half-close, then drain the peer until EOF: closing with
  ## unread beacons in the kernel buffer would RST the connection, and an
  ## RST discards receive queues — the peer could lose our BYE.
  let deadline = getMonoTime() + initDuration(milliseconds = 3000)
  while (nl.outq.len > 0 or nl.wire_pos < nl.wire_out.len) and
        getMonoTime() < deadline:
    try:
      nl.flush_outgoing()
    except NetLinkError:
      nl.sock.close()
      return  # peer already gone; nothing left to flush to
    sleep(1)
  when not defined(windows):
    discard posix.shutdown(nl.sock.getFd(), SHUT_WR)
  while getMonoTime() < deadline:
    var fds = @[nl.sock.getFd()]
    if selectRead(fds, 50) <= 0: continue
    var buf: array[4096, char]
    if nl.sock.recv(addr buf[0], buf.len) <= 0: break  # EOF/error: peer gone
  nl.sock.close()
