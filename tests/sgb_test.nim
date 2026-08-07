# Super Game Boy acceptance test.
#
# Drives tests/roms/sgbtest.gb (built by tests/roms/sgbtest.py) and checks the
# whole SGB path end to end: the P1 packet receiver, PAL01/PAL23, ATTR_DIV,
# ATTR_BLK, the per-cell colorization of the Game Boy screen, and the two VRAM
# transfers that carry a border (CHR_TRN + PCT_TRN).
#
# Every expectation below is recomputed here from the same rules the ROM
# builder used, so the test fails if either side drifts.
#
# With DINGBAT_SGB_PNG=<dir> it also writes screen.png and border.png for
# eyeballing. That is not part of the assertions.

import std/[os, strformat, strutils]
import dingbat/gb/gb
import dingbat/common/serialize

when defined(sgb_png):
  import stb_image/write as stbiw

const ROM = "tests/roms/sgbtest.gb"

var failures = 0
proc check(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "FAIL: ", msg

proc rgb555(r, g, b: int): uint16 =
  uint16((r and 0x1F) or ((g and 0x1F) shl 5) or ((b and 0x1F) shl 10))

# ---- the palettes the ROM sends (mirror of sgbtest.py) ----
const BACKDROP = 0'u16                                   # colour 0, shared
let PAL_EXPECT = [
  [BACKDROP, rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31)],
  [BACKDROP, rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31)],
  [BACKDROP, rgb555(10, 10, 10), rgb555(20, 20, 20), rgb555(31, 31, 31)],
  [BACKDROP, rgb555(31, 16, 0), rgb555(16, 31, 0), rgb555(0, 16, 31)],
]

let BORDER_COLORS = [
  rgb555(0, 0, 0),
  rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31),
  rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31),
  rgb555(31, 31, 31), rgb555(16, 0, 0), rgb555(0, 16, 0),
  rgb555(0, 0, 16), rgb555(16, 16, 0), rgb555(16, 0, 16),
  rgb555(0, 16, 16), rgb555(16, 16, 16), rgb555(24, 12, 4),
]

proc expected_attr(x, y: int): uint8 =
  ## ATTR_DIV (horizontal split at row 9: above = 1, line = 3, below = 2)
  ## then ATTR_BLK (rect x 4..11, y 2..6, inside + its surrounding line = 0).
  result =
    if y < 9: 1'u8
    elif y == 9: 3'u8
    else: 2'u8
  let on_edge = ((x == 4 or x == 11) and y >= 2 and y <= 6) or
                ((y == 2 or y == 6) and x >= 4 and x <= 11)
  let inside = x > 4 and x < 11 and y > 2 and y < 6
  if on_edge or inside: result = 0'u8

proc expected_border_tile(tx, ty: int): int =
  if tx >= 6 and tx < 26 and ty >= 5 and ty < 23: 0
  else: 1 + ((tx + ty) mod 15)

# ---------------------------------------------------------------- run

if not fileExists(ROM):
  echo "missing ", ROM, " -- run `python3 tests/roms/sgbtest.py`"
  quit(1)

var m = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
m.post_init()
for _ in 0 ..< 20: m.step_frame()

check(m.sgb != nil, "SGB adapter not attached for an SGB-flagged cart")
if m.sgb == nil: quit(1)
check(m.boot_model == bmSgb, "boot model should be bmSgb (C = 0x14 detection)")

let s = m.sgb

# ---- palettes ----
for p in 0 ..< 4:
  for c in 0 ..< 4:
    check(s.pal[p * 4 + c] == PAL_EXPECT[p][c],
          &"palette {p} colour {c}: got {s.pal[p*4+c]:04X} " &
          &"want {PAL_EXPECT[p][c]:04X}")

# ---- attribute map ----
var attr_bad = 0
for y in 0 ..< 18:
  for x in 0 ..< 20:
    if s.attr[y * 20 + x] != expected_attr(x, y): inc attr_bad
check(attr_bad == 0, &"{attr_bad}/360 attribute cells wrong")

# ---- the colorized Game Boy screen ----
# The ROM draws vertical stripes: screen column c shows shade (c and 3).
var px_bad = 0
var first_bad = ""
for y in 0 ..< 144:
  for x in 0 ..< 160:
    let shade = (x div 8) and 3
    let pal = int(expected_attr(x div 8, y div 8))
    let want = PAL_EXPECT[pal][shade]
    let got = m.ppu.framebuffer[y * 160 + x]
    if got != want:
      inc px_bad
      if first_bad.len == 0:
        first_bad = &"({x},{y}) got {got:04X} want {want:04X} (pal {pal} shade {shade})"
check(px_bad == 0, &"{px_bad}/23040 screen pixels wrong; first {first_bad}")

# ---- the border ----
check(s.border_valid, "border was never rendered (CHR_TRN/PCT_TRN)")
var border_bad = 0
var border_first = ""
for py in 0 ..< 224:
  for px in 0 ..< 256:
    let tile = expected_border_tile(px div 8, py div 8)
    let ci = tile and 15
    let want = if ci == 0: 0'u16 else: BORDER_COLORS[ci] or 0x8000'u16
    let got = s.border[py * 256 + px]
    if got != want:
      inc border_bad
      if border_first.len == 0:
        border_first = &"({px},{py}) got {got:04X} want {want:04X} tile {tile}"
check(border_bad == 0, &"{border_bad}/57344 border pixels wrong; first {border_first}")

# The 20x18 hole the Game Boy window shows through must be fully transparent.
var hole_opaque = 0
for py in 40 ..< 184:
  for px in 48 ..< 208:
    if (s.border[py * 256 + px] and 0x8000'u16) != 0: inc hole_opaque
check(hole_opaque == 0, &"{hole_opaque} opaque pixels inside the GB window")

# ---- the scanline renderer must colorize identically ----
block:
  var sl = new_gb("", ROM, fifo = false, headless = true, run_bios = false)
  sl.post_init()
  for _ in 0 ..< 20: sl.step_frame()
  check(sl.sgb != nil, "scanline renderer: no SGB adapter")
  var diff = 0
  for i in 0 ..< 160 * 144:
    if sl.ppu.framebuffer[i] != m.ppu.framebuffer[i]: inc diff
  check(diff == 0, &"scanline vs FIFO renderer disagree on {diff} SGB pixels")

# ---- a non-SGB cart must be untouched ----
block:
  var plain = new_gb("", "tests/roms/gblinktest.gb", fifo = true,
                     headless = true, run_bios = false)
  plain.post_init()
  check(plain.sgb == nil, "a cart without the SGB header bits got an adapter")
  check(plain.ppu.sgb_attr == nil, "renderer SGB hook set on a non-SGB machine")

# ---- save state round trip ----
block:
  let payload = m.state_payload()
  let pal_before = s.pal
  let attr_before = s.attr
  let chr_before = s.chr
  for _ in 0 ..< 3: m.step_frame()
  # Scribble over the live state, then restore it.
  for i in 0 ..< s.pal.len: s.pal[i] = 0x1234'u16
  for i in 0 ..< s.attr.len: s.attr[i] = 3'u8
  for i in 0 ..< s.chr.len: s.chr[i] = 0xAA'u8
  m.apply_state_payload(payload)
  check(s.pal == pal_before, "SGB palettes did not survive a state round trip")
  check(s.attr == attr_before, "SGB attribute map did not survive a state round trip")
  check(s.chr == chr_before, "SGB border tiles did not survive a state round trip")
  check(GB_PAYLOAD_VERSION == 5'u32, "GB payload revision should be 5 for the SGB section")

# ---- optional PNG dump ----
when defined(sgb_png):
  proc dump(path: string; src: openArray[uint16]; w, h: int; over: bool) =
    var rgb = newSeq[uint8](w * h * 3)
    for i in 0 ..< w * h:
      let v = src[i]
      rgb[i * 3]     = uint8(((v and 0x1F) * 255) div 31)
      rgb[i * 3 + 1] = uint8((((v shr 5) and 0x1F) * 255) div 31)
      rgb[i * 3 + 2] = uint8((((v shr 10) and 0x1F) * 255) div 31)
    discard stbiw.writePNG(path, w, h, 3, rgb)

  let outdir = getEnv("DINGBAT_SGB_PNG")
  if outdir.len > 0:
    createDir(outdir)
    dump(outdir / "screen.png", m.ppu.framebuffer, 160, 144, false)
    dump(outdir / "border.png", s.border, 256, 224, false)
    # The composite the frontend would show: border over the centred screen.
    var comp = newSeq[uint16](256 * 224)
    for i in 0 ..< comp.len: comp[i] = s.pal[0]
    for y in 0 ..< 144:
      for x in 0 ..< 160:
        comp[(y + 40) * 256 + (x + 48)] = m.ppu.framebuffer[y * 160 + x]
    for i in 0 ..< comp.len:
      if (s.border[i] and 0x8000'u16) != 0: comp[i] = s.border[i] and 0x7FFF'u16
    dump(outdir / "composite.png", comp, 256, 224, false)
    echo "wrote PNGs to ", outdir

if failures == 0:
  echo "sgb_test: all checks passed"
else:
  echo &"sgb_test: {failures} failure(s)"
  quit(1)
