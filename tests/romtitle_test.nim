## Unit tests for cartridge header titles (src/dingbat/common/romtitle.nim).
##
## This is the string the native window title and the web page/lock screen put
## in front of a human, and its failure modes are all invisible to every ROM
## suite in the tree: a window that is one byte too wide appends a CGB cart's
## manufacturer code to its name ("POKEMON CRYSAXVE"), one that is too narrow
## truncates every DMG title, and an unsanitized field puts control bytes into
## a window title. So the boundaries and the sanitizer are enumerated here.
##
## web/index.js carries the same parse for the web frontend (romHeaderTitle,
## covered by web/tests/nowplaying.test.mjs) — the two must agree, and the
## cases below are deliberately mirrored there.

import std/strformat
import dingbat/common/romtitle

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

proc eq(got, want, msg: string) =
  check(got == want, &"{msg} (got \"{got}\", want \"{want}\")")

proc gb_rom(title: string; cgb = false; manufacturer = "AXVE"): seq[byte] =
  ## A 0x150-byte GB header with `title` at 0x134. `cgb` also writes the
  ## manufacturer code at 0x13F and the $C0 CGB flag at 0x143 — the fields that
  ## shrink the title window to 11 bytes.
  result = newSeq[byte](0x150)
  for i, c in title:
    if i >= 16: break
    result[0x134 + i] = byte(c)
  if cgb:
    for i, c in manufacturer:
      result[0x13F + i] = byte(c)
    result[0x143] = 0xC0'u8

proc gba_rom(title: string): seq[byte] =
  ## A 0xC0-byte GBA header with `title` at 0xA0 and a game code at 0xAC (which
  ## must never end up in the title).
  result = newSeq[byte](0xC0)
  for i, c in title:
    if i >= 12: break
    result[0xA0 + i] = byte(c)
  for i, c in "BPEE":
    result[0xAC + i] = byte(c)

echo "=== GBA: 12 bytes at 0xA0 ==="
block:
  eq(gba_header_title(gba_rom("POKEMON EMER")), "POKEMON EMER", "full-width title")
  eq(gba_header_title(gba_rom("METROID4")), "METROID4", "NUL-padded title")
  eq(gba_header_title(gba_rom("KIRBY      ")), "KIRBY", "space padding is trimmed")
  # The game code at 0xAC sits immediately after a full-width title, so a
  # one-byte-wide window would silently produce "POKEMON EMERB".
  check(gba_header_title(gba_rom("POKEMON EMER")).len == 12,
        "the game code at 0xAC is not part of the title")

echo ""
echo "=== GB: the CGB flag decides an 11- or 16-byte window ==="
block:
  eq(gb_header_title(gb_rom("SUPER MARIOLAND")), "SUPER MARIOLAND",
     "non-CGB cart gets the full 16 bytes")
  eq(gb_header_title(gb_rom("POKEMON_CRYSTAL", cgb = true)), "POKEMON_CRY",
     "CGB cart stops before the manufacturer code")
  eq(gb_header_title(gb_rom("ZELDA", cgb = true)), "ZELDA",
     "a short CGB title stops at its NUL, not at the window end")
  # $80 (CGB-enhanced, DMG-compatible) is the other flag value that shrinks it.
  block:
    var rom = gb_rom("POKEMON_CRYSTAL", cgb = true)
    rom[0x143] = 0x80'u8
    eq(gb_header_title(rom), "POKEMON_CRY", "$80 shrinks the window too")
  # Anything else at 0x143 is title byte 16, not a flag.
  block:
    var rom = gb_rom("ABCDEFGHIJKLMNOP")
    check(gb_header_title(rom).len == 16, "$00 at 0x143: all 16 bytes are title")

echo ""
echo "=== sanitizing ==="
block:
  eq(gb_header_title(newSeq[byte](0x150)), "", "all-zero GB header")
  eq(gba_header_title(newSeq[byte](0xC0)), "", "all-zero GBA header")
  # A garbage file: no NUL to stop at, so this exercises the filter arm.
  block:
    var rom = newSeq[byte](0x150)
    for i in 0 ..< rom.len: rom[i] = 0xFF'u8
    rom[0x143] = 0x00'u8   # not a CGB flag -> the wide window
    eq(gb_header_title(rom), "", "high bytes are dropped, not mangled")
  block:
    var rom = gba_rom("OK")
    rom[0xA2] = 0x01'u8    # control character
    rom[0xA3] = 0x80'u8    # >= 0x80
    rom[0xA4] = byte('!')
    eq(gba_header_title(rom), "OK!", "unprintables are dropped, printables kept")
  # Truncated files must never read past the end or guess.
  eq(gb_header_title(newSeq[byte](0x140)), "", "GB header shorter than 0x144")
  eq(gba_header_title(newSeq[byte](0x40)), "", "GBA header shorter than 0xAC")
  eq(gb_header_title(newSeq[byte](0)), "", "empty ROM")
  eq(gba_header_title(newSeq[byte](0)), "", "empty ROM (GBA)")

echo ""
if failures == 0:
  echo "romtitle: all checks passed"
else:
  echo &"romtitle: {failures} check(s) FAILED"
  quit(1)
