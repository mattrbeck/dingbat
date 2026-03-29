when defined(emscripten):
  type CycleCount* = uint32
else:
  type CycleCount* = uint64

type
  EventType* = enum
    # Shared
    etAPUFrameSeq, etAPUSample
    etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4
    etHandleInput
    # GB
    etIME
    # GBA
    etSaves, etInterrupts
    etPPUStartLine, etPPUStartHBlank, etPPUEndHBlank
    etTimer0, etTimer1, etTimer2, etTimer3
    etSerial

  Event* = object
    cycles*: CycleCount
    kind*: EventType

  Scheduler* = ref object
    events*: seq[Event]
    cycles*: CycleCount
    next_event: CycleCount
    current_speed: uint8
    dispatch*: proc(kind: EventType) {.closure.}

proc new_scheduler*(): Scheduler =
  result = Scheduler(next_event: high(CycleCount))
  result.events = @[]

proc schedule*(s: Scheduler; cycles: int; kind: EventType) =
  # Insert in descending order (largest first) so pop from end is O(1).
  let target = s.cycles + CycleCount(cycles)
  let ev = Event(cycles: target, kind: kind)
  var idx = 0
  for i in countdown(s.events.len - 1, 0):
    if s.events[i].cycles >= target:
      idx = i + 1
      break
  s.events.insert(ev, idx)
  s.next_event = s.events[^1].cycles

proc schedule_gb*(s: Scheduler; cycles: int; kind: EventType) =
  var c = cycles
  if kind != etIME:
    c = c shl s.current_speed
  s.schedule(c, kind)

proc clear*(s: Scheduler; kind: EventType) =
  # Remove all events of a given type (single-pass compaction).
  var j = 0
  for i in 0 ..< s.events.len:
    if s.events[i].kind != kind:
      if j != i: s.events[j] = s.events[i]
      inc j
  s.events.setLen(j)
  s.next_event = if s.events.len > 0: s.events[^1].cycles else: high(CycleCount)

proc call_current*(s: Scheduler) =
  while s.events.len > 0:
    let ev = s.events[^1]
    if s.cycles < ev.cycles:
      s.next_event = ev.cycles
      return
    s.events.setLen(s.events.len - 1)
    s.dispatch(ev.kind)
  s.next_event = high(CycleCount)

proc tick*(s: Scheduler; cycles: int) =
  if s.cycles + CycleCount(cycles) < s.next_event:
    s.cycles += CycleCount(cycles)
  else:
    for _ in 0 ..< cycles:
      s.cycles += 1
      s.call_current()

proc fast_forward*(s: Scheduler) =
  s.cycles = s.next_event
  s.call_current()

proc rebase*(s: Scheduler) =
  ## Subtract current cycle count from all event targets and reset to zero.
  ## Prevents overflow when using uint32 cycle counters.
  let base = s.cycles
  for i in 0 ..< s.events.len:
    s.events[i].cycles -= base
  s.next_event = if s.events.len > 0: s.events[^1].cycles else: high(CycleCount)
  s.cycles = 0

proc `speed_mode=`*(s: Scheduler; speed: uint8) =
  let old = s.current_speed
  s.current_speed = speed
  for i in 0 ..< s.events.len:
    if s.events[i].kind != etIME:
      let remaining = s.events[i].cycles - s.cycles
      let offset = remaining shr (old - speed)
      s.events[i].cycles = s.cycles + offset
  s.next_event = if s.events.len > 0: s.events[^1].cycles else: high(CycleCount)
