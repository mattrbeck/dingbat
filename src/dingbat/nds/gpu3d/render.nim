## The 3D rendering engine: rasterises the swapped Polygon/Vertex RAM into a
## 256x192 colour/depth/attribute buffer, a whole frame at a time
## (GBATEK "DS 3D Display Control", "Texture Formats/Coordinates/Blending",
## "Toon, Edge, Fog, Alpha-Blending, Anti-Aliasing", "Rear-Plane").
##
## Pixel format (also the format of Gpu3d.line): bits 0-5 red, 8-13 green,
## 16-21 blue (6-bit, the 3D engine's 18-bit colour), bits 24-28 alpha
## (0..31). Alpha 0 is transparent.
##
## Per polygon: scanlines from the top vertex row down to (not including)
## the bottom vertex row; each row's span runs between the two edges that
## cross it, from round(left) to round(right) exclusive, at least one dot.
## Attributes are perspective-correct: along edges and spans the linear
## factor f becomes p = f*w0 / ((1-f)*w1 + f*w0), with the polygon's w
## values normalised to 16 bits first. Z-buffer depth interpolates
## linearly in screen space, W-buffer depth perspective-correctly.
##
## TODO(3d): anti-aliasing, the exact DS edge rules (the "small polygon"
## right/bottom edge exclusions), the hardware's polygon-per-line limits
## and RDLINES underflow, and rendering per line against mid-frame writes.

import std/algorithm
import ../mem/vram
import geometry

const
  W* = 256
  H* = 192
  NPIX = W * H
  NO_ID = 0xFF'u8
  FLAG_FOG = 1'u8
  FLAG_EDGE = 2'u8
  FLAG_STENCIL = 4'u8

type
  Renderer* = ref object
    color*: array[NPIX, uint32]   ## the frame, pixel format above
    depth: array[NPIX, uint32]    ## 24-bit Z or W
    opaque_id: array[NPIX, uint8] ## polygon ID of the last opaque pixel
    trans_id: array[NPIX, uint8]  ## ID of the last translucent pixel, or NO_ID
    flags: array[NPIX, uint8]
    regs*: array[40, uint32]      ## 0x4000320-0x40003BF as written (word index)
    tex_pages: array[32, ptr UncheckedArray[uint8]]   ## texture slots 0-3
    pal_pages: array[8, ptr UncheckedArray[uint8]]    ## palette slots (6 used)
    zero_page: seq[uint8]
    mixed: seq[seq[uint8]]        ## pages several banks overlap: OR'd copies
    order: seq[int64]             ## sort key << 20 | polygon index

  EdgeSample = object
    x, xn: int64                  ## 16.16, here and on the next row
    lo, hi: int32                 ## the dots the edge covers on this row
    z, w, wn: int64               ## depth (linear), true w, normalised w
    r, g, b: int64                ## 6-bit colour << 8
    s, t: int64                   ## 12.4 texcoord << 4

  PolyCtx = object
    attr, tex, pltt: uint32
    id: uint8
    alpha: int32                  ## 1..31 (wire-frame edges use 31)
    mode: uint32                  ## 0 modulate, 1 decal, 2 toon/highlight, 3 shadow
    textured: bool
    fog: bool
    wbuffer: bool
    highlight: bool               ## DISP3DCNT.1
    blend: bool                   ## DISP3DCNT.3
    aref: int32                   ## dots need alpha > aref (ALPHA_TEST_REF or 0)

proc new_renderer*(): Renderer =
  result = Renderer(zero_page: newSeq[uint8](0x4000))
  result.order = newSeqOfCap[int64](MAX_POLYS)

# ---------------------------------------------------------------------------
# Register file (render side; not double-buffered, read at render time)

template reg16(r: Renderer; offset: int): uint32 =
  (r.regs[(offset - 0x320) shr 2] shr (8 * ((offset - 0x320) and 2))) and 0xFFFF'u32

template reg8(r: Renderer; offset: int): uint32 =
  (r.regs[(offset - 0x320) shr 2] shr (8 * ((offset - 0x320) and 3))) and 0xFF'u32

template expand6(c5: uint32): uint32 = c5 * 2 + (c5 + 31) div 32

proc rgb6(c15: uint32): uint32 {.inline.} =
  ## BGR555 to the pixel format's 6-bit channels (alpha 0)
  expand6(c15 and 31) or (expand6((c15 shr 5) and 31) shl 8) or
    (expand6((c15 shr 10) and 31) shl 16)

template ch(c: uint32; i: int): int32 = int32((c shr (8 * i)) and 0x3F)
template pack(r, g, b, a: int32): uint32 =
  uint32(r) or (uint32(g) shl 8) or (uint32(b) shl 16) or (uint32(a) shl 24)

# ---------------------------------------------------------------------------
# Texture memory: page tables over the VRAM bank mappings, built per frame

proc page_ptr(r: Renderer; vram: Vram; reg: VramRegion; page: int): ptr UncheckedArray[uint8] =
  let mask = vram.page_banks(reg, page)
  if mask == 0: return cast[ptr UncheckedArray[uint8]](addr r.zero_page[0])
  if (mask and (mask - 1)) == 0:
    for b in VramBank:
      if (mask and (1'u16 shl ord(b))) != 0:
        return cast[ptr UncheckedArray[uint8]](
          addr vram.bank_ptr(b)[(page * 0x4000) and (BANK_SIZE[b] - 1)])
  var buf = newSeq[uint8](0x4000)
  for b in VramBank:
    if (mask and (1'u16 shl ord(b))) != 0:
      let src = vram.bank_ptr(b)
      let base = (page * 0x4000) and (BANK_SIZE[b] - 1)
      for i in 0 ..< 0x4000: buf[i] = buf[i] or src[base + i]
  r.mixed.add buf
  cast[ptr UncheckedArray[uint8]](addr r.mixed[^1][0])

proc build_pages(r: Renderer; vram: Vram) =
  r.mixed.setLen(0)
  let zero = cast[ptr UncheckedArray[uint8]](addr r.zero_page[0])
  for p in 0..31: r.tex_pages[p] = r.page_ptr(vram, vrTexture, p)
  for p in 0..7: r.pal_pages[p] = (if p < 6: r.page_ptr(vram, vrTexPal, p) else: zero)

# The per-dot path runs without runtime checks: every index into the
# buffers and page tables is clamped or masked to its range.
{.push checks: off.}

template tex8(r: Renderer; a: int): uint32 = uint32(r.tex_pages[(a shr 14) and 31][a and 0x3FFF])
template tex16(r: Renderer; a: int): uint32 = r.tex8(a) or (r.tex8(a + 1) shl 8)
template pal16(r: Renderer; a: int): uint32 =
  uint32(r.pal_pages[(a shr 14) and 7][a and 0x3FFF]) or
    (uint32(r.pal_pages[((a + 1) shr 14) and 7][(a + 1) and 0x3FFF]) shl 8)

proc wrap_coord(c, size: int; repeat, flip: bool): int {.inline.} =
  if not repeat: return clamp(c, 0, size - 1)
  let m = c and (size - 1)
  if flip and (c and size) != 0: size - 1 - m else: m

proc mix5(c0, c1: uint32; k0, k1, sh: int): uint32 =
  ## per-channel (c0*k0 + c1*k1) >> sh on BGR555 colours
  for i in 0..2:
    let a = int((c0 shr (5 * i)) and 31)
    let b = int((c1 shr (5 * i)) and 31)
    result = result or (uint32((a * k0 + b * k1) shr sh) shl (5 * i))

proc texel(r: Renderer; tex, pltt: uint32; s, t: int64): uint32 =
  ## The texel at (s, t) (12.4) in pixel format; alpha 0 = transparent.
  let sw = 8 shl int((tex shr 20) and 7)
  let th = 8 shl int((tex shr 23) and 7)
  let u = wrap_coord(int(s shr 4), sw, (tex and 0x10000) != 0, (tex and 0x40000) != 0)
  let v = wrap_coord(int(t shr 4), th, (tex and 0x20000) != 0, (tex and 0x80000) != 0)
  let base = int(tex and 0xFFFF) * 8
  let pbase = int(pltt) * 16
  let zero_clear = (tex and 0x2000_0000'u32) != 0
  let i = v * sw + u
  case (tex shr 26) and 7
  of 1:   # A3I5: alpha 0..7 expanded as a*4 + a/2
    let b = r.tex8(base + i)
    let a = (b shr 5) * 4 + (b shr 6)
    rgb6(r.pal16(pbase + int(b and 31) * 2)) or (a shl 24)
  of 2:   # 4 colours, palette base in 8-byte steps
    let idx = (r.tex8(base + i shr 2) shr ((i and 3) * 2)) and 3
    if idx == 0 and zero_clear: 0'u32
    else: rgb6(r.pal16(int(pltt) * 8 + int(idx) * 2)) or (31'u32 shl 24)
  of 3:
    let idx = (r.tex8(base + i shr 1) shr ((i and 1) * 4)) and 15
    if idx == 0 and zero_clear: 0'u32
    else: rgb6(r.pal16(pbase + int(idx) * 2)) or (31'u32 shl 24)
  of 4:
    let idx = r.tex8(base + i)
    if idx == 0 and zero_clear: 0'u32
    else: rgb6(r.pal16(pbase + int(idx) * 2)) or (31'u32 shl 24)
  of 5:   # 4x4 compressed: 32-bit blocks in slot 0/2, index data in slot 1
    let blk = base + ((v shr 2) * (sw shr 2) + (u shr 2)) * 4
    let bits = (r.tex8(blk + (v and 3)) shr ((u and 3) * 2)) and 3
    let slot = (blk shr 17) and 3
    let ia = 0x20000 + ((blk and 0x1FFFF) shr 1) + (if slot == 2: 0x10000 else: 0)
    let info = r.tex16(ia)
    let pa = pbase + int(info and 0x3FFF) * 4
    let c0 = r.pal16(pa)
    let c1 = r.pal16(pa + 2)
    let c =
      case info shr 14
      of 0: (if bits == 3: 0x8000'u32 else: r.pal16(pa + int(bits) * 2))
      of 1:
        case bits
        of 0: c0
        of 1: c1
        of 2: mix5(c0, c1, 1, 1, 1)
        else: 0x8000'u32
      of 2: r.pal16(pa + int(bits) * 2)
      else:
        case bits
        of 0: c0
        of 1: c1
        of 2: mix5(c0, c1, 5, 3, 3)
        else: mix5(c0, c1, 3, 5, 3)
    if c == 0x8000'u32: 0'u32 else: rgb6(c and 0x7FFF) or (31'u32 shl 24)
  of 6:   # A5I3
    let b = r.tex8(base + i)
    rgb6(r.pal16(pbase + int(b and 7) * 2)) or ((b shr 3) shl 24)
  of 7:   # direct colour, bit 15 = alpha
    let c = r.tex16(base + i * 2)
    if (c and 0x8000) == 0: 0'u32 else: rgb6(c) or (31'u32 shl 24)
  else: 0'u32

# ---------------------------------------------------------------------------
# Rear plane

proc clear(r: Renderer; disp3dcnt: uint32) =
  let cc = r.regs[(0x350 - 0x320) shr 2]
  let id = uint8((cc shr 24) and 0x3F)
  if (disp3dcnt and 0x4000) != 0:
    # bitmap: colour in texture slot 2, depth + fog in slot 3, scrolled
    let ofs = r.reg16(0x356)
    for y in 0 ..< H:
      let yy = (y + int((ofs shr 8) and 0xFF)) and 0xFF
      for x in 0 ..< W:
        let xx = (x + int(ofs and 0xFF)) and 0xFF
        let c = r.tex16(0x40000 + (yy * 256 + xx) * 2)
        let d = r.tex16(0x60000 + (yy * 256 + xx) * 2)
        let i = y * W + x
        r.color[i] = rgb6(c) or (if (c and 0x8000) != 0: 31'u32 shl 24 else: 0)
        let d15 = d and 0x7FFF
        r.depth[i] = d15 * 0x200 + ((d15 + 1) div 0x8000) * 0x1FF
        r.opaque_id[i] = id
        r.trans_id[i] = NO_ID
        r.flags[i] = if (d and 0x8000) != 0: FLAG_FOG else: 0
  else:
    let c = rgb6(cc) or (((cc shr 16) and 31) shl 24)
    let d15 = r.reg16(0x354) and 0x7FFF
    let d = d15 * 0x200 + ((d15 + 1) div 0x8000) * 0x1FF
    let f = if (cc and 0x8000) != 0: FLAG_FOG else: 0'u8
    for i in 0 ..< NPIX:
      r.color[i] = c
      r.depth[i] = d
      r.opaque_id[i] = id
      r.trans_id[i] = NO_ID
      r.flags[i] = f

# ---------------------------------------------------------------------------
# Rasterisation

proc persp(f, w0, w1: int64): int64 {.inline.} =
  ## Linear factor f (0..1 as 0..0x10000) from end 0 to end 1, made
  ## perspective-correct with the ends' normalised w.
  if w0 == w1: return f
  let den = (0x10000 - f) * w1 + f * w0
  if den <= 0: f else: ((f * w0) shl 16) div den

proc sample_edge(a, b: Vertex; wa, wb: int64; y: int): EdgeSample =
  ## Edge a (top) -> b (bottom) at row y.
  let dy = int64(b.sy - a.sy)
  template x_at(yy: int): int64 =
    (int64(a.sx) shl 16) + (int64(b.sx - a.sx) shl 16) * (int64(yy) - a.sy) div dy
  let f = ((int64(y) - a.sy) shl 16) div dy
  let p = persp(f, wa, wb)
  result.x = x_at(y)
  result.xn = x_at(min(y + 1, int(b.sy)))
  # the dots the edge passes through on this row, owned as a left edge
  # (right of the boundary); the right edge's are shifted one left later
  let xa = (min(result.x, result.xn) + 0x8000) shr 16
  let xb = (max(result.x, result.xn) + 0x8000) shr 16
  result.lo = int32(xa)
  result.hi = int32(max(xa, xb - 1))
  result.z = int64(a.z24) + (int64(b.z24) - a.z24) * f div 0x10000
  result.w = int64(a.w) + (int64(b.w) - a.w) * p div 0x10000
  result.wn = wa + (wb - wa) * p div 0x10000
  result.r = (int64(a.r) shl 8) + ((int64(b.r) - a.r) shl 8) * p div 0x10000
  result.g = (int64(a.g) shl 8) + ((int64(b.g) - a.g) shl 8) * p div 0x10000
  result.b = (int64(a.b) shl 8) + ((int64(b.b) - a.b) shl 8) * p div 0x10000
  result.s = (int64(a.s) shl 4) + ((int64(b.s) - a.s) shl 4) * p div 0x10000
  result.t = (int64(a.t) shl 4) + ((int64(b.t) - a.t) shl 4) * p div 0x10000

proc vertex_sample(v: Vertex; wn: int64): EdgeSample =
  EdgeSample(x: int64(v.sx) shl 16, xn: int64(v.sx) shl 16, lo: v.sx, hi: v.sx, z: v.z24, w: v.w, wn: wn,
             r: int64(v.r) shl 8, g: int64(v.g) shl 8, b: int64(v.b) shl 8,
             s: int64(v.s) shl 4, t: int64(v.t) shl 4)

proc blend_texel(r: Renderer; c: PolyCtx; vr, vg, vb: int32; tx: uint32): uint32 {.inline.} =
  ## Vertex colour x texel by polygon mode (GBATEK "DS 3D Texture Blending");
  ## 6-bit colour, 5-bit alpha.
  let av = c.alpha
  var tr, tg, tb, ta: int32
  if c.textured:
    tr = ch(tx, 0); tg = ch(tx, 1); tb = ch(tx, 2); ta = int32(tx shr 24)
  else:
    tr = 63; tg = 63; tb = 63; ta = 31
  case c.mode
  of 1:
    # decal: the texel alpha mixes texel over vertex colour
    if not c.textured or ta == 0: return pack(vr, vg, vb, av)
    if ta == 31: return pack(tr, tg, tb, av)
    let a6 = ta * 2 + 1
    pack((tr * a6 + vr * (63 - a6)) shr 6, (tg * a6 + vg * (63 - a6)) shr 6,
         (tb * a6 + vb * (63 - a6)) shr 6, av)
  of 2:
    # toon/highlight: the vertex red picks the shading colour
    let sc = rgb6(r.reg16(0x380 + int(vr shr 1) * 2))
    let sr = ch(sc, 0)
    let sg = ch(sc, 1)
    let sb = ch(sc, 2)
    var rr = ((tr + 1) * (sr + 1) - 1) shr 6
    var gg = ((tg + 1) * (sg + 1) - 1) shr 6
    var bb = ((tb + 1) * (sb + 1) - 1) shr 6
    if c.highlight:
      rr = min(63, rr + sr); gg = min(63, gg + sg); bb = min(63, bb + sb)
    pack(rr, gg, bb, ((ta + 1) * (av + 1) - 1) shr 5)
  else:
    pack(((tr + 1) * (vr + 1) - 1) shr 6, ((tg + 1) * (vg + 1) - 1) shr 6,
         ((tb + 1) * (vb + 1) - 1) shr 6, ((ta + 1) * (av + 1) - 1) shr 5)

proc plot(r: Renderer; c: PolyCtx; x, y: int; L, R: EdgeSample; inv: int64; edge: bool) {.inline.} =
  ## One dot; `inv` = 2^32 / span width (16.16), 0 for a zero-width span.
  let i = y * W + x
  # position along the span, at the dot's centre
  let f = clamp((((int64(x) shl 16) + 0x8000 - L.x) * inv) shr 16, 0'i64, 0x10000'i64)
  let p = persp(f, L.wn, R.wn)
  let dval = if c.wbuffer: uint32(clamp(L.w + (R.w - L.w) * p div 0x10000, 0'i64, 0xFF_FFFF'i64))
             else: uint32(clamp(L.z + (R.z - L.z) * f div 0x10000, 0'i64, 0xFF_FFFF'i64))
  let old = r.depth[i]
  let pass = if (c.attr and 0x4000) != 0: abs(int64(dval) - int64(old)) <= 0x200
             else: dval < old
  if c.mode == 3 and c.id == 0:
    # shadow mask: flags the stencil where the volume's back side is in front
    if pass: r.flags[i] = r.flags[i] or FLAG_STENCIL
    return
  if not pass: return
  if c.mode == 3:
    # shadow: not where the mask was set (which it clears), nor on its own ID
    if (r.flags[i] and FLAG_STENCIL) != 0:
      r.flags[i] = r.flags[i] and not FLAG_STENCIL
      return
    if r.opaque_id[i] == c.id: return
  let vr = int32((L.r + (R.r - L.r) * p div 0x10000) shr 8)
  let vg = int32((L.g + (R.g - L.g) * p div 0x10000) shr 8)
  let vb = int32((L.b + (R.b - L.b) * p div 0x10000) shr 8)
  var tx = 0'u32
  if c.textured:
    let s = L.s + (R.s - L.s) * p div 0x10000
    let t = L.t + (R.t - L.t) * p div 0x10000
    tx = r.texel(c.tex, c.pltt, s shr 4, t shr 4)
  let px = r.blend_texel(c, clamp(vr, 0, 63), clamp(vg, 0, 63), clamp(vb, 0, 63), tx)
  let a = int32(px shr 24)
  if a <= c.aref: return
  if a == 31 and c.mode != 3:
    r.color[i] = px
    r.depth[i] = dval
    r.opaque_id[i] = c.id
    r.trans_id[i] = NO_ID
    r.flags[i] = (if c.fog: FLAG_FOG else: 0'u8) or (if edge: FLAG_EDGE else: 0'u8)
  else:
    # a translucent polygon does not blend twice over its own ID
    if r.trans_id[i] == c.id: return
    let o = r.color[i]
    let oa = int32(o shr 24)
    if c.blend and oa != 0:
      template mixc(k: int): int32 = (ch(px, k) * (a + 1) + ch(o, k) * (31 - a)) shr 5
      r.color[i] = pack(mixc(0), mixc(1), mixc(2), max(a, oa))
    else:
      r.color[i] = px
    if (c.attr and 0x800) != 0: r.depth[i] = dval
    r.trans_id[i] = c.id
    if not c.fog: r.flags[i] = r.flags[i] and not FLAG_FOG

proc draw_polygon(r: Renderer; poly: Polygon; verts: openArray[Vertex]; disp3dcnt: uint32;
                  wbuffer: bool) =
  let n = int(poly.count)
  if n < 1: return
  var v: array[16, Vertex]
  var wn: array[16, int64]
  var wmax = 1'i64
  for i in 0 ..< n:
    v[i] = verts[int(poly.first) + i]
    wmax = max(wmax, int64(v[i].w))
  # normalise w to 16 bits for the perspective weights
  var sh = 0
  while (wmax shr sh) > 0xFFFF: inc sh
  for i in 0 ..< n: wn[i] = max(1'i64, int64(v[i].w) shr sh)
  let fmt = (poly.tex shr 26) and 7
  let alpha = int32((poly.attr shr 16) and 31)
  let wire = alpha == 0
  var c = PolyCtx(attr: poly.attr, tex: poly.tex, pltt: poly.pltt,
                  id: uint8((poly.attr shr 24) and 0x3F),
                  alpha: (if wire: 31'i32 else: alpha), mode: (poly.attr shr 4) and 3,
                  textured: (disp3dcnt and 1) != 0 and fmt != 0,
                  fog: (poly.attr and 0x8000) != 0, wbuffer: wbuffer,
                  highlight: (disp3dcnt and 2) != 0, blend: (disp3dcnt and 8) != 0,
                  # alpha test: drawn only if alpha > ALPHA_TEST_REF (> 0 when off)
                  aref: (if (disp3dcnt and 4) != 0: int32(r.reg8(0x340) and 31) else: 0'i32))
  var area = 0'i64
  for i in 0 ..< n:
    let a = v[i]
    let b = v[(i + 1) mod n]
    area += int64(a.sx) * b.sy - int64(b.sx) * a.sy
  let line = area == 0
  # GBATEK "Polygon Size": opaque polygons drop their right and bottom
  # edges; wire-frames, translucent ones while blending is on, and every
  # polygon while edge marking or anti-aliasing is on keep them (vertical
  # right edges excepted)
  let full = wire or (disp3dcnt and 0x30) != 0 or poly.translucent and c.blend
  let ytop = int(poly.ymin)
  let ybot = if poly.ymax == poly.ymin or full: int(poly.ymax) + 1 else: int(poly.ymax)
  for y in max(0, ytop) ..< min(H, ybot):
    var L, R: EdgeSample
    var found = 0
    for i in 0 ..< n:
      var a = v[i]
      var b = v[(i + 1) mod n]
      var wa = wn[i]
      var wb = wn[(i + 1) mod n]
      if a.sy == b.sy: continue
      if a.sy > b.sy: (swap(a, b); swap(wa, wb))
      if y < a.sy or y >= b.sy: continue
      let e = sample_edge(a, b, wa, wb, y)
      # leftmost / rightmost crossing; ties (a shared top vertex) by slope
      if found == 0: (L = e; R = e)
      elif e.x < L.x or e.x == L.x and e.xn < L.xn: L = e
      elif e.x > R.x or e.x == R.x and e.xn >= R.xn: R = e
      inc found
    if found == 0:
      # a flat polygon, or a full-size one's bottom row: the row runs
      # between the outermost vertices on it
      var li, ri = -1
      for i in 0 ..< n:
        if v[i].sy != y: continue
        if li < 0 or v[i].sx < v[li].sx: li = i
        if ri < 0 or v[i].sx > v[ri].sx: ri = i
      if li < 0: continue
      L = vertex_sample(v[li], wn[li])
      R = vertex_sample(v[ri], wn[ri])
    elif found >= 2 and not line and not full:
      # the right edge owns the dots left of its boundary
      dec R.lo
      dec R.hi
    let xs = int((L.x + 0x8000) shr 16)
    var xe = int((R.x + 0x8000) shr 16)
    if full and (found == 0 or R.xn != R.x): xe = max(xe, int(R.hi) + 1)
    if xe <= xs: xe = xs + 1           # at least one dot wide
    let rim = y == ytop or y == ybot - 1
    let inv = if R.x > L.x: (1'i64 shl 32) div (R.x - L.x) else: 0'i64
    if line and found > 0 or wire and not rim:
      # only the edges: line segments, and wire-frames between their rims
      for x in max(0, int(L.lo)) .. min(W - 1, int(L.hi)):
        r.plot(c, x, y, L, R, inv, true)
      for x in max(0, int(R.lo)) .. min(W - 1, int(R.hi)):
        if x < int(L.lo) or x > int(L.hi): r.plot(c, x, y, L, R, inv, true)
    else:
      for x in max(0, xs) ..< min(W, xe):
        let edge = rim or (x >= int(L.lo) and x <= int(L.hi)) or
                   (x >= int(R.lo) and x <= int(R.hi))
        r.plot(c, x, y, L, R, inv, edge)

{.pop.}

# ---------------------------------------------------------------------------
# Post passes

proc edge_mark(r: Renderer) =
  ## Edge-flagged opaque dots take EDGE_COLOR[id/8] when a 4-neighbour has a
  ## different polygon ID and is further away (screen borders compare
  ## against the rear plane's ID and depth).
  let cc = r.regs[(0x350 - 0x320) shr 2]
  let clear_id = uint8((cc shr 24) and 0x3F)
  let d15 = r.reg16(0x354) and 0x7FFF
  let clear_depth = d15 * 0x200 + ((d15 + 1) div 0x8000) * 0x1FF
  var marked: seq[int32]
  for y in 0 ..< H:
    for x in 0 ..< W:
      let i = y * W + x
      if (r.flags[i] and FLAG_EDGE) == 0: continue
      let id = r.opaque_id[i]
      let d = r.depth[i]
      template differs(xx, yy: int): bool =
        if xx < 0 or xx >= W or yy < 0 or yy >= H: id != clear_id and d < clear_depth
        else: id != r.opaque_id[yy * W + xx] and d < r.depth[yy * W + xx]
      if differs(x - 1, y) or differs(x + 1, y) or differs(x, y - 1) or differs(x, y + 1):
        marked.add int32(i)
  for i in marked:
    let ec = rgb6(r.reg16(0x330 + int(r.opaque_id[i] shr 3) * 2))
    r.color[i] = ec or (r.color[i] and 0xFF00_0000'u32)

proc fog(r: Renderer; disp3dcnt: uint32) =
  let fc = r.regs[(0x358 - 0x320) shr 2]
  let fr = int32(expand6(fc and 31))
  let fg = int32(expand6((fc shr 5) and 31))
  let fb = int32(expand6((fc shr 10) and 31))
  let fa = int32((fc shr 16) and 31)
  let alpha_only = (disp3dcnt and 0x40) != 0
  let shift = int((disp3dcnt shr 8) and 15)
  let step = 0x400 shr shift
  let offset = int(r.reg16(0x35C) and 0x7FFF)
  var table: array[32, int32]
  for k in 0..31: table[k] = int32(r.reg8(0x360 + k) and 0x7F)
  for i in 0 ..< NPIX:
    if (r.flags[i] and FLAG_FOG) == 0: continue
    # FogDepthBoundary[n] = FOG_OFFSET + FOG_STEP*(n+1), on 15-bit depth
    let d = int(r.depth[i] shr 9)
    var dens: int32
    if step == 0: dens = (if d < offset + step: table[0] else: table[31])
    else:
      let k = (d - offset) div step - 1
      if k < 0: dens = table[0]
      elif k >= 31: dens = table[31]
      else:
        let frac = (d - offset) - (k + 1) * step
        dens = int32((int(table[k]) * (step - frac) + int(table[k + 1]) * frac) div step)
    if dens >= 127: dens = 128
    let o = r.color[i]
    let oa = int32(o shr 24)
    let na = (fa * dens + oa * (128 - dens)) shr 7
    if alpha_only:
      r.color[i] = (o and 0x00FF_FFFF'u32) or (uint32(na) shl 24)
    else:
      template mixc(k: int; fcc: int32): int32 = (fcc * dens + ch(o, k) * (128 - dens)) shr 7
      r.color[i] = pack(mixc(0, fr), mixc(1, fg), mixc(2, fb), na)

proc render_frame*(r: Renderer; vram: Vram; polys: openArray[Polygon];
                   verts: openArray[Vertex]; disp3dcnt: uint32; swap_param: uint32) =
  ## Draw the swapped buffer: opaque polygons first, then translucent ones
  ## (Y-sorted unless SWAP_BUFFERS bit 0 asked for manual order).
  r.build_pages(vram)
  r.clear(disp3dcnt)
  let wbuffer = (swap_param and 2) != 0
  # key: bottom row, then top row, then submission order (a stable sort)
  template key(i: int): int64 =
    ((int64(polys[i].ymax) + 0x400) shl 40) or ((int64(polys[i].ymin) + 0x400) shl 20) or int64(i)
  r.order.setLen(0)
  for i in 0 ..< polys.len:
    if not polys[i].translucent: r.order.add key(i)
  let n_opaque = r.order.len
  let manual = (swap_param and 1) != 0
  for i in 0 ..< polys.len:
    if polys[i].translucent: r.order.add (if manual: int64(i) else: key(i))
  r.order.toOpenArray(0, n_opaque - 1).sort()
  if not manual: r.order.toOpenArray(n_opaque, r.order.len - 1).sort()
  for k in r.order:
    r.draw_polygon(polys[int(k and 0xFFFFF)], verts, disp3dcnt, wbuffer)
  if (disp3dcnt and 0x20) != 0: r.edge_mark()
  if (disp3dcnt and 0x80) != 0: r.fog(disp3dcnt)
