## Four 16-bit timers per CPU (0x4000100-0x400010F), as on the GBA, but
## clocked from the 33.51 MHz system clock on both CPUs. Counters are lazy:
## a running timer's count is derived from the cycle it was (re)started at;
## an overflow is a scheduler event (evTimer9_x / evTimer7_x).
##
## The GBA core's timer.nim is cycle-exact against an AGB SP with its own
## latch/delay quirks; those are AGB measurements, so the DS starts from
## GBATEK's plain model and earns quirks from DS evidence.

import ../sched
import irq
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

type
  Timers* = ref object
    sched* {.cursor.}: NdsScheduler
    irq* {.cursor.}: IrqCtl
    first_event*: NdsEvent          ## evTimer9_0 or evTimer7_0
    reload*: array[4, uint16]
    control*: array[4, uint16]
    counter*: array[4, uint16]      ## count at `start_at` (or frozen count)
    start_at*: array[4, int64]      ## master cycle the count was taken

const PRESCALE_SHIFT = [0, 6, 8, 10]

proc running(t: Timers; i: int): bool {.inline.} = (t.control[i] and 0x80) != 0
proc cascade(t: Timers; i: int): bool {.inline.} = i > 0 and (t.control[i] and 4) != 0

proc tick_cycles(t: Timers; i: int): int64 {.inline.} =
  ## Master cycles per count (2 per system cycle).
  2'i64 shl PRESCALE_SHIFT[t.control[i] and 3]

proc current(t: Timers; i: int): uint16 =
  if not t.running(i) or t.cascade(i): return t.counter[i]
  let elapsed = (t.sched.now - t.start_at[i]) div t.tick_cycles(i)
  uint16((int64(t.counter[i]) + elapsed) and 0xFFFF)

proc schedule_overflow(t: Timers; i: int) =
  let ev = NdsEvent(ord(t.first_event) + i)
  if not t.running(i) or t.cascade(i):
    t.sched.cancel(ev)
    return
  let left = 0x10000'i64 - int64(t.counter[i])
  t.sched.schedule(t.start_at[i] + left * t.tick_cycles(i), ev)

proc overflow*(t: Timers; i: int) =
  ## Timer i wrapped (from its event, or a cascade).
  t.counter[i] = t.reload[i]
  t.start_at[i] = t.sched.now
  if (t.control[i] and 0x40) != 0:
    t.irq.raise_bit(ord(irqTimer0) + i)
  if not t.cascade(i): t.schedule_overflow(i)
  if i < 3 and t.running(i + 1) and t.cascade(i + 1):
    t.counter[i + 1] += 1
    if t.counter[i + 1] == 0: t.overflow(i + 1)

proc on_event*(t: Timers; ev: NdsEvent) =
  t.overflow(ord(ev) - ord(t.first_event))

proc read_reg*(t: Timers; offset: uint32): uint32 =
  let i = int((offset - 0x100) shr 2)
  uint32(t.current(i)) or (uint32(t.control[i]) shl 16)

proc write_reg*(t: Timers; offset: uint32; v, mask: uint32) =
  let i = int((offset - 0x100) shr 2)
  if (mask and 0xFFFF) != 0:
    let m = uint16(mask and 0xFFFF)
    t.reload[i] = (t.reload[i] and not m) or (uint16(v) and m)
  if (mask and 0xFFFF_0000'u32) != 0:
    let now_count = t.current(i)
    let was_running = t.running(i)
    let old = t.control[i]
    t.control[i] = uint16((v shr 16) and 0xC7)
    if t.running(i) and not was_running:
      t.counter[i] = t.reload[i]
      t.start_at[i] = t.sched.now
    elif was_running and ((old xor t.control[i]) and 0x87) == 0:
      # Still running, same prescaler and cascade (an IRQ-enable toggle):
      # the count carries on, prescaler phase included.
      discard
    else:
      t.counter[i] = now_count
      t.start_at[i] = t.sched.now
    t.schedule_overflow(i)

{.pop.}
