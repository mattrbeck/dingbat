# Transport-independent network-link state machine (docs/multiplayer.md).
# The remote peer appears through a RemoteSioDriver; the wire protocol is
# common/linkproto (timestamped bounded lead).
#
# Never blocks and never touches a transport: bytes arrive through `feed`,
# outbound frames are collected with `take_outgoing`, and the emulated clock
# advances only inside `try_advance`, which returns naStalled instead of
# waiting. Drivers: native TCP (gba/netlink.nim) and the browser WebRTC
# bridge (src/dingbat_wasm.nim).
#
# Sync model:
#  - Each side free-runs but never more than the lead ahead of the newest
#    clock the peer reported (CLOCK beacons: at least once per frame, and
#    immediately when a side blocks). Past the lead, try_advance stalls.
#  - SIO transfers are anchored to emulated cycles. The initiator sends
#    TRANSFER(clock=S, duration=D, data) and schedules its own completion at
#    S+D through the normal etSerial path. The responder answers REPLY when
#    its clock reaches the exchange point; if the REPLY has not arrived when
#    the initiator's completion fires, its clock parks at S+D (reply_wait)
#    until the REPLY or a BYE lands in feed. Latency slows emulation but
#    cannot desync it.
#  - A responder already past S when the TRANSFER arrives (allowed by the
#    lead bound) samples immediately and runs the D-cycle busy window from
#    its own clock; otherwise it schedules the exchange for exactly S.
#
# cpu.tick dispatches events after the instruction that crossed them, so
# try_advance observes reply_wait before any further instruction runs.
# The HELLO handshake is part of the same flow: `hello` reports hsWait until
# the peer's HELLO arrives, and try_advance refuses to run before hsDone.

import std/deques
import ../common/[linkproto, scheduler, util, input]
import gba

export linkproto

const
  NETLINK_LEAD* = 16384
    ## Max cycles past the newest peer clock report (~1 ms) for transports
    ## that exchange bytes every slice (the TCP pump). Bounds responder skew.
  NETLINK_LEAD_RAF* = 842688  # 3 × 280896-cycle frames
    ## Lead for transports that exchange bytes once per display frame (the
    ## browser delivers DataChannel messages between RAF ticks). Must exceed
    ## one frame of emulated time or it throttles emulation to the lead per
    ## real frame; three frames absorbs RAF jitter.
  NETLINK_SLICE = 4096
    ## Cycles run per try_advance progress step between lead checks.
  CLOCK_INTERVAL = 4096
    ## Send a CLOCK beacon whenever our clock advanced this far.
  FRAME_CYCLES = 280896
  SPEC_WINDOW_FRAMES* = 8
    ## Speculation bound: frames the master may run ahead of the newest
    ## peer-confirmed round before it falls back to the reply_wait stall.
    ## Caps rollback work and checkpoint memory (one state_payload per frame).
  ECHO_MAX = 4
    ## Saturating cap on the per-mode "responder mirrors us" counter.
  ECHO_CONFIRM = 2
    ## Predict our own outgoing word once the responder has echoed us this
    ## many rounds (the symmetric Cable Club sync).

type
  NetPhase = enum
    npIdle
    npMasterWait    # local transfer scheduled; etSerial completes it
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

  RoundEntry = object
    ## A completed master round since `confirmed_cycle`; replayed during a
    ## rollback and confirmed/corrected against arriving REPLYs.
    cycle: int64          # transfer start S (the round's key)
    mode: uint8
    peer_data: uint32     # the peer word we latched (predicted or real)
    listening: bool       # peer-was-listening flag we latched
    out_word: uint32      # our outgoing word (for the no-divergence check)
    predicted: bool       # latched from predict() (needs a REPLY to confirm)
    confirmed: bool        # the real REPLY has validated this round

  NetSnapshot = object
    ## Round state at a checkpoint, restored alongside the core's
    ## state_payload on rollback.
    phase: NetPhase
    round_cycle: int64
    round_duration: int
    round_mode: uint8
    round_out: uint32
    round_in: uint32
    round_listening: bool
    round_predicted: bool
    got_reply: bool
    reply_wait: bool
    pending_transfers: seq[LinkMsg]
    multi_recv: array[4, uint16]  # SIOMULTI0-3 latches: not in state_payload,
                                  # but a replay can read them before the
                                  # frame's round re-latches (link.nim too)

  Checkpoint = object
    cycle: int64          # now() at this frame boundary
    payload: string       # gba.state_payload() (frame-boundary only)
    snap: NetSnapshot

  InputEvent = object
    cycle: int64
    input: Input
    pressed: bool

  NetCore* = ref object
    gba*: GBA
    id*: int              # 0 = host/listener (multi-mode unit 0), 1 = joiner
    rom_crc: uint32
    lead: int64           # bounded-lead window while the link is idle
    lead_active: int64    # tighter bound while a link SIO mode is active:
                          # games sample SIOMULTI at explicit cycles and
                          # tolerate little skew, so the wide idle lead must
                          # tighten or the handshake never converges
    strict_crc: bool      # reject a ROM CRC mismatch; relaxed mode sets
                          # crc_mismatch (cross-version trades link fine)
    offset: int64         # global clock = offset + scheduler.cycles
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
    reply_wait: bool      # completion fired at S+D with no REPLY: clock parked
    lead_wait: bool       # bounded lead exceeded
    # TRANSFERs that arrived mid-round; replayed when phase returns idle.
    pending_transfers: seq[LinkMsg]
    in_frame: bool        # a frame is underway (try_advance is resumable)
    stalled*: bool        # "waiting for peer" telemetry
    stall_count*: int
    # ---- speculative execution (GGPO-style rollback) ----
    speculative: bool     # OFF: everything below is inert
    window_cycles: int64  # bound on how far ahead of confirmed we may run
    has_mastered: bool    # this side initiates transfers (widens its lead)
    round_predicted: bool # the in-flight round's completion was a prediction
    replaying: bool       # inside rollback re-emulation (suppress the outbox)
    replay_cursor: int    # next round_log index to re-supply during replay
    confirmed_cycle: int64# rounds up to here are confirmed by the peer
    checkpoints: Deque[Checkpoint]  # one frame-boundary snapshot per frame
    round_log: seq[RoundEntry]      # rounds latched since confirmed_cycle
    input_log: seq[InputEvent]      # host keypresses since confirmed_cycle
    # Indexed by `int(mode) and 7`: sized to the full mask so a corrupt wire
    # mode can never index out of bounds (unchecked under -d:danger).
    last_reply: array[8, tuple[word: uint32, listening: bool]]  # predictor state
    echo_predict: bool    # echo-aware predictor (default on; bench hook flips it)
    peer_echo: array[8, int]  # per-mode saturating "responder mirrors us" count
    window_wait: bool     # parked because the speculation window is full
    force_wrong: int      # test hook: mispredict the next N rounds
    pred_hits*, pred_misses*, rollbacks*: int  # telemetry
    replay_cycles*: int64 # total cycles re-emulated by rollbacks
    replay_overrun*: int  # times replay ran past the log (lossy idle-latch fallback)

  RemoteSioDriver* = ref object of SioDriver
    core*: NetCore

# ---------------- clocks & wire helpers ----------------

proc now(nc: NetCore): int64 =
  nc.offset + int64(nc.gba.scheduler.cycles)

proc wire_mode(m: SioMode): uint8 =
  # Wire encoding is fixed by the protocol, independent of Nim enum order
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

proc effective_lead(nc: NetCore): int64 =
  ## The tight lead applies whenever either side is in a link SIO mode; the
  ## wide idle lead otherwise. A speculating master may instead run a whole
  ## window ahead (rollback repairs divergence); the responder keeps the
  ## tight lead so it samples each transfer near its anchor cycle.
  if nc.speculative and nc.has_mastered:
    return nc.window_cycles + int64(FRAME_CYCLES)
  if nc.gba.serial.sio_mode() in {smMulti, smNormal8, smNormal32} or
     nc.peer_in_multi or nc.peer_in_normal:
    min(nc.lead, nc.lead_active)
  else:
    nc.lead

proc send_msg(nc: NetCore; data: string) =
  # Replay must not re-send: every outgoing frame went out on the original
  # pass (only the peer's word was mispredicted, which is local latching).
  if nc.replaying: return
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

# ---------------- speculation: prediction & round log ----------------

proc predict(nc: NetCore; mode: uint8): tuple[word: uint32, listening: bool] =
  ## Guess the responder's next REPLY for `mode`: our own outgoing word once
  ## the responder has mirrored us for ECHO_CONFIRM rounds (the symmetric
  ## Cable Club "all players ready" sync, where "same as last" mispredicts on
  ## every word change), else the word it last sent.
  let idx = int(mode) and 7
  if nc.force_wrong > 0:
    dec nc.force_wrong
    return (0xDEAD0000'u32 or uint32(nc.pred_hits + nc.pred_misses), true)
  if nc.echo_predict and nc.peer_echo[idx] >= ECHO_CONFIRM:
    return (nc.round_out, nc.last_reply[idx].listening)
  nc.last_reply[idx]

proc note_reply(nc: NetCore; mode: uint8; word: uint32; listening: bool;
                our_word: uint32) =
  ## Record the peer's real word and whether it mirrored our output.
  let idx = int(mode) and 7
  nc.last_reply[idx] = (word, listening)
  if word == our_word:
    nc.peer_echo[idx] = min(nc.peer_echo[idx] + 1, ECHO_MAX)
  else:
    nc.peer_echo[idx] = max(nc.peer_echo[idx] - 1, 0)

proc log_round(nc: NetCore) =
  ## Append the just-completed master round (live pass only).
  nc.round_log.add RoundEntry(
    cycle: nc.round_cycle, mode: nc.round_mode,
    peer_data: nc.round_in, listening: nc.round_listening,
    out_word: nc.round_out, predicted: nc.round_predicted,
    confirmed: not nc.round_predicted)

proc replay_round(nc: NetCore; cycle: int64): int =
  ## Index of the logged round starting at `cycle` (−1 if none).
  for i in 0 ..< nc.round_log.len:
    if nc.round_log[i].cycle == cycle: return i
  -1

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
  # Service a TRANSFER the peer opened while we were mid-round.
  nc.phase = npIdle
  if nc.pending_transfers.len > 0:
    let m = nc.pending_transfers[0]
    nc.pending_transfers.delete(0)
    nc.handle_remote_transfer(m)

proc slave_finish(nc: NetCore) =
  ## The exchange point on the responding unit.
  let serial = nc.gba.serial
  case nc.round_mode
  of WIRE_MULTI:
    if serial.sio_mode() == smMulti:
      serial.multi_recv[nc.id] = uint16(nc.round_out and 0xFFFF)
      serial.multi_recv[1 - nc.id] = uint16(nc.round_in and 0xFFFF)
      serial.multi_recv[2] = 0xFFFF'u16
      serial.multi_recv[3] = 0xFFFF'u16
    # Also clears a stale busy bit if the game switched modes mid-round.
    serial.finish_sio_transfer()
  of WIRE_NORMAL8, WIRE_NORMAL32:
    # The whole full-duplex exchange happens at the master's completion
    # cycle (as in link.nim complete_normal).
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
      # GBATEK: the master's clock shifts both registers whether or not the
      # slave started; the slave only gets busy-clear/IRQ if it did.
      if started:
        serial.finish_sio_transfer()
  else:
    discard
  nc.round_idle()

proc slave_sample(nc: NetCore) =
  ## Multi-mode round start on the child: latch SIOMLT_SEND, answer the
  ## parent, show busy for the round's duration.
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
  # Degenerate overlap (both units mastering at once, or we are parked in
  # our own completion): answer with current data, touch no transfer state.
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
    # Cross-mastered transfers: each side answers the other's directly.
    nc.immediate_reply(m)
    return
  if nc.phase != npIdle:
    nc.pending_transfers.add(m)  # round_idle replays it
    return
  nc.round_cycle = m.clock
  nc.round_duration = int(m.duration)
  nc.round_mode = m.mode
  nc.round_in = m.data
  case m.mode
  of WIRE_MULTI:
    let delta = nc.round_cycle - nc.now()
    if delta > 0:
      nc.phase = npSlaveSample  # sample at exactly cycle S
      nc.gba.serial.schedule_sio_completion(int(delta))
    else:
      nc.slave_sample()  # already past S: sample now, busy from our clock
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
  ## Local start-bit rising edge: send TRANSFER and schedule our own
  ## completion through the normal etSerial path.
  let serial = nc.gba.serial
  let dur = if mode == WIRE_MULTI: serial.multi_transfer_cycles()
            else: serial.normal_transfer_cycles()
  nc.has_mastered = true  # initiators get the speculative lead
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
  ## Latch the exchange on the initiator. `round_in`/`round_listening` hold
  ## the word being latched (real, predicted or replayed).
  let serial = nc.gba.serial
  let listening = nc.round_listening
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
  if nc.speculative and not nc.replaying:
    nc.log_round()
  nc.round_idle()

proc replay_master_complete(nc: NetCore) =
  ## Re-emulation reached a round's completion: re-supply the logged word.
  ## The log is consumed by cursor, not by cycle: a checkpoint restore
  ## reproduces frame-boundary state exactly but round cycles can drift by a
  ## few cycles, while their order and data cannot.
  if nc.replay_cursor >= nc.round_log.len:
    # More rounds re-fired than were logged: corrected peer data changed
    # local control flow. Latch an idle line so it is at least deterministic.
    inc nc.replay_overrun
    nc.round_in = 0xFFFFFFFF'u32
    nc.round_listening = false
    nc.round_predicted = true
    nc.master_finish()
    return
  let e = nc.round_log[nc.replay_cursor]
  inc nc.replay_cursor
  # A corrected peer word must not have changed our own outgoing word (that
  # TRANSFER was already sent).
  doAssert nc.round_out == e.out_word,
    "speculation divergence: replayed round outgoing word changed (" &
    $nc.round_out & " vs logged " & $e.out_word & ")"
  nc.round_in = e.peer_data
  nc.round_listening = e.listening
  nc.round_predicted = e.predicted
  nc.master_finish()

proc master_complete(nc: NetCore) =
  ## Our etSerial fired at S+D.
  if nc.replaying:
    nc.replay_master_complete()
    return
  if nc.got_reply or nc.peer_done:
    nc.round_predicted = false
    nc.master_finish()
  elif nc.speculative and nc.now() - nc.confirmed_cycle <= nc.window_cycles:
    # Predict the peer's word and keep emulating; the real REPLY confirms it
    # or forces a rollback when it lands in feed().
    let p = nc.predict(nc.round_mode)
    nc.round_in = p.word
    nc.round_listening = p.listening
    nc.round_predicted = true
    nc.master_finish()
  else:
    # Park the clock until the REPLY (or BYE) arrives.
    nc.send_clock(blocked = true)
    nc.reply_wait = true
    nc.enter_stall()

# ---------------- speculation: checkpoints & rollback ----------------

proc capture_snapshot(nc: NetCore): NetSnapshot =
  NetSnapshot(phase: nc.phase, round_cycle: nc.round_cycle,
    round_duration: nc.round_duration, round_mode: nc.round_mode,
    round_out: nc.round_out, round_in: nc.round_in,
    round_listening: nc.round_listening, round_predicted: nc.round_predicted,
    got_reply: nc.got_reply, reply_wait: nc.reply_wait,
    pending_transfers: nc.pending_transfers,
    multi_recv: nc.gba.serial.multi_recv)

proc restore_snapshot(nc: NetCore; s: NetSnapshot) =
  nc.phase = s.phase
  nc.round_cycle = s.round_cycle
  nc.round_duration = s.round_duration
  nc.round_mode = s.round_mode
  nc.round_out = s.round_out
  nc.round_in = s.round_in
  nc.round_listening = s.round_listening
  nc.round_predicted = s.round_predicted
  nc.got_reply = s.got_reply
  nc.reply_wait = s.reply_wait
  nc.pending_transfers = s.pending_transfers
  nc.gba.serial.multi_recv = s.multi_recv

proc take_checkpoint(nc: NetCore) =
  ## Frame-boundary snapshot of the core plus our round state.
  nc.checkpoints.addLast Checkpoint(cycle: nc.now(),
    payload: nc.gba.state_payload(), snap: nc.capture_snapshot())

proc replay_start(cp: Checkpoint): int64 =
  ## Earliest round start a rollback to this checkpoint can re-fire: a round
  ## in flight at the checkpoint re-completes first, so its start is the
  ## low-water mark. Seeds the replay cursor and bounds log retention; the
  ## two must agree or replay re-fires a round with no log entry.
  if cp.snap.phase == npMasterWait: cp.snap.round_cycle else: cp.cycle

proc advance_confirmed(nc: NetCore) =
  ## Recompute confirmed_cycle (start of the oldest unconfirmed round, or
  ## now()) and drop checkpoints/log entries the window no longer needs.
  var first_unconfirmed = high(int64)
  for e in nc.round_log:
    if not e.confirmed and e.cycle < first_unconfirmed:
      first_unconfirmed = e.cycle
  # A round in flight (not yet logged) can still demand a rollback to before
  # its start, which may precede the frame boundary just checkpointed; it
  # must bound confirmed_cycle or its checkpoint gets pruned.
  if nc.phase == npMasterWait and nc.round_cycle < first_unconfirmed:
    first_unconfirmed = nc.round_cycle
  nc.confirmed_cycle =
    if first_unconfirmed == high(int64): nc.now() else: first_unconfirmed
  # Keep the newest checkpoint at/before confirmed_cycle as the baseline.
  while nc.checkpoints.len >= 2 and nc.checkpoints[1].cycle <= nc.confirmed_cycle:
    nc.checkpoints.popFirst()
  if nc.checkpoints.len > 0:
    # Retain the log back to the oldest checkpoint's replay-start, not its
    # cycle: a round straddling it re-fires on a rollback there.
    let baseline = replay_start(nc.checkpoints[0])
    var kept: seq[RoundEntry] = @[]
    for e in nc.round_log:
      if e.cycle >= baseline: kept.add e
    nc.round_log = kept
    if nc.input_log.len > 0:
      var ins: seq[InputEvent] = @[]
      for ev in nc.input_log:
        if ev.cycle >= baseline: ins.add ev
      nc.input_log = ins

proc rollback_and_replay(nc: NetCore; from_cycle: int64) =
  ## Restore the newest checkpoint at/before `from_cycle` and re-emulate to
  ## the current clock, re-supplying each logged round's corrected peer word
  ## and replaying host input. The outbox is suppressed throughout.
  let target = nc.now()
  var ci = -1
  for i in countdown(nc.checkpoints.len - 1, 0):
    if nc.checkpoints[i].cycle <= from_cycle:
      ci = i; break
  doAssert ci >= 0, "rollback: no checkpoint at/before cycle " & $from_cycle
  let cp = nc.checkpoints[ci]
  nc.replay_cycles += target - cp.cycle
  while nc.checkpoints.len > ci + 1: discard nc.checkpoints.popLast()
  nc.gba.apply_state_payload(cp.payload)
  nc.offset = cp.cycle - int64(nc.gba.scheduler.cycles)
  nc.restore_snapshot(cp.snap)
  # Cursor at the first round that re-fires (see replay_start).
  let start_cycle = replay_start(cp)
  nc.replay_cursor = 0
  while nc.replay_cursor < nc.round_log.len and
        nc.round_log[nc.replay_cursor].cycle < start_cycle:
    inc nc.replay_cursor
  nc.replaying = true
  let gba = nc.gba
  var iput = 0
  while iput < nc.input_log.len and nc.input_log[iput].cycle < nc.now():
    inc iput  # inputs already baked into the checkpoint
  while nc.now() < target:
    while iput < nc.input_log.len and nc.input_log[iput].cycle <= nc.now():
      gba.handle_input(nc.input_log[iput].input, nc.input_log[iput].pressed)
      inc iput
    if gba.cpu.halted:
      gba.scheduler.fast_forward()
    else:
      gba.cpu.tick()
    if gba.ppu.frame > 0:
      nc.offset += int64(gba.end_frame())
      nc.take_checkpoint()  # regenerate this frame's corrected checkpoint
  nc.replaying = false

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
    let listening = (m.flags and LINK_REPLY_LISTENING) != 0
    if nc.speculative:
      let idx = nc.replay_round(m.cycle)
      let our_word = if idx >= 0: nc.round_log[idx].out_word else: nc.round_out
      nc.note_reply(m.mode, m.data, listening, our_word)
      if idx >= 0 and not nc.round_log[idx].confirmed:
        if not nc.round_log[idx].predicted:
          nc.round_log[idx].confirmed = true  # was latched from a real reply
        elif nc.round_log[idx].peer_data == m.data and
             nc.round_log[idx].listening == listening:
          nc.round_log[idx].confirmed = true
          inc nc.pred_hits
        else:
          # Misprediction: correct the log and re-emulate from there.
          inc nc.pred_misses
          inc nc.rollbacks
          nc.round_log[idx].peer_data = m.data
          nc.round_log[idx].listening = listening
          nc.round_log[idx].predicted = false
          nc.round_log[idx].confirmed = true
          nc.rollback_and_replay(m.cycle)
        nc.advance_confirmed()
        return
      # idx < 0: reply for the still-in-flight round (beat S+D); fall through.
    if nc.phase == npMasterWait and m.cycle == nc.round_cycle:
      nc.round_in = m.data
      nc.round_listening = listening
      nc.got_reply = true
      if nc.reply_wait:
        # Parked at S+D for exactly this reply: complete at the parked cycle.
        nc.reply_wait = false
        nc.exit_stall()
        nc.round_predicted = false
        nc.master_finish()
        if nc.speculative: nc.advance_confirmed()
    # else: stale reply for an abandoned round; drop it
  of lmBye:
    nc.peer_done = true
    nc.peer_clock = high(int64) shr 2  # never lead-stall on a finished peer
    if nc.reply_wait:
      # No reply is coming; complete as a yanked cable (all-1s data).
      nc.reply_wait = false
      nc.exit_stall()
      nc.round_predicted = false
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
    # GBATEK: SI = 0 parent / 1 child, SD = 1 when every unit is ready. The
    # peer's readiness comes from its CLOCK beacons.
    var v = uint16(nc.id and 3) shl 4
    if nc.id != 0: v = v or 0x0004'u16
    if nc.peer_in_multi: v = v or 0x0008'u16
    v
  of smNormal8, smNormal32:
    # SI = the peer's last reported SO while it is in a normal mode; else high.
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
    if bit(serial.siocnt, 0):  # internal clock: we are the master
      if nc.phase == npIdle:
        nc.master_start(if mode == smNormal32: WIRE_NORMAL32 else: WIRE_NORMAL8)
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
  # The peer's SD/SI status bits depend on our mode; tell it right away.
  drv.core.send_clock()

# ---------------- the advance loop ----------------

proc try_advance*(nc: NetCore): NetAdvance =
  ## Advance the local core by up to one slice, never blocking: naFrame at a
  ## frame boundary, naProgress mid-frame, naStalled with the clock parked on
  ## the peer (feed() unblocks it), naHello before the handshake is done.
  ## A stall inside a frame resumes that frame on a later call.
  case nc.hello
  of hsWait: return naHello
  of hsFailed: return naHello
  of hsDone: discard
  if nc.reply_wait:
    return naStalled  # parked at S+D inside an exchange; feed() resolves it
  let gba = nc.gba
  if not nc.in_frame:
    gba.frame_start_cycles = gba.scheduler.cycles
    nc.in_frame = true
  # A responder mid-exchange owes the REPLY the initiator is parked on. If
  # the lead/window stall kept us from reaching that completion while the
  # initiator's clock is frozen waiting for us, neither side can advance
  # (cross-game multi trades hit this). So while an exchange is in flight
  # locally, drain it to the pending completion instead of stalling: sampling
  # already happened at the anchor, and the drain is bounded by the round.
  let inflight = nc.phase in {npSlaveSample, npSlaveFinish}
  var draining = false
  if not nc.peer_done and nc.now() > nc.peer_clock + nc.effective_lead:
    if not inflight:
      if not nc.lead_wait:
        nc.lead_wait = true
        nc.enter_stall()
        nc.send_clock(blocked = true)
      return naStalled
    draining = true  # bypass the stall to close the in-flight exchange
  elif nc.lead_wait:
    nc.lead_wait = false
    nc.exit_stall()
  # Speculation back-pressure: park when the window fills until REPLYs
  # advance confirmed_cycle.
  if nc.speculative and not nc.peer_done and
     nc.now() - nc.confirmed_cycle > nc.window_cycles:
    if not inflight:
      if not nc.window_wait:
        nc.window_wait = true
        nc.enter_stall()
        nc.send_clock(blocked = true)
      return naStalled
    draining = true
  elif nc.window_wait:
    nc.window_wait = false
    nc.exit_stall()
  if nc.now() - nc.last_clock_sent >= CLOCK_INTERVAL:
    nc.send_clock()
  let target = gba.scheduler.cycles + CycleCount(NETLINK_SLICE)
  while gba.scheduler.cycles < target and gba.ppu.frame == 0:
    if gba.cpu.halted:
      gba.scheduler.fast_forward()
    else:
      gba.cpu.tick()
    if nc.reply_wait:
      return naStalled  # etSerial parked the clock mid-slice
    if draining and nc.phase == npIdle:
      # Drained; hand back so the next call re-evaluates the stall.
      return naProgress
  if gba.ppu.frame > 0:
    nc.send_clock()
    nc.offset += int64(gba.end_frame())
    nc.in_frame = false
    if nc.speculative:
      nc.take_checkpoint()
      nc.advance_confirmed()
    return naFrame
  naProgress

# ---------------- construction ----------------

proc rebaseline*(nc: NetCore) =
  ## Reset the link-clock origin to the core's current cycle (attaching to a
  ## running core). Only valid before the first CLOCK is sent.
  nc.offset = -int64(nc.gba.scheduler.cycles)

proc debug_state*(nc: NetCore): string =
  ## One-line state dump for frontends' diagnostics.
  result = "hello=" & $nc.hello & " phase=" & $nc.phase & " now=" & $nc.now() &
    " peer_clock=" & $nc.peer_clock & " reply_wait=" & $nc.reply_wait &
    " lead_wait=" & $nc.lead_wait & " got_reply=" & $nc.got_reply &
    " round_cycle=" & $nc.round_cycle & " pending=" & $nc.pending_transfers.len &
    " stalls=" & $nc.stall_count & " peer_mode=" & $nc.peer_mode &
    " peer_done=" & $nc.peer_done
  if nc.speculative:
    result.add " spec[hits=" & $nc.pred_hits & " misses=" & $nc.pred_misses &
      " rollbacks=" & $nc.rollbacks & " ckpts=" & $nc.checkpoints.len &
      " log=" & $nc.round_log.len & " window_wait=" & $nc.window_wait &
      " confirmed=" & $nc.confirmed_cycle & " replay_cyc=" & $nc.replay_cycles & "]"

# ---- speculation test/telemetry hooks ----

proc all_confirmed*(nc: NetCore): bool =
  ## No speculated round is still awaiting its REPLY; tests drain to this.
  for e in nc.round_log:
    if not e.confirmed: return false
  true

proc pred_stats*(nc: NetCore): tuple[hits, misses, rollbacks: int] =
  (nc.pred_hits, nc.pred_misses, nc.rollbacks)

proc replay_cost*(nc: NetCore): int64 = nc.replay_cycles
proc replay_overruns*(nc: NetCore): int = nc.replay_overrun
  ## Nonzero means speculation could not stay bit-identical (corrected data
  ## changed control flow). Should be 0 on a healthy predictor.

proc set_echo_predict*(nc: NetCore; on: bool) =
  ## Bench hook: A/B the echo-aware predictor against plain "same as last".
  nc.echo_predict = on

proc force_mispredict*(nc: NetCore; n: int) =
  ## Test hook: mispredict the next `n` rounds to exercise rollback recovery.
  nc.force_wrong = n

proc note_input*(nc: NetCore; input: Input; pressed: bool) =
  ## Apply a host keypress and record it so a rollback replays it at the
  ## same cycle. The transports still call gba.handle_input directly, so
  ## speculative input replay is wired but unexercised.
  nc.gba.handle_input(input, pressed)
  if nc.speculative and not nc.replaying:
    nc.input_log.add InputEvent(cycle: nc.now(), input: input, pressed: pressed)

proc new_net_core*(gba: GBA; id: int; rom_crc: uint32;
                   strict_crc = true; lead: int64 = NETLINK_LEAD;
                   lead_active: int64 = NETLINK_LEAD;
                   speculative = false): NetCore =
  ## Wire a post-init core to the protocol and queue our HELLO. id 0 =
  ## host = multi-mode unit 0. `lead` is the idle bounded-lead window (pick
  ## it to exceed the transport's byte-exchange cadence; the sides need not
  ## agree); `lead_active` the tighter window while a link SIO mode is
  ## active. `speculative` enables rollback: the master predicts REPLYs and
  ## rolls back to a frame checkpoint on a misprediction; off is a no-op.
  doAssert id in {0, 1}, "the network link is 2-player: unit id must be 0 or 1"
  result = NetCore(gba: gba, id: id, rom_crc: rom_crc, strict_crc: strict_crc,
                   lead: lead, lead_active: lead_active, peer_mode: 0xFF,
                   speculative: speculative, echo_predict: true,
                   window_cycles: int64(SPEC_WINDOW_FRAMES) * FRAME_CYCLES,
                   checkpoints: initDeque[Checkpoint]())
  result.send_msg(encode_hello(LINK_SYSTEM_GBA, uint8(id), rom_crc))
  gba.set_sio_driver(RemoteSioDriver(core: result))
