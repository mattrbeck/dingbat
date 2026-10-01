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
## The clock runs from the host's local time plus whatever offset the
## software's writes set. Same chip family as the GBA cart RTC, so the
## calendar arithmetic is gba/rtc_calendar.nim's; the register layout
## differs (DS hour: AM/PM is bit 6). TODO(rtc): INT1/INT2 alarms and
## frequency interrupts (to SIO SI, IF.7), the clock adjustment register's
## effect, and DSi extended commands.

import std/times
import ../../gba/rtc_calendar

type
  RtcState = enum rsIdle, rsCommand, rsWrite, rsRead

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
    offset*: int64            ## calendar seconds minus host local time
    weekday_offset*: int      ## register weekday minus calendar weekday

const
  STAT1_RESET = 0x01'u8
  STAT1_24H = 0x02'u8
  STAT1_RW = 0x0E'u8          ## 12/24 + two general-purpose bits
  STAT1_READ_CLEARS = 0xF0'u8 ## INT flags, power-low, power-off

proc host_seconds(): int64 =
  let now = getTime().toUnix
  now + local_zone_offset(now)

proc new_rtc*(): Rtc =
  ## The state the firmware leaves: 24-hour mode, power flags clear, clock
  ## on the host's local time.
  Rtc(stat1: STAT1_24H)

proc now_seconds(r: Rtc): int64 = host_seconds() + r.offset

proc param_bytes(cmd: int; stat2: uint8): int =
  case cmd
  of 0, 4, 3, 7: 1
  of 2: 7
  of 6, 5: 3
  of 1: (if (stat2 and 0x0F) == 0x04: 3 else: 1)  # INT1: alarm or frequency
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
  r.stat1 = 0
  r.stat2 = 0
  r.alarm1 = [0'u8, 0, 0]
  r.alarm2 = [0'u8, 0, 0]
  r.adjust = 0
  r.free = 0
  # 2000-01-01 00:00:00
  r.offset = CAL_2000_01_01 - host_seconds()
  r.weekday_offset = 0

proc set_datetime(r: Rtc; date: bool) =
  ## Store a written date+time (7 bytes) or time (3 bytes).
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
  r.offset = s - host_seconds()
  if date:
    r.weekday_offset = int(r.buf[3] and 7) - calendar_weekday(s)

proc store_write(r: Rtc) =
  ## All parameter bytes of a write have arrived.
  case r.command
  of 0:
    if (r.buf[0] and STAT1_RESET) != 0: r.reset_chip()
    r.stat1 = (r.stat1 and not STAT1_RW) or (r.buf[0] and STAT1_RW)
  of 4: r.stat2 = r.buf[0]
  of 2: r.set_datetime(true)
  of 6: r.set_datetime(false)
  of 1:
    if r.count == 3:
      for i in 0..2: r.alarm1[i] = r.buf[i]
    else: r.alarm1[2] = r.buf[0]
  of 5: (for i in 0..2: r.alarm2[i] = r.buf[i])
  of 3: r.adjust = r.buf[0]
  else: r.free = r.buf[0]

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
