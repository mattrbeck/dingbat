type
  EventType* = enum
    # Shared
    etAPU, etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4
    etHandleInput
    # GB
    etIME
    # GBA
    etSaves, etInterrupts, etPPU
    etTimer0, etTimer1, etTimer2, etTimer3

  Event* = object
    cycles*: uint64
    cb: proc() {.closure.}
    kind*: EventType

  Scheduler* = ref object
    events*: seq[Event]
    cycles*: uint64
    next_event: uint64
    current_speed: uint8

proc new_scheduler*(): Scheduler =
  result = Scheduler(next_event: high(uint64))
  result.events = @[]

proc schedule*(s: Scheduler; cycles: int; cb: proc() {.closure.}; kind: EventType) =
  # Insert in sorted order by target cycle.
  let target = s.cycles + uint64(cycles)
  let ev = Event(cycles: target, cb: cb, kind: kind)
  var idx = s.events.len
  for i in 0 ..< s.events.len:
    if s.events[i].cycles > target:
      idx = i
      break
  s.events.insert(ev, idx)
  s.next_event = s.events[0].cycles

proc schedule_gb*(s: Scheduler; cycles: int; cb: proc() {.closure.}; kind: EventType) =
  var c = cycles
  if kind != etIME:
    c = c shl s.current_speed
  s.schedule(c, cb, kind)

proc clear*(s: Scheduler; kind: EventType) =
  # Remove all events of a given type.
  var i = 0
  while i < s.events.len:
    if s.events[i].kind == kind:
      s.events.delete(i)
    else:
      inc i
  s.next_event = if s.events.len > 0: s.events[0].cycles else: high(uint64)

proc call_current*(s: Scheduler) =
  while true:
    if s.events.len == 0:
      s.next_event = high(uint64)
      return
    let ev = s.events[0]
    if s.cycles >= ev.cycles:
      ev.cb()
      s.events.delete(0)
    else:
      s.next_event = ev.cycles
      return

proc tick*(s: Scheduler; cycles: int) =
  if s.cycles + uint64(cycles) < s.next_event:
    s.cycles += uint64(cycles)
  else:
    for _ in 0 ..< cycles:
      s.cycles += 1
      s.call_current()

proc fast_forward*(s: Scheduler) =
  s.cycles = s.next_event
  s.call_current()

proc `speed_mode=`*(s: Scheduler; speed: uint8) =
  let old = s.current_speed
  s.current_speed = speed
  for i in 0 ..< s.events.len:
    if s.events[i].kind != etIME:
      let remaining = s.events[i].cycles - s.cycles
      let offset = remaining shr (old - speed)
      s.events[i].cycles = s.cycles + offset
