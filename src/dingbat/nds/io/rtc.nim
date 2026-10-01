## ARM7 RTC port 0x4000138: a Seiko S-35180 bit-banged through three GPIO
## lines (GBATEK "DS Real-Time Clock"): bit 0 data, bit 1 /SCK, bit 2 CS,
## bits 4-6 their directions (1 = the CPU drives the line).
##
## A transfer starts on CS rising. Bytes go LSB first: the CPU drives a data
## bit with /SCK low and the chip samples it when /SCK rises; for reads the
## chip drives a bit on each /SCK falling edge and the CPU samples it after
## the rise. The first byte is the command `0110 ccc r` (bits 0-3 the fixed
## code 6, 4-6 the register, 7 = read). Software that sends commands MSB
## first (the Seiko datasheet's order) numbers the registers bit-reversed;
## the fixed code reads the same either way, so nothing here changes.
##
## Time is counted in ticks of the chip's 32768 Hz crystal: the host's local
## time, or (`set_fixed_clock`) a fixed start plus emulated time, plus the
## offset the software's writes set, plus the clock-adjust register's rate
## correction. Same chip family as the GBA cart RTC, so the calendar
## arithmetic is gba/rtc_calendar.nim's; the register layout differs (DS
## hour: AM/PM is bit 6).
##
## Interrupts (GBATEK "DS Real-Time Clock", Interrupt; Seiko S-35190A
## datasheet Rev.4.2 "INT Pin Output Mode", which numbers bits the other way
## round: its B7 is bit 0 here): status 2 bits 0-3 select INT1 (selected
## frequency, per-minute edge, minute-periodical 1/2, alarm 1, 32 kHz), bit 6
## enables alarm 2. Both drive one open-drain /INT pin, wired to SIO SI; with
## RCNT in general-purpose mode and bit 8 set, SI falling raises IF.7. RCNT
## lives here because on the DS its only job is that wire. DSi extended
## commands are not modelled.

import std/times
import ../../gba/rtc_calendar
import ../sched
import irq

type
  RtcState = enum rsIdle, rsCommand, rsWrite, rsRead

  IntMode = enum
    imNone, imFreq, imMinuteEdge, imMinuteSteady1, imAlarm, imMinuteSteady2, im32k

  Rtc* = ref object
    reg*: uint16              ## last value written to the port
    state: RtcState
    command: int              ## register 0..7 (forward bit order)
    buf: array[7, uint8]      ## parameter bytes of the running access
    count: int                ## parameter bytes the register takes
    index: int                ## byte being shifted
    bit: int                  ## bit within it
    shift: uint8              ## byte being received
    out_bit: uint8            ## data line the chip drives
    stat1*, stat2*: uint8
    alarm1*, alarm2*: array[3, uint8]
    adjust*, free*: uint8
    offset*: int64            ## ticks: calendar time minus the base clock
    weekday_offset*: int      ## register weekday minus calendar weekday
    adj_since: int64          ## base ticks when `adjust` was last written
    sched* {.cursor.}: NdsScheduler  ## for interrupt events (nil: none)
    fixed*: bool              ## clock follows emulated time from `fixed_start`
    fixed_start*: int64       ## ticks at emulated cycle 0
    slept*: int64             ## master cycles spent in sleep (the crystal runs on)
    # /INT
    last_ticks: int64         ## time of the last update (minute carries)
    int1_latch, int2_latch: bool  ## alarm / per-minute edge outputs held low
    minute_started: bool      ## per-minute modes: first carry since selected
    si_high: bool             ## SI level at the last evaluation
    next_due*: int64          ## RTC clock (sched.now + slept) of the next check
    rcnt*: uint16             ## RCNT 0x4000134
    irq* {.cursor.}: IrqCtl

const
  TICK_HZ* = 32768'i64
  MINUTE_TICKS = 60 * TICK_HZ
  PULSE_TICKS = 256           ## minute-periodical 2: "L" for 7.81 ms
  STAT1_RESET = 0x01'u8
  STAT1_24H = 0x02'u8
  STAT1_RW = 0x0E'u8          ## 12/24 + two general-purpose bits
  STAT1_INT1 = 0x10'u8
  STAT1_INT2 = 0x20'u8
  STAT1_READ_CLEARS = 0xF0'u8 ## INT flags, power-low, power-off
  STAT2_INT2AE = 0x40'u8

proc cycles_to_ticks(c: int64): int64 =
  (c div MASTER_HZ) * TICK_HZ + (c mod MASTER_HZ) * TICK_HZ div MASTER_HZ

proc host_ticks(): int64 =
  let t = getTime()
  let s = t.toUnix
  (s + local_zone_offset(s)) * TICK_HZ + int64(t.nanosecond) * TICK_HZ div 1_000_000_000

proc new_rtc*(): Rtc =
  ## The state the firmware leaves: 24-hour mode, power flags clear, no
  ## interrupt selected, clock on the host's local time.
  Rtc(stat1: STAT1_24H, rcnt: 0x8000, si_high: true, next_due: high(int64),
      last_ticks: -1)

proc clock_cycles(r: Rtc): int64 {.inline.} = r.sched.now + r.slept

proc base_ticks(r: Rtc): int64 =
  ## Host local time, or (`fixed`) a fixed start plus emulated time, for
  ## reproducible runs.
  if r.fixed: r.fixed_start + cycles_to_ticks(r.clock_cycles()) else: host_ticks()

proc correction(r: Rtc; elapsed: int64): int64 =
  ## Clock adjustment (datasheet "Function of Clock Correction", Table 14/15):
  ## bits 0-6 = N, bit 7 = every 60 s instead of 20 s. N = 1..63 speeds the
  ## clock up by N steps of 3.052 ppm (1.017 ppm), 64..127 slows it by
  ## 128 - N steps, 0 = off. One step is one tick per 10 s (30 s). The chip
  ## applies it in jumps every 20 s (60 s); here it is spread evenly.
  let n = int64(r.adjust and 0x7F)
  if n == 0: return 0
  let steps = if n < 64: n else: n - 128
  let per = if (r.adjust and 0x80) != 0: 30 * TICK_HZ else: 10 * TICK_HZ
  elapsed * steps div per

proc now_ticks*(r: Rtc): int64 =
  let b = r.base_ticks()
  b + r.offset + r.correction(b - r.adj_since)

proc now_seconds(r: Rtc): int64 = r.now_ticks() div TICK_HZ

proc rebase(r: Rtc) =
  ## Fold the correction so far into `offset` (before `adjust` or the time
  ## changes).
  let b = r.base_ticks()
  r.offset += r.correction(b - r.adj_since)
  r.adj_since = b

proc set_fixed_clock*(r: Rtc; sched: NdsScheduler; calendar_seconds: int64) =
  ## Run the clock from emulated time, starting at `calendar_seconds`.
  r.sched = sched
  r.fixed = true
  r.fixed_start = calendar_seconds * TICK_HZ - cycles_to_ticks(r.clock_cycles())
  r.offset = 0
  r.adj_since = r.base_ticks()
  r.last_ticks = r.now_ticks()

proc param_bytes(cmd: int; stat2: uint8): int =
  case cmd
  of 0, 4, 3, 7: 1
  of 2: 7
  of 6, 5: 3
  of 1: (if (stat2 and 0x04) != 0: 3 else: 1)  # INT1: alarm (GBATEK: stat2 bit 2) or frequency
  else: 1

proc hour_reg(r: Rtc; h: int): uint8 =
  let pm = if h >= 12: 0x40'u8 else: 0'u8
  if (r.stat1 and STAT1_24H) != 0: bcd(h) or pm
  else: bcd(h mod 12) or pm

proc hour_written(r: Rtc; v: uint8): int =
  let h = from_bcd(v and 0x3F)
  if (r.stat1 and STAT1_24H) != 0:
    if h < 0 or h > 23: 0 else: h
  else:
    let base = if h < 0 or h > 11: 0 else: h
    if (v and 0x40) != 0: base + 12 else: base

# --- /INT and SI ------------------------------------------------------------

proc int1_mode(r: Rtc): IntMode =
  ## Status 2 bits 0-3 = INT1FE, INT1ME, INT1AE, 32kE (datasheet Table 11).
  let m = r.stat2 and 0x0F
  if (m and 8) != 0: return im32k
  case m and 7
  of 1, 5: imFreq
  of 2, 6: imMinuteEdge
  of 3: imMinuteSteady1
  of 4: imAlarm
  of 7: imMinuteSteady2
  else: imNone

proc alarm_match(r: Rtc; a: array[3, uint8]; t: int64): bool =
  ## Each byte's bit 7 enables its comparison (day of week, hour with its
  ## AM/PM bit as the hour register reads, minute).
  let c = from_calendar_seconds(t div TICK_HZ)
  let wd = (c.weekday + r.weekday_offset + 7) mod 7
  if (a[0] and 0x80) != 0 and int(a[0] and 7) != wd: return false
  if (a[1] and 0x80) != 0 and (a[1] and 0x7F) != (r.hour_reg(c.hour) and 0x7F): return false
  if (a[2] and 0x80) != 0 and (a[2] and 0x7F) != bcd(c.minute): return false
  true

proc minute_carry(r: Rtc; t: int64) =
  ## The seconds counter wrapped to 00 (datasheet: alarms compare, and the
  ## per-minute modes start, at minute-carry processing).
  let mode = r.int1_mode()
  if mode in {imMinuteEdge, imMinuteSteady1, imMinuteSteady2}: r.minute_started = true
  if mode == imMinuteEdge: r.int1_latch = true
  if mode == imAlarm and r.alarm_match(r.alarm1, t):
    r.int1_latch = true
    r.stat1 = r.stat1 or STAT1_INT1
  if (r.stat2 and STAT2_INT2AE) != 0 and r.alarm_match(r.alarm2, t):
    r.int2_latch = true
    r.stat1 = r.stat1 or STAT1_INT2

proc int_low(r: Rtc; t: int64): bool =
  ## /INT asserted at tick `t`. Selected frequencies (datasheet Figure 19/20):
  ## each k Hz square wave is low for the first half of its period, aligned to
  ## the seconds counter, and /INT is low while any selected one is.
  result = r.int2_latch
  case r.int1_mode()
  of imNone: discard
  of imFreq:
    let f = t mod TICK_HZ
    let sel = r.alarm1[2] and 0x1F
    for k in 0..4:
      if (sel and (1'u8 shl k)) != 0:
        let period = TICK_HZ shr k
        if f mod period < period div 2: result = true
  of imMinuteEdge, imAlarm: result = result or r.int1_latch
  of imMinuteSteady1:
    if r.minute_started and (t div TICK_HZ) mod 60 < 30: result = true
  of imMinuteSteady2:
    if r.minute_started and t mod MINUTE_TICKS < PULSE_TICKS: result = true
  of im32k:
    # 32768 Hz: low in the first half of each tick, at cycle resolution
    if r.sched != nil:
      result = result or ((r.clock_cycles() * 2 * TICK_HZ div MASTER_HZ) and 1) == 0

proc gp_mode(r: Rtc): bool {.inline.} = (r.rcnt and 0xC000) == 0x8000

proc si_level(r: Rtc; int_low: bool): bool =
  ## SI: the open-drain /INT against the line's pull-up, or ANDed with the
  ## CPU's own drive when RCNT makes SI an output (GBATEK: RCNT=8144h works
  ## as a pull-up).
  result = not int_low
  if r.gp_mode() and (r.rcnt and 0x40) != 0: result = result and (r.rcnt and 4) != 0

proc si_edge(r: Rtc; high: bool) =
  ## SI falling raises IF.7 in general-purpose mode with RCNT.8 set (GBATEK
  ## "DS Real-Time Clock", Interrupt). Turning RCNT.8 on while SI is low is
  ## not an edge.
  if r.si_high and not high and r.gp_mode() and (r.rcnt and 0x100) != 0 and r.irq != nil:
    r.irq.raise_irq(irqSerial)
  r.si_high = high

proc update(r: Rtc) =
  ## Bring the interrupt state up to now: a minute carry since the last
  ## update, then the SI level.
  let t = r.now_ticks()
  if r.last_ticks >= 0 and t div MINUTE_TICKS > r.last_ticks div MINUTE_TICKS:
    r.minute_carry(t)
  r.last_ticks = t
  r.si_edge(r.si_level(r.int_low(t)))

proc irq_wanted(r: Rtc): bool {.inline.} =
  r.gp_mode() and (r.rcnt and 0x100) != 0

proc schedule_next(r: Rtc) =
  ## Book the next moment the pin can change (evRtc), or nothing when no
  ## interrupt is selected. Ticks become master cycles at the nominal rate;
  ## the event re-reads the clock, so drift or a host clock only re-polls.
  r.next_due = high(int64)
  if r.sched == nil: return
  let t = r.last_ticks
  var next = high(int64)
  let mode = r.int1_mode()
  if mode in {imMinuteEdge, imMinuteSteady1, imMinuteSteady2, imAlarm} or
     (r.stat2 and STAT2_INT2AE) != 0:
    next = (t div MINUTE_TICKS + 1) * MINUTE_TICKS
  case mode
  of imFreq:
    # every selected wave changes on a multiple of 1/32 s (16 Hz's half period)
    if (r.alarm1[2] and 0x1F) != 0: next = min(next, (t div 1024 + 1) * 1024)
  of imMinuteSteady1: next = min(next, (t div (30 * TICK_HZ) + 1) * 30 * TICK_HZ)
  of imMinuteSteady2:
    if t mod MINUTE_TICKS < PULSE_TICKS: next = min(next, t - t mod MINUTE_TICKS + PULSE_TICKS)
  of im32k:
    if r.irq_wanted(): next = min(next, t + 1)
  else: discard
  if next == high(int64):
    r.sched.cancel(evRtc)
    return
  let cycles = ((next - t) * MASTER_HZ + TICK_HZ - 1) div TICK_HZ
  r.next_due = r.clock_cycles() + max(cycles, 1)
  r.sched.schedule(r.next_due - r.slept, evRtc)

proc on_event*(r: Rtc) =
  ## evRtc (or a due check while asleep).
  r.update()
  if r.int1_mode() == im32k and r.irq_wanted() and r.irq != nil:
    r.irq.raise_irq(irqSerial)   # one falling edge per tick
  r.schedule_next()

proc refresh(r: Rtc) =
  r.update()
  r.schedule_next()

proc read_rcnt*(r: Rtc): uint16 =
  ## General-purpose mode: bits 0-3 read the lines (SC, SD, SI, SO): an
  ## output reads what is driven, SI as input the /INT wire, the others as
  ## inputs their pull-ups (GBATEK "SIO General-Purpose Mode").
  if r.sched != nil: r.update()
  result = r.rcnt
  if r.gp_mode():
    for i in 0..3:
      if (r.rcnt and (0x10'u16 shl i)) == 0:
        let high = if i == 2: r.si_high else: true
        result = (result and not (1'u16 shl i)) or (if high: 1'u16 shl i else: 0)

proc write_rcnt*(r: Rtc; v, mask: uint16) =
  r.rcnt = (r.rcnt and not mask) or (v and mask and 0xC1FF'u16)
  r.refresh()

# --- registers ---------------------------------------------------------------

proc load_read(r: Rtc) =
  ## Fill `buf` with the register's current contents.
  case r.command
  of 0:
    r.buf[0] = r.stat1 and not STAT1_RESET
    r.stat1 = r.stat1 and not STAT1_READ_CLEARS
  of 4: r.buf[0] = r.stat2
  of 2, 6:
    let s = r.now_seconds()
    let c = from_calendar_seconds(s)
    let wd = (c.weekday + r.weekday_offset + 7) mod 7
    let t = [bcd(c.year mod 100), bcd(c.month), bcd(c.day), uint8(wd),
             r.hour_reg(c.hour), bcd(c.minute), bcd(c.second)]
    if r.command == 2:
      for i in 0..6: r.buf[i] = t[i]
    else:
      for i in 0..2: r.buf[i] = t[4 + i]
  of 1:
    if r.count == 3:
      for i in 0..2: r.buf[i] = r.alarm1[i]
    else: r.buf[0] = r.alarm1[2]   # frequency register shares alarm1 minute
  of 5: (for i in 0..2: r.buf[i] = r.alarm2[i])
  of 3: r.buf[0] = r.adjust
  else: r.buf[0] = r.free

proc reset_chip(r: Rtc) =
  ## Datasheet "Register Status After Initialization": everything 00h, the
  ## clock at 2000-01-01 00:00:00 (status 1 keeps the bits written with the
  ## reset, below).
  r.stat1 = 0
  r.stat2 = 0
  r.alarm1 = [0'u8, 0, 0]
  r.alarm2 = [0'u8, 0, 0]
  r.adjust = 0
  r.free = 0
  r.int1_latch = false
  r.int2_latch = false
  r.minute_started = false
  r.adj_since = r.base_ticks()
  r.offset = CAL_2000_01_01 * TICK_HZ - r.adj_since
  r.weekday_offset = 0
  r.last_ticks = r.now_ticks()

proc set_datetime(r: Rtc; date: bool) =
  ## Store a written date+time (7 bytes) or time (3 bytes). The divider
  ## below one second restarts at the write (Assumed).
  let cur = from_calendar_seconds(r.now_seconds())
  var year = cur.year
  var month = cur.month
  var day = cur.day
  var t0 = 0
  if date:
    let y = from_bcd(r.buf[0])
    year = 2000 + max(y, 0)
    month = clamp(from_bcd(r.buf[1] and 0x1F), 1, 12)
    day = clamp(from_bcd(r.buf[2] and 0x3F), 1, days_in_month(year, month))
    t0 = 4
  let h = r.hour_written(r.buf[t0])
  let mi = clamp(from_bcd(r.buf[t0 + 1] and 0x7F), 0, 59)
  let se = clamp(from_bcd(r.buf[t0 + 2] and 0x7F), 0, 59)
  let s = to_calendar_seconds(year, month, day, h, mi, se)
  r.rebase()
  r.offset = s * TICK_HZ - r.adj_since
  if date:
    r.weekday_offset = int(r.buf[3] and 7) - calendar_weekday(s)
  r.last_ticks = r.now_ticks()     # a written time is not a minute carry

proc store_write(r: Rtc) =
  ## All parameter bytes of a write have arrived.
  case r.command
  of 0:
    if (r.buf[0] and STAT1_RESET) != 0: r.reset_chip()
    r.stat1 = (r.stat1 and not STAT1_RW) or (r.buf[0] and STAT1_RW)
  of 4:
    let old_mode = r.int1_mode()
    r.stat2 = r.buf[0]
    if r.int1_mode() != old_mode:
      # a newly selected mode starts over; leaving alarm / edge mode is what
      # releases the pin (datasheet: "set 0 in INT1AE / INT1ME")
      r.int1_latch = false
      r.minute_started = false
    if (r.stat2 and STAT2_INT2AE) == 0: r.int2_latch = false
  of 2: r.set_datetime(true)
  of 6: r.set_datetime(false)
  of 1:
    if r.count == 3:
      for i in 0..2: r.alarm1[i] = r.buf[i]
    else: r.alarm1[2] = r.buf[0]
  of 5: (for i in 0..2: r.alarm2[i] = r.buf[i])
  of 3:
    r.rebase()
    r.adjust = r.buf[0]
  else: r.free = r.buf[0]
  if r.command != 7: r.refresh()

proc byte_in(r: Rtc; b: uint8) =
  case r.state
  of rsCommand:
    let c = b
    if (c and 0x0F) != 0x06:
      r.state = rsIdle            # not a command: ignore until CS drops
      return
    r.command = int((c shr 4) and 7)
    r.count = param_bytes(r.command, r.stat2)
    r.index = 0
    if r.sched != nil: r.update()  # flags and time as of the command
    if (c and 0x80) != 0:
      r.state = rsRead
      r.load_read()
    else:
      r.state = rsWrite
  of rsWrite:
    if r.index < r.count:
      r.buf[r.index] = b
      inc r.index
      if r.index == r.count: r.store_write()
  else: discard

proc read_reg*(r: Rtc): uint16 =
  ## Lines the CPU drives read back as written; the data line, when the CPU
  ## has it as an input, reads what the chip drives.
  result = r.reg
  if (r.reg and 0x10) == 0:
    result = (result and not 1'u16) or uint16(r.out_bit)

proc write_reg*(r: Rtc; v: uint16) =
  let old = r.reg
  r.reg = v
  let cs = (v and 4) != 0
  let sck = (v and 2) != 0
  let was_cs = (old and 4) != 0
  let was_sck = (old and 2) != 0
  if not cs:
    r.state = rsIdle
    return
  if not was_cs:
    r.state = rsCommand
    r.bit = 0
    r.shift = 0
    return
  if was_sck and not sck:
    # falling edge: the chip drives its next bit
    if r.state == rsRead:
      let i = min(r.index, r.count - 1)
      r.out_bit = (r.buf[i] shr r.bit) and 1
  elif sck and not was_sck:
    # rising edge: a bit moves
    if r.state in {rsCommand, rsWrite}:
      r.shift = r.shift or (uint8(v and 1) shl r.bit)
    inc r.bit
    if r.bit == 8:
      r.bit = 0
      if r.state == rsRead:
        if r.index < r.count - 1: inc r.index
      else:
        let b = r.shift
        r.shift = 0
        r.byte_in(b)

proc sleep_advance*(r: Rtc; cycles: int64; stop: proc(): bool) =
  ## The machine is asleep (its clocks stopped) for `cycles` master cycles;
  ## the RTC's crystal runs on, so due checks happen at their times. Returns
  ## early, at that check's time, once `stop` (a wake-up) is true.
  if r.sched == nil:
    r.slept += cycles
    return
  let stop_at = r.slept + cycles
  while r.next_due <= r.sched.now + stop_at:
    r.slept = max(r.slept, r.next_due - r.sched.now)
    r.on_event()
    if stop(): break
  if not stop(): r.slept = stop_at
  if not r.fixed: r.update()   # host clock: poll once
  # the booked event is in the frozen timeline's terms; move it by the sleep
  if r.next_due != high(int64): r.sched.schedule(r.next_due - r.slept, evRtc)
