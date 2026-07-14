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

import std/deques
import ../common/[linkproto, scheduler, util, input]
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
  FRAME_CYCLES = 280896
    ## Cycles per GBA video frame; the speculation window is measured in these.
  SPEC_WINDOW_FRAMES* = 8
    ## Speculative-execution bound: the master may run at most this many frames
    ## ahead of the newest peer-confirmed round before it back-pressures (falls
    ## back to today's reply_wait stall). ~8 frames ≈ 130 ms absorbs a
    ## round-trip while capping unconfirmed rollback work + checkpoint memory
    ## (one ~600 KB state_payload per frame).
  ECHO_MAX = 4
    ## Saturating cap on the per-mode "responder mirrors us" confidence counter.
  ECHO_CONFIRM = 2
    ## Predict our own outgoing word (not the peer's last) once the responder
    ## has echoed us this many recent rounds — the symmetric Cable Club sync.

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

  RoundEntry = object
    ## One completed master round latched since `confirmed_cycle`, in cycle
    ## order. Speculation replays these to re-supply the peer's word during a
    ## rollback and to confirm/correct them against arriving REPLYs.
    cycle: int64          # transfer start S (the round's key)
    mode: uint8
    peer_data: uint32     # the peer word we latched (predicted or real)
    listening: bool       # peer-was-listening flag we latched
    out_word: uint32      # our outgoing word (for the no-divergence check)
    predicted: bool       # latched from predict() (needs a REPLY to confirm)
    confirmed: bool        # the real REPLY has validated this round

  NetSnapshot = object
    ## The netcore's own round state at a checkpoint — restored alongside the
    ## core's state_payload on rollback (the core payload does not carry it).
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
    lead_active: int64    # tighter bound while a serial link mode is active:
                          # multi-mode games (e.g. Pokémon Cable Club trades)
                          # sample each other's SIOMULTI data at explicit
                          # cycles and only tolerate a small skew, so the wide
                          # idle lead (a browser needs it for full-speed solo
                          # play) must tighten the moment either side enters a
                          # link SIO mode or the handshake never converges.
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
    # ---- speculative execution (GGPO-style rollback) ----
    speculative: bool     # OFF: everything below is inert (a pure no-op)
    window_cycles: int64  # bound on how far ahead of confirmed we may run
    has_mastered: bool    # this side initiates transfers (widens its lead)
    round_predicted: bool # the in-flight round's completion was a prediction
    replaying: bool       # inside rollback re-emulation (suppress the outbox)
    replay_cursor: int    # next round_log index to re-supply during replay
    confirmed_cycle: int64# rounds up to here are confirmed by the peer
    checkpoints: Deque[Checkpoint]  # one frame-boundary snapshot per frame
    round_log: seq[RoundEntry]      # rounds latched since confirmed_cycle
    input_log: seq[InputEvent]      # host keypresses since confirmed_cycle
    last_reply: array[6, tuple[word: uint32, listening: bool]]  # predictor state
    echo_predict: bool    # use the echo-aware predictor (default on; a bench hook flips it)
    peer_echo: array[6, int]  # per-mode saturating "the responder mirrors us" confidence
    window_wait: bool     # parked because the speculation window is full
    force_wrong: int      # test hook: mispredict the next N rounds on purpose
    pred_hits*, pred_misses*, rollbacks*: int  # telemetry
    replay_cycles*: int64 # honest cost: total cycles re-emulated by rollbacks
    replay_overrun*: int  # times replay ran past the log (lossy idle-latch fallback)

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

proc effective_lead(nc: NetCore): int64 =
  ## Tighten the bounded-lead window whenever either side is in a serial link
  ## mode, so an actively-linking game (which samples the peer's data at exact
  ## cycles) never drifts past its skew tolerance; fall back to the wide idle
  ## lead otherwise for full-speed solo play while nominally connected.
  ##
  ## Speculation removes the correctness need for a tight lead on the
  ## *initiating* side: rollback repairs any divergence, so the master may race
  ## a whole window ahead — that is where the speedup comes from. The responder
  ## keeps the tight lead so it still samples each transfer near its anchor
  ## cycle. The real back-pressure is the window bound checked in try_advance.
  if nc.speculative and nc.has_mastered:
    return nc.window_cycles + int64(FRAME_CYCLES)
  if nc.gba.serial.sio_mode() in {smMulti, smNormal8, smNormal32} or
     nc.peer_in_multi or nc.peer_in_normal:
    min(nc.lead, nc.lead_active)
  else:
    nc.lead

proc send_msg(nc: NetCore; data: string) =
  # During rollback re-emulation every outgoing frame was already sent on the
  # original pass (same cycles/data — only the peer's word was mispredicted,
  # which is purely local latching), so replay must not re-send anything.
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
  ## Guess the responder's next REPLY for `mode`. Two signals, cheapest first:
  ##   * echo-aware: a Pokémon Cable Club "all players ready" sync is symmetric
  ##     — same-team/same-version peers send the SAME handshake word each round,
  ##     so once we've watched the responder mirror our output for a few rounds
  ##     (`peer_echo >= ECHO_CONFIRM`) our OWN outgoing word (`round_out`)
  ##     predicts its reply far better than its last word does. This is the case
  ##     that gates the trade room, and where "same as last" mispredicts on every
  ##     word change in the cycling handshake.
  ##   * fallback: the same word it last sent (handshakes also hold runs of
  ##     identical words, and asymmetric bursts have no better cheap guess).
  ## `force_wrong` is a test hook that deliberately mispredicts.
  let idx = int(mode) and 7
  if nc.force_wrong > 0:
    dec nc.force_wrong
    return (0xDEAD0000'u32 or uint32(nc.pred_hits + nc.pred_misses), true)
  if nc.echo_predict and nc.peer_echo[idx] >= ECHO_CONFIRM:
    return (nc.round_out, nc.last_reply[idx].listening)
  nc.last_reply[idx]

proc note_reply(nc: NetCore; mode: uint8; word: uint32; listening: bool;
                our_word: uint32) =
  ## Record the peer's real word so future predictions echo it, and track
  ## whether the responder is mirroring our output (drives the echo predictor).
  let idx = int(mode) and 7
  nc.last_reply[idx] = (word, listening)
  if word == our_word:
    nc.peer_echo[idx] = min(nc.peer_echo[idx] + 1, ECHO_MAX)
  else:
    nc.peer_echo[idx] = max(nc.peer_echo[idx] - 1, 0)

proc log_round(nc: NetCore) =
  ## Append the just-completed master round (called from master_finish on the
  ## live pass only). `round_in`/`round_listening` hold whatever we latched —
  ## a prediction (needs a REPLY to confirm) or a real reply that beat S+D.
  nc.round_log.add RoundEntry(
    cycle: nc.round_cycle, mode: nc.round_mode,
    peer_data: nc.round_in, listening: nc.round_listening,
    out_word: nc.round_out, predicted: nc.round_predicted,
    confirmed: not nc.round_predicted)

proc replay_round(nc: NetCore; cycle: int64): int =
  ## Index of the logged round starting at `cycle` (−1 if none). Used during
  ## re-emulation to re-supply a round's latched peer word deterministically.
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
  nc.has_mastered = true  # this side initiates → it gets the speculative lead
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
  ## when the REPLY already arrived, when we speculate a word at S+D, from
  ## feed() when a parked REPLY (or a BYE) lands, or from replay re-supplying
  ## a logged word. `round_in`/`round_listening` hold the word being latched
  ## (real, predicted, or replayed); `round_predicted` flags which.
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
  ## Re-emulation reached a round's completion: re-supply exactly the word we
  ## latched originally (corrected for confirmed rounds) from the log, so the
  ## local timeline reproduces. Rounds re-fire in the SAME ORDER they were
  ## logged, so we consume the log by a cursor rather than by cycle — a
  ## checkpoint restore reproduces frame-boundary state exactly but not the
  ## few-cycle intra-frame phase, so round *cycles* can drift by a hair while
  ## their order and data cannot.
  if nc.replay_cursor >= nc.round_log.len:
    # More rounds re-fired than were logged — only possible if corrected peer
    # data changed local control flow (a genuine divergence). Latch an idle
    # line so it is at least deterministic; the acceptance test would catch it.
    inc nc.replay_overrun
    nc.round_in = 0xFFFFFFFF'u32
    nc.round_listening = false
    nc.round_predicted = true
    nc.master_finish()
    return
  let e = nc.round_log[nc.replay_cursor]
  inc nc.replay_cursor
  # No-divergence check: a corrected peer word must not have changed our own
  # outgoing word (that TRANSFER was already sent to the peer).
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
    # SPECULATE: predict the peer's word, latch it, and keep emulating past
    # S+D instead of parking. The real REPLY confirms it (or forces a
    # rollback) when it lands in feed().
    let p = nc.predict(nc.round_mode)
    nc.round_in = p.word
    nc.round_listening = p.listening
    nc.round_predicted = true
    nc.master_finish()
  else:
    # Not speculating (feature off, or the window is full → back-pressure).
    # STALL POINT: park the emulated clock here until the REPLY (or BYE)
    # arrives — never free-run past a pending exchange.
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
    pending_transfers: nc.pending_transfers)

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

proc take_checkpoint(nc: NetCore) =
  ## Snapshot the core (state_payload — frame boundaries only) plus our round
  ## state, for rollback. Called at every frame boundary while speculating.
  nc.checkpoints.addLast Checkpoint(cycle: nc.now(),
    payload: nc.gba.state_payload(), snap: nc.capture_snapshot())

proc replay_start(cp: Checkpoint): int64 =
  ## The earliest round-START a rollback to this checkpoint can re-fire: a round
  ## in flight AS OF the checkpoint (started before the boundary, completes
  ## after) is the first to re-complete, so its start — not the boundary — is
  ## the low-water mark. Used both to seed the replay cursor and to decide how
  ## far back the round log must be retained; the two MUST agree or replay
  ## re-fires a round with no log entry (a spurious divergence).
  if cp.snap.phase == npMasterWait: cp.snap.round_cycle else: cp.cycle

proc advance_confirmed(nc: NetCore) =
  ## The peer has validated some rounds: recompute confirmed_cycle (the start
  ## cycle of the oldest still-unconfirmed round, or now() if all confirmed),
  ## then drop checkpoints/log entries the window no longer needs.
  var first_unconfirmed = high(int64)
  for e in nc.round_log:
    if not e.confirmed and e.cycle < first_unconfirmed:
      first_unconfirmed = e.cycle
  # A round in flight (started at round_cycle, not yet completed → not yet in the
  # log) can still mispredict and demand a rollback to before its START, which
  # may sit BEFORE the frame boundary we just checkpointed. It must bound
  # confirmed_cycle too, or its rollback checkpoint gets pruned as "confirmed"
  # and the later REPLY asserts (no checkpoint at/before its cycle). This only
  # bites a round straddling a frame boundary — invisible in short exchanges.
  if nc.phase == npMasterWait and nc.round_cycle < first_unconfirmed:
    first_unconfirmed = nc.round_cycle
  nc.confirmed_cycle =
    if first_unconfirmed == high(int64): nc.now() else: first_unconfirmed
  # Keep the newest checkpoint at/before confirmed_cycle as the rollback
  # baseline; older ones can never be a rollback target again.
  while nc.checkpoints.len >= 2 and nc.checkpoints[1].cycle <= nc.confirmed_cycle:
    nc.checkpoints.popFirst()
  # Drop log entries (rounds + host input) baked into the baseline: they are
  # already in the checkpoint and can never be replayed again.
  if nc.checkpoints.len > 0:
    # Retain the log back to the OLDEST checkpoint's replay-start (not its
    # cycle): a round straddling that checkpoint re-fires on a rollback there and
    # must still have its entry, or replay_master_complete consumes the wrong one.
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
  ## Restore the newest checkpoint at/before `from_cycle` and deterministically
  ## re-emulate forward to the current clock, re-supplying each logged round's
  ## (now-corrected) peer word and replaying host input. The outbox is
  ## suppressed throughout — the peer already has our originals.
  let target = nc.now()
  var ci = -1
  for i in countdown(nc.checkpoints.len - 1, 0):
    if nc.checkpoints[i].cycle <= from_cycle:
      ci = i; break
  doAssert ci >= 0, "rollback: no checkpoint at/before cycle " & $from_cycle
  let cp = nc.checkpoints[ci]
  # Honest cost: this rollback re-emulates every cycle from the checkpoint up to
  # now(). Summed over a run, replay_cycles is the CPU the predictor wasted — the
  # metric the step/stall speed proxy is blind to (re-emulation is invisible to it).
  nc.replay_cycles += target - cp.cycle
  while nc.checkpoints.len > ci + 1: discard nc.checkpoints.popLast()
  nc.gba.apply_state_payload(cp.payload)
  nc.offset = cp.cycle - int64(nc.gba.scheduler.cycles)
  nc.restore_snapshot(cp.snap)
  # Point the replay cursor at the first round that re-fires (a round straddling
  # the checkpoint, else the first starting at/after it). This key is stored
  # (drift-free), unlike a cycle computed during replay, and matches the
  # low-water mark advance_confirmed retains the log to.
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
    if gba.ppu.frame:
      nc.offset += int64(gba.end_frame())
      nc.take_checkpoint()  # regenerate this frame's (now-corrected) checkpoint
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
      # Our outgoing word for the round this REPLY answers: from the log if we
      # latched it, else the in-flight round's (the reply beat our S+D).
      let our_word = if idx >= 0: nc.round_log[idx].out_word else: nc.round_out
      nc.note_reply(m.mode, m.data, listening, our_word)
      if idx >= 0 and not nc.round_log[idx].confirmed:
        # A round we already latched (speculatively or live) is being confirmed.
        if not nc.round_log[idx].predicted:
          nc.round_log[idx].confirmed = true  # was latched from a real reply
        elif nc.round_log[idx].peer_data == m.data and
             nc.round_log[idx].listening == listening:
          nc.round_log[idx].confirmed = true
          inc nc.pred_hits
        else:
          # Misprediction: correct the logged word and roll back to re-emulate
          # everything since, with the real data.
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
        # The clock is parked at S+D waiting for exactly this reply: latch
        # and complete now, at the parked cycle.
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
  # The window tightens automatically while a link SIO mode is active.
  if not nc.peer_done and nc.now() > nc.peer_clock + nc.effective_lead:
    if not nc.lead_wait:
      nc.lead_wait = true
      nc.enter_stall()
      nc.send_clock(blocked = true)
    return naStalled
  if nc.lead_wait:
    nc.lead_wait = false
    nc.exit_stall()
  # Speculation back-pressure: bound how far past the newest peer-confirmed
  # round we may run. When the window fills, park until arriving REPLYs
  # confirm rounds (advancing confirmed_cycle) — this is the worst case that
  # degrades to today's stall behaviour, never worse.
  if nc.speculative and not nc.peer_done and
     nc.now() - nc.confirmed_cycle > nc.window_cycles:
    if not nc.window_wait:
      nc.window_wait = true
      nc.enter_stall()
      nc.send_clock(blocked = true)
    return naStalled
  if nc.window_wait:
    nc.window_wait = false
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
    if nc.speculative:
      nc.take_checkpoint()
      nc.advance_confirmed()
    return naFrame
  naProgress

# ---------------- construction ----------------

proc rebaseline*(nc: NetCore) =
  ## Reset the link-clock origin to the core's current cycle. Used when
  ## attaching to an already-running core mid-game so now() starts near zero
  ## on both sides; the bounded-lead sync then absorbs the residual skew.
  ## Only valid before the first CLOCK is sent (i.e. right after construction).
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
  ## True when no speculated round is still awaiting its peer REPLY — i.e. the
  ## visible state has settled to what the blocking path would produce. Tests
  ## drain to this before comparing final state.
  for e in nc.round_log:
    if not e.confirmed: return false
  true

proc pred_stats*(nc: NetCore): tuple[hits, misses, rollbacks: int] =
  (nc.pred_hits, nc.pred_misses, nc.rollbacks)

proc replay_cost*(nc: NetCore): int64 = nc.replay_cycles
proc replay_overruns*(nc: NetCore): int = nc.replay_overrun
  ## Times a rollback re-emulated more rounds than were logged and fell back to
  ## the lossy idle latch — a nonzero count means speculation could NOT stay
  ## bit-identical (genuine divergence from control flow the corrected data
  ## changed). Should be 0 on a healthy predictor.
  ## Total cycles re-emulated by rollbacks over this run — the honest CPU cost
  ## the step/stall speed proxy cannot see.

proc set_echo_predict*(nc: NetCore; on: bool) =
  ## Bench hook: turn the echo-aware predictor off to A/B it against the plain
  ## "same as last" guess. Production leaves it on.
  nc.echo_predict = on

proc force_mispredict*(nc: NetCore; n: int) =
  ## Test hook: make the predictor deliberately return a wrong word for the
  ## next `n` rounds, to exercise rollback recovery.
  nc.force_wrong = n

proc note_input*(nc: NetCore; input: Input; pressed: bool) =
  ## Apply a host keypress AND record it on the speculative timeline so a
  ## rollback can replay it at the same cycle. Frontends should route input
  ## through this (rather than gba.handle_input) while a speculative link is
  ## live; with speculation off it is just handle_input. NOTE: the current
  ## transports still call gba.handle_input directly, so speculative input
  ## replay is wired but unexercised — the acceptance ROM is self-driving and
  ## takes no input. A game that reads the keypad under speculation needs this
  ## call added at the frontends' input path (a follow-up, out of scope here as
  ## the transports must stay otherwise untouched).
  nc.gba.handle_input(input, pressed)
  if nc.speculative and not nc.replaying:
    nc.input_log.add InputEvent(cycle: nc.now(), input: input, pressed: pressed)

proc new_net_core*(gba: GBA; id: int; rom_crc: uint32;
                   strict_crc = true; lead: int64 = NETLINK_LEAD;
                   lead_active: int64 = NETLINK_LEAD;
                   speculative = false): NetCore =
  ## Wire a post-init core to the protocol state machine and queue our
  ## HELLO. The transport must then shuttle bytes with feed/take_outgoing;
  ## try_advance reports naHello until the peer's HELLO validates.
  ## id 0 = host/listener = multi-mode unit 0. `lead` is this side's idle
  ## bounded-lead window — pick it to exceed the transport's byte-exchange
  ## cadence (NETLINK_LEAD for a pumped socket, NETLINK_LEAD_RAF for a
  ## browser RAF loop); the two sides need not agree. `lead_active` is the
  ## tighter window used while a link SIO mode is active (defaults to the
  ## native lead, which real link games tolerate); it caps `lead`.
  ## `speculative` enables GGPO-style rollback: the master predicts the
  ## responder's REPLY, keeps emulating, and rolls back to a frame checkpoint
  ## only on a misprediction. Default off — a no-op that preserves the exact
  ## blocking-path behaviour. The result is bit-identical either way; it only
  ## decouples emulation speed from RTT.
  doAssert id in {0, 1}, "the network link is 2-player: unit id must be 0 or 1"
  result = NetCore(gba: gba, id: id, rom_crc: rom_crc, strict_crc: strict_crc,
                   lead: lead, lead_active: lead_active, peer_mode: 0xFF,
                   speculative: speculative, echo_predict: true,
                   window_cycles: int64(SPEC_WINDOW_FRAMES) * FRAME_CYCLES,
                   checkpoints: initDeque[Checkpoint]())
  result.send_msg(encode_hello(LINK_SYSTEM_GBA, uint8(id), rom_crc))
  gba.set_sio_driver(RemoteSioDriver(core: result))
