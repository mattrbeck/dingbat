import serialize

when defined(emscripten):
  type CycleCount* = uint32
else:
  type CycleCount* = uint64

const MAX_EVENTS* = 64  # far above the ~15 events ever pending at once
                        # Exported because it is a save-state compatibility
                        # floor, not just a capacity: load_from refuses a
                        # state carrying more pending events than this, so
                        # lowering it rejects existing files. Pinned in
                        # tests/savestate_compat_test.nim.

type
  EventType* = enum
    # Shared
    etAPUFrameSeq, etAPUSample
    etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4
    etHandleInput
    # GB (etRtcSecond also drives the GBA RTC per-minute IRQ poll; enum order
    # is savestate format — do not reorder)
    etIME, etRtcSecond
    # GBA
    etSaves, etInterrupts
    etPPUStartLine, etPPUStartHBlank, etPPUSetHBlankFlag, etPPUEndHBlank
    etTimer0, etTimer1, etTimer2, etTimer3
    etSerial, etDMA
    # Appended, never inserted: the ordinal of every kind above is part of
    # the save-state format, and tests/savestate_compat_test.nim pins each one
    # at compile time — a reorder fails the build there, not a user's state.
    # Drives the Game Boy Camera's capture countdown.
    etCameraDone

  Event* = object
    cycles*: CycleCount
    kind*: EventType

  Scheduler* = ref object
    # Sorted descending by target cycle (soonest last) in a fixed array so
    # scheduling never touches seq grow/shrink machinery; pop is O(1)
    evbuf: array[MAX_EVENTS, Event]
    nevents: int
    cycles*: CycleCount
    # Exposed so the GBA bus catch-up can test "no event due" inline without
    # a cross-module call on every MMIO access
    next_event*: CycleCount
    current_speed: uint8
    # True while an event handler runs; guards against re-entrant tick()
    # (e.g. a DMA triggered by an event touching MMIO mid-dispatch)
    dispatching*: bool
    dispatch*: proc(kind: EventType) {.closure.}
    # Deferred-work pump, run after an event dispatch with dispatching
    # already false. Handlers stay pure (they only mark work — e.g. GBA DMA
    # requests); the pump executes it outside dispatch so it can advance the
    # clock and dispatch nested events (DMA priority preemption). Nil for GB.
    # Only invoked when a handler set pump_requested — a closure call per
    # event (~1000/frame) measurably costs host instructions.
    pump*: proc() {.closure.}
    pump_requested*: bool

proc new_scheduler*(): Scheduler =
  result = Scheduler(next_event: high(CycleCount))

proc speed*(s: Scheduler): uint8 {.inline.} = s.current_speed
  ## CGB speed shift (0 = normal, 1 = double). schedule_gb scales every
  ## non-etIME delay by this, so anything keeping its own deadlines in
  ## scheduler cycles (the GB APU channels' lazy catch-up) must scale by it
  ## too, and must be rescaled alongside pending events on a speed switch.

iterator events*(s: Scheduler): Event =
  ## Pending events, soonest last (kept for debug UIs and RTC queries)
  for i in 0 ..< s.nevents:
    yield s.evbuf[i]

proc schedule*(s: Scheduler; cycles: int; kind: EventType) =
  assert s.nevents < MAX_EVENTS
  let target = s.cycles + CycleCount(cycles)
  # Shift sooner events right; ties keep the newest event at the higher
  # index so it pops first (matches the historical insertion order)
  var i = s.nevents
  while i > 0 and s.evbuf[i - 1].cycles < target:
    s.evbuf[i] = s.evbuf[i - 1]
    dec i
  s.evbuf[i] = Event(cycles: target, kind: kind)
  inc s.nevents
  s.next_event = s.evbuf[s.nevents - 1].cycles

proc schedule_gb*(s: Scheduler; cycles: int; kind: EventType) =
  var c = cycles
  if kind != etIME:
    c = c shl s.current_speed
  s.schedule(c, kind)

proc clear*(s: Scheduler; kind: EventType) =
  # Remove all events of a given type (single-pass compaction).
  var j = 0
  for i in 0 ..< s.nevents:
    if s.evbuf[i].kind != kind:
      if j != i: s.evbuf[j] = s.evbuf[i]
      inc j
  s.nevents = j
  s.next_event = if j > 0: s.evbuf[j - 1].cycles else: high(CycleCount)

proc has_event*(s: Scheduler; kind: EventType): bool =
  ## Is an event of this kind still waiting to fire? Used by the GBA state
  ## loader to tell "this machine has already recognised its pending interrupt"
  ## apart from "the recognition check is still in flight" — see
  ## gba/savestate.nim.
  for i in 0 ..< s.nevents:
    if s.evbuf[i].kind == kind: return true
  false

proc call_current*(s: Scheduler) =
  while s.nevents > 0:
    let ev = s.evbuf[s.nevents - 1]
    if s.cycles < ev.cycles:
      s.next_event = ev.cycles
      return
    dec s.nevents
    s.dispatching = true
    s.dispatch(ev.kind)
    s.dispatching = false
    if s.pump_requested:
      s.pump_requested = false
      s.pump()
  s.next_event = high(CycleCount)

proc tick_slow(s: Scheduler; cycles: CycleCount) =
  # Jump directly to each due event's timestamp so handlers observe the
  # exact cycle they were scheduled for (same semantics as stepping one
  # cycle at a time, without the per-cycle loop).
  #
  # The advance is quota-based (remaining cycles applied on top of the live
  # clock) rather than toward a precomputed absolute target: a dispatch can
  # re-entrantly advance the clock (a GBA DMA burst pumped from an event
  # handler drains its stall cycles between transfers), and the rest of this
  # tick's quota must then apply AFTER that stall — an absolute target would
  # overlap the two, silently dropping the drained cycles.
  var remaining = cycles
  while s.cycles + remaining >= s.next_event:
    remaining -= s.next_event - s.cycles
    s.cycles = s.next_event
    s.call_current()
  s.cycles += remaining

proc tick*(s: Scheduler; cycles: int) {.inline.} =
  # Kept tiny so it inlines into the CPU instruction loop; the event
  # dispatch loop lives out of line.
  let n = CycleCount(cycles)
  if s.cycles + n < s.next_event:
    s.cycles += n
  else:
    s.tick_slow(n)

proc fast_forward*(s: Scheduler) =
  s.cycles = s.next_event
  s.call_current()

proc fast_forward_bounded*(s: Scheduler; bound: CycleCount) =
  ## fast_forward that may not skip past `bound`.
  ##
  ## The unbounded form snaps `cycles` to whatever the next scheduled event
  ## happens to be, which makes emulated time inside an idle loop depend on
  ## WHICH events exist rather than on the loop. A spin loop polling a hardware
  ## register re-reads it once per skip, so the skip length IS that loop's
  ## sampling resolution — and the GBA PSG's per-waveform-period events used to
  ## hold that resolution at ~32 cycles by accident (see gba/apu.nim). Callers
  ## that keep deadlines OUTSIDE evbuf must pass their soonest one here, or
  ## moving those deadlines out of the scheduler silently coarsens every idle
  ## loop in the machine.
  ##
  ## When the bound bites, nothing is due, so there is nothing to dispatch: just
  ## advance and let the caller re-run the loop body. `bound` must be strictly
  ## ahead of `cycles` (or high(CycleCount) for "no bound") — forward progress
  ## in the caller's loop depends on it.
  if bound < s.next_event:
    s.cycles = bound
  else:
    s.cycles = s.next_event
    s.call_current()

proc rebase*(s: Scheduler; keep_phase_mask: CycleCount = 0): CycleCount {.discardable.} =
  ## NOTE: the GB APU keeps per-channel deadlines OUTSIDE this array (lazy
  ## catch-up, see gb/apu/channel1.nim). Every caller must hand the returned
  ## base to gb_rebase/apu_rebase so those deadlines move with the events.
  ##
  ## Subtract the current cycle count (rounded down to keep the low
  ## keep_phase_mask bits — GBA timers derive prescaler phase from the
  ## absolute cycle count) from all event targets. Returns the subtracted
  ## base. Prevents overflow when using uint32 cycle counters.
  let base = s.cycles and not keep_phase_mask
  for i in 0 ..< s.nevents:
    s.evbuf[i].cycles -= base
  s.next_event = if s.nevents > 0: s.evbuf[s.nevents - 1].cycles else: high(CycleCount)
  s.cycles -= base
  base

proc save_to*(s: Scheduler; w: var Writer) =
  ## Serialize all scheduler state. Event kinds are written by ordinal; the
  ## dispatch closure is not serialized — it stays registered on the owning
  ## emulator and maps each kind back to its handler.
  w.write_u64(uint64(s.cycles))
  w.write_u8(s.current_speed)
  w.write_u8(uint8(s.nevents))
  for i in 0 ..< s.nevents:
    w.write_u8(uint8(ord(s.evbuf[i].kind)))
    w.write_u64(uint64(s.evbuf[i].cycles))

proc load_from*(s: Scheduler; r: var Reader) =
  ## Restore scheduler state saved by save_to. Events are stored in the
  ## internal order (sorted descending by target cycle, soonest last), so
  ## they are restored verbatim.
  let cycles = r.read_u64()
  let speed = r.read_u8()
  let n = int(r.read_u8())
  if n > MAX_EVENTS:
    raise newException(StateError, "too many scheduler events in state")
  s.cycles = CycleCount(cycles)
  s.current_speed = speed
  s.nevents = n
  for i in 0 ..< n:
    let kind = r.read_u8()
    if int(kind) > int(high(EventType)):
      raise newException(StateError, "unknown scheduler event kind in state")
    let target = r.read_u64()
    s.evbuf[i] = Event(cycles: CycleCount(target), kind: EventType(kind))
  s.next_event = if n > 0: s.evbuf[n - 1].cycles else: high(CycleCount)

proc `speed_mode=`*(s: Scheduler; speed: uint8) =
  ## NOTE: as with rebase, the GB APU's per-channel deadlines live outside
  ## evbuf; gb/memory.nim's stop_instr rescales them around this call.
  let old = s.current_speed
  if speed == old: return
  s.current_speed = speed
  for i in 0 ..< s.nevents:
    if s.evbuf[i].kind != etIME:
      # Real-time events (APU) are stored in CPU cycles, which run twice as
      # fast in double speed: entering double speed doubles the remaining
      # delay, leaving it halves it. The old code shifted right with an
      # underflowing uint8 exponent when entering, collapsing every pending
      # event to fire immediately.
      let remaining = s.evbuf[i].cycles - s.cycles
      let rescaled = if speed > old: remaining shl (speed - old)
                     else: remaining shr (old - speed)
      s.evbuf[i].cycles = s.cycles + rescaled
  s.next_event = if s.nevents > 0: s.evbuf[s.nevents - 1].cycles else: high(CycleCount)
