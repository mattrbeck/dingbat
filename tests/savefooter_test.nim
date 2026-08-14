## Unit tests for GB battery-save RTC/mapper footers (src/dingbat/gb/gb.nim).
##
## The loaders must hold two properties at once:
##  - a footer dingbat (or BGB/VBA/mGBA — same MBC3 layout) wrote round-trips
##    exactly, and a dumped-then-idle clock catches up by the wall time that
##    passed;
##  - anything after the RAM that is NOT a known footer — an imported forum
##    save padded out to a power of two, a foreign emulator's layout — is
##    ignored, because parsing padding as a clock walks the RTC through five
##    decades of "catch-up" and sets the sticky day-overflow flag (this is the
##    exact failure the exact-length checks exist to prevent).

import std/[os, strformat, tempfiles]
import dingbat/gb/gb

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

const NOW = 1_755_000_000'i64  # a fixed "today" for the frozen deterministic clock

let dir = createTempDir("dingbat_savefooter_", "")

proc make_rom(name: string; cart_type: uint8): string =
  ## Minimal 32 KiB cartridge: only the header bytes the loader reads matter.
  var rom = newString(0x8000)
  rom[0x0147] = char(cart_type)
  rom[0x0149] = char(0x03)  # 32 KiB RAM
  result = dir / name & ".gb"
  writeFile(result, rom)

proc boot(rom_path: string): GB =
  new_gb("", rom_path, fifo = true, headless = true, run_bios = false)

proc add_u32(s: var string; v: uint32) =
  for i in 0 .. 3: s.add(char((v shr (8 * i)) and 0xFF))

proc ram_image(): string =
  result = newString(0x8000)
  for i in 0 ..< result.len: result[i] = char((i * 3 + 7) and 0xFF)

proc mbc3_footer(live, latched: array[5, uint8]; ts: int64; ts_bytes: int): string =
  for v in live: result.add_u32(uint32(v))
  for v in latched: result.add_u32(uint32(v))
  for i in 0 ..< ts_bytes: result.add(char((uint64(ts) shr (8 * i)) and 0xFF))

echo "=== MBC3 RTC footer ==="

enable_deterministic_gb_rtc(NOW)

block:  # dingbat's own save -> load round-trips exactly (48-byte footer)
  let rom = make_rom("roundtrip", 0x10)  # MBC3+TIMER+RAM+BATTERY
  let gb1 = boot(rom)
  let cart1 = Mbc3(gb1.cartridge)
  cart1.rtc_live    = [7'u8, 8, 9, 10, 0]
  cart1.rtc_latched = [1'u8, 2, 3, 4, 0]
  cart1.ram_dirty = true
  cart1.mbc_save()
  let cart2 = Mbc3(boot(rom).cartridge)
  check(cart2.rtc_live == [7'u8, 8, 9, 10, 0] and
        cart2.rtc_latched == [1'u8, 2, 3, 4, 0],
        "own 48-byte footer round-trips with no drift at the same instant")

block:  # a 48-byte footer dumped 1d 1h 1m 1s ago catches up by exactly that
  let rom = make_rom("catchup48", 0x10)
  writeFile(rom.changeFileExt("sav"),
    ram_image() & mbc3_footer([5'u8, 10, 3, 100, 0], [1'u8, 2, 3, 4, 5],
                              NOW - 90061, 8))
  let cart = Mbc3(boot(rom).cartridge)
  check(cart.rtc_live == [6'u8, 11, 4, 101, 0],
        &"48-byte footer: 90061 s of catch-up lands on 6/11/4/101 (got {cart.rtc_live})")
  check(cart.rtc_latched == [1'u8, 2, 3, 4, 5],
        "latched registers load as stated, un-caught-up")
  check(cart.ram[100] == uint8((100 * 3 + 7) and 0xFF), "RAM loads alongside the footer")

block:  # the old 32-bit-VBA 44-byte variant parses too
  let rom = make_rom("catchup44", 0x10)
  writeFile(rom.changeFileExt("sav"),
    ram_image() & mbc3_footer([5'u8, 10, 3, 100, 0], [0'u8, 0, 0, 0, 0],
                              NOW - 90061, 4))
  let cart = Mbc3(boot(rom).cartridge)
  check(cart.rtc_live == [6'u8, 11, 4, 101, 0],
        &"44-byte footer: same catch-up (got {cart.rtc_live})")

block:  # a save padded to 64 KiB is NOT a footer: clock stays at power-on
  let rom = make_rom("padded", 0x10)
  writeFile(rom.changeFileExt("sav"), ram_image() & newString(0x8000))
  let cart = Mbc3(boot(rom).cartridge)
  check(cart.rtc_live == [0'u8, 0, 0, 0, 0],
        &"zero-padded tail leaves the RTC at power-on (got {cart.rtc_live})")
  check((cart.rtc_live[4] and 0x80) == 0,
        "…and the sticky day-overflow flag is NOT set by a 1970 'catch-up'")
  check(cart.ram[100] == uint8((100 * 3 + 7) and 0xFF), "RAM still loads from a padded file")

block:  # an exactly-48-byte ZEROED footer: registers load, but no 1970 catch-up
  let rom = make_rom("zerofooter", 0x10)
  writeFile(rom.changeFileExt("sav"),
    ram_image() & mbc3_footer([0'u8, 0, 0, 0, 0], [0'u8, 0, 0, 0, 0], 0, 8))
  let cart = Mbc3(boot(rom).cartridge)
  check(cart.rtc_live == [0'u8, 0, 0, 0, 0] and (cart.rtc_live[4] and 0x80) == 0,
        "zeroed timestamp keeps the stated registers and skips five decades of catch-up")

block:  # a foreign-length tail (neither 44 nor 48) is ignored
  let rom = make_rom("foreign", 0x10)
  writeFile(rom.changeFileExt("sav"), ram_image() & newString(30))
  let cart = Mbc3(boot(rom).cartridge)
  check(cart.rtc_live == [0'u8, 0, 0, 0, 0],
        "a 30-byte tail is not parsed as a footer")

echo "=== HuC3 footer ==="

block:  # a HuC3 save padded with 0xFF must not be misread as dingbat's layout
  let rom = make_rom("huc3pad", 0xFE)
  var pad = newString(0x8000)
  for i in 0 ..< pad.len: pad[i] = char(0xFF)
  writeFile(rom.changeFileExt("sav"), ram_image() & pad)
  let cart = Huc3(boot(rom).cartridge)
  check(cart.nyb3(HUC3_CLOCK) < 1440,
        &"padded tail leaves a valid minute-of-day (got {cart.nyb3(HUC3_CLOCK)})")

removeDir(dir)

if failures > 0:
  echo &"{failures} check(s) FAILED"
  quit(1)
echo "all checks passed"
