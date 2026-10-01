## DS 2D engines, driven register by register: each scene pokes VRAMCNT,
## palettes, OAM and engine registers directly, renders one frame through
## Gpu (both engines, capture, screen routing) and checks pixels whose value
## follows from GBATEK. Every scene also writes a PNG of both screens (top
## above bottom) for eyeballing: $NDS_2D_OUT, default the system temp dir.
##
##   nim c -r -d:release -d:test_harness --path:src tests/nds_2d_test.nim

import std/[os, strutils]
import dingbat/nds/mem/vram
import dingbat/nds/gpu/[gpu, engine2d]
import dingbat/nds/nds   # bgr555_to_rgba
import dingbat/nds/gpu3d/gpu3d
import ../tools/ndsrun

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

proc hex4(v: uint16): string = "0x" & toHex(v, 4)

proc expect_px(g: Gpu; top: bool; x, y: int; want: uint16; name: string) =
  let got = if top: g.top[y * 256 + x] else: g.bottom[y * 256 + x]
  check(got == want, name, "(" & $x & "," & $y & ") got " & hex4(got) & " want " & hex4(want))

# --- setup helpers ------------------------------------------------------------

proc fresh(): Gpu =
  result = new_gpu()
  result.write_powcnt1(0x8203)          # LCDs, A and B on, A on top
  result.engine_a.write_reg(0, 0x10000, 0xFFFF_FFFF'u32)
  result.engine_b.write_reg(0, 0x10000, 0xFFFF_FFFF'u32)

proc reg(e: Engine2D; offset: uint32; v: uint32) =
  e.write_reg(offset and not 3'u32, v shl ((offset and 3) * 8),
              0xFFFF'u32 shl ((offset and 3) * 8))
proc reg32(e: Engine2D; offset: uint32; v: uint32) =
  e.write_reg(offset, v, 0xFFFF_FFFF'u32)

proc bank_w16(g: Gpu; b: VramBank; off: int; v: uint16) =
  ## Straight into a bank (ext palettes are not CPU-visible once mapped).
  let p = g.vram.bank_ptr(b)
  p[off] = uint8(v)
  p[off + 1] = uint8(v shr 8)

proc bank_w8(g: Gpu; b: VramBank; off: int; v: uint8) =
  g.vram.bank_ptr(b)[off] = v

proc frame(g: Gpu) =
  for v in 0 ..< 263:
    g.vcount = v
    g.start_line()
    if v < 192: g.render_line(v)

proc save(g: Gpu; name: string) =
  let dir = getEnv("NDS_2D_OUT", getTempDir())
  var rgba = newSeq[uint32](256 * 384)
  for i in 0 ..< 256 * 192:
    rgba[i] = bgr555_to_rgba(g.top[i])
    rgba[256 * 192 + i] = bgr555_to_rgba(g.bottom[i])
  write_png(dir / ("nds2d_" & name & ".png"), 256, 384, rgba)

proc rgb(r, g, b: int): uint16 = uint16(r or (g shl 5) or (b shl 10))

# A 3x5 font, each glyph drawn 2x wide into rows 1-5 of an 8x8 tile
const FONT_CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const FONT = [   # rows top-down, space-separated
  "... ... ... ... ...", "### #.# #.# #.# ###", ".#. ##. .#. .#. ###", "### ..# ### #.. ###",
  "### ..# ### ..# ###", "#.# #.# ### ..# ..#", "### #.. ### ..# ###", "### #.. ### #.# ###",
  "### ..# ..# ..# ..#", "### #.# ### #.# ###", "### #.# ### ..# ###", "### #.# ### #.# #.#",
  "##. #.# ##. #.# ##.", "### #.. #.. #.. ###", "##. #.# #.# #.# ##.", "### #.. ### #.. ###",
  "### #.. ### #.. #..", "### #.. #.# #.# ###", "#.# #.# ### #.# #.#", "### .#. .#. .#. ###",
  "..# ..# ..# #.# ###", "#.# #.# ##. #.# #.#", "#.. #.. #.. #.. ###", "#.# ### ### #.# #.#",
  "##. #.# #.# #.# #.#", "### #.# #.# #.# ###", "### #.# ### #.. #..", "### #.# #.# ### ..#",
  "### #.# ##. #.# #.#", "### #.. ### ..# ###", "### .#. .#. .#. .#.", "#.# #.# #.# #.# ###",
  "#.# #.# #.# #.# .#.", "#.# #.# ### ### #.#", "#.# #.# .#. #.# #.#", "#.# #.# .#. .#. .#.",
  "### ..# .#. #.. ###"]

proc glyph_row(ch: char; row: int): int =
  ## The 6-pixel row bits (bit 0 = leftmost) of `ch`, rows 1..5 of the tile.
  let gi = FONT_CHARS.find(ch)
  if gi < 0 or row < 1 or row > 5: return 0
  let s = FONT[gi]
  for c in 0..2:
    if s[(row - 1) * 4 + c] == '#': result = result or (3 shl (c * 2 + 1))

proc put_font4(g: Gpu; r: VramRegion; base: int; ink: int) =
  ## 4bpp glyph tiles at base (tile n = FONT_CHARS[n]), colour index `ink`.
  for t, ch in FONT_CHARS:
    for row in 0..7:
      let bits = glyph_row(ch, row)
      var word = 0'u32
      for x in 0..7:
        if (bits and (1 shl x)) != 0: word = word or (uint32(ink) shl (x * 4))
      g.vram.write16(r, base + t * 32 + row * 4, uint16(word))
      g.vram.write16(r, base + t * 32 + row * 4 + 2, uint16(word shr 16))

proc put_font8(g: Gpu; r: VramRegion; base: int; ink: int) =
  for t, ch in FONT_CHARS:
    for row in 0..7:
      let bits = glyph_row(ch, row)
      for x in countup(0, 7, 2):
        let lo = if (bits and (1 shl x)) != 0: ink else: 0
        let hi = if (bits and (1 shl (x + 1))) != 0: ink else: 0
        g.vram.write16(r, base + t * 64 + row * 8 + x, uint16(lo or (hi shl 8)))

proc put_text(g: Gpu; r: VramRegion; map: int; tx, ty: int; s: string; attr = 0'u16) =
  for i, ch in s:
    let t = max(0, FONT_CHARS.find(ch))
    g.vram.write16(r, map + ((ty * 32) + tx + i) * 2, uint16(t) or attr)

# --- scenes -------------------------------------------------------------------

proc scene_text() =
  echo "text BGs: 4bpp/8bpp, DISPCNT char/screen offsets, flips, scroll, engine B"
  let g = fresh()
  let a = g.engine_a
  let b = g.engine_b
  g.vram.write_cnt(vbA, 0x81)                     # A BG 0x06000000
  g.vram.write_cnt(vbC, 0x84)                     # B BG 0x06200000
  # A: DISPCNT char base +64K, screen base +64K; BG0CNT char 1 (16K), screen 2
  a.reg32(0, 0x0901_0000'u32 or 0x0100)
  a.reg(0x08, (1 shl 2) or (2 shl 8))
  g.put_font4(vrABg, 0x10000 + 0x4000, 1)
  let map = 0x10000 + 2 * 0x800
  g.put_text(vrABg, map, 1, 1, "HELLO DS 2D")
  g.put_text(vrABg, map, 1, 3, "PAL2", 0x2000)
  g.put_text(vrABg, map, 1, 5, "HFLIP", 0x0400)
  g.put_text(vrABg, map, 1, 7, "VFLIP", 0x0800)
  g.palette[0] = rgb(0, 0, 8)
  g.palette[1] = rgb(31, 31, 31)
  g.palette[0x21] = rgb(31, 16, 0)
  # B: BG1 8bpp, priority 0, scrolled by (-4, -4)
  b.reg32(0, 0x0001_0200)
  b.reg(0x0A, 0x80 or (1 shl 2) or (16 shl 8))
  b.reg(0x14, 0x1FC)
  b.reg(0x16, 0x1FC)
  g.put_font8(vrBBg, 0x4000, 7)
  g.put_text(vrBBg, 16 * 0x800, 0, 0, "ENGINE B 8BPP")
  g.palette[512] = rgb(0, 8, 0)
  g.palette[512 + 7] = rgb(31, 31, 0)
  g.frame()
  g.save("text")
  # 'H' at tile (1,1): its left stroke is columns 1-2, rows 1-5 of the tile
  g.expect_px(true, 8 + 1, 8 + 1, rgb(31, 31, 31), "A 4bpp glyph pixel")
  g.expect_px(true, 8 + 3, 8 + 1, rgb(0, 0, 8), "A 4bpp transparent -> backdrop")
  g.expect_px(true, 8 + 1, 24 + 1, rgb(31, 16, 0), "palette bank 2")
  # 'F' (tile 2 of "HFLIP") row 5 is "#..": columns 1-2, flipped 5-6
  g.expect_px(true, 16 + 6, 40 + 5, rgb(31, 31, 31), "H flip moves the stroke right")
  g.expect_px(true, 16 + 1, 40 + 5, rgb(0, 0, 8), "H flip clears the left side")
  # 'F' of "VFLIP": row 1 shows tile row 6 (empty)
  g.expect_px(true, 16 + 5, 56 + 1, rgb(0, 0, 8), "V flip: row 1 is the old row 6")
  g.expect_px(true, 16 + 5, 56 + 6, rgb(31, 31, 31), "V flip: row 6 is the old row 1")
  g.expect_px(false, 4 + 1, 4 + 1, rgb(31, 31, 0), "B 8bpp + scroll")

proc scene_extpal() =
  echo "8bpp ext palettes (BG text slot select, OBJ ext palette)"
  let g = fresh()
  let a = g.engine_a
  g.vram.write_cnt(vbA, 0x81)                     # A BG
  g.vram.write_cnt(vbB, 0x82)                     # A OBJ
  g.vram.write_cnt(vbE, 0x84)                     # A BG ext palettes
  g.vram.write_cnt(vbF, 0x85)                     # A OBJ ext palette
  # BG0 8bpp text, ext palette slot 2 (BG0CNT.13); BG1 slot 1
  a.reg32(0, 0xC001_1310'u32)                     # ext BG+OBJ, BG0, BG1, OBJ, 1D
  a.reg(0x08, 0x80 or (1 shl 2) or (2 shl 8) or 0x2000 or 1)
  a.reg(0x0A, 0x80 or (1 shl 2) or (3 shl 8) or 2)
  g.put_font8(vrABg, 0x4000, 5)
  g.put_text(vrABg, 2 * 0x800, 1, 1, "SLOT2 PAL3", 0x3000)
  g.put_text(vrABg, 3 * 0x800, 1, 3, "SLOT1 PAL0")
  g.bank_w16(vbE, 2 * 0x2000 + (3 * 256 + 5) * 2, rgb(0, 31, 31))
  g.bank_w16(vbE, 1 * 0x2000 + (0 * 256 + 5) * 2, rgb(31, 0, 31))
  g.palette[5] = rgb(31, 0, 0)                    # must NOT show
  # one 8bpp 8x8 OBJ, ext palette 4
  for i in 0 ..< 32: g.vram.write16(vrAObj, i * 2, 0x0909)
  g.oam[0] = 100 or 0x2000                        # y=100, 8bpp
  g.oam[1] = 20
  g.oam[2] = 0 or (4 shl 12)
  g.bank_w16(vbF, (4 * 256 + 9) * 2, rgb(31, 31, 0))
  for i in 1 ..< 128: g.oam[i * 4] = 0x200        # rest disabled
  g.frame()
  g.save("extpal")
  g.expect_px(true, 8 + 1, 8 + 1, rgb(0, 31, 31), "BG0 slot 2 palette 3")
  g.expect_px(true, 8 + 1, 24 + 1, rgb(31, 0, 31), "BG1 slot 1 palette 0")
  g.expect_px(true, 23, 103, rgb(31, 31, 0), "OBJ ext palette 4")

proc scene_affine_bitmap() =
  echo "affine BG, extended BGs (16-bit tiled, 256-colour, direct), large bitmap"
  let g = fresh()
  let a = g.engine_a
  let b = g.engine_b
  g.vram.write_cnt(vbA, 0x81)
  g.vram.write_cnt(vbB, 0x89)                     # A BG +128K
  # mode 5: BG2 direct-colour 256x256 at 0x20000 rotated 30 deg;
  # BG3 256-colour 256x256 at 0x00000, priority 1 under BG2
  a.reg32(0, 0x0001_0C05)
  a.reg(0x0C, 0x84 or (8 shl 8) or (1 shl 14))    # BG2: bitmap direct, base 8*16K
  a.reg(0x0E, 0x80 or (0 shl 8) or (1 shl 14) or 1)
  for y in 0 ..< 256:
    for x in 0 ..< 256:
      let c = if (((x shr 4) xor (y shr 4)) and 1) == 0: rgb(x shr 3, y shr 3, 31) or 0x8000
              else: 0'u16                         # alpha 0: see BG3 through
      g.vram.write16(vrABg, 0x20000 + (y * 256 + x) * 2, c)
      g.vram.write16(vrABg, (y * 256 + (x and not 1)), uint16(1 + (x shr 5)) or (uint16(1 + (x shr 5)) shl 8))
  for i in 1..8: g.palette[i] = rgb(i * 3, 31 - i * 3, 8)
  # rotation 30 degrees about the origin, scale 1
  let ca = int16(222)   # cos 30 * 256
  let sa = int16(128)   # sin 30 * 256
  a.reg(0x20, uint32(cast[uint16](ca)))
  a.reg(0x22, uint32(cast[uint16](-sa)))
  a.reg(0x24, uint32(cast[uint16](sa)))
  a.reg(0x26, uint32(cast[uint16](ca)))
  a.reg32(0x28, uint32(64 shl 8))
  a.reg32(0x2C, 0)
  a.reg(0x30, 0x100)
  a.reg(0x36, 0x100)
  # B: mode 2 GBA-style affine BG2 (8-bit map), 128x128, wrap, zoom 2x
  g.vram.write_cnt(vbC, 0x84)
  b.reg32(0, 0x0001_0402)
  b.reg(0x0C, 0x2000 or (1 shl 2) or (0 shl 8))
  for i in 0 ..< 256: g.vram.write16(vrBBg, i * 2, uint16(((i and 1) + 1) or (((i + 1) and 1) + 1) shl 8))
  for t in 1..2:
    for p in 0 ..< 32:
      g.vram.write16(vrBBg, 0x4000 + t * 64 + p * 2, uint16(t * 0x0101 + (if p mod 4 == 0: 0x0202 else: 0)))
  g.palette[512 + 1] = rgb(31, 8, 8)
  g.palette[512 + 2] = rgb(8, 8, 31)
  g.palette[512 + 3] = rgb(31, 31, 31)
  g.palette[512 + 4] = rgb(0, 0, 0)
  b.reg(0x20, 0x80)
  b.reg(0x26, 0x80)
  g.frame()
  g.save("affine_bitmap")
  # pixel (0,0): BG2 samples (64,0): checker cell (4,0) is even -> direct colour
  g.expect_px(true, 0, 0, rgb(64 shr 3, 0, 31), "direct-colour bitmap with ref point")
  # mode 6 large bitmap on its own
  let g2 = fresh()
  let a2 = g2.engine_a
  for bk in [vbA, vbB, vbC, vbD]:
    g2.vram.write_cnt(bk, 0x81'u8 or (uint8(ord(bk)) shl 3))
  a2.reg32(0, 0x0001_0406)
  a2.reg(0x0C, 0)                                  # 512x1024
  for y in 0 ..< 1024:
    for x in countup(0, 511, 2):
      let v = uint16(1 + ((y shr 7) and 7))
      g2.vram.write16(vrABg, y * 512 + x, v or (v shl 8))
  for i in 1..8: g2.palette[i] = rgb(i * 4 - 1, 0, 31 - i * 3)
  a2.reg(0x20, 0x100)
  a2.reg(0x26, 0x500)                              # 5 rows per line: 192 lines span 960
  g2.frame()
  g2.save("large_bitmap")
  g2.expect_px(true, 10, 0, rgb(3, 0, 28), "large bitmap row 0")
  g2.expect_px(true, 10, 191, rgb(7 * 4 + 3, 0, 31 - 8 * 3), "large bitmap row 955 (third 128K bank)")

proc scene_objs() =
  echo "OBJs: 1D/2D tiles, bitmap OBJs, affine double-size, priority, Y wrap"
  let g = fresh()
  let a = g.engine_a
  g.vram.write_cnt(vbB, 0x82)                     # A OBJ
  # 1D tile mapping with 64-byte boundary, bitmap OBJ 1D 128-byte
  a.reg32(0, 0x0011_1050)
  g.palette[0] = rgb(4, 4, 4)
  for i in 1..15:
    g.palette[256 + 16 + i] = rgb(i * 2, 31 - i * 2, 16)
    g.palette[256 + 32 + i] = rgb(31, i * 2, 0)
  # 4bpp 16x16 sprite, tile 2 (= byte 128): each 8x8 tile a solid colour 1..4
  for t in 0..3:
    for p in 0 ..< 16:
      g.vram.write16(vrAObj, 128 + t * 32 + p * 2, uint16((t + 1) * 0x1111))
  for i in 0 ..< 128: g.oam[i * 4] = 0x200
  g.oam[0] = 10 or (0 shl 14)
  g.oam[1] = 10 or (1 shl 14)                     # 16x16
  g.oam[2] = 2 or (1 shl 12) or (1 shl 10)        # tile 2, palette 1, prio 1
  # overlapping sprite, higher index but better priority: wins
  g.oam[4] = 14
  g.oam[5] = 14 or (1 shl 14)
  g.oam[6] = 2 or (2 shl 12) or (0 shl 10)
  # overlapping sprite, higher index, equal priority to OBJ 1: loses
  g.oam[8] = 18
  g.oam[9] = 18 or (1 shl 14)
  g.oam[10] = 3 or (1 shl 12) or (0 shl 10)
  # bitmap OBJ 1D (128-byte steps), 16x8, alpha 15, tile 8 -> byte 1024
  for y in 0 ..< 8:
    for x in 0 ..< 16:
      g.vram.write16(vrAObj, 1024 + (y * 16 + x) * 2,
                     if x < 12: rgb(31, x * 2, y * 4) or 0x8000 else: 0)
  g.oam[12] = 60 or (3 shl 10) or (1 shl 14)      # bitmap, wide
  g.oam[13] = 60
  g.oam[14] = 8 or (15 shl 12)
  # affine double-size 16x16 at (100, 60), rotated 45, using tile 2
  g.oam[16] = 60 or 0x300
  g.oam[17] = 100 or (1 shl 14) or (0 shl 9)
  g.oam[18] = 2 or (1 shl 12)
  g.oam[3] = 181; g.oam[7] = cast[uint16](-181'i16); g.oam[11] = 181; g.oam[15] = 181
  # vertical wrap: y=250, 16 tall -> lines 250..255 and 0..9
  g.oam[20] = 250
  g.oam[21] = 200 or (1 shl 14)
  g.oam[22] = 2 or (1 shl 12)
  g.frame()
  g.save("objs")
  g.expect_px(true, 11, 11, g.palette[256 + 16 + 1], "4bpp 1D sprite tile 0")
  g.expect_px(true, 11 + 8, 11, g.palette[256 + 16 + 2], "4bpp 1D sprite tile 1")
  g.expect_px(true, 15, 15, g.palette[256 + 32 + 1], "priority 0 OBJ 1 over priority 1 OBJ 0")
  # OBJ 2 (prio 0, colour 3) vs OBJ 1 (prio 0, palette 2): OBJ 1 wins
  g.expect_px(true, 19, 19, g.palette[256 + 32 + 1], "equal priority: lower OAM index wins")
  g.expect_px(true, 60 + 2, 60 + 3, rgb(31, 4, 12), "bitmap OBJ pixel")
  g.expect_px(true, 60 + 13, 60 + 3, rgb(4, 4, 4), "bitmap OBJ alpha-0 pixel transparent")
  g.expect_px(true, 207, 2, g.palette[256 + 16 + 3], "Y wrap: bottom sprite shows at top")
  g.expect_px(true, 116, 76, g.palette[256 + 16 + 4], "affine double-size centre")

proc scene_windows_blend() =
  echo "windows, OBJ window, alpha / brightness, semi-transparent OBJ, master brightness"
  let g = fresh()
  let a = g.engine_a
  let b = g.engine_b
  g.vram.write_cnt(vbA, 0x81)
  g.vram.write_cnt(vbB, 0x82)
  # BG0 solid colour 1 everywhere (4bpp tile 1), BG1 solid colour 2, priority 1
  for p in 0 ..< 16:
    g.vram.write16(vrABg, 0x4000 + 32 + p * 2, 0x1111)
    g.vram.write16(vrABg, 0x4000 + 64 + p * 2, 0x2222)
  for i in 0 ..< 1024:
    g.vram.write16(vrABg, 0x0000 + i * 2, 1)
    g.vram.write16(vrABg, 0x0800 + i * 2, 2)
  g.palette[0] = rgb(0, 0, 0)
  g.palette[1] = rgb(20, 0, 0)
  g.palette[2] = rgb(0, 0, 20)
  a.reg(0x08, (1 shl 2) or (0 shl 8))
  a.reg(0x0A, (1 shl 2) or (1 shl 8) or 1)
  # WIN0 = (32..96, 32..96) shows BG1 only; outside shows BG0+BG1+OBJ with
  # effects; OBJ window (a 32x32 OBJ at 160,40) shows BG1 + effects
  a.reg32(0, 0x0001_B310)
  a.reg(0x40, (32 shl 8) or 96)
  a.reg(0x44, (32 shl 8) or 96)
  a.reg(0x48, 0x02)
  a.reg(0x4A, 0x33 or (0x22 shl 8))
  # BLDCNT: alpha, 1st BG0, 2nd BG1; EVA 8, EVB 8
  a.reg(0x50, 0x01 or (1 shl 6) or (0x02 shl 8))
  a.reg(0x52, 8 or (8 shl 8))
  for p in 0 ..< 128: g.vram.write16(vrAObj, p * 2, 0x3333)
  g.palette[256 + 3] = rgb(31, 31, 31)
  for i in 0 ..< 128: g.oam[i * 4] = 0x200
  g.oam[0] = 40 or (2 shl 10)                     # OBJ window
  g.oam[1] = 160 or (2 shl 14)                    # 32x32
  g.oam[2] = 0
  # semi-transparent OBJ at (20,150) 8x8, priority 0, over BG0 (not 2nd target)
  # and at (200,150) blending with BG1 when BG0 is off there: use window? keep
  # simple: a semi OBJ is forced alpha only when the layer below is 2nd target
  g.oam[4] = 150 or (1 shl 10)
  g.oam[5] = 20
  g.oam[6] = 0
  g.frame()
  g.save("windows_blend")
  # outside: BG0 over BG1 alpha 8/8: (20*8 + 0)>>4 = 10 red, (0+20*8)>>4 = 10 blue
  g.expect_px(true, 4, 4, rgb(10, 0, 10), "alpha blend outside windows")
  g.expect_px(true, 50, 50, rgb(0, 0, 20), "WIN0 shows BG1 only, no effect")
  g.expect_px(true, 170, 50, rgb(0, 0, 20), "OBJ window shows BG1")
  # semi OBJ over BG0 (BG0 is not a 2nd target): opaque white
  g.expect_px(true, 22, 152, rgb(31, 31, 31), "semi OBJ over non-2nd target stays opaque")
  # now make BG0 2nd target too: the semi OBJ blends with BG0
  a.reg(0x50, 0x01 or (1 shl 6) or (0x03 shl 8))
  g.frame()
  g.expect_px(true, 22, 152, rgb((31 * 8 + 20 * 8) shr 4, 15, 15), "semi OBJ forced alpha")
  # brightness up 8 on BG0 outside the windows, master brightness down 16 on B
  a.reg(0x50, 0x01 or (2 shl 6))
  a.reg(0x54, 8)
  b.reg32(0, 0x0001_0000)
  g.palette[512] = rgb(31, 31, 31)
  b.reg(0x6C, (2 shl 14) or 8)
  g.frame()
  g.save("brightness")
  g.expect_px(true, 4, 4, rgb(20 + ((31 - 20) * 8) shr 4, 15, 15), "brightness up")
  g.expect_px(false, 4, 4, rgb(16, 16, 16), "master brightness down 8/16")

proc scene_window_wrap() =
  echo "window edges: X1>X2 wraps, X2=0 runs to 256, Y1 in 0..6 is open at line 0"
  let g = fresh()
  let a = g.engine_a
  g.palette[0] = rgb(0, 0, 31)
  a.reg32(0, 0x0001_2000)                          # WIN0 only, no layers
  a.reg(0x40, (200 shl 8) or 40)                   # wraps: 200..255 + 0..39
  a.reg(0x44, (2 shl 8) or 100)                    # Y 2..99 (open since line 258)
  a.reg(0x48, 0x20)                                # inside: effects
  a.reg(0x4A, 0x00)
  a.reg(0x50, 0x20 or (3 shl 6))                   # darken the backdrop
  a.reg(0x54, 16)
  g.frame()                                        # first frame primes the latch
  g.frame()
  g.save("window_wrap")
  g.expect_px(true, 10, 0, 0, "inside (wrapped part), line 0")
  g.expect_px(true, 100, 0, rgb(0, 0, 31), "outside")
  g.expect_px(true, 220, 50, 0, "inside (right part)")
  g.expect_px(true, 10, 120, rgb(0, 0, 31), "below Y2")

proc scene_3d_capture() =
  echo "BG0 as 3D (alpha blend over 2nd target), display capture"
  let g = fresh()
  let a = g.engine_a
  let g3 = new_gpu3d()
  g.gpu3d = g3
  g.vram.write_cnt(vbA, 0x81)
  # BG1 solid blue under the 3D layer
  for p in 0 ..< 16: g.vram.write16(vrABg, 0x4000 + 32 + p * 2, 0x1111)
  for i in 0 ..< 1024: g.vram.write16(vrABg, 0x0800 + i * 2, 1)
  g.palette[1] = rgb(0, 0, 30)
  a.reg(0x0A, (1 shl 2) or (1 shl 8) or 1)
  a.reg32(0, 0x0001_0308)                          # BG0=3D, BG1
  a.reg(0x50, 0x02 shl 8)                          # BG1 2nd target, no effect mode
  # the stub fills transparent; poke the line by hand after each render via
  # a gpu3d line that is constant: red 6-bit 62, alpha 15 on the left half
  # (render_line clears it, so render through a frame with a patched line)
  g.vram.write_cnt(vbD, 0x80)                      # D in LCDC: capture target
  a.reg32(0x64, 0x8000_0000'u32 or (3 shl 16) or (3 shl 20))   # A->D, 256x192
  for v in 0 ..< 263:
    g.vcount = v
    g.start_line()
    if v < 192:
      # emulate a 3D renderer: render_line is the stub; pre-fill after it
      a.line3d = addr g3.line
      g.render_line(v)
  # The stub cleared the line, so 3D is transparent: BG1 shows, capture holds it
  g.expect_px(true, 10, 10, rgb(0, 0, 30), "3D transparent -> BG1")
  let d = g.vram.bank_ptr(vbD)
  let cap = uint16(d[(10 * 256 + 10) * 2]) or (uint16(d[(10 * 256 + 10) * 2 + 1]) shl 8)
  check(cap == (rgb(0, 0, 30) or 0x8000), "capture wrote the composite with alpha", hex4(cap))
  check((a.dispcapcnt and 0x8000_0000'u32) == 0, "capture busy bit cleared at the end")
  # direct check of the 3D compositing seam (no stub in the way)
  for x in 0 ..< 256:
    g3.line[x] = if x < 128: 62'u32 or (15'u32 shl 24) else: 0'u32
  a.line3d = addr g3.line
  a.render_line(5)
  let want = uint16((((62 * 16 + 0 * 2 * 16) shr 5) shr 1) or
                    ((((0 * 16 + 60 * 16) shr 5) shr 1) shl 10))
  check(a.line[10] == want, "3D alpha over 2nd target", hex4(a.line[10]) & " want " & hex4(want))
  check(a.line[200] == rgb(0, 0, 30), "3D transparent half")
  # VRAM display mode 2 shows the captured bank
  a.reg32(0, 0x000E_0000)                          # display mode 2, bank D
  g.frame()
  g.expect_px(true, 10, 10, rgb(0, 0, 30), "VRAM display of the captured bank")

when isMainModule:
  scene_text()
  scene_extpal()
  scene_affine_bitmap()
  scene_objs()
  scene_windows_blend()
  scene_window_wrap()
  scene_3d_capture()
  if failures > 0:
    echo failures, " failure(s)"
    quit(1)
  echo "all passed"
