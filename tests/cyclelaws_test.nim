## The cycle laws measured on an AGB SP, held against the core without the
## console: tests/roms/cyclelaws/ is tools/hwlink/lawrom.py's freeze of the
## recorded tables (breakram-agb.json, r0-agb.json) -- one ROM per payload
## that runs it once per recorded argument and leaves each answer in EWRAM --
## and laws.json says how to read each word and what the console answered.
##
## The mGBA suite cannot stand in for this: its rows are sums, and two terms a
## cycle out in opposite directions pass it (docs/cycle-hunt-method.md). These
## cells are the terms.
##
##   nimble test_cyclelaws
##
## Runs under the HLE BIOS always, and under Nintendo's as well when
## DINGBAT_GBA_BIOS (or tests/roms/gba_bios.bin) is there -- it never is in CI.

import std/[json, os, sha1, strformat, strutils]
import dingbat/gba/gba

const Dir = "tests/roms/cyclelaws"
const Results = 0x02000000'u32
const Marker = 0x02000FFC'u32          # payloadrun.s: every argument has run

proc word(emu: GBA; a: uint32): uint32 =
  for k in 0'u32 .. 3: result = result or (uint32(emu.bus[a + k]) shl (8 * k))

proc show(kind: string; v: uint32): string =
  ## tools/hwlink/breakram.py `show`, by the kind lawrom.py wrote down
  if kind == "hex": return v.toHex(8)
  if v == 0xFFFFFFFF'u32: return "WD"
  case kind
  of "edge": &"{int(v and 7):03b} v{v shr 8}"
  of "stamp":
    let reads = v and 0xFFFF
    &"T={v shr 16} " & (if reads >= 0x4000: "-" else: $reads)
  else:
    if (v shr 8) >= 0x4000: "-" else: &"{v shr 8}@{v and 0xFF}"

var failures = 0

proc run(bios: string) =
  let label = if bios.len == 0: "HLE" else: "real BIOS"
  var total, bad = 0
  for law in parseFile(Dir / "laws.json"):
    let rom = Dir / law["rom"].getStr
    if $secureHashFile(rom) != law["sha1"].getStr.toUpperAscii:
      echo &"  FAIL {rom} is not the ROM laws.json describes; run tools/hwlink/lawrom.py"
      inc failures
      continue
    let emu = new_gba(bios, rom, run_bios = false, use_hle = bios.len == 0)
    emu.post_init()
    # No peeking until the run is over: a debugger's read moves the open-bus
    # latch like any other, and breakram's loop is reading that latch.
    for _ in 1 .. law["frames"].getInt: emu.step_frame()
    if emu.word(Marker) != 0x600D0000'u32:
      echo &"  FAIL {label} {rom} never finished"
      inc failures
      continue
    var i = 0'u32
    for cell in law["cells"]:
      let got = show(cell["kind"].getStr, emu.word(Results + 4 * i))
      let want = if bios.len == 0 and cell.hasKey("hle_want"): cell["hle_want"].getStr
                 else: cell["want"].getStr
      inc total
      if got != want:
        inc bad
        echo &"  FAIL {label} {cell[\"id\"].getStr}: {got}, console {want}"
      inc i
  echo &"{label}: {total - bad}/{total} cells are the console's"
  failures += bad

run("")
var bios = getEnv("DINGBAT_GBA_BIOS", "tests/roms/gba_bios.bin")
if fileExists(bios): run(bios)
else: echo "real BIOS: not here, skipped"

if failures == 0: echo "ALL CYCLE LAWS HOLD"
else:
  echo failures, " FAILURES"
  quit(1)
