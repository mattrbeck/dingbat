## The GBA slot (slot 2): the device models in src/dingbat/nds/io/slot2.nim
## driven directly (open bus, Rumble Pak, Expansion Pak, a GBA cart's SRAM /
## FLASH / EEPROM / GPIO), then our probe ROM (tests/nds/src/slot2_probe,
## built by tests/nds/tools/build_slot2.sh) run under each device with its
## 82 result words checked. docs/nds/slot2.md lists the words and which of
## them the reference runs agree with.
##
## Run with: nimble test_ndsslot2

import std/[os, strutils]
import dingbat/nds/nds
import dingbat/gba/storage_chip

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

proc hex(v: uint32): string = "0x" & toHex(v, 8)

proc gba_rom(size: int; lib: string): seq[uint8] =
  ## A synthetic GBA ROM: halfword i holds i xor 0x5A5A, a header with game
  ## code "TEST", maker "01", 96h, and `lib` (a backup library ID) at 1000h.
  result = newSeq[uint8](size)
  for i in 0 ..< size div 2:
    let v = uint16(i) xor 0x5A5A
    result[2 * i] = uint8(v); result[2 * i + 1] = uint8(v shr 8)
  for i in 0xA0 ..< 0xC0: result[i] = 0
  for i, c in "TEST": result[0xAC + i] = uint8(c)
  result[0xB0] = uint8('0'); result[0xB1] = uint8('1')
  result[0xB2] = 0x96
  for i, c in lib: result[0x1000 + i] = uint8(c)

proc rom16(r: seq[uint8]; off: int): uint32 = uint32(r[off]) or (uint32(r[off + 1]) shl 8)

# ---------------------------------------------------------------------------
# Device level

block open_bus:
  echo "empty slot"
  let s = new_slot2()
  check s.rom_read16(0x0800_ABCE'u32, 6) == 0x55E7 and s.rom_read16(0x0800_ABCE'u32, 8) == 0x55E7,
        "6 / 8 cycles: address/2"
  check s.rom_read16(0x0800_ABCE'u32, 10) == 0xFFEF, "10 cycles: address/2 OR FE08h"
  check s.rom_read16(0x0800_ABCE'u32, 18) == 0xFFFF, "18 cycles: FFFFh"
  check s.ram_read8(0x0A00_1234'u32) == 0xFF, "SRAM region FFh"
  check s.gba_header_info() == [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        "boot info for no cart: FFh, the flags byte 00h (the real firmware's)"

block rumble_pak:
  echo "Rumble Pak"
  let s = new_slot2()
  s.insert_rumble_pak()
  var ok = 0
  for i in 0'u32 ..< 0x1000:
    if s.rom_read16(0x0800_0000'u32 + i * 2, 6) == (i and 0xFFFD): inc ok
  check ok == 0x1000, "GBATEK detection loop at 6 cycles: every halfword reads (i AND FFFDh)", $ok
  check s.rom_read16(0x0800_0000'u32, 18) == 0xFFFD,
        "18 cycles (the libnds detection setting): 0x08000000 reads FFFDh"
  check (s.rom_read16(0x0800_00B2'u32, 18) and 0xFF) != 0x96, "no GBA header (B2h is not 96h)"
  check s.rumble() == 0, "still before any write"
  s.rom_write(0x0800_1000'u32, 2, 16)
  s.end_frame()
  check s.rumble() == 64, "one latch change in a frame: light", $s.rumble()
  for i in 0 ..< 6: s.rom_write(0x0800_1000'u32, uint32((i and 1) * 2), 16)
  s.end_frame()
  check s.rumble() == 255, "many changes: full strength", $s.rumble()
  s.rom_write(0x0800_1000'u32, 2, 16)   # the latch is already 1: no change
  s.end_frame()
  check s.rumble() == 0, "no change in a frame: still"

block expansion_pak:
  echo "Memory Expansion Pak"
  let s = new_slot2()
  s.insert_expansion_pak()
  check s.rom_read16(0x0800_00B2'u32, 10) == 0x0000 and s.rom_read16(0x0800_00B6'u32, 10) == 0x2424 and
        s.rom_read16(0x0800_00BE'u32, 10) == 0x7FFF, "header ID bytes B0h-BFh"
  check s.rom_read16(0x0800_0000'u32, 10) == 0xFFFF, "rest of the ROM region FFFFh"
  s.rom_write(0x0900_0000'u32, 0x1234, 16)
  check s.rom_read16(0x0900_0000'u32, 10) == 0x1234, "starts unlocked: a write sticks"
  s.rom_write(0x0824_0000'u32, 0, 16)
  check s.rom_read16(0x0900_0000'u32, 10) == 0xFFFF, "locked: RAM reads FFFFh"
  s.rom_write(0x0900_0000'u32, 0x9999, 16)
  s.rom_write(0x0824_0000'u32, 1, 16)
  check s.rom_read16(0x0900_0000'u32, 10) == 0x1234, "a locked write is dropped"
  s.rom_write(0x0900_0001'u32, 0xAB, 8)
  check s.rom_read16(0x0900_0000'u32, 10) == 0x1234, "byte stores do nothing"
  s.rom_write(0x097F_FFFE'u32, 0xBEEF, 16)
  check s.rom_read16(0x097F_FFFE'u32, 10) == 0xBEEF and s.rom_read16(0x0980_0000'u32, 10) == 0xFFFF,
        "8 MB at 0x09000000, nothing past it"

block gba_flash:
  echo "GBA cart: FLASH 128K"
  let s = new_slot2()
  let rom = gba_rom(0x10_0000, "FLASH1M_V103")
  var sav = newSeq[uint8](0x20000)
  for b in sav.mitems: b = 0xFF
  sav[0x12345] = 0x42
  s.insert_gba(rom, sav)
  check s.save_type == stFLASH1M and s.save.len == 0x20000, "FLASH1M_V -> 128 KB FLASH", $s.save_type
  check s.rom_read16(0x0800_0100'u32, 10) == rom16(rom, 0x100), "ROM halfword"
  check s.rom_read16(0x0810_0002'u32, 6) == 0x0001 and s.rom_read16(0x0810_0002'u32, 10) == 0xFE09,
        "past the ROM: open bus as for an empty slot"
  template cmd(c: uint8) =
    s.ram_write8(0x0A00_5555'u32, 0xAA); s.ram_write8(0x0A00_2AAA'u32, 0x55)
    s.ram_write8(0x0A00_5555'u32, c)
  cmd(0x90)
  check (s.ram_read8(0x0A00_0000'u32) or (s.ram_read8(0x0A00_0001'u32) shl 8)) == 0x1362,
        "ID mode: Sanyo 1362h"
  cmd(0xF0)
  cmd(0xB0); s.ram_write8(0x0A00_0000'u32, 1)
  check s.ram_read8(0x0A00_2345'u32) == 0x42, "bank 1 reads the second 64 KB"
  cmd(0xA0); s.ram_write8(0x0A00_0010'u32, 0x5A)
  check s.save[0x10010] == 0x5A and s.dirty, "byte program into bank 1"
  cmd(0x80); s.ram_write8(0x0A00_5555'u32, 0xAA); s.ram_write8(0x0A00_2AAA'u32, 0x55)
  s.ram_write8(0x0A00_0000'u32, 0x30)
  check s.save[0x10010] == 0xFF and s.save[0x12345] == 0x42, "4 KB sector erase"
  check s.gba_header_info() == [0'u8, 0, 0, 0, 0, 0, uint8('0'), uint8('1'),
                                 uint8('T'), uint8('E'), uint8('S'), uint8('T')],
        "boot info: header BEh, B5h-B7h, flags, maker, game code"

block gba_sram:
  echo "GBA cart: SRAM"
  let s = new_slot2()
  s.insert_gba(gba_rom(0x8_0000, "SRAM_V113"))
  check s.save_type == stSRAM and s.save.len == 0x8000, "SRAM_V -> 32 KB SRAM"
  s.ram_write8(0x0A00_7FFF'u32, 0x77)
  check s.ram_read8(0x0A00_7FFF'u32) == 0x77 and s.ram_read8(0x0A01_7FFF'u32) == 0x77,
        "write / read back, repeating every 64 KB"

block gba_eeprom:
  echo "GBA cart: EEPROM"
  let s = new_slot2()
  s.insert_gba(gba_rom(0x10_0000, "EEPROM_V124"))
  check s.save_type == stEEPROM, "EEPROM_V -> EEPROM"
  proc send(s: Slot2; bits: openArray[int]) =
    for b in bits: s.rom_write(0x0900_0000'u32, uint32(b), 16)
  proc bits_of(v: uint64; n: int): seq[int] =
    for i in countdown(n - 1, 0): result.add int((v shr i) and 1)
  # 64 Kbit: write block 5 (10, 14-bit address, 64 data bits, 0)
  let data = 0x0123_4567_89AB_CDEF'u64
  s.send(@[1, 0] & bits_of(5, 14) & bits_of(data, 64) & @[0])
  check s.rom_read16(0x0900_0000'u32, 10) == 1, "ready after the write"
  check s.save.len == 0x2000 and s.save[40] == 0x01 and s.save[47] == 0xEF,
        "81-bit write: 64 Kbit chip, block 5 stored MSB first"
  s.send(@[1, 1] & bits_of(5, 14) & @[0])
  var got = 0'u64
  for i in 0 ..< 68:
    let b = s.rom_read16(0x0900_0000'u32, 10) and 1
    if i >= 4: got = (got shl 1) or uint64(b)
  check got == data, "read back: 4 dummy bits then the 64 data bits", toHex(got)
  check s.rom_read16(0x0800_0000'u32, 10) == 0x5A5A, "the ROM below 0x09000000 is unaffected"

block gba_gpio:
  echo "GBA cart: GPIO rumble"
  let s = new_slot2()
  s.insert_gba(gba_rom(0x40_0000, "SRAM_V113"))
  check s.rom_read16(0x0800_00C4'u32, 10) == rom16(s.rom, 0xC4), "port write-only: ROM data"
  s.rom_write(0x0800_00C8'u32, 1, 16)
  s.rom_write(0x0800_00C6'u32, 8, 16)
  s.rom_write(0x0800_00C4'u32, 8, 16)
  check s.rom_read16(0x0800_00C4'u32, 10) == 8 and s.rumble() == 255,
        "bit 3 an output driven high: motor on"
  s.rom_write(0x0800_00C4'u32, 0, 16)
  check s.rumble() == 0, "driven low: off"

# ---------------------------------------------------------------------------
# The probe ROM

const
  ROM_DIR = "~/.cache/dingbat-nds/roms"
  TIMING = {39 .. 52, 80, 81}
  # Empty slot. Every word except the timing ones (checked as differences
  # below) and 65-67 (boot info: GBATEK's FFh; the reference leaves 0000FFFF,
  # 0, 0) agrees with the reference runs.
  EMPTY = [
    0x0000FE08'u32, 0x0000FFEF, 0x0000FFFF, 0xFE89FE88'u32,   # 0-3   10 cycles
    0x00000000, 0x000055E7, 0x0000FFFF, 0x00810080,       # 4-7   8
    0x00000000, 0x000055E7, 0x0000FFFF, 0x00810080,       # 8-11  6
    0x0000FFFF, 0x0000FFFF, 0x0000FFFF, 0xFFFFFFFF'u32,       # 12-15 18
    0x0000FE08, 0x0000FFEF, 0x0000FFFF, 0xFE89FE88'u32,       # 16-19 10 + 4
    0x000000FF, 0x0000FFFF, 0xFFFFFFFF'u32, 0x000000FF,       # 20-23 SRAM
    0x00000000, 0x00000000, 0x00000000,                   # 24-26 ARM9 not owner
    0x0000FE08, 0x0000FFEF, 0x00000000, 0x000055E7,       # 27-34 ARM7 owner
    0x00000000, 0x000055E7, 0x0000FFFF, 0x0000FFFF,
    0x000000FF, 0x0000608C, 0x00006080, 0x00000000,       # 35-38
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,             # 39-52 timing
    0x00000800,                                           # 53 rumble loop
    0x00590058, 0x005B005A, 0x005D005C, 0x005F005E,       # 54-57 header
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # 58-62
    0xFE5FFE5E'u32, 0x0000FFFF,                               # 63-64
    0xFFFFFFFF'u32, 0xFFFF00FF'u32, 0xFFFFFFFF'u32,                   # 65-67 boot info (flags 00h)
    0x0000E8FF, 0x0000607F, 0x000000FF, 0x0000FE09,       # 68-71
    0x0000FE08, 0x0000FE09, 0x0000FE08, 0x0000FE08, 0xFE09FE08'u32,  # 72-76
    0x0000FE6A, 0xFE6BFE6A'u32, 0xFE6BFE6A'u32,                   # 77-79 GPIO
    0, 0]                                                 # 80-81 timing

proc rumble_expect(): array[82, uint32] =
  ## The empty slot with AD1 pulled low: every ROM-region halfword AND FFFDh
  ## (the reference instead reads FFFDh everywhere; GBATEK's detection loop
  ## only works on this model).
  result = EMPTY
  for i in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 16, 17, 18, 27, 28, 29, 30, 31, 32,
            33, 34, 58, 59, 60, 61, 62, 71, 72, 73, 74, 75, 77]:
    result[i] = result[i] and 0xFFFD
  for i in [3, 7, 11, 15, 19, 54, 55, 56, 57, 63, 76, 78, 79]:
    result[i] = result[i] and 0xFFFDFFFD'u32
  result[53] = 0x1000

proc expansion_expect(): array[82, uint32] =
  ## Every word agrees with the reference runs except the SRAM-region bytes
  ## (FFh here, 00h there), the timing and boot info, and 75 (the lock
  ## register's address: FFFFh here, 0 there).
  result = EMPTY
  for i in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 16, 17, 18, 27, 28, 29, 30, 31,
            32, 33, 34, 58, 62, 71, 73, 74, 75, 77]:
    result[i] = 0xFFFF
  for i in [3, 7, 11, 15, 19, 56, 63, 78, 79]: result[i] = 0xFFFFFFFF'u32
  result[53] = 0
  result[54] = 0x0000FFFF; result[55] = 0x24242400; result[57] = 0x7FFFFFFF
  result[59] = 0x1234; result[60] = 0x5678; result[61] = 0x5678; result[72] = 0x5678
  result[76] = 0x89ABCDEF'u32

proc run_probe(rom: seq[uint8]; kind: Slot2Kind; cart: seq[uint8] = @[]): seq[uint32] =
  let n = new_nds(rom, @[], @[], @[])
  n.insert_slot2(kind, cart)
  for f in 0 ..< 30: n.run_frame()
  for i in 0 .. 82:
    let o = 0x200100 + 4 * i
    result.add uint32(n.main_ram[o]) or (uint32(n.main_ram[o + 1]) shl 8) or
               (uint32(n.main_ram[o + 2]) shl 16) or (uint32(n.main_ram[o + 3]) shl 24)

proc check_words(name: string; got: seq[uint32]; want: array[82, uint32]) =
  var bad: seq[string]
  for i in 0 ..< 82:
    if i notin TIMING and got[i] != want[i]: bad.add $i & "=" & hex(got[i]) & " want " & hex(want[i])
  check bad.len == 0, name & ": result words", bad.join(", ")

proc check_timing(name: string; r: seq[uint32]) =
  ## Bus cycles for 16 loads: each step of the first access time (10, 8, 6,
  ## 18) moves 16 loads by 2 cycles each; the second access time does not
  ## touch a nonsequential load; SRAM follows its own setting the same way.
  template d(a, b: int): int = int(r[a]) - int(r[b])
  check d(39, 40) == 32 and d(40, 41) == 32 and d(42, 39) == 128 and r[43] == r[39] and
        r[44] == r[41], name & ": ARM9 ROM first access 10/8/6/18, second access no effect"
  check d(45, 46) == 32 and d(46, 47) == 32 and d(48, 45) == 128,
        name & ": ARM9 SRAM 10/8/6/18"
  check d(49, 50) == 32 and d(50, 51) == 32 and d(52, 49) == 128,
        name & ": ARM7 ROM first access from its own EXMEMSTAT"

block probe:
  let path = ROM_DIR.expandTilde / "slot2_probe.nds"
  if not fileExists(path):
    echo "slot2_probe.nds not built (tests/nds/tools/build_slot2.sh): skipped"
  else:
    let rom = cast[seq[uint8]](readFile(path))
    echo "probe: empty slot"
    let e = run_probe(rom, s2Empty)
    check e[82] == 0x32544F53'u32, "probe ran to the end"
    check_words("empty", e, EMPTY)
    check_timing("empty", e)
    echo "probe: Rumble Pak"
    check_words("Rumble Pak", run_probe(rom, s2RumblePak), rumble_expect())
    echo "probe: Expansion Pak"
    check_words("Expansion Pak", run_probe(rom, s2ExpansionPak), expansion_expect())
    echo "probe: GBA cart (synthetic 1 MB, FLASH 128K)"
    let cart = gba_rom(0x10_0000, "FLASH1M_V103")
    let g = run_probe(rom, s2GbaCart, cart)
    check g[0] == rom16(cart, 0) and g[1] == rom16(cart, 0xABCE) and
          g[3] == (rom16(cart, 0x100) or (rom16(cart, 0x102) shl 16)),
          "ROM halfwords and words from the image"
    check g[2] == 0xFFFF and g[71] == 0xFE09, "past the 1 MB image: open bus"
    check g[20] == 0xFF and g[22] == 0xFFFFFFFF'u32, "erased FLASH reads FFh, repeated across a word"
    check g[63] == 0x54534554'u32 and g[64] == 0x1362, "game code 'TEST'; FLASH ID 1362h"
    check g[65] == 0 and g[66] == 0x31300000'u32 and g[67] == 0x54534554'u32,
          "boot info at 0x027FFC30 from the header"
    check g[77] == rom16(cart, 0xC4) and g[78] == 0 and g[79] == 0x000F0005'u32,
          "GPIO: ROM data until readable, then direction/data read back"

if failures > 0:
  echo failures, " FAILED"
  quit 1
echo "all slot-2 tests passed"
