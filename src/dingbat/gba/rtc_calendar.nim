## GBA cartridge RTC (Seiko S-3511A) calendar rules and the battery-save RTC
## trailer. Pure procs, imported by gba.nim (rtc.nim, storage.nim) and tested
## directly by tests/gba_rtc_test.nim.
##
## Clock representation. The RTC's date and time are held as "calendar
## seconds": the chip's year/month/day/hour/minute/second read as a UTC civil
## time and counted in seconds since 1970-01-01. They carry no time zone; the
## chip has none. Year register 00..99 is 2000..2099 (S-3511A datasheet
## Rev. 1.4, "Year data (00 to 99) ... links together with the auto calender
## feature till 2,099"), so a calendar second before 2000 or from 2100 on is
## shown as `year mod 100`, as the chip's two-digit counter would.
##
## ---------------------------------------------------------------------------
## Battery-save RTC trailer
## ---------------------------------------------------------------------------
## Defined by FlashGBX, the GBxCart RW dumping tool (github.com/lesserkuma/
## FlashGBX): with "RTC" selected, a GBA save backup is the raw chip bytes
## followed by 16 bytes (FlashGBX/LK_Device.py `_BackupRestoreRAM`, which
## appends the 7 bytes of the cart's date/time read, the status register
## (`RTCReadStatus`, "24h mode = 0x40, reset flag = 0x80") and
## `struct.pack("<Q", int(time.time()))`; Mapper.py `AGB_GPIO.ReadRTC`).
## Lesserkuma proposed it for emulators in mGBA issue #2431 and mGBA adopted
## it in 0.10 (commit bb711d311f, "Store RTC data in savegames", closes #240);
## FlashGBX 3.19's changelog notes the format adjustments made for that.
##
##   off  len  field
##   0    1    year     BCD 00..99
##   1    1    month    BCD 01..12
##   2    1    day      BCD 01..31
##   3    1    weekday  0..6 (the chip's septenary counter)
##   4    1    hour     BCD; bit 7 = PM flag when written by FlashGBX
##   5    1    minute   BCD 00..59
##   6    1    second   BCD 00..59
##   7    1    status register (0x40 = 24-hour); older FlashGBX writes 0x01
##   8    8    u64 LE unix seconds (host clock) at which bytes 0..6 were read
##
## The date/time is a LOCAL time on the host that wrote it (FlashGBX reads a
## physical clock the owner set to local time; mGBA formats with localtime).
## A reader resumes the clock as `saved date/time + (now - latch)`.
##
## Hour byte, read: FlashGBX stores the chip register as read, and the chip
## sets bit 7 for 12..23 o'clock even in 24-hour mode (datasheet Table 11
## note *1; GBATEK "GBA Cart Real-Time Clock": AM/PM is hour bit 7 on the
## GBA). Its own restore path decodes `hour & 0x7F` as a 24-hour value, and
## emulators write the 24-hour value without the flag. Both decode with
## `hour & 0x3F`; a flag on a value below 12 is a 12-hour-mode reading and
## adds 12.
## Hour byte, written: the 24-hour value WITHOUT bit 7. FlashGBX's restore
## masks the flag off, and an emulator that decodes the byte as plain BCD
## (mGBA 0.10.5) reads 0x97 as hour 97, four days out.
##
## Trailer location: every GBA backup size is a multiple of 512 bytes (EEPROM
## 512/8192, SRAM 32768, flash 65536/131072), and writers append the trailer
## to the chip size they use, which for EEPROM is not necessarily the chip's
## (8192-byte files for 4Kbit games are common). So the trailer is the last
## 16 bytes exactly when `file length mod 512 == 16`, whatever the chip.

import std/times

const
  RTC_TRAILER_LEN* = 16
  RTC_TRAILER_CONTROL_FILLER* = 0x01'u8
    ## Older FlashGBX versions wrote 0x01 in the status byte (mGBA issue
    ## #2431: "01 ... 24h flag"); FlashGBX's own restore maps it to 0x40.
  S3511_STATUS_RW_BITS* = 0x6A'u8
    ## Datasheet 2.2: B6 12/24, B5 INTAE, B3 INTME, B1 INTFE are R/W; B7 POWER
    ## is read-only; "B4, B2 and B0: If having written contents, they are
    ## ignored. When they are read, 0 can be read from them."
  S3511_STATUS_24H* = 0x40'u8
  CAL_2000_01_01* = 946_684_800'i64   ## calendar seconds of 2000-01-01 00:00:00
  MAX_PLAUSIBLE_LATCH = 1'i64 shl 40  ## ~36,800 AD; beyond this it is noise

type
  CalendarTime* = object
    year*, month*, day*, hour*, minute*, second*: int  # full year, 24-hour
    weekday*: int   # 0 = Sunday, from the date

  TrailerClock* = object
    ## A decoded trailer: the clock it describes and the status to adopt.
    seconds*: int64        ## calendar seconds of the saved date/time
    weekday*: int          ## saved weekday counter, 0..6
    latch*: int64          ## unix seconds the reading was taken at
    has_status*: bool      ## false for the FlashGBX 0x01 filler
    status*: uint8         ## masked to S3511_STATUS_RW_BITS

# ---- BCD -------------------------------------------------------------------

proc bcd*(v: int): uint8 =
  ## Two-digit BCD of 0..99.
  uint8(((v div 10) mod 10) shl 4) or uint8(v mod 10)

proc from_bcd*(b: uint8): int =
  ## Value of a BCD byte, or -1 if either nibble is above 9.
  let hi = int(b shr 4)
  let lo = int(b and 0x0F)
  if hi > 9 or lo > 9: -1 else: hi * 10 + lo

# ---- Calendar arithmetic ---------------------------------------------------

proc is_leap*(year: int): bool =
  (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0

proc days_in_month*(year, month: int): int =
  case month
  of 2: (if is_leap(year): 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

proc to_calendar_seconds*(year, month, day, hour, minute, second: int): int64 =
  dateTime(year, Month(month), MonthdayRange(day), HourRange(hour),
           MinuteRange(minute), SecondRange(second), zone = utc()).toTime.toUnix

proc from_calendar_seconds*(s: int64): CalendarTime =
  let d = utc(fromUnix(s))
  CalendarTime(year: d.year, month: d.month.int, day: d.monthday.int,
               hour: d.hour, minute: d.minute, second: d.second,
               # std/times: dMon = 0 .. dSun = 6
               weekday: (d.weekday.int + 1) mod 7)

proc calendar_weekday*(s: int64): int = from_calendar_seconds(s).weekday

proc local_zone_offset*(unix: int64): int64 =
  ## Seconds to add to a unix time to get the host's local civil time as
  ## calendar seconds (std/times utcOffset is seconds WEST of UTC).
  -int64(local(fromUnix(unix)).utcOffset)

# ---- S-3511A register semantics --------------------------------------------

proc register_hour*(h: int; status: uint8): uint8 =
  ## The hour register as the chip presents a 24-hour value. Datasheet
  ## Table 11 *1 / GBATEK: bit 7 (AM/PM) reads 1 for 12..23 o'clock in BOTH
  ## modes; in 12-hour mode the hour field is 00..11 ("12 o'clock is 00h").
  let pm = if h >= 12: 0x80'u8 else: 0'u8
  if (status and S3511_STATUS_24H) != 0: bcd(h) or pm
  else: bcd(h mod 12) or pm

proc datetime_registers*(s: int64; weekday: int; status: uint8): array[7, uint8] =
  ## DATE_TIME read: year, month, day, weekday, hour, minute, second.
  let c = from_calendar_seconds(s)
  [bcd(c.year mod 100), bcd(c.month), bcd(c.day), uint8(weekday),
   register_hour(c.hour, status), bcd(c.minute), bcd(c.second)]

proc written_hour*(raw: uint8; status: uint8): int =
  ## Hour register write, datasheet Table 11: 24-hour mode accepts 00..23 and
  ## ignores AM/PM; 12-hour mode accepts 00..11 plus AM/PM. Any other value
  ## (24..29, 3X, XA..XF / 12..19, XA..XF) becomes 00; the flag still selects
  ## PM in 12-hour mode (Assumed: the table names only the hour result).
  let h = from_bcd(raw and 0x3F)
  if (status and S3511_STATUS_24H) != 0:
    if h < 0 or h > 23: 0 else: h
  else:
    let base = if h < 0 or h > 11: 0 else: h
    if (raw and 0x80) != 0: base + 12 else: base

proc normalize_datetime*(year_b, month_b, day_b, hour, minute_b, second_b: uint8;
                         weekday_b: uint8): tuple[seconds: int64, weekday: int] =
  ## A real-time data write as the chip stores it (datasheet section 4,
  ## "Processing of none-existent data and end-of-month"). Bits the
  ## datasheet's Figure 10 marks as fixed 0 are dropped first. `hour` is
  ## already the 24-hour value (written_hour).
  ##   year  XA..XF, AX..FX         -> 00
  ##   month 00, 13..19, XA..XF     -> 01
  ##   day   00, 32..39, XA..XF     -> 01
  ##   weekday 7                    -> 0
  ##   minute 60..79, XA..XF        -> 00
  ##   second 60..79, XA..XF        -> processed "by a carry pulse one second
  ##     after the end of writing ... sent to the minute counter": stored here
  ##     as 59, so the next tick is second 00 of the next minute. (A read in
  ##     the first second shows 59 rather than the raw value.)
  ##   "Any none-existent day is corrected to the first day of the next
  ##   month. For example, February 30 is changed to March 1."
  var year = from_bcd(year_b)
  if year < 0: year = 0
  var month = from_bcd(month_b and 0x1F)
  if month < 1 or month > 12: month = 1
  var day = from_bcd(day_b and 0x3F)
  if day < 1 or day > 31: day = 1
  var weekday = int(weekday_b and 0x07)
  if weekday == 7: weekday = 0
  var minute = from_bcd(minute_b and 0x7F)
  if minute < 0 or minute > 59: minute = 0
  var second = from_bcd(second_b and 0x7F)
  if second < 0 or second > 59: second = 59
  var full_year = 2000 + year
  if day > days_in_month(full_year, month):
    day = 1
    inc month
    if month > 12:
      month = 1
      # 2099 -> 00: the chip's two-digit counter
      full_year = if year == 99: 2000 else: full_year + 1
  (to_calendar_seconds(full_year, month, day, int(hour), minute, second), weekday)

# ---- Trailer ---------------------------------------------------------------

proc trailer_offset*(file_len: int): int =
  ## Offset of the RTC trailer in a battery file of `file_len` bytes, or -1.
  if file_len >= RTC_TRAILER_LEN and file_len mod 512 == RTC_TRAILER_LEN:
    file_len - RTC_TRAILER_LEN
  else:
    -1

proc trailer_hour(raw: uint8): int =
  ## See "Hour byte, read" above. -1 if not a valid hour.
  let h = from_bcd(raw and 0x3F)
  if h < 0 or h > 23: return -1
  if (raw and 0x80) != 0 and h < 12: h + 12 else: h

proc parse_trailer*(t: openArray[byte]; clock: var TrailerClock): bool =
  ## Decode a 16-byte trailer. False (and `clock` untouched) when it cannot be
  ## a clock reading: a chip only ever reports in-range BCD, so any field out
  ## of range, a latch of 0 (a writer that never read the clock) or an
  ## implausibly large latch means the bytes are not a reading. A trailer this
  ## rejects is still not chip data (the caller has already cut it off).
  if t.len != RTC_TRAILER_LEN: return false
  let year = from_bcd(t[0])
  let month = from_bcd(t[1])
  let day = from_bcd(t[2])
  let weekday = int(t[3])
  let hour = trailer_hour(t[4])
  let minute = from_bcd(t[5])
  let second = from_bcd(t[6])
  if year < 0 or month < 1 or month > 12 or day < 1 or weekday > 6 or
     hour < 0 or minute < 0 or minute > 59 or second < 0 or second > 59:
    return false
  if day > days_in_month(2000 + year, month): return false
  var latch = 0'u64
  for i in 0 .. 7: latch = latch or (uint64(t[8 + i]) shl (8 * i))
  if latch == 0 or latch >= uint64(MAX_PLAUSIBLE_LATCH): return false
  clock.seconds = to_calendar_seconds(2000 + year, month, day, hour, minute, second)
  clock.weekday = weekday
  clock.latch = int64(latch)
  clock.has_status = t[7] != RTC_TRAILER_CONTROL_FILLER
  clock.status = t[7] and S3511_STATUS_RW_BITS
  true

proc encode_trailer*(seconds: int64; weekday: int; status: uint8;
                     latch: int64): array[RTC_TRAILER_LEN, byte] =
  ## The trailer for a clock reading `seconds` (calendar) taken at unix time
  ## `latch`. Hour is the 24-hour value without the PM flag (see above).
  let c = from_calendar_seconds(seconds)
  result[0] = bcd(c.year mod 100)
  result[1] = bcd(c.month)
  result[2] = bcd(c.day)
  result[3] = uint8(weekday mod 7)
  result[4] = bcd(c.hour)
  result[5] = bcd(c.minute)
  result[6] = bcd(c.second)
  result[7] = status and S3511_STATUS_RW_BITS
  for i in 0 .. 7: result[8 + i] = uint8((uint64(latch) shr (8 * i)) and 0xFF)
