## Where a window that starts left of the screen sits, across WX x SCX & 7
## (WIN_FINE_PAD, WIN_WX0_PHASE; docs/gb-failure-triage.md I6). Run standalone:
##   nimble test_gbwindowscx
##
## No ROM on disk: one program, assembled here from bytes, draws a window of
## two black tiles at map row 0 (window lines 0..7, every other tile white)
## with WX and SCX patched in, on a DMG and on a CGB in CGB mode. The picture
## is the black run on lines 0..7: Pan Docs, "Window" -- the window's top-left
## pixel is at WX - 7, and only WX = 0 "is switched to before the initial fine
## scroll adjustment", i.e. shifted left by SCX & 7. SameBoy (DMG B and CGB
## E, black box) draws every cell checked here the same way; mode 3's length
## for these lines is pinned elsewhere (gambatte window/m2int_wx03_scx*,
## mealybug m3_window_timing*).
##
## DINGBAT_WINSCX_ROMS=<dir> also writes each ROM there, for running the same
## cells on another emulator.

import std/os
import dingbat/gb/gb

var failures = 0
var checks = 0
proc check(cond: bool; msg: string) =
  inc checks
  if not cond:
    inc failures
    if failures <= 40: echo "  [FAIL] ", msg

proc program(wx, scx: int): seq[int] =
  result = @[
    0xF3,                         # di
    0xF0, 0x44, 0xFE, 0x90,       # wait: ldh a,[LY]; cp 144
    0x20, 0xFA,                   #   jr nz,wait
    0xAF, 0xE0, 0x40,             # xor a; ldh [LCDC],a      LCD off in V-blank
    0x21, 0x00, 0x90,             # ld hl,$9000              tile 0: colour 0
    0x06, 0x10,                   # ld b,16
    0x22, 0x05, 0x20, 0xFC,       #   ld [hl+],a; dec b; jr nz
    0x3E, 0xFF, 0x06, 0x10,       # ld a,$FF; ld b,16        tile 1: colour 3
    0x22, 0x05, 0x20, 0xFC,       #   ld [hl+],a; dec b; jr nz
    0x21, 0x00, 0x9C,             # ld hl,$9C00              window map: tile 0
    0x01, 0x00, 0x04,             # ld bc,$0400
    0xAF, 0x22, 0x0B, 0x78, 0xB1, #   xor a; ld [hl+],a; dec bc; ld a,b; or c
    0x20, 0xF9,                   #   jr nz
    0x3E, 0x01,                   # ld a,1                   map row 0, columns 0-1:
    0xEA, 0x00, 0x9C,             #   ld [$9C00],a           tile 1
    0xEA, 0x01, 0x9C,             #   ld [$9C01],a
    0x3E, 0x80, 0xE0, 0x68]       # ld a,$80; ldh [BCPS],a   CGB BG palette 0:
  for _ in 0 ..< 3:               #   colours 0..2 white
    result.add([0x3E, 0xFF, 0xE0, 0x69, 0x3E, 0x7F, 0xE0, 0x69])
  result.add([0xAF, 0xE0, 0x69, 0xE0, 0x69,   # colour 3 black (a DMG ignores all this)
    0x3E, 0xE4, 0xE0, 0x47,       # ld a,$E4; ldh [BGP],a
    0xAF, 0xE0, 0x4A, 0xE0, 0x42, # WY = 0, SCY = 0
    0x3E, wx, 0xE0, 0x4B,         # WX
    0x3E, scx, 0xE0, 0x43,        # SCX
    0x3E, 0xE1, 0xE0, 0x40,       # LCDC = on, window map $9C00, window on, BG on
    0x18, 0xFE])                  # jr $

proc make_rom(code: openArray[int]; cgb: bool): string =
  result = newString(0x8000)
  for i, b in [0xC3, 0x50, 0x01]: result[0x100 + i] = char(b)  # jp $0150
  for i, b in code: result[0x150 + i] = char(b)
  if cgb: result[0x143] = char(0x80)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(result[a])) - 1
  result[0x14D] = char(sum and 0xFF)

let dump_dir = getEnv("DINGBAT_WINSCX_ROMS")
let tmp_rom = getTempDir() / ("dingbat_winscx_" & $getCurrentProcessId() & ".gb")

proc black_run(wx, scx: int; cgb: bool): seq[(int, int)] =
  ## (first black x, black count) for lines 0..7, then the count on the
  ## lines below them (all white).
  let rom = make_rom(program(wx, scx), cgb)
  writeFile(tmp_rom, rom)
  if dump_dir.len > 0:
    writeFile(dump_dir / ((if cgb: "cgb" else: "dmg") & "_wx" & $wx & "_scx" & $scx &
                          (if cgb: ".gbc" else: ".gb")), rom)
  let emu = new_gb("", tmp_rom, headless = true, run_bios = false,
                   force_cgb = cgb, force_dmg = not cgb)
  emu.gb_set_revision(if cgb: grCgbE else: grDmgABC)
  emu.post_init()
  emu.cartridge.sav_path = ""
  for _ in 0 ..< 4: emu.step_frame()
  let black = if cgb: 0x0000'u16 else: DMG_COLORS[3]
  var below = 0
  for y in 0 ..< GB_HEIGHT:
    var first = -1
    var n = 0
    for x in 0 ..< GB_WIDTH:
      if emu.ppu.framebuffer[y * GB_WIDTH + x] == black:
        if first < 0: first = x
        inc n
    if y < 8: result.add((first, n))
    else: below += n
  result.add((-1, below))

proc expect(wx, s: int): (int, int) =
  ## Two black tiles from window x 0: screen x WX - 7 - shift, where the
  ## shift is SCX & 7 at WX = 0 only.
  let left = wx - 7 - (if wx == 0: s else: 0)
  (max(0, left), left + 16 - max(0, left))

echo "Window position, WX x SCX & 7"
for cgb in [false, true]:
  for wx in 0 .. 8:
    for s in 0 .. 7:
      # WX = 0 with SCX & 7 in 1..6 (1..7 on a CGB) is a hardware question:
      # DocBoy and SameBoy drop one more pixel there (docs/gb-failure-triage.md
      # I6, I8); Pan Docs and dingbat do not. Not asserted.
      if wx == 0 and s > 0 and (s < 7 or cgb): continue
      let got = black_run(wx, s, cgb)
      let want = expect(wx, s)
      let dev = if cgb: "CGB" else: "DMG"
      for y in 0 ..< 8:
        check(got[y] == want, dev & " WX=" & $wx & " SCX=" & $s & " line " & $y &
              ": black from x " & $got[y][0] & " for " & $got[y][1] &
              ", want from " & $want[0] & " for " & $want[1])
      check(got[8][1] == 0, dev & " WX=" & $wx & " SCX=" & $s & ": " &
            $got[8][1] & " black pixels below line 8")

removeFile(tmp_rom)
if failures > 0:
  echo "FAILED: ", failures, " of ", checks, " checks"
  quit(1)
echo "all ", checks, " checks passed"
