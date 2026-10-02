## DS 3D engine, driven directly: command sequences go through
## Gpu3d.write_reg exactly as the ARM9 bus delivers them, a V-blank swaps,
## the frame renders, and each scene is checked at a few dots and written
## as a PNG for eyeballing (over a grey checkerboard where alpha is 0).
##
##   nim c -r -d:release -d:test_harness --path:src tests/nds_3d_test.nim [OUTDIR]

import std/[os, math, strutils]
import zippy
import dingbat/nds/mem/vram
import dingbat/nds/io/irq
import dingbat/nds/gpu3d/gpu3d
import dingbat/nds/nds
import dingbat/nds/sched

# --- PNG (as tools/ndsrun.nim) --------------------------------------------

proc crc32(data: openArray[uint8]): uint32 =
  var table {.global.}: array[256, uint32]
  if table[1] == 0:
    for i in 0'u32 .. 255:
      var c = i
      for _ in 0..7: c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
      table[i] = c
  result = 0xFFFFFFFF'u32
  for b in data: result = table[(result xor b) and 0xFF] xor (result shr 8)
  result = not result

proc be32(s: var seq[uint8]; v: uint32) =
  s.add uint8(v shr 24); s.add uint8(v shr 16); s.add uint8(v shr 8); s.add uint8(v)

proc chunk(png: var seq[uint8]; kind: string; data: seq[uint8]) =
  png.be32(uint32(data.len))
  var body: seq[uint8]
  for c in kind: body.add uint8(c)
  body.add data
  png.add body
  png.be32(crc32(body))

proc write_png(path: string; w, h: int; rgba: seq[uint32]) =
  var raw: seq[uint8]
  for y in 0 ..< h:
    raw.add 0
    for x in 0 ..< w:
      let p = rgba[y * w + x]
      raw.add uint8(p); raw.add uint8(p shr 8); raw.add uint8(p shr 16)
  var png = @[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  var ihdr: seq[uint8]
  ihdr.be32(uint32(w)); ihdr.be32(uint32(h))
  ihdr.add [8'u8, 2, 0, 0, 0]
  png.chunk("IHDR", ihdr)
  let z = compress(cast[seq[uint8]](raw), dataFormat = dfZlib)
  png.chunk("IDAT", cast[seq[uint8]](z))
  png.chunk("IEND", @[])
  writeFile(path, cast[string](png))

# --- driving the engine ------------------------------------------------------

var outdir = "."
var failures = 0

proc check(cond: bool; what: string) =
  if not cond:
    inc failures
    echo "  FAIL: ", what

proc fx(v: float): uint32 = cast[uint32](int32(round(v * 4096)))   # 20.12
proc fx16(v: float): uint32 = uint32(cast[uint16](int16(round(v * 4096))))

proc cmd(g: Gpu3d; id: int; params: varargs[uint32]) =
  ## Through the command port 0x4000400 + id*4 (one dummy write if none).
  let o = uint32(0x400 + id * 4)
  if params.len == 0: g.write_reg(o, 0, 0xFFFF_FFFF'u32)
  for p in params: g.write_reg(o, p, 0xFFFF_FFFF'u32)

proc reg(g: Gpu3d; offset: int; v: uint32; mask = 0xFFFF_FFFF'u32) =
  g.write_reg(uint32(offset), v, mask)

proc rgb15(r, g, b: int): uint32 = uint32(r or (g shl 5) or (b shl 10))

proc vtx(g: Gpu3d; x, y, z: float) =
  g.cmd(0x23, fx16(x) or (fx16(y) shl 16), fx16(z))

proc color(g: Gpu3d; r, gg, b: int) = g.cmd(0x20, rgb15(r, gg, b))
proc texcoord(g: Gpu3d; s, t: float) =
  g.cmd(0x22, uint32(cast[uint16](int16(s * 16))) or (uint32(cast[uint16](int16(t * 16))) shl 16))

proc poly_attr(alpha: int; id = 0; front = true, back = false; extra = 0'u32): uint32 =
  (if back: 0x40'u32 else: 0) or (if front: 0x80'u32 else: 0) or
    (uint32(alpha) shl 16) or (uint32(id) shl 24) or extra

proc load4x4(g: Gpu3d; m: array[16, float]) =
  var p: seq[uint32]
  for v in m: p.add fx(v)
  g.cmd(0x16, p)

proc setup(g: Gpu3d; clear_alpha = 0) =
  g.reg(0x060, 0x0001)                                  # DISP3DCNT: textures on
  g.reg(0x350, rgb15(2, 2, 6) or (uint32(clear_alpha) shl 16) or (63'u32 shl 24))
  g.reg(0x354, 0x7FFF, 0xFFFF)                          # clear depth: far
  g.cmd(0x60, 0xBFFF0000'u32)                           # viewport 0,0 - 255,191
  g.cmd(0x10, 0); g.cmd(0x15)                           # projection = identity
  g.cmd(0x10, 2); g.cmd(0x15)                           # position+vector = identity

proc finish(g: Gpu3d; name: string) =
  g.cmd(0x50, 0)          # SWAP_BUFFERS
  g.on_vblank()
  g.render_frame()
  var img = newSeq[uint32](256 * 192)
  for y in 0 ..< 192:
    for x in 0 ..< 256:
      let p = g.ren.color[y * 256 + x]
      let a = int(alpha5(p))
      let bg = if ((x shr 3) + (y shr 3)) mod 2 == 0: 0x60 else: 0x90
      var c = 0'u32
      for k in 0..2:
        let c6 = int((p shr (8 * k)) and 0x3F)
        let v = (c6 * 4 + (c6 shr 4)) * a div 31 + bg * (31 - a) div 31
        c = c or (uint32(v) shl (8 * k))
      img[y * 256 + x] = c or 0xFF00_0000'u32
  write_png(outdir / name & ".png", 256, 192, img)

proc px(g: Gpu3d; x, y: int): uint32 = g.ren.color[y * 256 + x]
proc rgb_of(p: uint32): (int, int, int) =
  (int(p and 0x3F), int((p shr 8) and 0x3F), int((p shr 16) and 0x3F))
proc fresh(): (Gpu3d, Vram) =
  let v = new_vram()
  (new_gpu3d(v, IrqCtl()), v)

# --- scenes ------------------------------------------------------------------

proc scene_triangle() =
  echo "triangle"
  let (g, _) = fresh()
  g.setup()
  g.cmd(0x29, poly_attr(31))
  g.cmd(0x40, 0)                     # BEGIN_VTXS: triangles
  g.color(31, 0, 0); g.vtx(-0.8, -0.8, 0)
  g.color(0, 31, 0); g.vtx(0.8, -0.8, 0)
  g.color(0, 0, 31); g.vtx(0.0, 0.8, 0)
  g.cmd(0x41)
  g.finish("tri")
  check(alpha5(g.px(5, 5)) == 0, "corner is the transparent rear plane")
  let c = g.px(128, 110)
  check(alpha5(c) == 31, "centre is drawn opaque")
  let (r, gg, b) = rgb_of(c)
  check(r > 10 and gg > 10 and b > 10, "centre mixes all three vertex colours: " & $(r, gg, b))
  let (r2, _, _) = rgb_of(g.px(30, 170))
  check(r2 > 50, "bottom-left is near the red vertex")
  check(g.read_reg(0x604) == 0, "RAM_COUNT empty after the swap")

proc scene_quad_packed() =
  echo "quad (packed GXFIFO)"
  let (g, _) = fresh()
  g.setup()
  # packed: COLOR, BEGIN_VTXS, VTX_10 x2 / VTX_10 x2, END
  template w(v: uint32) = g.reg(0x400, v)
  proc v10(x, y, z: float): uint32 =
    template c(f: float): uint32 = uint32(int(round(f * 64)) and 0x3FF)
    c(x) or (c(y) shl 10) or (c(z) shl 20)
  g.cmd(0x29, poly_attr(31))
  w(0x24244020'u32)                  # COLOR, BEGIN, VTX_10, VTX_10
  w(rgb15(31, 31, 0)); w(1); w(v10(-0.5, -0.5, 0)); w(v10(0.5, -0.5, 0))
  w(0x00002424'u32)                  # VTX_10, VTX_10
  w(v10(0.5, 0.5, 0)); w(v10(-0.5, 0.5, 0))
  check((g.read_reg(0x600) and (1'u32 shl 26)) != 0, "GXSTAT: FIFO empty after packed run")
  check((g.read_reg(0x604) and 0xFFF) == 1, "RAM_COUNT: one polygon")
  check((g.read_reg(0x604) shr 16) == 4, "RAM_COUNT: four vertices")
  g.finish("quad")
  check(rgb_of(g.px(128, 96)) == (63, 63, 0), "quad centre is yellow")
  check(alpha5(g.px(60, 96)) == 0, "left of the quad is clear")
  check(alpha5(g.px(70, 96)) == 31 and alpha5(g.px(185, 96)) == 31, "quad spans x 64..191")
  check(alpha5(g.px(193, 96)) == 0, "right of the quad is clear")

proc scene_depth() =
  echo "depth overlap"
  let (g, _) = fresh()
  g.setup()
  g.cmd(0x29, poly_attr(31, back = true))
  g.cmd(0x40, 0)
  # red: tilted, near (z -0.5) on the left, far (+0.5) on the right
  g.color(31, 0, 0); g.vtx(-0.9, -0.6, -0.5); g.vtx(0.9, -0.6, 0.5); g.vtx(0.9, 0.6, 0.5)
  g.color(31, 0, 0); g.vtx(-0.9, -0.6, -0.5); g.vtx(0.9, 0.6, 0.5); g.vtx(-0.9, 0.6, -0.5)
  # green: flat at z 0, drawn second
  g.color(0, 31, 0); g.vtx(-0.6, -0.9, 0); g.vtx(0.6, -0.9, 0); g.vtx(0.6, 0.9, 0)
  g.color(0, 31, 0); g.vtx(-0.6, -0.9, 0); g.vtx(0.6, 0.9, 0); g.vtx(-0.6, 0.9, 0)
  g.finish("depth")
  check(rgb_of(g.px(70, 96)) == (63, 0, 0), "left: red is in front")
  check(rgb_of(g.px(186, 96)) == (0, 63, 0), "right: green is in front")

proc tex_setup(g: Gpu3d; v: Vram) =
  v.write_cnt(vbA, 0x83)     # bank A: texture slot 0
  v.write_cnt(vbB, 0x8B)     # bank B: texture slot 1 (4x4 index data)
  v.write_cnt(vbE, 0x83)     # bank E: texture palette slots 0-3

proc scene_textured(v: Vram; g: Gpu3d) =
  # direct colour 32x32 checker (8-texel squares) at 0, a hole at its centre
  for t in 0..31:
    for s in 0..31:
      var c = if ((s shr 3) + (t shr 3)) mod 2 == 0: 0x801F'u32 else: 0xFC00'u32
      if s in 12..19 and t in 12..19: c = 0
      v.write16(vrTexture, (t * 32 + s) * 2, uint16(c))
  # 16-colour 16x16 vertical stripes at 0x1000, palette 1 (0x20 bytes)
  for t in 0..15:
    for s in countup(0, 15, 2):
      v.write8(vrTexture, 0x1000 + (t * 16 + s) div 2,
               uint8((s and 15) or (((s + 1) and 15) shl 4)))
  for i in 0..15: v.write16(vrTexPal, 0x20 + i * 2, uint16(rgb15(i * 2, 31 - i * 2, 16)))
  # 4x4 compressed 16x16 at 0x2000: mode 3 blocks interpolating black-white
  for blk in 0..15:
    v.write32(vrTexture, 0x2000 + blk * 4, 0xE4E4E4E4'u32)   # texels 0,1,2,3 per row
    v.write16(vrTexture, 0x20000 + 0x1000 + blk * 2, uint16(0xC000 or 0x10))  # mode 3, pal +0x40
  v.write16(vrTexPal, 0x40 + 0x40, 0)
  v.write16(vrTexPal, 0x40 + 0x42, 0x7FFF)

proc scene_texture() =
  echo "textured quads"
  let (g, v) = fresh()
  g.tex_setup(v)
  scene_textured(v, g)
  g.setup()
  g.cmd(0x29, poly_attr(31))
  g.color(31, 31, 31)
  proc quad(g: Gpu3d; x0, y0, x1, y1: float; size: float) =
    g.cmd(0x40, 1)
    g.texcoord(0, size); g.vtx(x0, y0, 0)
    g.texcoord(size, size); g.vtx(x1, y0, 0)
    g.texcoord(size, 0); g.vtx(x1, y1, 0)
    g.texcoord(0, 0); g.vtx(x0, y1, 0)
  # direct, 32x32, repeated twice
  g.cmd(0x2A, 0'u32 or (3'u32 shl 16) or (2'u32 shl 20) or (2'u32 shl 23) or (7'u32 shl 26))
  g.quad(-0.95, 0.05, -0.05, 0.95, 64)
  # 16-colour, 16x16, palette base 0x20
  g.cmd(0x2A, (0x1000'u32 div 8) or (1'u32 shl 20) or (1'u32 shl 23) or (3'u32 shl 26))
  g.cmd(0x2B, 0x20 div 16)
  g.quad(0.05, 0.05, 0.95, 0.95, 16)
  # 4x4 compressed, 16x16, palette base 0x40
  g.cmd(0x2A, (0x2000'u32 div 8) or (1'u32 shl 20) or (1'u32 shl 23) or (5'u32 shl 26))
  g.cmd(0x2B, 0x40 div 16)
  g.quad(-0.95, -0.95, -0.05, -0.05, 16)
  # untextured, translucent (alpha 16) over the 16-colour quad
  g.reg(0x060, 0x0009)        # textures + alpha blending
  g.cmd(0x2A, 0)
  g.cmd(0x29, poly_attr(16, id = 5))
  g.color(31, 0, 0)
  g.cmd(0x40, 1)
  g.vtx(0.3, -0.95, -0.1); g.vtx(0.95, -0.95, -0.1); g.vtx(0.95, 0.5, -0.1); g.vtx(0.3, 0.5, -0.1)
  g.finish("texture")
  # direct quad covers x 6..121, y 5..90; texel squares are 8 texels =
  # ~7 dots at 2 repeats over 115 dots
  check(rgb_of(g.px(10, 10)) == (63, 0, 0) or rgb_of(g.px(10, 10)) == (0, 0, 63),
        "direct texture texel colour: " & toHex(g.px(10, 10)))
  check(alpha5(g.px(35, 26)) == 0, "direct texture alpha-0 texel shows through")
  let (r1, g1, _) = rgb_of(g.px(140, 30))
  check(g1 > r1, "16-colour stripes: green-heavy on the left")
  let (r2, g2, _) = rgb_of(g.px(185, 30))
  check(r2 > g2 - 30, "16-colour stripes: redder on the right")
  # each block row is texels 0, 1, 2, 3 = black, white, 3/8, 5/8 (mode 3);
  # texel 0 covers about x 6..13, texel 3 about x 28..35
  let (dr, _, _) = rgb_of(g.px(9, 150))
  let (br, _, _) = rgb_of(g.px(31, 150))
  check(dr == 0 and br > 30 and br < 45, "4x4 compressed: mode 3 texel 0 black, texel 3 at 5/8")
  # over the alpha-0 rear plane a translucent dot is written, not blended
  check(g.px(200, 150) == 0x1000003F'u32, "translucent red over the rear plane: " & toHex(g.px(200, 150)))
  let t = g.px(200, 70)
  let (tr, tg, _) = rgb_of(t)
  check(alpha5(t) == 31 and tr > 40 and tg < 40, "translucent red blends over the quad: " & toHex(t))

proc rot_x(a: float): array[9, float] = [1.0, 0, 0, 0, cos(a), sin(a), 0, -sin(a), cos(a)]
proc rot_y(a: float): array[9, float] = [cos(a), 0, -sin(a), 0, 1.0, 0, sin(a), 0, cos(a)]

proc perspective(g: Gpu3d; fovy, aspect, n, f: float) =
  let c = 1.0 / tan(fovy / 2)
  g.cmd(0x10, 0)
  g.load4x4([c / aspect, 0, 0, 0,
             0, c, 0, 0,
             0, 0, (n + f) / (n - f), -1,
             0, 0, 2 * n * f / (n - f), 0])
  g.cmd(0x10, 2)

proc cube(g: Gpu3d; lit: bool) =
  const faces = [([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
                 ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
                 ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [0, 1, 0], [1, 0, 0])]
  const cols = [(31, 0, 0), (0, 31, 0), (0, 0, 31), (31, 31, 0), (31, 0, 31), (0, 31, 31)]
  g.cmd(0x40, 1)
  for i, (n, u, v) in faces:
    if lit:
      template nc(k: int): uint32 = uint32(int(n[k] * 0x1FF) and 0x3FF)
      g.cmd(0x21, nc(0) or (nc(1) shl 10) or (nc(2) shl 20))
    else:
      g.color(cols[i][0], cols[i][1], cols[i][2])
    for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
      var p: array[3, float]
      for k in 0..2: p[k] = 0.5 * float(n[k] + a * u[k] + b * v[k])
      g.vtx(p[0], p[1], p[2])

proc scene_cube() =
  echo "rotated cube"
  let (g, _) = fresh()
  g.setup()
  g.perspective(70.0 * PI / 180, 256 / 192, 0.1, 40)
  g.cmd(0x15)
  g.cmd(0x1C, fx(0), fx(0), fx(-2.2))
  var m: seq[uint32]
  for x in rot_y(0.6): m.add fx(x)
  g.cmd(0x1A, m)
  m.setLen(0)
  for x in rot_x(0.5): m.add fx(x)
  g.cmd(0x1A, m)
  g.cmd(0x29, poly_attr(31, id = 1))
  g.cube(false)
  check((g.read_reg(0x604) and 0xFFF) == 3, "back faces culled: 3 of 6 stored, got " &
        $(g.read_reg(0x604) and 0xFFF))
  g.finish("cube")
  check(alpha5(g.px(128, 96)) == 31, "cube covers the centre")
  check(alpha5(g.px(5, 5)) == 0, "corner is clear")

proc scene_lit_cube() =
  echo "lit cube (2 lights)"
  let (g, _) = fresh()
  g.setup()
  g.perspective(60.0 * PI / 180, 256 / 192, 0.1, 40)
  g.cmd(0x15)
  # light 0 white from the upper left front, light 1 dim blue from the right
  template lv(x, y, z: float; n: int): uint32 =
    (uint32(int(x * 0x1FF) and 0x3FF)) or (uint32(int(y * 0x1FF) and 0x3FF) shl 10) or
      (uint32(int(z * 0x1FF) and 0x3FF) shl 20) or (uint32(n) shl 30)
  g.cmd(0x32, lv(0.577, -0.577, -0.577, 0))
  g.cmd(0x33, rgb15(31, 31, 31))
  g.cmd(0x32, lv(-0.9, 0.0, -0.43, 1))
  g.cmd(0x33, rgb15(0, 0, 20) or (1'u32 shl 30))
  g.cmd(0x30, rgb15(24, 20, 12) or (rgb15(6, 6, 6) shl 16))   # diffuse / ambient
  g.cmd(0x31, rgb15(16, 16, 16) or (rgb15(0, 0, 0) shl 16))   # specular / emission
  g.cmd(0x1C, fx(0), fx(0), fx(-2.5))
  var m: seq[uint32]
  for x in rot_y(-0.7): m.add fx(x)
  g.cmd(0x1A, m)
  m.setLen(0)
  for x in rot_x(0.45): m.add fx(x)
  g.cmd(0x1A, m)
  g.cmd(0x29, poly_attr(31, id = 2) or 3)   # lights 0 and 1
  g.cmd(0x40, 1)                            # latch the light enables
  g.cube(true)
  g.finish("cube_lit")
  check(alpha5(g.px(128, 96)) == 31, "lit cube covers the centre")

proc scene_strips_and_clip() =
  echo "strips + clipping"
  let (g, _) = fresh()
  g.setup()
  g.cmd(0x29, poly_attr(31))
  # a triangle strip zig-zag running off both sides (clipped)
  g.cmd(0x40, 2)
  for i in 0..9:
    let x = -1.4 + float(i) * 0.31
    let y = if i mod 2 == 0: 0.8 else: 0.2   # v0 v1 v2 anticlockwise
    g.color(i * 3, 31 - i * 3, 10)
    g.vtx(x, y, 0)
  # a quad strip
  g.cmd(0x40, 3)
  for i in 0..5:
    g.color(31, i * 6, 0)
    g.vtx(-0.9 + float(i) * 0.35, -0.2, 0)
    g.vtx(-0.9 + float(i) * 0.35, -0.8, 0)
  g.finish("strips")
  check(alpha5(g.px(0, 60)) == 31 or alpha5(g.px(1, 50)) == 31, "clipped strip reaches the left border")
  check(alpha5(g.px(128, 130)) == 31, "quad strip drawn (front faces)")

proc scene_effects() =
  echo "wire-frame, edge marking, fog, A3I5/A5I3, 4/256-colour"
  let (g, v) = fresh()
  g.tex_setup(v)
  # A3I5 8x8 at 0x3000: alpha rises left to right, index = row
  for t in 0..7:
    for s in 0..7: v.write8(vrTexture, 0x3000 + t * 8 + s, uint8((s shl 5) or t))
  # A5I3 8x8 at 0x3100: alpha rises top to bottom, index = column
  for t in 0..7:
    for s in 0..7: v.write8(vrTexture, 0x3100 + t * 8 + s, uint8((t * 4 + 3) shl 3 or (s and 7)))
  # 4-colour 8x8 at 0x3200 (diagonal bands), palette at 0x08 (8-byte steps)
  for t in 0..7:
    var b0, b1 = 0
    for s in 0..3: b0 = b0 or (((s + t) and 3) shl (2 * s))
    for s in 4..7: b1 = b1 or (((s + t) and 3) shl (2 * (s - 4)))
    v.write8(vrTexture, 0x3200 + t * 2, uint8(b0)); v.write8(vrTexture, 0x3201 + t * 2, uint8(b1))
  for i, c in [rgb15(31, 31, 31), rgb15(31, 0, 0), rgb15(0, 31, 0), rgb15(0, 0, 31)]:
    v.write16(vrTexPal, 0x08 + i * 2, uint16(c))
  # 256-colour 8x8 at 0x3300, palette at 0x200: index = t*8+s, grey ramp
  for i in 0..63: v.write8(vrTexture, 0x3300 + i, uint8(i))
  for i in 0..63: v.write16(vrTexPal, 0x200 + i * 2, uint16(rgb15(i shr 1, i shr 1, i shr 1)))
  for i in 0..31: v.write16(vrTexPal, 0x20 + i * 2, uint16(rgb15(31, i, 31 - i)))  # A3I5/A5I3 pal
  g.setup(clear_alpha = 31)
  g.reg(0x060, 0x00A9)        # textures, blending, edge marking, fog
  g.reg(0x330, rgb15(31, 31, 31), 0xFFFF)            # edge colour 0 (IDs 0-7): white
  g.reg(0x358, rgb15(16, 16, 20) or (31'u32 shl 16)) # fog colour
  g.reg(0x35C, 0x3C00, 0xFFFF)                       # fog offset: boundaries 0x4000 up
  for i in 0..7: g.reg(0x360 + i * 4, uint32(min(127, i * 16 * 4)) * 0x01010101'u32)
  proc quad(g: Gpu3d; x0, y0, x1, y1, z: float; size = 8.0) =
    g.cmd(0x40, 1)
    g.texcoord(0, size); g.vtx(x0, y0, z)
    g.texcoord(size, size); g.vtx(x1, y0, z)
    g.texcoord(size, 0); g.vtx(x1, y1, z)
    g.texcoord(0, 0); g.vtx(x0, y1, z)
  g.color(31, 31, 31)
  # top row: wire-frame quad, edge-marked opaque quad (ID 1 over rear ID 63)
  g.cmd(0x2A, 0)
  g.cmd(0x29, poly_attr(0, id = 1))
  g.quad(-0.9, 0.2, -0.45, 0.9, 0)
  g.cmd(0x29, poly_attr(31, id = 2))
  g.color(0, 16, 31)
  g.quad(-0.35, 0.2, 0.1, 0.9, 0)
  # fogged quad, receding: near on the left, far on the right
  g.cmd(0x29, poly_attr(31, id = 9, extra = 0x8000))
  g.color(31, 16, 0)
  g.cmd(0x40, 1)
  g.vtx(0.2, 0.2, 0.0); g.vtx(0.9, 0.2, 0.99); g.vtx(0.9, 0.9, 0.99); g.vtx(0.2, 0.9, 0.0)
  # bottom row: A3I5, A5I3, 4-colour, 256-colour
  g.color(31, 31, 31)
  g.cmd(0x29, poly_attr(31, id = 10))
  g.cmd(0x2B, 0x20 div 16)
  g.cmd(0x2A, (0x3000'u32 div 8) or (1'u32 shl 26))
  g.quad(-0.95, -0.9, -0.55, -0.1, 0)
  g.cmd(0x2A, (0x3100'u32 div 8) or (6'u32 shl 26))
  g.quad(-0.45, -0.9, -0.05, -0.1, 0)
  g.cmd(0x2B, 0x08 div 8)
  g.cmd(0x2A, (0x3200'u32 div 8) or (2'u32 shl 26) or (3'u32 shl 16))
  g.quad(0.05, -0.9, 0.45, -0.1, 0, 16)
  g.cmd(0x2B, 0x200 div 16)
  g.cmd(0x2A, (0x3300'u32 div 8) or (4'u32 shl 26))
  g.quad(0.55, -0.9, 0.95, -0.1, 0)
  g.finish("effects")
  # wire-frame: edges drawn, inside shows the rear plane
  check(rgb_of(g.px(12, 40)) == (63, 63, 63), "wire-frame left edge drawn: " & toHex(g.px(12, 40)))
  check(rgb_of(g.px(40, 40)) == rgb_of(g.px(3, 3)), "wire-frame inside is the rear plane")
  # edge marking: the opaque quad's border takes the edge colour
  check(rgb_of(g.px(83, 40)) == (63, 63, 63), "edge-marked border is white: " & toHex(g.px(83, 40)))
  check(rgb_of(g.px(85, 40)) == (0, 33, 63), "edge-marked interior keeps its colour")
  # fog: more fog to the right
  let (nr, _, _) = rgb_of(g.px(160, 40))
  let (fr, _, _) = rgb_of(g.px(236, 40))
  check(nr > fr, "fog thickens with depth: " & $nr & " vs " & $fr)
  # A3I5: transparent column 0, solid on the right
  check(g.px(7, 150) == g.px(3, 3) and g.px(50, 150) != g.px(3, 3),
        "A3I5: alpha-0 column not drawn, solid column drawn")
  check(rgb_of(g.px(170, 150)) != rgb_of(g.px(175, 150)) or rgb_of(g.px(170, 150)) != rgb_of(g.px(170, 156)),
        "4-colour bands")
  let (d0, _, _) = rgb_of(g.px(198, 106))
  let (d1, _, _) = rgb_of(g.px(246, 172))
  check(d1 > d0, "256-colour ramp brightens: " & $d0 & " -> " & $d1)

proc scene_shadow() =
  echo "shadow volume"
  let (g, _) = fresh()
  g.setup(clear_alpha = 31)
  g.reg(0x060, 0x0008)
  g.cmd(0x50, 1)   # manual translucent order (mask before colour) from here on
  g.on_vblank()
  # floor: an opaque quad, ID 1
  g.cmd(0x29, poly_attr(31, id = 1))
  g.color(20, 28, 20)
  g.cmd(0x40, 1)
  g.vtx(-0.9, -0.9, 0); g.vtx(0.9, -0.9, 0); g.vtx(0.9, 0.9, 0); g.vtx(-0.9, 0.9, 0)
  # a box straddling the floor (z -0.5..0.5) over the centre: mask pass
  # renders its back faces with ID 0, then the colour pass its front, ID 2
  proc box(g: Gpu3d) =
    const faces = [([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
                   ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
                   ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [0, 1, 0], [1, 0, 0])]
    g.cmd(0x40, 1)
    for (n, u, v) in faces:
      for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
        var p: array[3, float]
        for k in 0..2: p[k] = 0.4 * float(n[k] + a * u[k] + b * v[k])
        # identity projection: smaller z is nearer, so mirror z to keep the
        # outward faces' winding (front = facing -z)
        g.vtx(p[0], p[1], -p[2])
  g.color(0, 0, 0)
  g.cmd(0x29, poly_attr(16, id = 0, front = false, back = true) or 0x30)
  g.box()
  g.cmd(0x29, poly_attr(16, id = 2, front = true, back = false) or 0x30)
  g.box()
  g.finish("shadow")
  let (fr, fg, _) = rgb_of(g.px(20, 20))
  let (sr, sg, _) = rgb_of(g.px(128, 96))
  check(sg < fg and sr < fr, "shadow darkens the floor inside the volume: " & toHex(g.px(128, 96)))

proc scene_wbuffer() =
  echo "W-buffer + perspective texture"
  let (g, v) = fresh()
  g.tex_setup(v)
  scene_textured(v, g)
  g.setup()
  g.perspective(60.0 * PI / 180, 256 / 192, 0.1, 40)
  g.cmd(0x15)
  g.cmd(0x29, poly_attr(31, back = true))
  g.color(31, 31, 31)
  g.cmd(0x2A, 0'u32 or (3'u32 shl 16) or (2'u32 shl 20) or (2'u32 shl 23) or (7'u32 shl 26))
  # a floor plane receding into the distance, textured 8x repeated
  g.cmd(0x40, 1)
  g.texcoord(0, 256); g.vtx(-1, -0.5, -0.5)
  g.texcoord(256, 256); g.vtx(1, -0.5, -0.5)
  g.texcoord(256, 0); g.vtx(1, -0.5, -7.9)
  g.texcoord(0, 0); g.vtx(-1, -0.5, -7.9)
  g.cmd(0x50, 2)          # W-buffering for what follows
  g.on_vblank()
  g.cmd(0x40, 1)
  g.texcoord(0, 256); g.vtx(-1, -0.5, -0.5)
  g.texcoord(256, 256); g.vtx(1, -0.5, -0.5)
  g.texcoord(256, 0); g.vtx(1, -0.5, -7.9)
  g.texcoord(0, 0); g.vtx(-1, -0.5, -7.9)
  g.finish("wbuffer")
  check(alpha5(g.px(128, 180)) == 31, "near floor drawn")

proc scene_registers() =
  echo "registers"
  let (g, _) = fresh()
  g.cmd(0x10, 2)
  for i in 0..2: g.cmd(0x11)
  check(((g.read_reg(0x600) shr 8) and 31) == 3, "push x3: stack level 3")
  g.cmd(0x12, 2)
  check(((g.read_reg(0x600) shr 8) and 31) == 1, "pop 2: stack level 1")
  for i in 0..31: g.cmd(0x11)
  check((g.read_reg(0x600) and 0x8000) != 0, "stack overflow flags GXSTAT.15")
  g.reg(0x600, 0x8000)
  check((g.read_reg(0x600) and 0x8000) == 0, "GXSTAT.15 acknowledged")
  # SWAP_BUFFERS stalls the FIFO until V-blank
  g.cmd(0x50, 0)
  g.cmd(0x15)
  g.cmd(0x10, 0)
  let st = g.read_reg(0x600)
  check(((st shr 16) and 0x1FF) == 0 and (st and (1'u32 shl 27)) != 0 and (st and (1'u32 shl 26)) != 0,
        "two commands behind the swap sit in the PIPE: FIFO empty, engine busy: " & toHex(st))
  for i in 0 ..< 10: g.cmd(0x15)
  let st2 = g.read_reg(0x600)
  check(((st2 shr 16) and 0x1FF) == 8, "12 queued: 4 in the PIPE, 8 in the FIFO: " & toHex(st2))
  g.on_vblank()
  check((g.read_reg(0x600) and (1'u32 shl 26)) != 0, "FIFO drained at V-blank")
  # POS_TEST through identity clip matrix
  g.cmd(0x10, 0); g.cmd(0x15); g.cmd(0x10, 1); g.cmd(0x15)
  g.cmd(0x71, fx16(0.5) or (fx16(-0.25) shl 16), fx16(1.0))
  check(g.read_reg(0x620) == 0x800 and g.read_reg(0x624) == fx(-0.25) and
        g.read_reg(0x62C) == 0x1000, "POS_TEST result")
  # box test: a box at the origin is in view, one far off is not
  g.cmd(0x70, 0, fx16(0.5) shl 16, fx16(0.5) or (fx16(0.5) shl 16))
  check((g.read_reg(0x600) and 2) != 0, "BOX_TEST inside")
  g.cmd(0x70, fx16(3.0) or (fx16(3.0) shl 16), fx16(3.0) or (fx16(0.5) shl 16),
        fx16(0.5) or (fx16(0.5) shl 16))
  check((g.read_reg(0x600) and 2) == 0, "BOX_TEST outside")
  # FIFO IRQ: mode 2 (empty) raises IF.21
  let irq = IrqCtl()
  let g2 = new_gpu3d(new_vram(), irq)
  g2.reg(0x600, 2'u32 shl 30, 0xC000_0000'u32)
  check((irq.iff and (1'u32 shl 21)) != 0, "GX FIFO empty IRQ raised")

proc scene_timing() =
  echo "command timing (GBATEK cycles), FIFO stall, swap"
  let g = new_gpu3d(new_vram(), IrqCtl())
  let sc = new_nds_scheduler()
  g.sched = sc
  sc.now = 1000
  # BOX_TEST: 103 bus cycles = 206 master; GXSTAT.0/27 until then
  g.cmd(0x70, 0, fx16(0.5) shl 16, fx16(0.5) or (fx16(0.5) shl 16))
  check((g.read_reg(0x600) and 0x0800_0001'u32) == 0x0800_0001'u32, "BOX_TEST busy at its start")
  sc.now = 1000 + 205
  check((g.read_reg(0x600) and 1) == 1, "BOX_TEST still busy 1 cycle before 103")
  sc.now = 1000 + 206
  check((g.read_reg(0x600) and 0x0800_0001'u32) == 0, "BOX_TEST done after 103 bus cycles")
  # MTX_PUSH sets GXSTAT.14 for 17 cycles; the level changes at once
  g.cmd(0x10, 1)
  g.cmd(0x11)
  check(((g.read_reg(0x600) shr 8) and 31) == 0, "push waits for MTX_MODE's cycle")
  sc.now += 2
  let st = g.read_reg(0x600)
  check((st and 0x4000) != 0 and ((st shr 8) and 31) == 1, "push: stack busy, level 1: " & toHex(st))
  sc.now += 33
  check((g.read_reg(0x600) and 0x4000) != 0, "push busy at 16.5 cycles")
  sc.now += 1
  check((g.read_reg(0x600) and 0x4000) == 0, "push done after 17 cycles")
  # commands queue behind a busy engine: 10 IDENTITY = 190 cycles
  let t0 = sc.now
  for i in 0 ..< 10: g.cmd(0x15)
  sc.now = t0 + 2 * 190 - 1
  check((g.read_reg(0x600) and (1'u32 shl 27)) != 0, "10 x MTX_IDENTITY busy until 190 cycles")
  sc.now = t0 + 2 * 190
  check((g.read_reg(0x600) and (1'u32 shl 27)) == 0, "10 x MTX_IDENTITY done at 190 cycles")
  # NORMAL: 9, 9, 10, 11, 12 cycles for 0..4 lights (docs/oracles.md)
  for (mask, want) in [(0, 9), (1, 9), (3, 10), (7, 11), (15, 12)]:
    g.cmd(0x29, uint32(mask) or 0x1F0080'u32)
    g.cmd(0x40, 0)
    sc.now += 100
    let t1 = sc.now
    g.cmd(0x21, 0)
    sc.now = t1 + 2 * want - 1
    check((g.read_reg(0x600) and (1'u32 shl 27)) != 0, "NORMAL with mask " & $mask & " busy at " & $(want - 1))
    sc.now = t1 + 2 * want
    check((g.read_reg(0x600) and (1'u32 shl 27)) == 0, "NORMAL with mask " & $mask & " done at " & $want)
  g.cmd(0x41)
  # MTX_TRANS in mode 2: 22 + 30
  g.cmd(0x10, 2)
  sc.now += 100
  let t2 = sc.now
  g.cmd(0x1C, 0, 0, 0)
  sc.now = t2 + 2 * 52 - 1
  check((g.read_reg(0x600) and (1'u32 shl 27)) != 0, "MTX_TRANS mode 2 busy at 51")
  sc.now = t2 + 2 * 52
  check((g.read_reg(0x600) and (1'u32 shl 27)) == 0, "MTX_TRANS mode 2 done at 52")
  # SWAP_BUFFERS: busy to V-blank + 392; a full FIFO behind it stalls the writer
  sc.now += 100
  g.next_vblank = sc.now + 50_000
  g.cmd(0x50, 0)
  for i in 0 ..< 260: g.cmd(0x15)
  check(g.stall_until == 0 or g.stall_until <= sc.now, "260 entries fit (FIFO + PIPE)")
  g.cmd(0x15)
  check(g.stall_until == g.next_vblank + 2 * 392, "the 261st waits for V-blank + 392: " & $g.stall_until)
  check(((g.read_reg(0x600) shr 16) and 0x1FF) == 256, "GXSTAT shows a full FIFO")
  sc.now = g.next_vblank
  g.on_vblank()
  check((g.read_reg(0x600) and (1'u32 shl 27)) != 0, "busy for 392 cycles after the swap")
  sc.now = g.next_vblank + 2 * 392
  let lv = (g.read_reg(0x600) shr 16) and 0x1FF
  check(lv == 256, "the first command behind the swap starts at V-blank + 392: " & $lv)
  # 260 entries left: below half (FIFO 127, PIPE 4) after 260 - 131 more
  # starts, 19 cycles apart
  let w = g.wake_at(128)
  check(w == g.next_vblank + 2 * 392 + 2 * 19 * (260 - 131),
        "wake_at(128): " & $(w - g.next_vblank))

proc scene_budget() =
  echo "render line budget (RDLINES_COUNT, DISP3DCNT.12)"
  for (n, want, under) in [(1, 46'u32, false), (16, 42'u32, false), (64, 0'u32, true)]:
    let (g, _) = fresh()
    g.setup()
    g.cmd(0x29, poly_attr(31, back = true))
    for i in 0 ..< n:
      g.cmd(0x40, 1)
      g.vtx(-1, -1, 0); g.vtx(1, -1, 0); g.vtx(1, 1, 0); g.vtx(-1, 1, 0)
    g.finish("budget" & $n)
    check(g.ren.rdlines == want and g.ren.underflow == under,
          $n & " full-screen quads: RDLINES " & $g.ren.rdlines & ", underflow " & $g.ren.underflow)
    # latched at the next V-blank, the underflow flag until acknowledged
    g.on_vblank()
    check(g.read_reg(0x320) == want, "RDLINES_COUNT reads the frame's value")
    check(((g.read_reg(0x060) and 0x1000) != 0) == under, "DISP3DCNT.12 set on underflow")
    g.reg(0x060, 0x1000, 0xFFFF)
    check((g.read_reg(0x060) and 0x1000) == 0, "DISP3DCNT.12 acknowledged by writing 1")

# --- the 3d_* test ROMs through the whole machine ---------------------------
#
# Each ROM's 3D colour buffer after 30 frames, as a CRC32 of its pixels.
# Where docs/oracles.md (NDS core) lists a ROM as matching a reference core
# at 18-bit colour, the hash is that output too, so a change here is a
# regression against the reference, not just against ourselves.
# NDS3D_UPDATE=1 prints the current table instead of checking it.

const ROM_HASHES = [
  ("3d_aa", 0x61F4ACC0'u32),
  ("3d_alpha", 0xF2349E45'u32),
  ("3d_alpha_noblend", 0xDD017278'u32),
  ("3d_blendmodes", 0xE339E209'u32),
  ("3d_clip", 0x5A21F942'u32),
  ("3d_depth", 0x2DFBB5E5'u32),
  ("3d_depth_w", 0x674FA30D'u32),
  ("3d_edge", 0xEAD6701D'u32),
  ("3d_fog", 0x01CED223'u32),
  ("3d_fog_alpha", 0xB462745B'u32),
  ("3d_geom", 0x5DDB7367'u32),
  ("3d_highlight", 0x98B0EEB4'u32),
  ("3d_light", 0xC97F4195'u32),
  ("3d_lines", 0x39602BC0'u32),
  ("3d_probe_aa", 0xECD367B5'u32),
  ("3d_probe_aa2", 0x7FE8EE94'u32),
  ("3d_probe_aa3", 0x7CA905F7'u32),
  ("3d_probe_aa3_edge", 0x0A099C75'u32),
  ("3d_probe_aa3_em", 0xC0E36B35'u32),
  ("3d_probe_aa4", 0xCE98E0F8'u32),
  ("3d_probe_aa_edge", 0xE3239CE2'u32),
  ("3d_probe_clip", 0xA5425543'u32),
  ("3d_probe_clip_persp", 0xED82B05F'u32),
  ("3d_probe_clipq", 0x318D51CE'u32),
  ("3d_probe_degen", 0x2A2E3368'u32),
  ("3d_probe_degen_aa", 0xF0E22BB9'u32),
  ("3d_probe_degen_edge", 0x466996FF'u32),
  ("3d_probe_edge2", 0xA1611174'u32),
  ("3d_probe_lerp", 0xB433E213'u32),
  ("3d_probe_light", 0x758ED3D5'u32),
  ("3d_probe_light_spec", 0x9CE83578'u32),
  ("3d_probe_light_sum", 0x087F8B9D'u32),
  ("3d_probe_light_tab", 0x73BB57EB'u32),
  ("3d_probe_line", 0xCBAC0DCE'u32),
  ("3d_probe_persp", 0x20F374FC'u32),
  ("3d_probe_persp_tex", 0xD826BD30'u32),
  ("3d_probe_persp_w16", 0x99540F9B'u32),
  ("3d_probe_persp_w256", 0x99540F9B'u32),
  ("3d_probe_tri", 0xD166D2B0'u32),
  ("3d_probe_tri_edge", 0x3EF4A7F0'u32),
  ("3d_probe_tri_flat", 0xFC1EEC8A'u32),
  ("3d_probe_tri_flat_edge", 0xFEE01043'u32),
  ("3d_probe_tri_rgb", 0x9BA28853'u32),
  ("3d_probe_tri_s2", 0x3E8D02B5'u32),
  ("3d_probe_tri_s2_edge", 0xC04E4977'u32),
  ("3d_probe_tri_xlu", 0x7CF56E69'u32),
  ("3d_probe_wire", 0xF9C3C7B7'u32),
  ("3d_probe_ztie", 0xBA1273B1'u32),
  ("3d_rearbitmap", 0xE3EA2B86'u32),
  ("3d_shadow", 0x355DB884'u32),
  ("3d_small", 0xB917CCF7'u32),
  ("3d_sort", 0x0BC6BFF2'u32),
  ("3d_sort_manual", 0x6ADC1A16'u32),
  ("3d_status", 0xC265245B'u32),
  ("3d_tex4x4", 0x2B703353'u32),
  ("3d_texcoord", 0x2B123AE8'u32),
  ("3d_texfmt", 0x2550B011'u32),
  ("3d_texwrap", 0x1CBBF735'u32),
  ("3d_vcolor", 0x230F1C99'u32),
]

proc rom_scenes() =
  echo "3d_* ROMs (30 frames)"
  # Test ROMs stay out of the repo (tests/nds/README.md).
  let dir = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms") / "3d"
  let update = getEnv("NDS3D_UPDATE") == "1"
  for (name, want) in ROM_HASHES:
    let path = dir / name & ".nds"
    if not fileExists(path):
      check(false, "missing " & path)
      continue
    let n = load_nds(path)
    for f in 0 ..< 30: n.run_frame()
    var bytes = newSeq[uint8](256 * 192 * 4)
    copyMem(addr bytes[0], addr n.gpu3d.ren.color[0], bytes.len)
    let h = crc32(bytes)
    if update: echo "  (\"", name, "\", 0x", toHex(h), "'u32),"
    else: check(h == want, name & ": 3D buffer CRC " & toHex(h) & ", expected " & toHex(want))

when isMainModule:
  if paramCount() >= 1: outdir = paramStr(1)
  createDir(outdir)
  scene_triangle()
  scene_quad_packed()
  scene_depth()
  scene_texture()
  scene_cube()
  scene_lit_cube()
  scene_strips_and_clip()
  scene_effects()
  scene_shadow()
  scene_wbuffer()
  scene_registers()
  scene_timing()
  scene_budget()
  rom_scenes()
  if failures > 0:
    echo failures, " check(s) failed"
    quit(1)
  echo "all 3D checks passed; PNGs in ", outdir
