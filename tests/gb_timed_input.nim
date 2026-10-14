## Timed joypad input for the GB test harness: key changes placed at an exact
## machine time instead of between frames (`dingbat_test --input=...`). The
## format, its granularity and the DocBoy mapping are in tests/README.md,
## "Timed joypad input (--input)"; tests/gb_timed_input_test.nim pins the
## timing.
##
## Time is counted in dots (4.194304 MHz, DocBoy's "tick") from the hand-off:
## dot 0 is the first dot of the M-cycle that fetches the opcode at $0100. A
## timed event is applied on a 4-dot step -- the first one at or after its
## time at which it is the first due event in list order, at most one event
## per step -- before anything else in the M-cycle that starts there, so a P1
## read, an IF read or the interrupt check of that M-cycle sees it. An `@op`
## event is applied when that opcode is fetched, before the next M-cycle.
##
## Mechanism (zero cost to shipping builds; every hook is under
## `when defined(test_harness)`, src/dingbat/gb/joypad.nim): one scheduler
## event at a time, kind etHandleInput, which the GB core never books itself.
## Booking it in real time (schedule_gb) lets the scheduler carry it through
## frame rebases and speed switches and makes every fast path (the idle-loop
## and HALT skips, the speed-switch stall) stop on it. STOP mode freezes the
## scheduler, so mem_tick_stopped hands each STOP step to this module, which
## brings the event forward by that step's 4 cycles.

import std/strutils
import dingbat/gb/gb
import dingbat/common/[scheduler, input]

type
  TimedInput* = object
    at*: int64        ## dots after the hand-off (op < 0)
    op*: int          ## >= 0: applied on the fetch of this opcode instead
    keys*: seq[Input] ## changed together, as one event
    down*: bool       ## true = press, false = release

const TimedInputSyntax* =
  "--input=WHEN:KEY[+KEY]:press|release[,...]; WHEN = dots after the " &
  "hand-off (decimal) or @HH (on the fetch of opcode HH, hex); KEY = a b " &
  "select start up down left right"

proc parse_input_key*(s: string): Input =
  case s.toLowerAscii()
  of "a": Input.A
  of "b": Input.B
  of "select": Input.SELECT
  of "start": Input.START
  of "up": Input.UP
  of "down": Input.DOWN
  of "left": Input.LEFT
  of "right": Input.RIGHT
  else: raise newException(ValueError, "unknown button: " & s)

proc parse_timed_inputs*(spec: string): seq[TimedInput] =
  ## `WHEN:KEY[+KEY]:ACTION` items, comma-separated, in list order (which
  ## breaks ties: see the module doc). Raises ValueError on a malformed item.
  for raw in spec.split(','):
    let item = raw.strip()
    if item.len == 0: continue
    let parts = item.split(':')
    if parts.len != 3:
      raise newException(ValueError, "want WHEN:KEY:ACTION, got " & item)
    var ev = TimedInput(op: -1)
    let w = parts[0].strip()
    if w.startsWith("@"):
      ev.op = parseHexInt(w[1 .. ^1])
      if ev.op notin 0 .. 255:
        raise newException(ValueError, "opcode out of range: " & w)
    else:
      ev.at = parseBiggestInt(w)
      if ev.at < 0: raise newException(ValueError, "negative time: " & w)
    for k in parts[1].split('+'): ev.keys.add(parse_input_key(k.strip()))
    case parts[2].strip().toLowerAscii()
    of "press", "pressed": ev.down = true
    of "release", "released": ev.down = false
    else: raise newException(ValueError, "want press or release, got " & parts[2])
    result.add(ev)

# One armed machine at a time (the harness runs one GB per process).
var pending: seq[(int, TimedInput)]  # (list index, event), list order
var booked_dot: int64 = -1   # the step the pending etHandleInput stands for
var applied: seq[(int64, int)]  # (dot or -1, list index) per applied event

proc step_of(e: TimedInput): int64 = (e.at + 3) div 4 * 4

proc next_step(after: int64): int64 =
  ## The first 4-dot step at or after `after` at which a timed event is due.
  result = -1
  for (_, e) in pending:
    if e.op < 0:
      let s = max(after, step_of(e))
      if result < 0 or s < result: result = s

proc apply(gb: GB; idx: int; e: TimedInput; dot: int64) =
  for k in e.keys: gb.handle_input(k, e.down)
  applied.add((dot, idx))

proc refresh_ops() =
  gb_harness_ops = {}
  for (_, e) in pending:
    if e.op >= 0: gb_harness_ops.incl(uint8(e.op))

proc book(gb: GB; now: int64; here_to_now: int) =
  ## Book the next due step after `now`. `here_to_now`: scheduler cycles from
  ## the scheduler's present position to the dispatch point of `now`.
  let next = next_step(now + 4)
  if next < 0:
    booked_dot = -1
    return
  # The dispatch point of dot d is the end of the first scheduler tick of the
  # M-cycle starting at d (cycles(d) + 4): handlers observe the cycle they
  # were booked for, and mem_read samples after its tick (memory.nim).
  gb.scheduler.schedule(
    here_to_now + int((next - now) shl gb.scheduler.speed), etHandleInput)
  booked_dot = next

proc fire(gb: GB; here_to_now: int) =
  let now = booked_dot
  for i, (idx, e) in pending:
    if e.op < 0 and e.at <= now:
      let ev = e
      pending.delete(i)
      apply(gb, idx, ev, now)
      break
  book(gb, now, here_to_now)

proc on_input(gb: GB; stopped: bool) {.nimcall.} =
  if not stopped:
    fire(gb, 0)
    return
  # STOP mode: the scheduler stands still, so this step's 4 cycles are taken
  # off the booked event; once it falls inside this step it is applied here.
  if booked_dot < 0: return
  let due = gb.scheduler.pending_at(etHandleInput)
  if due == high(CycleCount): return
  if due <= gb.scheduler.cycles + 4:
    gb.scheduler.clear(etHandleInput)
    fire(gb, 4)
  else:
    gb.scheduler.advance_pending(etHandleInput, gb.scheduler.cycles, 4)

proc on_op(gb: GB; opcode: uint8) {.nimcall.} =
  for i, (idx, e) in pending:
    if e.op == int(opcode):
      let ev = e
      pending.delete(i)
      apply(gb, idx, ev, -1)
      break
  refresh_ops()

proc arm_timed_inputs*(gb: GB; events: seq[TimedInput]) =
  ## Install `events` on `gb`. Call after post_init and before the first
  ## step: the scheduler's present position is the start of dot 0.
  gb.scheduler.clear(etHandleInput)
  pending = @[]
  for i, e in events: pending.add((i, e))
  applied = @[]
  gb_harness_input = on_input
  gb_harness_op = on_op
  refresh_ops()
  booked_dot = 0
  let first = next_step(0)
  if first < 0:
    booked_dot = -1
    return
  gb.scheduler.schedule(4 + int(first shl gb.scheduler.speed), etHandleInput)
  booked_dot = first

proc timed_inputs_left*(): int = pending.len
  ## Events never applied (the run ended first, or the opcode never ran).

proc timed_inputs_applied*(): seq[(int64, int)] = applied
  ## (dot, list index) per applied event, in order; dot is -1 for `@op`.
