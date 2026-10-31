## The late object abort (OBJ_ABORT_LATE, fifo_obj_abort_late) belongs to the
## mode 3 that armed it. Run standalone:
##   nimble test_gbobjabortlate
##
## `obj_abort_last` remembers the dot an object's fetch ended on, so an LCDC.1
## clear OBJ_ABORT_LEAD dots later can still refund the stall. It used to
## outlive its line: a clear on the same dot of H-Blank, or of any V-Blank
## line after line 143's last object, ran the refund's pipeline dots there,
## and the shifter wrote past the framebuffer (row 148 + 160: "index 23840
## not in 0 .. 23039"). In the iOS app that Defect escaped dingbat_run_frame
## and left the core dead until relaunch (bug report 2026-10-31, a DMG demo
## that keeps toggling LCDC.1).
##
## No ROM on disk: the program, assembled here from bytes, puts ten objects on
## lines 136..143 and then writes LCDC with OBJ off and on in a loop whose
## period drifts against the 456-dot line, so its clears land on every dot
## phase of H-Blank and V-Blank within a few frames. Three loop lengths. The
## test only asks that the core survives and draws nothing outside mode 3.

import std/os
import dingbat/gb/gb

var failures = 0
var checks = 0
proc check(cond: bool; msg: string) =
  inc checks
  if not cond:
    inc failures
    if failures <= 40: echo "  [FAIL] ", msg

proc program(pad: int): seq[int] =
  result = @[
    0xF3,                         # di
    0xF0, 0x44, 0xFE, 0x90,       # wait: ldh a,[LY]; cp 144
    0x20, 0xFA,                   #   jr nz,wait
    0xAF, 0xE0, 0x40,             # xor a; ldh [LCDC],a      LCD off in V-blank
    0x21, 0x10, 0x80,             # ld hl,$8010              tile 1: colour 3
    0x3E, 0xFF, 0x06, 0x10,       # ld a,$FF; ld b,16
    0x22, 0x05, 0x20, 0xFC,       #   ld [hl+],a; dec b; jr nz
    0x21, 0x00, 0xFE,             # ld hl,$FE00              OAM: all off screen
    0xAF, 0x06, 0xA0,             # xor a; ld b,160
    0x22, 0x05, 0x20, 0xFC,       #   ld [hl+],a; dec b; jr nz
    0x21, 0x00, 0xFE,             # ld hl,$FE00              ten objects, Y 152
    0x0E, 0x08,                   # ld c,8                   (lines 136..143),
    0x06, 0x0A,                   # ld b,10                  X 8, 24, ... 152
    0x3E, 0x98, 0x22,             #   ld a,152; ld [hl+],a
    0x79, 0x22,                   #   ld a,c; ld [hl+],a
    0xC6, 0x10, 0x4F,             #   add 16; ld c,a
    0x3E, 0x01, 0x22,             #   ld a,1; ld [hl+],a
    0xAF, 0x22,                   #   xor a; ld [hl+],a
    0x05, 0x20, 0xF1,             #   dec b; jr nz
    0x3E, 0xE4, 0xE0, 0x47,       # ld a,$E4; ldh [BGP],a
    0xE0, 0x48,                   # ldh [OBP0],a
    0x3E, 0x83, 0xE0, 0x40]       # ld a,$83; ldh [LCDC],a   LCD, OBJ and BG on
  # loop: OBJ off, OBJ on, `pad` nops: 13 + pad M-cycles a turn.
  result.add([0x3E, 0x81, 0xE0, 0x40, 0x3E, 0x83, 0xE0, 0x40])
  for _ in 0 ..< pad: result.add(0x00)
  result.add([0x18, -(10 + pad) and 0xFF])

proc make_rom(code: openArray[int]): string =
  result = newString(0x8000)
  for i, b in [0xC3, 0x50, 0x01]: result[0x100 + i] = char(b)  # jp $0150
  for i, b in code: result[0x150 + i] = char(b)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(result[a])) - 1
  result[0x14D] = char(sum and 0xFF)

let tmp_rom = getTempDir() / ("dingbat_objabortlate_" & $getCurrentProcessId() & ".gb")

echo "Late object abort outside mode 3"
for pad in 0 .. 2:
  writeFile(tmp_rom, make_rom(program(pad)))
  let emu = new_gb("", tmp_rom, headless = true, run_bios = false, force_dmg = true)
  emu.gb_set_revision(grDmgABC)
  emu.post_init()
  emu.cartridge.sav_path = ""
  var frame = 0
  var err = ""
  var black = 0   # object pixels on line 143, over every frame
  try:
    while frame < 120:
      emu.step_frame()
      inc frame
      for x in 0 ..< GB_WIDTH:
        if emu.ppu.framebuffer[143 * GB_WIDTH + x] == DMG_COLORS[3]: inc black
  except IndexDefect as e:
    err = e.msg
  let loop = "loop of " & $(13 + pad) & " M-cycles"
  check(err.len == 0, loop & ": " & err & " in frame " & $frame)
  # The objects were fetched on the line the window outlived.
  check(err.len > 0 or black > 0, loop & ": no object pixels on line 143")

removeFile(tmp_rom)
if failures > 0:
  echo "FAILED: ", failures, " of ", checks, " checks"
  quit(1)
echo "all ", checks, " checks passed"
