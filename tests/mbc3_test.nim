## Unit tests for MBC3 / MBC30 banking (src/dingbat/gb/mbc/mbc3.nim). Pan
## Docs, "MBC3": the MBC30 (Japanese Pokemon Crystal) drives 8 ROM-bank bits
## (256 banks, 4 MiB) and 3 RAM-bank bits (8 banks, 64 KiB; header RAM-size
## code $05) where MBC3 drives 7 and 2. The cart type byte is the same, so the
## loader tells them apart by size. Synthetic carts, every bank stamped with
## its own number, built through load_cartridge as a real file would be, and
## a 64 KiB battery save and a save state that must keep the high banks.
##
## Build: nim c -r -d:test_harness -d:release --hints:off --path:src \
##          tests/mbc3_test.nim

import std/[os, tempfiles]
import dingbat/gb/gb

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

let dir = createTempDir("dingbat_mbc3_", "")

proc make_rom(name: string; rom_code, ram_code: uint8; cart_type = 0x13'u8): string =
  ## 32 KiB << rom_code of ROM, byte $0000 of every 16 KiB bank = its number
  ## (as both test ROMs lay it out), cart type and RAM code in the header.
  let size = 0x8000 shl int(rom_code)
  var rom = newString(size)
  for bank in 0 ..< size div 0x4000:
    rom[bank * 0x4000] = char(bank and 0xFF)
    rom[bank * 0x4000 + 1] = char(bank shr 8)
  rom[0x0147] = char(cart_type)
  rom[0x0148] = char(rom_code)
  rom[0x0149] = char(ram_code)
  result = dir / name & ".gb"
  writeFile(result, rom)

proc rom_bank_read(c: Mbc; bank: int): int =
  ## Select `bank` through $2000-$3FFF and read the stamp at $4000, through
  ## both the method and the flat-ROM fast path read_byte takes.
  mbc_write(c, 0x2000, uint8(bank))
  mbc_sync_rom_map(c)
  let slow = int(mbc_read(c, 0x4000)) or (int(mbc_read(c, 0x4001)) shl 8)
  let fast = int(mbc_read_rom_hi(c, 0x4000)) or (int(mbc_read_rom_hi(c, 0x4001)) shl 8)
  if slow != fast: return -1
  slow

proc fill_ram_banks(c: Mbc; n: int) =
  mbc_write(c, 0x0000, 0x0A)
  for b in 0 ..< n:
    mbc_write(c, 0x4000, uint8(b))
    mbc_write(c, 0xA000, uint8(0x40 + b))
    mbc_write(c, 0xBFFF, uint8(0x80 + b))

echo "=== MBC30: 4 MiB ROM, 64 KiB RAM ==="
block:
  let c = load_cartridge(make_rom("mbc30", 0x07, 0x05))
  check(c of Mbc3, "cart type $13 loads as MBC3")
  check(c.rom.len == 0x400000, "4 MiB ROM image")
  check(c.ram.len == 0x10000, "header RAM code $05 = 64 KiB")
  var ok = true
  for bank in 1 .. 255:
    if rom_bank_read(c, bank) != bank: ok = false
  check(ok, "ROM banks $01-$FF each map their own bank (8-bit bank register)")
  check(rom_bank_read(c, 0) == 1, "bank 0 written selects bank 1")
  check(rom_bank_read(c, 0x80) == 0x80, "bank $80 is not folded onto bank 0")
  fill_ram_banks(c, 8)
  ok = true
  for b in 0 ..< 8:
    mbc_write(c, 0x4000, uint8(b))
    if mbc_read(c, 0xA000) != uint8(0x40 + b) or mbc_read(c, 0xBFFF) != uint8(0x80 + b):
      ok = false
  check(ok, "RAM banks 0-7 are eight distinct 8 KiB banks")
  check(c.ram[7 * 0x2000] == 0x47 and c.ram[0xFFFF] == 0x87,
        "RAM bank 7 is the image's last 8 KiB (the .sav layout)")
  mbc_write(c, 0x4000, 0x0D)
  check(mbc_read(c, 0xA000) == 0xFF, "RAM bank $0D (no RTC register) reads open bus")
  mbc_write(c, 0x4000, 0x08)
  check(mbc_read(c, 0xA000) == 0xFF, "no RTC on type $13: $08 reads open bus")

echo "=== MBC3: 2 MiB ROM, 32 KiB RAM ==="
block:
  let c = load_cartridge(make_rom("mbc3", 0x06, 0x03))
  check(c.ram.len == 0x8000, "header RAM code $03 = 32 KiB")
  var ok = true
  for bank in 1 .. 127:
    if rom_bank_read(c, bank) != bank: ok = false
  check(ok, "ROM banks $01-$7F each map their own bank")
  check(rom_bank_read(c, 0x85) == 5, "bit 7 is not wired: $85 selects bank 5")
  fill_ram_banks(c, 4)
  mbc_write(c, 0x4000, 0x04)
  mbc_write(c, 0xA000, 0x99)
  check(mbc_read(c, 0xA000) == 0xFF, "RAM bank 4 reads open bus on a 32 KiB MBC3")
  mbc_write(c, 0x4000, 0x00)
  check(mbc_read(c, 0xA000) == 0x40, "and a write there does not reach bank 0")

echo "=== MBC30 64 KiB battery save ==="
block:
  let path = make_rom("mbc30bat", 0x07, 0x05)
  let c = load_cartridge(path)
  fill_ram_banks(c, 8)
  mbc_write(c, 0x0000, 0x00)   # RAM disable flushes the battery file
  check(fileExists(path.changeFileExt(".sav")) and
        getFileSize(path.changeFileExt(".sav")) == 0x10000,
        "the .sav is the full 64 KiB")
  let c2 = load_cartridge(path)
  mbc_write(c2, 0x0000, 0x0A)
  mbc_write(c2, 0x4000, 0x07)
  check(mbc_read(c2, 0xA000) == 0x47 and mbc_read(c2, 0xBFFF) == 0x87,
        "bank 7 comes back from the .sav")

echo "=== MBC30 save state ==="
block:
  let path = make_rom("mbc30state", 0x07, 0x05)
  let gb = new_gb("", path, headless = true, run_bios = false)
  gb.post_init()
  gb.cartridge.sav_path = ""
  fill_ram_banks(gb.cartridge, 8)
  mbc_write(gb.cartridge, 0x2000, 0xC3)
  mbc_write(gb.cartridge, 0x4000, 0x06)
  mbc_sync_rom_map(gb.cartridge)
  let state = gb.state_bytes()
  let gb2 = new_gb("", path, headless = true, run_bios = false)
  gb2.post_init()
  gb2.cartridge.sav_path = ""
  check(gb2.load_state_bytes(state), "state loads")
  check(mbc_read_rom_hi(gb2.cartridge, 0x4000) == 0xC3,
        "ROM bank $C3 is mapped after the load (fast path)")
  check(mbc_read(gb2.cartridge, 0xA000) == 0x46, "RAM bank 6 is selected after the load")
  mbc_write(gb2.cartridge, 0x4000, 0x07)
  check(mbc_read(gb2.cartridge, 0xBFFF) == 0x87, "RAM bank 7's contents are in the state")

removeDir(dir)
if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
