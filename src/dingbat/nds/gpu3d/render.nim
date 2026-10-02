## The 3D rendering engine: rasterises the swapped Polygon/Vertex RAM into a
## 256x192 colour/depth/attribute buffer, a whole frame at a time
## (GBATEK "DS 3D Display Control", "Texture Formats/Coordinates/Blending",
## "Toon, Edge, Fog, Alpha-Blending, Anti-Aliasing", "Rear-Plane").
##
## Pixel format (also the format of Gpu3d.line): bits 0-5 red, 8-13 green,
## 16-21 blue (6-bit, the 3D engine's 18-bit colour), bits 24-28 alpha
## (0..31). Alpha 0 is transparent.
##
## Per polygon: rows from the top vertex row down to (not including) the
## bottom one; on each row the two edges crossing it cover runs of dots and
## the span runs between them (edge rules below, at Edge). Attributes are
## interpolated along the edges, then across the span: linearly where the
## two ends' w are equal, else perspective-correctly with 9-bit (edge) and
## 8-bit (span) factors. Colours carry 9 bits through interpolation.
## Z-buffer depth interpolates linearly in screen space: exactly along
## edges, by an 18-bit reciprocal of the span's length across it
## (3d_probe_zinterp*); W-buffer depth as the other attributes (Assumed).
##
## Line budget (GBATEK "DS 3D Overview", RDLINES_COUNT): the hardware
## renders line by line into a 48-line cache from line 214 on, and the
## display takes a line from it at each line start; a line not ready by
## then is an underflow (DISP3DCNT.12). Each frame's line costs are
## estimated while drawing (`line_cost`: RENDER_POLY_CYCLES per polygon on
## the line plus its span at RENDER_DOTS_PER_CYCLE; both Assumed, GBATEK
## gives no figures and the reference runs do not model it:
## 3d_timing_rdlines) and `budget` replays them against the display to
## give the frame's RDLINES_COUNT (the fewest lines ever buffered, minus 2)
## and whether it underflowed. The picture itself is unaffected.
##
## TODO(3d): rendering per line against mid-frame writes.

import std/[algorithm, math]
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
  # line budget (Assumed; docs/nds/3d-timing.md)
  RENDER_POLY_CYCLES {.intdefine.} = 8      ## per polygon crossing a line
  RENDER_DOTS_PER_CYCLE {.intdefine.} = 2   ## span dots filled per bus cycle
  LINE_BUS_CYCLES = 2130                    ## a display line: 355 dots x 6
  CACHE_LINES = 48
  RENDER_LEAD = 49                          ## line 214 to line 0 of the next frame

type
  Renderer* = ref object
    color*: array[NPIX, uint32]   ## the frame, pixel format above
    depth: array[NPIX, uint32]    ## 24-bit Z or W
    opaque_id: array[NPIX, uint8] ## polygon ID of the last opaque pixel
    trans_id: array[NPIX, uint8]  ## ID of the last translucent pixel, or NO_ID
    flags: array[NPIX, uint8]
    below: array[NPIX, uint32]    ## the nearest opaque colour behind the top one (anti-aliasing)
    below_depth: array[NPIX, uint32]
    aacov: array[NPIX, uint8]     ## anti-aliasing coverage of the opaque dot (31 = whole)
    regs*: array[40, uint32]      ## 0x4000320-0x40003BF as written (word index)
    tex_pages: array[32, ptr UncheckedArray[uint8]]   ## texture slots 0-3
    pal_pages: array[8, ptr UncheckedArray[uint8]]    ## palette slots (6 used)
    zero_page: seq[uint8]
    mixed: seq[seq[uint8]]        ## pages several banks overlap: OR'd copies
    order: seq[int64]             ## sort key << 20 | polygon index
    line_cost: array[H, int32]    ## estimated bus cycles to render each line
    rdlines*: uint32              ## RDLINES_COUNT this frame would leave
    underflow*: bool              ## a line was not ready when displayed

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
    aa: bool                      ## DISP3DCNT.4: keep the layer behind edge dots
    wire: bool                    ## alpha 0: wire-frame

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

proc texel(r: Renderer; tex, pltt: uint32; s, t: int64): uint32 {.inline.} =
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
  of 7:   # direct colour, bit 15 = alpha (a transparent texel keeps its
          # colour: wire-frames show it, 3d_lines on the reference cores)
    let c = r.tex16(base + i * 2)
    rgb6(c) or (if (c and 0x8000) == 0: 0'u32 else: 31'u32 shl 24)
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
        r.aacov[i] = 31
        r.below[i] = r.color[i]
        r.below_depth[i] = r.depth[i]
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
      r.aacov[i] = 31
      r.below[i] = c
      r.below_depth[i] = d
      r.flags[i] = f

# ---------------------------------------------------------------------------
# Rasterisation

when defined(r3dprof):
  import std/[monotimes, times]
  var prof_ns, prof_frames, prof_polys, prof_dots, prof_pass, prof_setup, prof_draw: int64

# Edges. Screen positions are whole dots. An edge runs from its top vertex
# to its bottom one and covers rows y0 ..< y1; its x on row y is
#   X(y) = x0 << 18 + slope * (y - y0)  (minus 1 when x decreases),
# slope = dx * floor(2^18 / dy), or exactly +-1.0 when |dx| == dy.
# On each row an edge covers a run of dots: x-major edges (|dx| > dy) the
# dots whose centres lie between X(y) and X(y) + the slope with its low 9
# bits cleared (rounded, half up: the hardware line captures), other edges
# the one dot holding X(y); a vertical right edge covers the dot left of
# it. These are the rules the 3d_probe_tri* ROMs pin (run against the
# reference cores, docs/oracles.md).

const
  XSHIFT = 18
  XHALF = 1'i64 shl (XSHIFT - 1)

type
  Edge = object
    x0, y0, x1, y1: int32
    a, b: int32                 ## vertex indices (top, bottom)
    slope: int64
    xmaj: bool                  ## |dx| > dy: runs of several dots
    fwd: bool                   ## runs from vertex i down to vertex i + 1
    amaj: bool                  ## |dx| >= dy: endpoint attributes as x-major
    dec, vert: bool

  Run = object
    s, e: int32                 ## dots s ..< e
    xmaj, inc, vert: bool

  VAttr = object                ## per-vertex attributes, interpolation units
    c: array[3, int64]          ## 9-bit colour (6-bit * 8 + 7, 0 stays 0)
    s, t: int64                 ## texcoord, 12.4
    z: int64                    ## Z-buffer depth (24 bits)
    w: int64                    ## clip w

  EndAttr = object              ## attributes at one end of a row's span
    x: int32
    c: array[3, int64]
    s, t, z, w: int64

proc make_edge(sx, sy: openArray[int32]; a, b: int): Edge =
  var a = a
  var b = b
  let fwd = sy[a] < sy[b]
  if not fwd: swap(a, b)
  result = Edge(x0: sx[a], y0: sy[a], x1: sx[b], y1: sy[b], a: int32(a), b: int32(b), fwd: fwd)
  let dx = int64(sx[b] - sx[a])
  let dy = int64(sy[b] - sy[a])
  result.slope = if abs(dx) == dy: (if dx > 0: 1'i64 shl XSHIFT else: -(1'i64 shl XSHIFT))
                 else: dx * ((1'i64 shl XSHIFT) div dy)
  result.xmaj = abs(dx) > dy
  result.amaj = abs(dx) >= dy
  result.dec = dx < 0
  result.vert = dx == 0

template edge_x(e: Edge; y: int): int64 =
  (int64(e.x0) shl XSHIFT) + e.slope * (int64(y) - e.y0) - (if e.dec: 1'i64 else: 0'i64)

proc edge_run(e: Edge; y: int; right: bool): Run {.inline.} =
  if e.vert:
    return if right: Run(s: e.x0 - 1, e: e.x0, vert: true) else: Run(s: e.x0, e: e.x0 + 1, vert: true)
  let xa = e.edge_x(y)
  if e.xmaj:
    # the run's far end steps the slope without its low 9 bits: a dot
    # whose centre x(y + 1) passes by less than (slope mod 512) / 2^18 is
    # left out (the hardware line captures, all 4 x 49601 exact)
    let st = abs(e.slope) and not 511'i64
    let xb = if e.dec: xa - st else: xa + st
    Run(s: int32((min(xa, xb) + XHALF) shr XSHIFT), e: int32((max(xa, xb) + XHALF) shr XSHIFT),
        xmaj: true, inc: not e.dec)
  else:
    let p = int32(xa shr XSHIFT)
    Run(s: p, e: p + 1, inc: not e.dec)

# Interpolation (3d_probe_lerp / _persp / _persp_tex): colours carry 9 bits
# (shown as c >> 3). Between two points with equal w the value moves
# linearly, floor(a + (b - a) * n / d); with different w by a perspective
# factor f = floor(n * w0 * 2^P / (n * w0 + (d - n) * w1)), P = 9 along
# edges and 8 across spans, as a + ((b - a) * f >> P).

proc lin(a, b, n, d: int64): int64 {.inline.} =
  a + floorDiv((b - a) * n, d)

template pfac(n, d, w0, w1: int64; P: int): int64 =
  ((n * w0) shl P) div (n * w0 + (d - n) * w1)

proc edge_end(e: Edge; va: openArray[VAttr]; y: int; x: int32): EndAttr {.inline.} =
  ## The edge's attributes at row y (y + 1 for the far end of an x-major
  ## run, see draw_polygon), placed at dot x.
  let A = va[e.a]
  let B = va[e.b]
  let n = int64(y) - e.y0
  let d = int64(e.y1 - e.y0)
  result.x = x
  # one division: a 38-bit factor, rounded per sign so that each value is
  # exactly floor(a + (b - a) * n / d)
  let nn = n shl 38
  let fl = nn div d
  let fc = fl + (if fl * d != nn: 1'i64 else: 0'i64)
  template li(a, b: int64): int64 =
    let dd = b - a
    a + ashr(dd * (if dd >= 0: fc else: fl), 38)
  result.z = li(A.z, B.z)
  if A.w == B.w:
    for k in 0..2: result.c[k] = li(A.c[k], B.c[k])
    result.s = li(A.s, B.s)
    result.t = li(A.t, B.t)
    result.w = A.w
  else:
    let f = pfac(n, d, A.w, B.w, 9)
    for k in 0..2: result.c[k] = A.c[k] + ashr((B.c[k] - A.c[k]) * f, 9)
    result.s = A.s + ashr((B.s - A.s) * f, 9)
    result.t = A.t + ashr((B.t - A.t) * f, 9)
    result.w = A.w + ashr((B.w - A.w) * f, 9)

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
    # 5-bit texel alpha over 32 (GBATEK writes (Rt*At + Rv*(63-At))/64;
    # 3d_blendmodes on the reference core pins this form exactly)
    pack((tr * ta + vr * (31 - ta)) shr 5, (tg * ta + vg * (31 - ta)) shr 5,
         (tb * ta + vb * (31 - ta)) shr 5, av)
  of 2:
    # toon/highlight: the vertex red picks the shading colour
    let sc = rgb6(r.reg16(0x380 + int(vr shr 1) * 2))
    let sr = ch(sc, 0)
    let sg = ch(sc, 1)
    let sb = ch(sc, 2)
    var rr, gg, bb: int32
    if c.highlight:
      # highlight: the texel modulated by the vertex red as a grey, plus
      # the table colour (GBATEK modulates by the table colour; the
      # reference core's 3d_highlight frame pins this form exactly)
      rr = min(63, (((tr + 1) * (vr + 1) - 1) shr 6) + sr)
      gg = min(63, (((tg + 1) * (vr + 1) - 1) shr 6) + sg)
      bb = min(63, (((tb + 1) * (vr + 1) - 1) shr 6) + sb)
    else:
      rr = ((tr + 1) * (sr + 1) - 1) shr 6
      gg = ((tg + 1) * (sg + 1) - 1) shr 6
      bb = ((tb + 1) * (sb + 1) - 1) shr 6
    pack(rr, gg, bb, ((ta + 1) * (av + 1) - 1) shr 5)
  else:
    pack(((tr + 1) * (vr + 1) - 1) shr 6, ((tg + 1) * (vg + 1) - 1) shr 6,
         ((tb + 1) * (vb + 1) - 1) shr 6, ((ta + 1) * (av + 1) - 1) shr 5)

type
  SpanStep = object
    ## floor(n * 2^38 / d) and its remainder, stepped along a span so
    ## that consecutive dots need no division
    d, q, rr, n, f, acc: int64

proc span_step(xl, xr: int32): SpanStep {.inline.} =
  let d = max(1'i64, int64(xr - xl))
  SpanStep(d: d, q: (1'i64 shl 38) div d, rr: (1'i64 shl 38) mod d, n: -2)

proc step_to(sp: var SpanStep; n: int64) {.inline.} =
  if n == sp.n + 1:
    sp.f += sp.q
    sp.acc += sp.rr
    if sp.acc >= sp.d:
      sp.acc -= sp.d
      inc sp.f
  elif n != sp.n:
    let nn = n shl 38
    sp.f = nn div sp.d
    sp.acc = nn - sp.f * sp.d
  sp.n = n

proc plot(r: Renderer; c: PolyCtx; x, y: int; L, R: EndAttr; sp: var SpanStep; edge: bool;
          cov = 31'i32) {.inline.} =
  ## One dot of the span from L to R; `cov` is its anti-aliasing coverage
  ## (0..31, 31 = whole).
  let i = y * W + x
  # One division gives the dot's factor along the span; with equal w the
  # factor (38 bits, rounded so that every attribute comes out as
  # floor(a + (b - a) * n / d) exactly) is linear, else the 8-bit
  # perspective one. Depth first, the rest only for dots that pass.
  let d = int64(R.x - L.x)
  let n = int64(x - L.x)
  let eqw = L.w == R.w
  var fl, fc, f8, z, w: int64
  if d <= 0:
    z = L.z; w = L.w
  else:
    sp.step_to(n)
    fl = sp.f
    fc = fl + (if sp.acc != 0: 1'i64 else: 0'i64)
    let dz = R.z - L.z
    # depth steps across the span by an 18-bit reciprocal of its length,
    # so it lands just short of the exact value at whole steps: a polygon
    # drawn later wins the tie where its depth rises along the span
    # (3d_probe_zinterp_x on the reference cores; any 16..30 bits fit,
    # 18 Assumed like the edge slope's)
    z = L.z + ashr(dz * n * ((1'i64 shl 18) div d), 18)
    if eqw:
      w = L.w
    else:
      f8 = pfac(n, d, L.w, R.w, 8)
      w = L.w + ashr((R.w - L.w) * f8, 8)
  template at(a, b: int64): int64 =
    if d <= 0: a
    elif eqw:
      let dd = b - a
      a + ashr(dd * (if dd >= 0: fc else: fl), 38)
    else: a + ashr((b - a) * f8, 8)
  let dv = if c.wbuffer: w else: z
  let dval = uint32(max(0'i64, min(dv, 0xFF_FFFF'i64)))
  let old = r.depth[i]
  let pass = if (c.attr and 0x4000) != 0: abs(int64(dval) - int64(old)) <= 0x200
             else: dval < old
  when defined(r3dprof):
    inc prof_dots
    if pass: inc prof_pass
  if c.mode == 3:
    # Shadow volumes (GBATEK "DS 3D Shadow Polygons"), as the reference
    # cores agree on 3d_shadow: the mask (ID 0) flags the dots where its
    # back side is hidden, i.e. where the scene lies inside the volume; the
    # shadow (ID > 0) draws only on flagged dots, clearing the flag, and
    # not on its own polygon ID. A shadow with no mask draws nothing.
    if c.id == 0:
      if not pass: r.flags[i] = r.flags[i] or FLAG_STENCIL
      return
    if (r.flags[i] and FLAG_STENCIL) == 0: return
    r.flags[i] = r.flags[i] and not FLAG_STENCIL
    if not pass or r.opaque_id[i] == c.id: return
  elif not pass:
    # With anti-aliasing each dot keeps two layers: the top one and the
    # nearest one behind it, which a partly covered top dot mixes over at
    # the end. A dot hidden by the top layer still lands in the one behind
    # when it is nearer than that: opaque ones replace it, translucent ones
    # blend into it, whatever the drawing order (3d_aa, 3d_probe_aa2,
    # 3d_probe_aa3 on the reference cores). Only dots whose top is partly
    # covered or an edge ever read it.
    if not c.aa or (r.aacov[i] >= 31 and (r.flags[i] and FLAG_EDGE) == 0) or
       dval >= r.below_depth[i]: return
  let vr = int32(max(0'i64, min(ashr(at(L.c[0], R.c[0]), 3), 63'i64)))
  let vg = int32(max(0'i64, min(ashr(at(L.c[1], R.c[1]), 3), 63'i64)))
  let vb = int32(max(0'i64, min(ashr(at(L.c[2], R.c[2]), 3), 63'i64)))
  var tx = 0'u32
  if c.textured:
    tx = r.texel(c.tex, c.pltt, at(L.s, R.s), at(L.t, R.t))
  var px = r.blend_texel(c, vr, vg, vb, tx)
  # wire-frame lines are drawn at alpha 31 (GBATEK), whatever the texel's
  # alpha: transparent texels too (3d_lines on the reference cores)
  if c.wire: px = px or (31'u32 shl 24)
  let a = int32(px shr 24)
  if a <= c.aref: return
  template blend_into(dst: var uint32) =
    let o = dst
    let oa = int32(o shr 24)
    if c.blend and oa != 0:
      template mixc(k: int): int32 = (ch(px, k) * (a + 1) + ch(o, k) * (31 - a)) shr 5
      dst = pack(mixc(0), mixc(1), mixc(2), max(a, oa))
    else:
      dst = px
  if not pass:
    if a == 31:
      r.below[i] = px
      r.below_depth[i] = dval
    else:
      blend_into(r.below[i])
      if (c.attr and 0x800) != 0: r.below_depth[i] = dval
    return
  if a == 31 and c.mode != 3:
    # anti-aliased edge dots keep their coverage for the post pass, and
    # what they cover moves one layer down
    r.below[i] = r.color[i]
    r.below_depth[i] = r.depth[i]
    r.aacov[i] = uint8(cov)
    r.color[i] = px
    r.depth[i] = dval
    r.opaque_id[i] = c.id
    r.trans_id[i] = NO_ID
    r.flags[i] = (if c.fog: FLAG_FOG else: 0'u8) or (if edge: FLAG_EDGE else: 0'u8)
  else:
    # a translucent polygon does not blend twice over its own ID
    if r.trans_id[i] == c.id: return
    blend_into(r.color[i])
    # over a partly covered edge dot it tints the layer behind as well
    # (3d_probe_aa3: anti-aliasing still applies under translucency)
    if c.aa and (r.aacov[i] < 31 or (r.flags[i] and FLAG_EDGE) != 0): blend_into(r.below[i])
    if (c.attr and 0x800) != 0: r.depth[i] = dval
    r.trans_id[i] = c.id
    if not c.fog: r.flags[i] = r.flags[i] and not FLAG_FOG

proc aa_cov(e: Edge; y, x: int; right: bool; lend = 0'i32): int32 =
  ## Anti-aliasing coverage (0..31) of dot x on row y by edge e
  ## (3d_probe_aa, 3d_probe_aa4 on the reference cores). y-major edges
  ## measure where the edge crosses the row's middle within the dot: right
  ## edges keep floor(32 * covered), left ones 31 - floor(32 * uncovered).
  ## x-major edges measure a 10-bit edge height h at the dot's centre from
  ## the run's exact left end (18-bit X), at floor((2^28 - 1) dy / (|dx|
  ## 2^18)) per dot; left edges are covered by h, right ones by 1023 - h
  ## and measured from the end of the left run (`lend`) where the two
  ## overlap; c = h >> 5.
  if e.vert: return 31
  if not e.xmaj:
    # X at y + 1/2 relative to the dot, 18 fraction bits
    let xm = (e.edge_x(y) + e.edge_x(y + 1)) div 2 - (int64(x) shl XSHIFT)
    let num = clamp(if right: xm else: (1'i64 shl XSHIFT) - xm, 0'i64, 1'i64 shl XSHIFT)
    if right: return int32(min(31'i64, (32 * num) shr XSHIFT))
    return int32(clamp(31 - ((32 * ((1'i64 shl XSHIFT) - num)) shr XSHIFT), 0'i64, 31'i64))
  let inc = (((1'i64 shl 28) - 1) * int64(e.y1 - e.y0)) div (abs(int64(e.x1 - e.x0)) shl XSHIFT)
  var start = min(e.edge_x(y), e.edge_x(y + 1))
  if right: start = max(start, int64(lend) shl XSHIFT)
  let h = (((int64(x) shl XSHIFT) + XHALF - start) * inc) shr XSHIFT
  let v = if right: 1023 - h else: h
  int32(clamp(v shr 5, 0'i64, 31'i64))

proc charge(r: Renderer; y, x0, x1: int) {.inline.} =
  ## Line budget: one polygon's span on line y.
  let w = max(0, min(W, x1) - max(0, x0))
  r.line_cost[y] += int32(RENDER_POLY_CYCLES + w div RENDER_DOTS_PER_CYCLE)

proc draw_polygon(r: Renderer; poly: Polygon; verts: openArray[Vertex]; disp3dcnt: uint32;
                  wbuffer: bool) =
  let n = int(poly.count)
  if n < 1 or n > 16: return
  var sx, sy: array[16, int32]
  var va: array[16, VAttr]
  var ymin = high(int32)
  var ymax = low(int32)
  for i in 0 ..< n:
    let v = verts[int(poly.first) + i]
    sx[i] = v.sx; sy[i] = v.sy
    ymin = min(ymin, v.sy); ymax = max(ymax, v.sy)
    # 5-bit vertex colours carry 9 bits through interpolation: the 6-bit
    # expansion (GBATEK, COLOR) times 8 plus 7, zero staying zero
    template c9(c5: int32): int64 = (if c5 == 0: 0'i64 else: int64(c5) * 16 + 15)
    va[i] = VAttr(c: [c9(v.r), c9(v.g), c9(v.b)], s: v.s, t: v.t, z: v.z24, w: v.w)
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
                  aref: (if (disp3dcnt and 4) != 0: int32(r.reg8(0x340) and 31) else: 0'i32),
                  aa: (disp3dcnt and 0x10) != 0, wire: wire)
  # a polygon whose vertices sit on at most two dots is a line segment:
  # always drawn whole (GBATEK "Polygon Definitions by Vertices")
  var line = true
  block:
    var o = -1
    for i in 1 ..< n:
      if sx[i] != sx[0] or sy[i] != sy[0]:
        if o < 0: o = i
        elif sx[i] != sx[o] or sy[i] != sy[o]: line = false
  # zero area: every vertex on one line (games close gaps between walls
  # with such polygons)
  var zero_area = true
  block:
    var o = 0
    for i in 1 ..< n:
      if o == 0:
        if sx[i] != sx[0] or sy[i] != sy[0]: o = i
      elif int64(sx[o] - sx[0]) * (sy[i] - sy[0]) != int64(sy[o] - sy[0]) * (sx[i] - sx[0]):
        zero_area = false
  # GBATEK "Polygon Size": only opaque polygons without edge marking or
  # anti-aliasing leave out their bottom/right edges
  let full = wire or line or (disp3dcnt and 0x30) != 0 or poly.translucent and c.blend
  # anti-aliasing (DISP3DCNT.4): edges of opaque polygons, lines and
  # wire-frames included ("accidentally", GBATEK: dirty lines with missing
  # dots, as the reference runs of 3d_aa draw them), not translucent ones
  let aa = (disp3dcnt and 0x10) != 0 and not poly.translucent
  if ymin == ymax:
    # all on one row: the dots from the leftmost vertex to the rightmost
    if ymin < 0 or ymin >= H: return
    var li, ri = 0
    for i in 1 ..< n:
      if sx[i] < sx[li]: li = i
      if sx[i] > sx[ri]: ri = i
    let L = EndAttr(x: sx[li], c: va[li].c, s: va[li].s, t: va[li].t, z: va[li].z, w: va[li].w)
    let R = EndAttr(x: sx[ri], c: va[ri].c, s: va[ri].s, t: va[ri].t, z: va[ri].z, w: va[ri].w)
    var sp = span_step(L.x, R.x)
    r.charge(int(ymin), int(sx[li]), max(int(sx[ri]), int(sx[li]) + 1))
    for x in max(0, int(sx[li])) ..< min(W, max(int(sx[ri]), int(sx[li]) + 1)):
      r.plot(c, x, int(ymin), L, R, sp, true)
    return
  var edges: array[16, Edge]
  var ne = 0
  for i in 0 ..< n:
    let j = (i + 1) mod n
    if sy[i] == sy[j]: continue
    edges[ne] = make_edge(sx, sy, i, j)
    inc ne
  var nbottom = 0
  for i in 0 ..< n:
    if sy[i] == ymax: inc nbottom
  let flat_bottom = nbottom >= 2
  for y in max(0, int(ymin)) ..< min(H, int(ymax)):
    # the two edges crossing this row, ordered by x at the row's centre
    var li, ri = -1
    for k in 0 ..< ne:
      if edges[k].y0 > y or edges[k].y1 <= y: continue
      if li < 0: li = k
      elif ri < 0: ri = k
    if li < 0 or ri < 0: continue
    block:
      let a = edges[li]
      let b = edges[ri]
      # x(y + 1/2) of each as a fraction over 2*dy, cross-multiplied
      let na = int64(a.x0) * 2 * (a.y1 - a.y0) + int64(a.x1 - a.x0) * (2 * y + 1 - 2 * a.y0)
      let nb = int64(b.x0) * 2 * (b.y1 - b.y0) + int64(b.x1 - b.x0) * (2 * y + 1 - 2 * b.y0)
      let lhs = na * (b.y1 - b.y0)
      let rhs = nb * (a.y1 - a.y0)
      # on a tie (a zero-width polygon) the edge that runs forward in
      # vertex order from the top is the left one (3d_probe_degen)
      if lhs > rhs or lhs == rhs and (a.edge_x(y) > b.edge_x(y) or
                                      a.edge_x(y) == b.edge_x(y) and b.fwd and not a.fwd):
        swap(li, ri)
    let le = edges[li]
    let re = edges[ri]
    let L = le.edge_run(y, false)
    let R = re.edge_run(y, true)
    r.charge(y, int(L.s), int(R.e))
    # span ends: the outer ends of the two runs, each with the edge's
    # attributes for the row that end belongs to
    let yl = if le.amaj and le.dec: y + 1 else: y
    let yr = if re.amaj and not re.dec and not re.vert: y + 1 else: y
    let EL = le.edge_end(va, yl, L.s)
    let ER = re.edge_end(va, yr, R.e)
    var sp = span_step(EL.x, ER.x)
    let rim = y == int(ymin) or y == int(ymax) - 1
    let last_flat = flat_bottom and y == int(ymax) - 1
    # wire-frames: the two runs only, except on the top row and the row
    # above a flat bottom, which are drawn whole
    if wire and y != int(ymin) and not last_flat:
      for x in max(0, int(L.s)) ..< min(W, int(L.e)):
        r.plot(c, x, y, EL, ER, sp, true, (if aa: le.aa_cov(y, x, false) else: 31'i32))
      for x in max(0, int(max(R.s, L.e))) ..< min(W, int(R.e)):
        r.plot(c, x, y, EL, ER, sp, true, (if aa: re.aa_cov(y, x, true, L.e) else: 31'i32))
      continue
    # which runs are drawn: all when full size; else the left run unless it
    # is a bottom x-major edge, the right run only when it is a top x-major
    # edge (or vertical); on the last row above a flat bottom, the x-major
    # runs both (3d_probe_tri, 3d_probe_tri_flat)
    let ldraw = full or not (L.xmaj and L.inc) or last_flat
    let rdraw = full or (R.xmaj and R.inc) or R.vert or (last_flat and R.xmaj)
    if aa:
      for x in max(0, int(L.s)) ..< min(W, int(L.e)): r.plot(c, x, y, EL, ER, sp, true, le.aa_cov(y, x, false))
      for x in max(0, int(L.e)) ..< min(W, int(R.s)): r.plot(c, x, y, EL, ER, sp, rim)
      for x in max(0, int(max(R.s, L.e))) ..< min(W, int(R.e)): r.plot(c, x, y, EL, ER, sp, true, re.aa_cov(y, x, true, L.e))
      continue
    if ldraw:
      for x in max(0, int(L.s)) ..< min(W, int(L.e)): r.plot(c, x, y, EL, ER, sp, true)
    for x in max(0, int(L.e)) ..< min(W, int(R.s)): r.plot(c, x, y, EL, ER, sp, rim)
    if rdraw:
      # the right run starts after the left one, unless the polygon has no
      # area and the left one is not drawn (a zero-width x-major polygon
      # shows its right runs: 3d_probe_degen)
      for x in max(0, int(max(R.s, if ldraw or not zero_area: L.e else: L.s))) ..< min(W, int(R.e)):
        r.plot(c, x, y, EL, ER, sp, true)

{.pop.}

# ---------------------------------------------------------------------------
# Post passes

proc edge_mark(r: Renderer; aa: bool) =
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
    if aa:
      # with anti-aliasing the edge colour goes on at about half strength
      # over the layer behind the dot (GBATEK; 3d_probe_aa_edge: alpha 16,
      # 3d_probe_aa3_edge: the layer, not the polygon's own colour)
      let o = r.below[i]
      template mixe(k: int): int32 = (ch(ec, k) * 17 + ch(o, k) * 15) shr 5
      r.color[i] = pack(mixe(0), mixe(1), mixe(2), 0) or (r.color[i] and 0xFF00_0000'u32)
    else:
      r.color[i] = ec or (r.color[i] and 0xFF00_0000'u32)

proc anti_alias(r: Renderer) =
  ## Opaque edge dots with partial coverage mix over the nearest opaque
  ## colour behind them (`below`), whatever their neighbours' IDs: a mesh
  ## shows no seams because its neighbouring polygon is that colour
  ## (3d_probe_aa / _aa_edge pin the coverage, 3d_probe_aa2 / _aa3 the
  ## layer, translucent polygons included).
  for i in 0 ..< NPIX:
    let cov = int32(r.aacov[i])
    if cov >= 31: continue
    let o = r.below[i]
    let px = r.color[i]
    template mixa(k: int): int32 = (ch(px, k) * (cov + 1) + ch(o, k) * (31 - cov)) shr 5
    # no coverage at all leaves the colour beneath
    r.color[i] = if cov == 0: o
                 else: pack(mixa(0), mixa(1), mixa(2), (if (o shr 24) == 0: cov else: 31'i32))

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


proc render_frame_body(r: Renderer; vram: Vram; polys: openArray[Polygon];
                       verts: openArray[Vertex]; disp3dcnt: uint32; swap_param: uint32)

proc budget(r: Renderer) =
  ## Replay the frame's line costs against the display: line k renders once
  ## line k-1 is done and line k-48 has left the cache; display line j takes
  ## its line at (RENDER_LEAD + j) line times after rendering starts. The
  ## fewest lines buffered at any display, minus 2, is RDLINES_COUNT (46 when
  ## the cache stays full).
  var done: array[H, int64]
  var t = 0'i64
  for k in 0 ..< H:
    var start = t
    if k >= CACHE_LINES: start = max(start, int64(RENDER_LEAD + k - CACHE_LINES) * LINE_BUS_CYCLES)
    t = start + r.line_cost[k]
    done[k] = t
  var fewest = CACHE_LINES
  var k = 0
  r.underflow = false
  for j in 0 ..< H:
    let shown = int64(RENDER_LEAD + j) * LINE_BUS_CYCLES
    while k < H and done[k] <= shown: inc k
    if k <= j: r.underflow = true
    # past line 191 there is nothing left to buffer: the cache counts as
    # full once every remaining line is in
    fewest = min(fewest, if k >= H: CACHE_LINES else: min(k - j, CACHE_LINES))
  r.rdlines = uint32(clamp(fewest - 2, 0, 46))

proc render_frame*(r: Renderer; vram: Vram; polys: openArray[Polygon];
                   verts: openArray[Vertex]; disp3dcnt: uint32; swap_param: uint32) =
  ## Draw the swapped buffer: opaque polygons first, then translucent ones
  ## (Y-sorted unless SWAP_BUFFERS bit 0 asked for manual order).
  ## -d:r3dprof prints the mean render time every 600 frames.
  when defined(r3dprof):
    let t0 = getMonoTime()
    r.render_frame_body(vram, polys, verts, disp3dcnt, swap_param)
    prof_ns += (getMonoTime() - t0).inNanoseconds
    prof_polys += polys.len
    inc prof_frames
    if prof_frames mod 600 == 0:
      echo "r3dprof: ", prof_ns div prof_frames div 1000, " us/frame, ", prof_polys div prof_frames,
           " polys/frame, ", prof_dots div prof_frames, " dots, ", prof_pass div prof_frames, " pass, setup ",
           prof_setup div prof_frames div 1000, " us, draw ", prof_draw div prof_frames div 1000, " us"
      prof_setup = 0; prof_draw = 0
      prof_ns = 0; prof_frames = 0; prof_polys = 0; prof_dots = 0; prof_pass = 0
  else:
    r.render_frame_body(vram, polys, verts, disp3dcnt, swap_param)

proc render_frame_body(r: Renderer; vram: Vram; polys: openArray[Polygon];
                       verts: openArray[Vertex]; disp3dcnt: uint32; swap_param: uint32) =
  when defined(r3dprof):
    let ta = getMonoTime()
  r.build_pages(vram)
  r.clear(disp3dcnt)
  for y in 0 ..< H: r.line_cost[y] = 0
  when defined(r3dprof):
    prof_setup += (getMonoTime() - ta).inNanoseconds
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
  when defined(r3dprof):
    let tb = getMonoTime()
  for k in r.order:
    r.draw_polygon(polys[int(k and 0xFFFFF)], verts, disp3dcnt, wbuffer)
  when defined(r3dprof):
    prof_draw += (getMonoTime() - tb).inNanoseconds
  if (disp3dcnt and 0x10) != 0: r.anti_alias()
  if (disp3dcnt and 0x20) != 0: r.edge_mark((disp3dcnt and 0x10) != 0)
  if (disp3dcnt and 0x80) != 0: r.fog(disp3dcnt)
  r.budget()
