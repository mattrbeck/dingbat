import serialize

when defined(emscripten):
  type CycleCount* = uint32
else:
  type CycleCount* = uint64

const MAX_EVENTS = 64  # far above the ~15 events ever pending at once

type
  EventType* = enum
    # Shared
    etAPUFrameSeq, etAPUSample
    etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4
    etHandleInput
    # GB
    etIME, etRtcSecond
    # GBA
    etSaves, etInterrupts
    etPPUStartLine, etPPUStartHBlank, etPPUSetHBlankFlag, etPPUEndHBlank
    etTimer0, etTimer1, etTimer2, etTimer3
    etSerial, etDMA

  Event* = object
    cycles*: CycleCount
    kind*: EventType

  Scheduler* = ref object
    # Sorted descending by target cycle (soonest last) in a fixed array so
    # scheduling never touches seq grow/shrink machinery; pop is O(1)
    evbuf: array[MAX_EVENTS, Event]
    nevents: int
    cycles*: CycleCount
    next_event: CycleCount
    current_speed: uint8
    # True while an event handler runs; guards against re-entrant tick()
    # (e.g. a DMA triggered by an event touching MMIO mid-dispatch)
    dispatching*: bool
    dispatch*: proc(kind: EventType) {.closure.}

proc new_scheduler*(): Scheduler =
  result = Scheduler(next_event: high(CycleCount))

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
  s.next_event = high(CycleCount)

proc tick*(s: Scheduler; cycles: int) {.inline.} =
  let target = s.cycles + CycleCount(cycles)
  if target < s.next_event:
    s.cycles = target
  else:
    # Jump directly to each due event's timestamp so handlers observe the
    # exact cycle they were scheduled for (same semantics as stepping one
    # cycle at a time, without the per-cycle loop).
    while target >= s.next_event:
      s.cycles = s.next_event
      s.call_current()
    s.cycles = target

proc fast_forward*(s: Scheduler) =
  s.cycles = s.next_event
  s.call_current()

proc rebase*(s: Scheduler; keep_phase_mask: CycleCount = 0): CycleCount {.discardable.} =
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
