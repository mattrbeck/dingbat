## GBA cartridge RTC: the settable S-3511A clock and the battery-save RTC
## trailer (src/dingbat/gba/rtc_calendar.nim, rtc.nim, storage.nim).
##
## Everything runs on synthetic ROMs (a few KB of zeros carrying the library
## ID strings the loader scans for) and drives the RTC through the GPIO port
## bit by bit, the way a game does, so the tests exercise the protocol and not
## just the helpers. Reference trailers are real files: the 16 bytes mGBA
## 0.10.5 appended to Pokemon Emerald's save in the playtest harness, and the
## example in the format proposal (mGBA issue #2431).
##
## Run with: nimble test_gbartc

import std/[os, strutils, tempfiles, times]
import dingbat/gba/gba

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

proc hex(b: openArray[byte]): string =
  for x in b: result.add(x.toHex(2))

proc unhex(s: string): seq[byte] =
  let t = s.replace(" ", "")
  for i in countup(0, t.len - 2, 2): result.add(uint8(parseHexInt(t[i .. i + 1])))

let dir = createTempDir("dingbat_gbartc_", "")

proc make_rom(name: string; ids: openArray[string]): string =
  ## A 4 KB ROM of zeros (ARM `andeq r0, r0, r0`) carrying library IDs.
  var rom = newString(0x1000)
  var off = 0x200
  for id in ids:
    for i, c in id: rom[off + i] = c
    off += id.len + 4
  result = dir / name & ".gba"
  writeFile(result, rom)

proc sav_path(rom: string): string = rom.changeFileExt(".sav")

proc boot(rom: string; epoch = -1'i64): GBA =
  result = new_gba("", rom, run_bios = false, use_hle = true)
  result.post_init()
  if epoch >= 0: result.enable_deterministic_rtc(epoch)

# ---- GPIO bit-banging, as a game's RTC driver does (GBATEK "GBA Cart I/O
# Port (GPIO)" + "Real-Time Clock"): CS low / SCK high idle, CS high to
# start, command MSB first, parameters LSB first, SCK low then high per bit.

proc gpio_w(g: GBA; reg: uint32; v: uint8) = g.bus.gpio[0x08000000'u32 + reg] = v
proc gpio_r(g: GBA; reg: uint32): uint8 = g.bus.gpio[0x08000000'u32 + reg]

proc rtc_begin(g: GBA; cmd: uint8) =
  g.gpio_w(0xC8, 1)          # reads enabled
  g.gpio_w(0xC6, 7)          # all three pins out (data writes are masked by it)
  g.gpio_w(0xC4, 1)          # SCK high, CS low
  g.gpio_w(0xC4, 5)          # CS high
  for i in 0 .. 7:
    let b = (cmd shr (7 - i)) and 1
    g.gpio_w(0xC4, 4'u8 or (b shl 1))
    g.gpio_w(0xC4, 5'u8 or (b shl 1))

proc rtc_end(g: GBA) =
  g.gpio_w(0xC6, 7)
  g.gpio_w(0xC4, 1)
  g.gpio_w(0xC4, 1)

proc rtc_read_bytes(g: GBA; cmd: uint8; n: int): seq[byte] =
  g.rtc_begin(cmd)
  g.gpio_w(0xC6, 5)          # SIO in
  for _ in 0 ..< n:
    var v = 0'u8
    for i in 0 .. 7:
      g.gpio_w(0xC4, 4)
      g.gpio_w(0xC4, 5)
      v = v or (((g.gpio_r(0xC4) shr 1) and 1) shl i)
    result.add(v)
  g.rtc_end()

proc rtc_write_bytes(g: GBA; cmd: uint8; data: openArray[byte]) =
  g.rtc_begin(cmd)
  for v in data:
    for i in 0 .. 7:
      let b = (v shr i) and 1
      g.gpio_w(0xC4, 4'u8 or (b shl 1))
      g.gpio_w(0xC4, 5'u8 or (b shl 1))
  g.rtc_end()

# GBATEK command bytes, MSB-first form (FlashGBX uses the same values)
const
  CMD_RESET = 0x60'u8
  CMD_STATUS_W = 0x62'u8
  CMD_STATUS_R = 0x63'u8
  CMD_DATETIME_W = 0x64'u8
  CMD_DATETIME_R = 0x65'u8
  CMD_TIME_W = 0x66'u8
  CMD_TIME_R = 0x67'u8

proc datetime(g: GBA): seq[byte] = g.rtc_read_bytes(CMD_DATETIME_R, 7)
proc status(g: GBA): uint8 = g.rtc_read_bytes(CMD_STATUS_R, 1)[0]

proc cal(y, mo, d, h, mi, s: int): int64 = to_calendar_seconds(y, mo, d, h, mi, s)

proc regs(y, mo, d, wd, h, mi, s: int): seq[byte] =
  ## Expected 24-hour DATE_TIME register bytes (PM flag per the datasheet).
  @[bcd(y mod 100), bcd(mo), bcd(d), uint8(wd),
    bcd(h) or (if h >= 12: 0x80'u8 else: 0'u8), bcd(mi), bcd(s)]

proc chip_image(n: int; seed: int): string =
  result = newString(n)
  for i in 0 ..< n: result[i] = char((i * 7 + seed) and 0xFF)

proc trailer_of(file: string): seq[byte] =
  for i in file.len - 16 ..< file.len: result.add(uint8(file[i]))

const E = 1_136_073_600'i64   # 2006-01-01 00:00:00 UTC, the playtest harness epoch

# ===========================================================================
echo "=== rtc_calendar: format primitives ==="

block:
  check(trailer_offset(512 + 16) == 512, "trailer after a 4Kbit EEPROM")
  check(trailer_offset(8192 + 16) == 8192, "trailer after an 8192-byte EEPROM file")
  check(trailer_offset(32768 + 16) == 32768, "trailer after SRAM")
  check(trailer_offset(65536 + 16) == 65536, "trailer after FLASH512")
  check(trailer_offset(131072 + 16) == 131072, "trailer after FLASH1M")
  var none = true
  for extra in [0, 1, 8, 15, 17, 32]:
    if trailer_offset(131072 + extra) != -1: none = false
  check(none, "no trailer for chip+0, +1..15, +17, +32")
  check(trailer_offset(15) == -1 and trailer_offset(0) == -1, "no trailer in tiny files")

block:  # mGBA 0.10.5, Pokemon Emerald, --rtc 1136073600 (TZ=UTC)
  var c: TrailerClock
  let t = unhex("06010100000000 40 801BB74300000000")
  check(parse_trailer(t, c), "mGBA's Emerald trailer parses")
  check(c.seconds == E and c.latch == E and c.weekday == 0,
        "mGBA trailer: 2006-01-01 00:00:00, Sunday, latched at the epoch")
  check(c.has_status and c.status == 0x40, "mGBA trailer: 24-hour status")
  check(hex(encode_trailer(c.seconds, c.weekday, c.status, c.latch)) == hex(t),
        "dingbat encodes mGBA's trailer byte for byte")

block:  # the proposal's example (mGBA issue #2431), FlashGBX-written
  var c: TrailerClock
  let t = unhex("04 05 31 01 97 14 15 01 A4 95 F2 61 00 00 00 00")
  check(parse_trailer(t, c), "FlashGBX example trailer parses")
  check(c.seconds == cal(2004, 5, 31, 17, 14, 15),
        "FlashGBX example: 2004-05-31 17:14:15 (hour 0x97 = PM flag + 17)",
        $from_calendar_seconds(c.seconds))
  check(c.weekday == 1 and c.latch == 1643287972, "FlashGBX example: Monday, latch 1643287972")
  check(not c.has_status, "FlashGBX 0x01 status byte is filler, not a status")
  let back = encode_trailer(c.seconds, c.weekday, 0x40, c.latch)
  check(back[4] == 0x17, "written hour is the 24-hour value without the PM flag",
        back[4].toHex)

block:  # hour byte decoding
  var c: TrailerClock
  proc hour_of(b: uint8): int =
    var t = unhex("20 03 15 00 00 30 00 40 01 00 00 00 00 00 00 00")
    t[4] = b
    if parse_trailer(t, c): from_calendar_seconds(c.seconds).hour else: -1
  check(hour_of(0x17) == 17 and hour_of(0x97) == 17, "0x17 and 0x97 are 17:00")
  check(hour_of(0x85) == 17, "12-hour reading 05 + PM is 17:00")
  check(hour_of(0x92) == 12 and hour_of(0x00) == 0, "0x92 is 12:00, 0x00 is 00:00")
  check(hour_of(0x24) == -1 and hour_of(0x1A) == -1, "0x24 and 0x1A are not hours")

block:  # implausible trailers
  var c: TrailerClock
  let good = unhex("20 03 15 00 12 30 00 40 01 00 00 00 00 00 00 00")
  check(parse_trailer(good, c), "baseline trailer parses")
  proc bad(i: int; v: uint8): bool =
    var t = good
    t[i] = v
    not parse_trailer(t, c)
  check(bad(0, 0x1A), "year nibble A is rejected")
  check(bad(1, 0x00) and bad(1, 0x13), "month 00 / 13 rejected")
  check(bad(2, 0x00) and bad(2, 0x32), "day 00 / 32 rejected")
  check(bad(3, 7), "weekday 7 rejected")
  check(bad(5, 0x60) and bad(6, 0x5A), "minute 60 / second 5A rejected")
  var feb30 = good
  feb30[1] = 0x02
  feb30[2] = 0x30
  check(not parse_trailer(feb30, c), "February 30 rejected")
  var zero_latch = good
  zero_latch[8] = 0
  check(not parse_trailer(zero_latch, c), "latch 0 (clock never read) rejected")
  var huge = good
  huge[15] = 0x80
  check(not parse_trailer(huge, c), "latch beyond 2^40 rejected")
  check(not parse_trailer(newSeq[byte](16), c), "all-zero trailer rejected")
  var ff = newSeq[byte](16)
  for b in ff.mitems: b = 0xFF
  check(not parse_trailer(ff, c), "erased (FF) trailer rejected")

block:  # datasheet Table 11 and end-of-month correction
  proc norm(y, mo, d, h, mi, s, wd: uint8): (CalendarTime, int) =
    let (sec, w) = normalize_datetime(y, mo, d, h, mi, s, wd)
    (from_calendar_seconds(sec), w)
  var (t, w) = norm(0x1A, 0x13, 0x00, 5, 0x60, 0x7A, 7)
  check(t.year == 2000 and t.month == 1 and t.day == 1 and t.minute == 0 and
        t.second == 59 and w == 0,
        "invalid year/month/day/minute/second/weekday -> 00/01/01/00/59(carry)/0", $t)
  (t, w) = norm(0x01, 0x02, 0x30, 0, 0, 0, 3)
  check(t.year == 2001 and t.month == 3 and t.day == 1 and w == 3,
        "2001-02-30 -> 2001-03-01, weekday counter untouched", $t)
  (t, w) = norm(0x04, 0x02, 0x29, 0, 0, 0, 0)
  check(t.month == 2 and t.day == 29, "2004-02-29 is kept (leap year)")
  (t, w) = norm(0x06, 0x04, 0x31, 0, 0, 0, 0)
  check(t.month == 5 and t.day == 1, "2006-04-31 -> 2006-05-01")
  check(written_hour(0x23, 0x40) == 23 and written_hour(0x24, 0x40) == 0 and
        written_hour(0x3A, 0x40) == 0, "24-hour writes: 23 kept, 24 and 3A -> 00")
  check(written_hour(0x97, 0x40) == 17, "24-hour write ignores the PM flag")
  check(written_hour(0x85, 0x00) == 17 and written_hour(0x05, 0x00) == 5,
        "12-hour write: 05 PM = 17, 05 AM = 5")
  check(written_hour(0x12, 0x00) == 0 and written_hour(0x92, 0x00) == 12,
        "12-hour write: 12 is invalid -> 00 (+PM = 12)")
  check(register_hour(17, 0x40) == 0x97 and register_hour(17, 0x00) == 0x85 and
        register_hour(12, 0x00) == 0x80 and register_hour(0, 0x00) == 0x00,
        "hour register reads: PM flag in both modes, 12 o'clock is 00h")

# ===========================================================================
echo "=== RTC protocol: reads, writes, strobes ==="

let rtc_rom = make_rom("rtc_sram", ["SRAM_V113", "SIIRTC_V001"])

block:  # fresh cart, deterministic
  removeFile(sav_path(rtc_rom))
  let g = boot(rtc_rom, E)
  check(g.storage.rtc_cart and g.storage.rtc != nil, "SIIRTC_V marks an RTC cart")
  check(g.status() == 0x40, "no battery record: status 40h (24-hour)", g.status().toHex)
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "deterministic clock reads the epoch (UTC)",
        hex(g.datetime()))
  check(not g.storage.dirty, "reading the clock does not dirty the battery file")
  g.rtc_write_bytes(CMD_STATUS_W, [0x40'u8])
  check(not g.storage.dirty, "rewriting the same status does not dirty the battery file")

block:  # set the clock, it runs from there
  let g = boot(rtc_rom, E)
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2031, 7, 14, 1, 21, 5, 9))
  check(g.datetime() == regs(2031, 7, 14, 1, 21, 5, 9), "DATE_TIME write reads back",
        hex(g.datetime()))
  check(g.storage.dirty, "setting the clock dirties the battery file")
  g.enable_deterministic_rtc(E + 3600 + 61)
  check(g.datetime() == regs(2031, 7, 14, 1, 22, 6, 10), "clock advances with the source (+1h01m01s)",
        hex(g.datetime()))
  g.rtc_write_bytes(CMD_TIME_W, [0x08'u8, 0x30, 0x00])
  check(g.datetime() == regs(2031, 7, 14, 1, 8, 30, 0), "TIME write keeps date and weekday",
        hex(g.datetime()))
  check(g.rtc_read_bytes(CMD_TIME_R, 3) == @[0x08'u8, 0x30, 0x00], "TIME read")
  # a weekday counter the game sets out of step with the date is kept
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2031, 7, 14, 5, 23, 59, 58))
  g.enable_deterministic_rtc(E + 3600 + 61 + 3)
  check(g.datetime() == regs(2031, 7, 15, 6, 0, 0, 1),
        "midnight carries the date and the (custom) weekday counter together", hex(g.datetime()))
  # invalid data is processed as the datasheet says
  g.rtc_write_bytes(CMD_DATETIME_W, [0x09'u8, 0x02, 0x30, 0x02, 0x10, 0x00, 0x00])
  check(g.datetime() == regs(2009, 3, 1, 2, 10, 0, 0), "2009-02-30 is stored as 2009-03-01",
        hex(g.datetime()))
  # 12-hour mode
  g.rtc_write_bytes(CMD_STATUS_W, [0x00'u8])
  check(g.status() == 0x00, "12-hour status reads back")
  check(g.rtc_read_bytes(CMD_TIME_R, 3) == @[0x10'u8, 0x00, 0x00], "10:00 in 12-hour mode")
  g.rtc_write_bytes(CMD_TIME_W, [0x83'u8, 0x15, 0x00])
  check(g.rtc_read_bytes(CMD_TIME_R, 3) == @[0x83'u8, 0x15, 0x00], "03:15 PM written and read in 12-hour mode")
  g.rtc_write_bytes(CMD_STATUS_W, [0xFF'u8])
  check(g.status() == 0x6A, "only the datasheet's R/W status bits stick", g.status().toHex)
  check(g.rtc_read_bytes(CMD_TIME_R, 3) == @[0x95'u8, 0x15, 0x00], "15:15 in 24-hour mode")
  g.rtc_write_bytes(CMD_STATUS_W, [0x40'u8])

block:  # RESET strobes on write AND read (GBATEK), and does not hang the bus
  # The chip would load 2000-01-01; dingbat returns to the host clock (the
  # epoch here) so a new game shows today's date (docs/gba-rtc.md)
  removeFile(sav_path(rtc_rom))
  let g = boot(rtc_rom, E)
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2031, 7, 14, 1, 21, 5, 9))
  discard g.rtc_read_bytes(0x61, 1)   # read-form reset command
  check(g.bus.gpio.rtc.state == rtcWaiting, "a read of the reset register leaves the RTC idle")
  check(g.status() == 0x00, "reset: status 00h")
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "reset: back to the source clock, not 2000-01-01",
        hex(g.datetime()))
  check(not g.bus.gpio.rtc.bias_set, "reset: the clock follows the source again")
  g.rtc_write_bytes(CMD_STATUS_W, [0x40'u8])
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2031, 7, 14, 1, 21, 5, 9))
  g.storage.dirty = false
  g.rtc_write_bytes(CMD_RESET, [])
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "reset by write")
  check(g.storage.dirty, "a reset that drops a set clock rewrites the battery file")
  g.enable_deterministic_rtc(E + 90)
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 1, 30), "after a reset the clock runs with the source")

block:  # a trailer that recorded host time keeps following the host
  # what a host-clock emulator (or dingbat with no game-set clock) writes:
  # the host's local time at the latch instant
  let then = getTime().toUnix - 86400
  var f = chip_image(0x8000, 3)
  let local_then = then + local_zone_offset(then)
  for b in encode_trailer(local_then, calendar_weekday(local_then), 0x40, then): f.add(char(b))
  writeFile(sav_path(rtc_rom), f)
  let g = boot(rtc_rom)
  check(g.bus.gpio.rtc.bias_host, "a host-time trailer is recognised")
  let local_now = getTime().toUnix + local_zone_offset(getTime().toUnix)
  let want = datetime_registers(local_now, calendar_weekday(local_now), 0x40)
  check(g.datetime()[0 .. 4] == want[0 .. 4], "host-time trailer: shows host local time now",
        hex(g.datetime()) & " vs " & hex(want))
  # the same file in a deterministic session uses the stored offset, which
  # every peer derives from the same bytes whatever its own zone
  let p = boot(rtc_rom, then + 60)
  let wp = datetime_registers(local_then + 60, calendar_weekday(local_then + 60), 0x40)
  check(p.datetime() == wp, "deterministic: saved + (now - latch), zone-independent",
        hex(p.datetime()) & " vs " & hex(wp))
  # a game setting the clock turns it into a set clock
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2031, 7, 14, 1, 21, 5, 9))
  check(not g.bus.gpio.rtc.bias_host and g.bus.gpio.rtc.bias_set, "a game write replaces host-following")

block:  # a trailer with a set clock stays set
  let then = getTime().toUnix - 3600
  var f = chip_image(0x8000, 4)
  for b in encode_trailer(cal(2012, 3, 4, 5, 6, 7), 0, 0x40, then): f.add(char(b))
  writeFile(sav_path(rtc_rom), f)
  let g = boot(rtc_rom)
  check(g.bus.gpio.rtc.bias_set and not g.bus.gpio.rtc.bias_host, "a set-clock trailer is not host time")
  removeFile(sav_path(rtc_rom))

block:  # Nintendo's RTC library order: data before direction, from power-on
  let g = boot(rtc_rom, E)
  check(g.bus.gpio.direction == 0, "GPIO direction resets to all-In")
  g.gpio_w(0xC8, 1)
  g.gpio_w(0xC4, 1)          # SCK high (latched; the pins are still inputs)
  g.gpio_w(0xC4, 5)          # SCK|CS (latched)
  g.gpio_w(0xC6, 7)          # outputs on: SCK and CS rise together
  for i in 0 .. 7:
    let b = (CMD_STATUS_R shr (7 - i)) and 1
    g.gpio_w(0xC4, 4'u8 or (b shl 1))
    g.gpio_w(0xC4, 5'u8 or (b shl 1))
  g.gpio_w(0xC6, 5)
  var v = 0'u8
  for i in 0 .. 7:
    g.gpio_w(0xC4, 4)
    g.gpio_w(0xC4, 5)
    v = v or (((g.gpio_r(0xC4) shr 1) and 1) shl i)
  check(v == 0x40, "the first transaction after power-on is seen (status probe reads 40h)", v.toHex)
  # CS still high after the last bit: extra clocks must not start a command
  g.gpio_w(0xC4, 4)
  g.gpio_w(0xC4, 5)
  check(g.bus.gpio.rtc.state == rtcWaiting, "clocking with CS held high after a read starts nothing")
  g.gpio_w(0xC6, 7)
  g.gpio_w(0xC4, 1)
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "next transaction after CS low works")
  # a data write with the direction still In does not reach the chip
  let g2 = boot(rtc_rom, E)
  g2.gpio_w(0xC4, 1)
  g2.gpio_w(0xC4, 5)
  check(g2.bus.gpio.rtc.state == rtcWaiting, "latched levels do not drive pins set to In")

# ===========================================================================
echo "=== Battery file: trailer read and write ==="

block:  # write -> read round trip (deterministic)
  let chip = chip_image(0x8000, 3)
  writeFile(sav_path(rtc_rom), chip)
  let g = boot(rtc_rom, E)
  check(g.storage.memory == cast[seq[byte]](chip), "plain chip-size save loads unchanged")
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "plain save: clock is the source clock")
  g.storage.write_save()
  check(readFile(sav_path(rtc_rom)).len == 0x8000, "boot without changes rewrites nothing")
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2024, 2, 29, 4, 23, 59, 30))
  g.enable_deterministic_rtc(E + 100)
  g.storage.write_save()
  let file = readFile(sav_path(rtc_rom))
  check(file.len == 0x8000 + 16, "an RTC write appends the trailer", $file.len)
  check(file[0 ..< 0x8000] == chip, "chip bytes are unchanged before the trailer")
  var c: TrailerClock
  check(parse_trailer(trailer_of(file), c), "the written trailer parses")
  check(c.latch == E + 100 and c.seconds == cal(2024, 2, 29, 23, 59, 30) + 100,
        "trailer = current clock, latched at the source clock",
        $from_calendar_seconds(c.seconds) & " @" & $c.latch)
  check(c.weekday == 5, "trailer weekday is the weekday counter (carried past midnight)")
  check(file[0x8000 + 7] == '\x40', "trailer status byte")
  # a later boot at a later source time resumes saved + elapsed
  let g2 = boot(rtc_rom, E + 100 + 86400)
  check(g2.datetime() == regs(2024, 3, 2, 6, 0, 1, 10), "boot one day later: saved + elapsed",
        hex(g2.datetime()))
  check(g2.storage.memory == cast[seq[byte]](chip), "chip bytes intact after reload")
  # repeated writes at the same deterministic instant are byte-identical
  g2.storage.dirty = true
  g2.storage.write_save()
  let a = readFile(sav_path(rtc_rom))
  g2.storage.dirty = true
  g2.storage.write_save()
  check(readFile(sav_path(rtc_rom)) == a, "deterministic trailer writes are byte-identical")
  # two peers booting the same file at the same epoch agree
  let p1 = boot(rtc_rom, E + 5000)
  let p2 = boot(rtc_rom, E + 5000)
  check(p1.datetime() == p2.datetime(), "two deterministic peers read the same clock")

block:  # host clock mode
  writeFile(sav_path(rtc_rom), chip_image(0x8000, 1))
  let g = boot(rtc_rom)
  let local_now = getTime().toUnix + local_zone_offset(getTime().toUnix)
  let got = g.datetime()
  let want = datetime_registers(local_now, calendar_weekday(local_now), 0x40)
  check(got[0 .. 4] == want[0 .. 4], "no trailer, host mode: the RTC shows host local time",
        hex(got) & " vs " & hex(want))
  # a trailer latched long ago resumes with the real elapsed time
  let then = getTime().toUnix - 3 * 86400
  var f = chip_image(0x8000, 1)
  for b in encode_trailer(cal(2010, 6, 1, 8, 0, 0), 2, 0x40, then): f.add(char(b))
  writeFile(sav_path(rtc_rom), f)
  let h = boot(rtc_rom)
  let r = h.datetime()
  check(r[0 .. 3] == @[0x10'u8, 0x06, 0x04, 0x05] and r[4] == 0x08,
        "host mode: saved 2010-06-01 08:00 + 3 days of wall time", hex(r))

block:  # FlashGBX example trailer on an RTC cart
  var f = chip_image(0x8000, 9)
  for b in unhex("04 05 31 01 97 14 15 01 A4 95 F2 61 00 00 00 00"): f.add(char(b))
  writeFile(sav_path(rtc_rom), f)
  let g = boot(rtc_rom, 1643287972 + 45)
  check(g.status() == 0x40, "FlashGBX 0x01 filler keeps 24-hour mode")
  check(g.datetime() == regs(2004, 5, 31, 1, 17, 15, 0), "FlashGBX save resumes at 17:14:15 + 45 s",
        hex(g.datetime()))
  check(g.storage.memory == cast[seq[byte]](f[0 ..< 0x8000]), "FlashGBX save: chip bytes intact")

block:  # a trailer's 12-hour status is honoured
  var f = chip_image(0x8000, 9)
  for b in encode_trailer(cal(2020, 1, 1, 15, 0, 0), 3, 0x00, E): f.add(char(b))
  writeFile(sav_path(rtc_rom), f)
  let g = boot(rtc_rom, E)
  check(g.status() == 0x00 and g.rtc_read_bytes(CMD_TIME_R, 1)[0] == 0x83,
        "status 00h from the trailer: 15:00 reads 03 PM")

block:  # garbage and short trailers
  for extra in [1, 7, 15]:
    var f = chip_image(0x8000, extra)
    for i in 0 ..< extra: f.add('\xAB')
    writeFile(sav_path(rtc_rom), f)
    let g = boot(rtc_rom, E)
    check(g.storage.memory == cast[seq[byte]](f[0 ..< 0x8000]) and not g.storage.has_trailer and
          g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0),
          "chip+" & $extra & " bytes: no trailer, chip intact, source clock")
  var f = chip_image(0x8000, 4)
  for i in 0 ..< 16: f.add(char(0x5A + i))
  writeFile(sav_path(rtc_rom), f)
  let g = boot(rtc_rom, E)
  check(g.storage.memory == cast[seq[byte]](f[0 ..< 0x8000]), "invalid trailer: chip bytes intact (not read as chip data)")
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "invalid trailer: source clock")
  g.storage.dirty = true
  g.storage.write_save()
  var c: TrailerClock
  let w = readFile(sav_path(rtc_rom))
  check(w.len == 0x8000 + 16 and parse_trailer(trailer_of(w), c),
        "invalid trailer is replaced by a valid one on write")

block:  # trailer on a cart without an RTC
  let plain = make_rom("plain_sram", ["SRAM_V113"])
  var f = chip_image(0x8000, 2)
  let t = encode_trailer(cal(2015, 5, 5, 5, 5, 5), 2, 0x40, E)
  for b in t: f.add(char(b))
  writeFile(sav_path(plain), f)
  let g = boot(plain, E)
  check(not g.storage.rtc_cart and g.storage.rtc == nil, "no SIIRTC_V: not an RTC cart")
  check(g.storage.memory == cast[seq[byte]](f[0 ..< 0x8000]), "chip bytes intact")
  check(g.datetime() == regs(2006, 1, 1, 0, 0, 0, 0), "trailer ignored for the clock")
  g.storage.memory[0] = 0x11
  g.storage.dirty = true
  g.storage.write_save()
  let w = readFile(sav_path(plain))
  check(w.len == 0x8000 + 16 and trailer_of(w) == @t,
        "trailer preserved verbatim when the save is rewritten")
  writeFile(sav_path(plain), chip_image(0x8000, 2))
  let g2 = boot(plain, E)
  g2.storage.dirty = true
  g2.storage.write_save()
  check(readFile(sav_path(plain)).len == 0x8000, "no trailer is invented for a cart without an RTC")

block:  # EEPROM: trailer after an 8192-byte file for a 4Kbit game
  let ee = make_rom("rtc_eeprom", ["EEPROM_V124", "SIIRTC_V001"])
  var f = chip_image(0x2000, 6)
  for b in encode_trailer(cal(2012, 12, 12, 12, 12, 12), 3, 0x40, E): f.add(char(b))
  writeFile(sav_path(ee), f)
  let g = boot(ee, E + 60)
  check(g.storage of EEPROM and g.storage.memory == cast[seq[byte]](f[0 ..< 0x2000]),
        "8192+16 file: all 8192 chip bytes, no trailer bytes")
  check(g.datetime() == regs(2012, 12, 12, 3, 12, 13, 12), "8192+16 file: clock resumed",
        hex(g.datetime()))
  # the game's first command reveals a 4Kbit part: the buffer shrinks
  g.storage.memory.setLen(0x200)
  g.storage.dirty = true
  g.storage.write_save()
  let w = readFile(sav_path(ee))
  check(w.len == 0x200 + 16, "4Kbit part: 512 bytes + trailer", $w.len)
  let g2 = boot(ee, E + 120)
  check(g2.storage.memory[0 ..< 0x200] == cast[seq[byte]](f[0 ..< 0x200]),
        "512+16 file: chip bytes intact")
  check(g2.datetime() == regs(2012, 12, 12, 3, 12, 14, 12), "512+16 file: clock resumed",
        hex(g2.datetime()))

# ===========================================================================
echo "=== Save states ==="

block:
  removeFile(sav_path(rtc_rom))
  let g = boot(rtc_rom, E)
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2040, 10, 10, 3, 10, 10, 10))
  g.rtc_write_bytes(CMD_STATUS_W, [0x42'u8])
  let img = g.state_bytes()
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2001, 1, 1, 1, 1, 1, 1))
  g.rtc_write_bytes(CMD_STATUS_W, [0x40'u8])
  check(g.load_state_bytes(img), "state loads")
  check(g.datetime() == regs(2040, 10, 10, 3, 10, 10, 10) and g.status() == 0x42,
        "state restores the set clock and status", hex(g.datetime()))
  # a fresh core (no .sav) loading it gets the same clock
  let g2 = boot(rtc_rom, E)
  check(g2.load_state_bytes(img) and g2.datetime() == regs(2040, 10, 10, 3, 10, 10, 10),
        "state carries the clock to another core")

block:  # a clock set EARLIER than the source clock: the bias is negative
  removeFile(sav_path(rtc_rom))
  let g = boot(rtc_rom, E)
  g.rtc_write_bytes(CMD_DATETIME_W, regs(2001, 2, 3, 6, 4, 5, 6))
  let img = g.state_bytes()
  let g2 = boot(rtc_rom, E)
  check(g2.load_state_bytes(img) and g2.datetime() == regs(2001, 2, 3, 6, 4, 5, 6),
        "a state with a negative clock bias loads", hex(g2.datetime()))

block:  # an older payload revision (tests/states corpus): status migrates, clock unset
  const corpus = "tests/states/inputrec.gba.v7.state"
  if fileExists(corpus) and fileExists("tests/roms/inputrec.gba"):
    let data = readFile(corpus)
    check(uint8(data[13]) in 1'u8 .. 6'u8, "corpus entry predates GBA payload revision 7")
    let g = new_gba("", "tests/roms/inputrec.gba", run_bios = false, use_hle = true)
    g.post_init()
    check(g.load_state_bytes(data), "pre-revision-7 state loads")
    let rtc = g.bus.gpio.rtc
    check(rtc.status == 0x42 and not rtc.irq and not rtc.bias_set,
          "pre-7: status = old reads (bit 1 + 24h), clock follows the source",
          rtc.status.toHex)
  else:
    check(false, "corpus state and ROM present (run from the repo root)")

removeDir(dir)
if failures > 0:
  echo "\n", failures, " failure(s)"
  quit(1)
echo "\nall GBA RTC tests passed"
