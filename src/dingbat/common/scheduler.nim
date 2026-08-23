import serialize

when defined(emscripten):
  type CycleCount* = uint32
else:
  type CycleCount* = uint64

const MAX_EVENTS* = 64  # far above the ~15 events ever pending at once

# MAX_EVENTS is a save-state acceptance floor, not just a capacity: load_from
# refuses a state with more pending events, so lowering it rejects existing
# files (pinned in tests/savestate_compat_test.nim).
#
# `pad` (save_to/load_from): this is the only variable-length section in either
# core's payload and it precedes the big fixed-size arrays, so one event coming
# or going shifts everything behind it and the rewind ring's XOR delta then
# compares misaligned memory. Padding to MAX_EVENTS fixes the payload length.
# ON for in-process payloads only (rewind ring, rollback snapshots); OFF for
# anything reaching a file, which keeps the .state format unchanged.

# Acceptance floors for a pending event's distance from "now" in a state file
# (lowering either rejects existing states; pinned in
# tests/savestate_compat_test.nim). HORIZON: the furthest real booking is a
# GBA timer at prescaler 1024 over a full 16-bit period (~67M cycles); 1<<28
# is four times that and 1/16 of the emscripten uint32 CycleCount. OVERDUE:
# call_current drains lazily, so an event may sit at most a frame in the past.
const
  MAX_EVENT_HORIZON* = CycleCount(1'u32 shl 28)
  MAX_EVENT_OVERDUE* = CycleCount(1'u32 shl 24)

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
    # Appended, never inserted: ordinals are save-state format (pinned at
    # compile time in tests/savestate_compat_test.nim).
    # Game Boy Camera capture countdown.
    etCameraDone
    # A CGB LYC write's owed STAT edge, one M-cycle after the byte lands
    # (CGB_LYC_EDGE_DEFER in gb/gb.nim).
    etGbLycEdge

  Event* = object
    cycles*: CycleCount
    kind*: EventType

  Scheduler* = ref object
    # Sorted descending by target cycle (soonest last); fixed array, O(1) pop
    evbuf: array[MAX_EVENTS, Event]
    nevents: int
    cycles*: CycleCount
    # Exposed so the GBA bus catch-up can test "no event due" inline
    next_event*: CycleCount
    current_speed: uint8
    # True while a handler runs; guards against re-entrant tick()
    dispatching*: bool
    dispatch*: proc(kind: EventType) {.closure.}
    # Deferred-work pump, run after a dispatch with dispatching already false
    # so it can advance the clock and dispatch nested events (GBA DMA priority
    # preemption). Nil for GB. Only invoked when a handler set pump_requested.
    pump*: proc() {.closure.}
    pump_requested*: bool

proc new_scheduler*(): Scheduler =
  result = Scheduler(next_event: high(CycleCount))

proc speed*(s: Scheduler): uint8 {.inline.} = s.current_speed
  ## CGB speed shift (0 = normal, 1 = double). schedule_gb scales every
  ## real-time delay by this; deadlines kept outside evbuf (GB APU channels)
  ## must too, and must be rescaled with the events on a speed switch.

iterator events*(s: Scheduler): Event =
  ## Pending events, soonest last (kept for debug UIs and RTC queries)
  for i in 0 ..< s.nevents:
    yield s.evbuf[i]

proc schedule*(s: Scheduler; cycles: int; kind: EventType) =
  assert s.nevents < MAX_EVENTS
  let target = s.cycles + CycleCount(cycles)
  # Ties keep the newest event at the higher index so it pops first
  var i = s.nevents
  while i > 0 and s.evbuf[i - 1].cycles < target:
    s.evbuf[i] = s.evbuf[i - 1]
    dec i
  s.evbuf[i] = Event(cycles: target, kind: kind)
  inc s.nevents
  s.next_event = s.evbuf[s.nevents - 1].cycles

proc schedule_gb*(s: Scheduler; cycles: int; kind: EventType) =
  var c = cycles
  # etIME and etGbLycEdge are counted in M-cycles (4 CPU cycles at either
  # speed), so they are not scaled; `speed_mode=` exempts the same two.
  if kind != etIME and kind != etGbLycEdge:
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
  ## Whether an event of this kind is still pending; the GBA state loader uses
  ## it to tell a recognised pending interrupt from a check still in flight.
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
  # Jump to each due event's timestamp so handlers observe the exact cycle
  # they were scheduled for. Quota-based (remaining cycles on top of the live
  # clock) rather than an absolute target: a dispatch can re-entrantly advance
  # the clock (a GBA DMA burst pumped from a handler), and the rest of the
  # quota must apply after that.
  var remaining = cycles
  while s.cycles + remaining >= s.next_event:
    remaining -= s.next_event - s.cycles
    s.cycles = s.next_event
    s.call_current()
  s.cycles += remaining

proc tick*(s: Scheduler; cycles: int) {.inline.} =
  # Kept tiny so it inlines into the CPU instruction loop
  let n = CycleCount(cycles)
  if s.cycles + n < s.next_event:
    s.cycles += n
  else:
    s.tick_slow(n)

proc fast_forward*(s: Scheduler) =
  s.cycles = s.next_event
  s.call_current()

proc fast_forward_bounded*(s: Scheduler; bound: CycleCount) =
  ## fast_forward that may not skip past `bound`. The skip length is an idle
  ## loop's sampling resolution of any register it polls, so callers keeping
  ## deadlines outside evbuf must pass their soonest one here, or moving
  ## deadlines out of the scheduler coarsens every idle loop. When the bound
  ## bites nothing is due, so nothing is dispatched. `bound` must be strictly
  ## ahead of `cycles` (or high(CycleCount) for "no bound").
  if bound < s.next_event:
    s.cycles = bound
  else:
    s.cycles = s.next_event
    s.call_current()

proc rebase*(s: Scheduler; keep_phase_mask: CycleCount = 0): CycleCount {.discardable.} =
  ## Subtract the current cycle count (rounded down to keep the low
  ## keep_phase_mask bits; GBA timers derive prescaler phase from it) from all
  ## event targets and return the base. Callers must hand it to
  ## gb_rebase/apu_rebase: the GB APU keeps deadlines outside this array.
  let base = s.cycles and not keep_phase_mask
  for i in 0 ..< s.nevents:
    s.evbuf[i].cycles -= base
  s.next_event = if s.nevents > 0: s.evbuf[s.nevents - 1].cycles else: high(CycleCount)
  s.cycles -= base
  base

proc save_to*(s: Scheduler; w: var Writer; pad = false) =
  ## Event kinds are written by ordinal; the dispatch closure is not
  ## serialized. `pad` writes MAX_EVENTS slots so the section has a fixed
  ## length (see the note at MAX_EVENTS); off for anything reaching a file.
  w.write_u64(uint64(s.cycles))
  w.write_u8(s.current_speed)
  w.write_u8(uint8(s.nevents))
  for i in 0 ..< s.nevents:
    w.write_u8(uint8(ord(s.evbuf[i].kind)))
    w.write_u64(uint64(s.evbuf[i].cycles))
  if pad:
    for i in s.nevents ..< MAX_EVENTS:
      w.write_u8(0'u8)
      w.write_u64(0'u64)

proc load_from*(s: Scheduler; r: var Reader; pad = false) =
  ## Events are stored in internal order (soonest last) and restored verbatim.
  let cycles = r.read_u64()
  let speed = r.read_u8()
  let n = int(r.read_u8())
  if n > MAX_EVENTS:
    raise state_error("too many scheduler events in state")
  s.cycles = CycleCount(cycles)
  # A shift amount (schedule_gb does `c shl current_speed`); only 0 and 1 are
  # legal. Unvalidated, a large value collapses every delay to nothing and the
  # emulator livelocks.
  check_range(int(speed), 0, 1, "scheduler.current_speed")
  s.current_speed = speed
  s.nevents = n
  for i in 0 ..< n:
    let kind = r.read_u8()
    if int(kind) > int(high(EventType)):
      raise state_error("unknown scheduler event kind in state")
    let target = CycleCount(r.read_u64())
    # Checked as a distance from `s.cycles`, not an absolute value, so one
    # guard covers both a wild cycle counter and a wild deadline (either
    # overflows the cycle arithmetic on the next step_frame with a Defect,
    # which is not a CatchableError). Unsigned wrap gives both distances,
    # including for the uint32 emscripten CycleCount.
    let ahead  = target - s.cycles
    let behind = s.cycles - target
    if ahead > MAX_EVENT_HORIZON and behind > MAX_EVENT_OVERDUE:
      raise state_error("scheduler event " & $EventType(kind) &
                        " is due an implausible distance from the current cycle")
    s.evbuf[i] = Event(cycles: target, kind: EventType(kind))
  if pad:
    for i in n ..< MAX_EVENTS:
      discard r.read_u8()
      discard r.read_u64()
  s.next_event = if n > 0: s.evbuf[n - 1].cycles else: high(CycleCount)

proc `speed_mode=`*(s: Scheduler; speed: uint8) =
  ## The GB APU's per-channel deadlines live outside evbuf; gb/memory.nim
  ## stop_instr rescales them around this call.
  let old = s.current_speed
  if speed == old: return
  s.current_speed = speed
  for i in 0 ..< s.nevents:
    # etIME and etGbLycEdge are counted in M-cycles (4 CPU cycles at both
    # speeds) and must not be rescaled; schedule_gb leaves the same two unscaled.
    if s.evbuf[i].kind != etIME and s.evbuf[i].kind != etGbLycEdge:
      # Real-time events are stored in CPU cycles, which run twice as fast in
      # double speed: entering doubles the remaining delay, leaving halves it.
      let remaining = s.evbuf[i].cycles - s.cycles
      let rescaled = if speed > old: remaining shl (speed - old)
                     else: remaining shr (old - speed)
      s.evbuf[i].cycles = s.cycles + rescaled
  s.next_event = if s.nevents > 0: s.evbuf[s.nevents - 1].cycles else: high(CycleCount)
