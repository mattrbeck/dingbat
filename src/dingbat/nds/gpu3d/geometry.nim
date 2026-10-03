## The 3D geometry engine (GBATEK "DS 3D Geometry Commands" through "DS 3D
## Tests"): matrix modes and stacks, the vertex colour / normal / texcoord
## state, lighting, polygon assembly from BEGIN_VTXS lists, clipping to the
## view volume and the viewport transform. Its output is the geometry side
## of Polygon/Vertex RAM (`polys`, `verts`), handed to the renderer at
## SWAP_BUFFERS. Fixed point as the hardware has it: matrices 20.12,
## vertices 4.12, normals and light vectors 1.9, texcoords 12.4.
##
## Vectors are rows and matrices multiply on the right (v' = v * M), so
## MTX_MULT sets C = M * C and ClipMatrix = Position * Projection.

import std/math

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  Mat* = array[16, int32]       ## m[0..15], row-major

  Vertex* = object
    x*, y*, z*, w*: int32       ## clip coordinates, 20.12
    r*, g*, b*: int32           ## colour, 5 bits per channel
    s*, t*: int32               ## texcoord, 12.4
    sx*, sy*: int32             ## screen position in pixels, top-left origin
    z24*: int32                 ## Z-buffer depth (z/w scaled to 0..0xFFFFFF)

  Polygon* = object
    first*, count*: int32       ## verts[first ..< first + count], convex
    attr*: uint32               ## POLYGON_ATTR as latched by BEGIN_VTXS
    tex*: uint32                ## TEXIMAGE_PARAM
    pltt*: uint32               ## PLTT_BASE
    ymin*, ymax*: int32         ## screen extent (the Y-sort keys)
    translucent*: bool          ## alpha 1..30 or an A3I5/A5I3 texture

  Geometry* = ref object
    mode*: int                  ## MTX_MODE
    proj*, pos*, vec*, tex*, clip*: Mat
    proj_stack, tex_stack: Mat
    pos_stack, vec_stack: array[32, Mat]
    proj_sp*, pos_sp*, tex_sp*: int
    stack_error*: bool          ## GXSTAT.15
    # vertex state
    vx, vy, vz: int32           ## last VTX coordinates (4.12)
    cr, cg, cb: int32           ## current vertex colour (5-bit)
    s_in, t_in: int32           ## TEXCOORD as issued
    s, t: int32                 ## texcoord after the transform mode
    attr_next, attr*: uint32    ## POLYGON_ATTR: written / latched at BEGIN
    teximage*, pltt_base*: uint32
    prim: int                   ## BEGIN_VTXS primitive type
    vbuf: array[4, Vertex]      ## vertices of the polygon being assembled
    nbuf: int
    strip_odd: bool             ## triangle strips: every 2nd one is clockwise
    strip_shared: bool          ## the previous strip polygon kept its vertices
    # lighting
    light_vec, half_vec, light_col: array[4, array[3, int32]]
    diffuse, ambient, specular, emission: array[3, int32]
    shine_table_on: bool
    shine: array[128, uint8]
    # viewport (x1, y1 bottom-left; x2, y2 top-right, inclusive)
    vp_x1, vp_y1, vp_x2, vp_y2: int32
    one_dot_depth*: uint32      ## DISP_1DOT_DEPTH (12.3 w)
    # Polygon/Vertex RAM being filled
    polys*: seq[Polygon]
    verts*: seq[Vertex]
    vram_count*: int            ## RAM_COUNT vertices (strip vertices shared)
    overflow*: bool             ## DISP3DCNT.13
    # test results
    pos_result*: array[4, int32]
    vec_result*: array[3, int16]
    box_result*: bool

const
  # Texcoord transform modes 2 and 3: (N or V, 1.0) * texture matrix, the
  # sum shifted right by these. GBATEK's parts table (N 1.9, V 4.12, matrix
  # 20.12, S/T 12.4) would give 17 and 20; the 3d_texcoord ROM on the
  # reference cores (all three agree) pins 21 and 24 exactly, i.e. the
  # products keep no fraction bits at all (docs/oracles.md, NDS core).
  TEXGEN_NORMAL_SHIFT {.intdefine.} = 21
  TEXGEN_VERTEX_SHIFT {.intdefine.} = 24
  MAX_POLYS* = 2048
  MAX_VERTS* = 6144
  MAX_CLIP = 16                 ## a quad clipped by 6 planes has at most 10
  ONE = 0x1000'i32
  IDENTITY: Mat = [ONE, 0, 0, 0, 0, ONE, 0, 0, 0, 0, ONE, 0, 0, 0, 0, ONE]

  ## Parameter words per command ID, -1 = invalid (ignored, takes none).
  CMD_PARAMS*: array[256, int8] = block:
    var p: array[256, int8]
    for i in 0..255: p[i] = -1
    p[0x00] = 0
    for (c, n) in [(0x10, 1), (0x11, 0), (0x12, 1), (0x13, 1), (0x14, 1), (0x15, 0),
                   (0x16, 16), (0x17, 12), (0x18, 16), (0x19, 12), (0x1A, 9),
                   (0x1B, 3), (0x1C, 3), (0x20, 1), (0x21, 1), (0x22, 1), (0x23, 2),
                   (0x24, 1), (0x25, 1), (0x26, 1), (0x27, 1), (0x28, 1), (0x29, 1),
                   (0x2A, 1), (0x2B, 1), (0x30, 1), (0x31, 1), (0x32, 1), (0x33, 1),
                   (0x34, 32), (0x40, 1), (0x41, 0), (0x50, 1), (0x60, 1),
                   (0x70, 3), (0x71, 2), (0x72, 1)]:
      p[c] = int8(n)
    p

template lo32(x: int64): int32 = cast[int32](uint32(cast[uint64](x) and 0xFFFF_FFFF'u64))
template sext16(x: uint32): int32 = int32(cast[int16](uint16(x and 0xFFFF)))
template sext10(x: uint32): int32 = (cast[int32]((x and 0x3FF) shl 22)) shr 22
template wrap16(x: int64): int32 = int32(cast[int16](uint16(cast[uint64](x) and 0xFFFF)))
template expand6(c5: uint32): int32 =
  ## 5-bit colour to the 6-bit internal value: x*2 + (x+31)/32 (GBATEK)
  int32(c5 * 2 + (c5 + 31) div 32)

proc new_geometry*(): Geometry =
  result = Geometry(proj: IDENTITY, pos: IDENTITY, vec: IDENTITY, tex: IDENTITY,
                    clip: IDENTITY, vp_x2: 255, vp_y2: 191, one_dot_depth: 0x7FFF)
  result.polys = newSeqOfCap[Polygon](MAX_POLYS)
  result.verts = newSeqOfCap[Vertex](MAX_VERTS)

proc reset_ram*(g: Geometry) =
  ## SWAP_BUFFERS hands the RAM over and the geometry side starts empty.
  g.polys.setLen(0)
  g.verts.setLen(0)
  g.vram_count = 0

# ---------------------------------------------------------------------------
# Matrices

proc mul(a, b: Mat): Mat =
  ## a * b, both 20.12; the 64-bit sum is truncated back to 32 bits.
  for i in 0..3:
    for j in 0..3:
      var acc = 0'i64
      for k in 0..3: acc += int64(a[i * 4 + k]) * int64(b[k * 4 + j])
      result[i * 4 + j] = lo32(acc shr 12)

proc update_clip(g: Geometry) {.inline.} = g.clip = mul(g.pos, g.proj)

proc load_param_mat(p: openArray[uint32]; kind: uint8): Mat =
  ## The 4x4 a MTX_LOAD/MULT/SCALE/TRANS parameter list stands for.
  template q(i: int): int32 = cast[int32](p[i])
  case kind
  of 0x16, 0x18:
    for i in 0..15: result[i] = q(i)
  of 0x17, 0x19:
    for r in 0..3:
      for c in 0..2: result[r * 4 + c] = q(r * 3 + c)
    result[15] = ONE
  of 0x1A:
    for r in 0..2:
      for c in 0..2: result[r * 4 + c] = q(r * 3 + c)
    result[15] = ONE
  of 0x1B:
    result[0] = q(0); result[5] = q(1); result[10] = q(2); result[15] = ONE
  of 0x1C:
    result = IDENTITY
    result[12] = q(0); result[13] = q(1); result[14] = q(2)
  else: result = IDENTITY

proc set_current(g: Geometry; m: Mat; multiply: bool; pos_only = false) =
  template apply(dst: var Mat) =
    dst = (if multiply: mul(m, dst) else: m)
  case g.mode
  of 0: apply(g.proj); g.update_clip()
  of 1: apply(g.pos); g.update_clip()
  of 2:
    apply(g.pos)
    if not pos_only: apply(g.vec)
    g.update_clip()
  else: apply(g.tex)

proc mtx_push(g: Geometry) =
  case g.mode
  of 0:
    if g.proj_sp != 0: g.stack_error = true
    g.proj_stack = g.proj
    g.proj_sp = (g.proj_sp + 1) and 1
  of 1, 2:
    # 31 valid entries; 31..63 flag the error (the upper half mirrors)
    if g.pos_sp >= 31: g.stack_error = true
    g.pos_stack[g.pos_sp and 31] = g.pos
    g.vec_stack[g.pos_sp and 31] = g.vec
    g.pos_sp = (g.pos_sp + 1) and 63
  else:
    if g.tex_sp != 0: g.stack_error = true
    g.tex_stack = g.tex
    g.tex_sp = (g.tex_sp + 1) and 1

proc mtx_pop(g: Geometry; p: uint32) =
  case g.mode
  of 0:
    g.proj_sp = (g.proj_sp - 1) and 1     # offset is always 1 here
    if g.proj_sp != 0: g.stack_error = true
    g.proj = g.proj_stack
    g.update_clip()
  of 1, 2:
    let n = int((cast[int32](p shl 26)) shr 26)   # signed 6-bit offset
    g.pos_sp = (g.pos_sp - n) and 63
    if g.pos_sp >= 31: g.stack_error = true
    g.pos = g.pos_stack[g.pos_sp and 31]
    g.vec = g.vec_stack[g.pos_sp and 31]
    g.update_clip()
  else:
    g.tex_sp = (g.tex_sp - 1) and 1
    if g.tex_sp != 0: g.stack_error = true
    g.tex = g.tex_stack

proc mtx_store(g: Geometry; p: uint32) =
  case g.mode
  of 0: g.proj_stack = g.proj
  of 1, 2:
    let n = int(p and 31)
    if n == 31: g.stack_error = true
    g.pos_stack[n] = g.pos
    g.vec_stack[n] = g.vec
  else: g.tex_stack = g.tex

proc mtx_restore(g: Geometry; p: uint32) =
  case g.mode
  of 0: g.proj = g.proj_stack; g.update_clip()
  of 1, 2:
    let n = int(p and 31)
    if n == 31: g.stack_error = true
    g.pos = g.pos_stack[n]
    g.vec = g.vec_stack[n]
    g.update_clip()
  else: g.tex = g.tex_stack

proc ack_stack_error*(g: Geometry) =
  ## GXSTAT.15 written 1: clears the error and resets the projection (and
  ## texture) stack pointer.
  g.stack_error = false
  g.proj_sp = 0
  g.tex_sp = 0

# ---------------------------------------------------------------------------
# Lighting (GBATEK "DS 3D Polygon Light Parameters", internal operation)

proc rgb5(v: uint32; shift: int): array[3, int32] =
  let c = v shr shift
  [int32(c and 31), int32((c shr 5) and 31), int32((c shr 10) and 31)]

proc vec_mul3(g: Geometry; x, y, z: int32): array[3, int32] =
  ## (x, y, z) * the directional matrix's upper-left 3x3, 12-bit fraction.
  let m = g.vec
  for c in 0..2:
    result[c] = lo32((int64(x) * m[c] + int64(y) * m[4 + c] + int64(z) * m[8 + c]) shr 12)

proc set_light_vector(g: Geometry; p: uint32) =
  let i = int(p shr 30)
  # 1.9 components scaled to 12-bit fractions before the matrix
  let l = g.vec_mul3(sext10(p) shl 3, sext10(p shr 10) shl 3, sext10(p shr 20) shl 3)
  g.light_vec[i] = l
  # half vector: light + line of sight (0, 0, -1.0) (GBATEK), here scaled
  # to unit length: the specular falloff of the reference cores
  # (3d_probe_light_spec/_tab) is cos(2 * angle to the unit half vector),
  # far sharper than GBATEK's square of the unnormalised dot product
  let hx = float(l[0])
  let hy = float(l[1])
  let hz = float(l[2] - ONE)
  let m = sqrt(hx * hx + hy * hy + hz * hz)
  g.half_vec[i] = if m == 0: [0'i32, 0, 0]
                  else: [int32(hx / m * 4096), int32(hy / m * 4096), int32(hz / m * 4096)]

proc apply_normal(g: Geometry; p: uint32) =
  let nx = sext10(p)
  let ny = sext10(p shr 10)
  let nz = sext10(p shr 20)
  if (g.teximage shr 30) == 2:
    # texcoord from the normal: (N, 1.0) * texture matrix with S, T as row 3
    # (GBATEK "DS 3D Texture Coordinates"); the shift is TEXGEN_NORMAL_SHIFT
    let m = g.tex
    g.s = wrap16(((int64(nx) * m[0] + int64(ny) * m[4] + int64(nz) * m[8]) shr TEXGEN_NORMAL_SHIFT) + g.s_in)
    g.t = wrap16(((int64(nx) * m[1] + int64(ny) * m[5] + int64(nz) * m[9]) shr TEXGEN_NORMAL_SHIFT) + g.t_in)
  let n = g.vec_mul3(nx shl 3, ny shl 3, nz shl 3)
  # GBATEK's sum (emission + per light: specular, diffuse, ambient terms)
  # is kept with 17 fraction bits and truncated once at the end
  # (3d_probe_light_sum; docs/oracles.md: the reference cores disagree)
  var col = [int64(g.emission[0]) shl 17, int64(g.emission[1]) shl 17, int64(g.emission[2]) shl 17]
  for i in 0..3:
    if (g.attr and (1'u32 shl i)) == 0: continue
    let l = g.light_vec[i]
    let h = g.half_vec[i]
    # the diffuse level keeps 8 fraction bits (3d_probe_light; docs/oracles.md:
    # reference cores; a 12-bit level is one step brighter on 22 of 192)
    let dif = (clamp(-((int64(l[0]) * n[0] + int64(l[1]) * n[1] + int64(l[2]) * n[2]) shr 12),
                     0'i64, int64(ONE)) shr 4) shl 4
    var shi = clamp(-((int64(h[0]) * n[0] + int64(h[1]) * n[1] + int64(h[2]) * n[2]) shr 12),
                    0'i64, int64(ONE))
    shi = max(0'i64, ((2 * shi * shi) shr 12) - ONE)
    # the level indexes the shininess table (7 bits); without the table the
    # entries count up linearly (GBATEK, SHININESS)
    let idx = min(127, int(shi shr 5))
    shi = (if g.shine_table_on: int64(g.shine[idx]) else: int64(idx) * 2) shl 4   # 0.8 -> 0.12
    for c in 0..2:
      let lc = int64(g.light_col[i][c])
      col[c] += int64(g.specular[c]) * lc * shi
      col[c] += int64(g.diffuse[c]) * lc * dif
      col[c] += (int64(g.ambient[c]) * lc) shl 12
  for c in 0..2: col[c] = col[c] shr 17
  g.cr = int32(min(31'i64, col[0]))
  g.cg = int32(min(31'i64, col[1]))
  g.cb = int32(min(31'i64, col[2]))

# ---------------------------------------------------------------------------
# Clipping and the viewport transform

template plane_dist(v: Vertex; plane: int): int64 =
  ## >= 0 inside: planes 0-5 are x >= -w, x <= w, y >= -w, y <= w,
  ## z >= -w (near), z <= w (far).
  case plane
  of 0: int64(v.w) + v.x
  of 1: int64(v.w) - v.x
  of 2: int64(v.w) + v.y
  of 3: int64(v.w) - v.y
  of 4: int64(v.w) + v.z
  else: int64(v.w) - v.z

proc intersect(a, b: Vertex; da, db: int64; plane: int): Vertex =
  ## The point on a->b where the plane distance crosses zero; always
  ## computed from the inside vertex `a` so shared edges clip identically.
  let den = da - db
  # coordinates and texcoords round down, colours (5-bit) round up
  # (3d_probe_clip / _clip_persp / _clipq, 3d_vcolor, 3d_clip on the
  # reference core)
  template lerp(f: untyped): int32 =
    lo32(int64(a.f) + floorDiv((int64(b.f) - a.f) * da, den))
  template clerp(f: untyped): int32 =
    int32(int64(a.f) - floorDiv(-(int64(b.f) - a.f) * da, den))
  result = Vertex(x: lerp(x), y: lerp(y), z: lerp(z), w: lerp(w), r: clerp(r), g: clerp(g),
                  b: clerp(b), s: lerp(s), t: lerp(t))
  # the new vertex lies exactly on the plane (3d_probe_clip_persp: a lerped
  # x one unit inside +w would land a dot short of the screen edge)
  case plane
  of 0: result.x = -result.w
  of 1: result.x = result.w
  of 2: result.y = -result.w
  of 3: result.y = result.w
  of 4: result.z = -result.w
  else: result.z = result.w

proc clip_polygon*(src: openArray[Vertex]; dst: var array[MAX_CLIP, Vertex]): int =
  ## Sutherland-Hodgman against the six sides of the view volume.
  var a, b: array[MAX_CLIP, Vertex]
  var n = src.len
  for i in 0 ..< n: a[i] = src[i]
  # near/far first, then y, then x: vertices cut by two planes (a corner)
  # come out as the reference core has them (3d_vcolor, 3d_clip)
  const ORDER = [4, 5, 2, 3, 0, 1]
  for plane in ORDER:
    var m = 0
    for i in 0 ..< n:
      let cur = a[i]
      let nxt = a[(i + 1) mod n]
      let dc = plane_dist(cur, plane)
      let dn = plane_dist(nxt, plane)
      if dc >= 0:
        b[m] = cur; inc m
        if dn < 0: (b[m] = intersect(cur, nxt, dc, dn, plane); inc m)
      elif dn >= 0:
        b[m] = intersect(nxt, cur, dn, dc, plane); inc m
      if m >= MAX_CLIP - 1: break
    n = m
    a = b
    if n == 0: return 0
  for i in 0 ..< n: dst[i] = a[i]
  n

proc to_screen(g: Geometry; v: var Vertex) =
  ## screen = (c + w) * size / 2w + origin (GBATEK "Notes on VTX commands");
  ## Y counts up from the bottom there, flipped here to the 2D top-left.
  let w = max(1'i64, int64(v.w))
  let vw = int64(g.vp_x2 - g.vp_x1 + 1)
  let vh = int64(g.vp_y2 - g.vp_y1 + 1)
  v.sx = lo32((int64(v.x) + w) * vw div (2 * w) + g.vp_x1)
  v.sy = lo32((w - int64(v.y)) * vh div (2 * w) + (191 - g.vp_y2))
  v.z24 = lo32(clamp(((int64(v.z) shl 14) div w + 0x3FFF) * 0x200, 0'i64, 0xFF_FFFF'i64))

# ---------------------------------------------------------------------------
# Polygon assembly

proc emit_polygon(g: Geometry; src: openArray[Vertex]; in_strip: bool) =
  let attr = g.attr
  # far-plane-crossing polygons are hidden unless POLYGON_ATTR.12
  if (attr and 0x1000) == 0:
    for v in src:
      if v.z > v.w: (g.strip_shared = false; return)
  var cv: array[MAX_CLIP, Vertex]
  let n = clip_polygon(src, cv)
  if n == 0:
    g.strip_shared = false
    return
  var clipped = n != src.len
  if not clipped:
    for i in 0 ..< n:
      if cv[i].x != src[i].x or cv[i].y != src[i].y or cv[i].z != src[i].z:
        clipped = true
  var ymin = high(int32)
  var ymax = low(int32)
  for i in 0 ..< n:
    g.to_screen(cv[i])
    ymin = min(ymin, cv[i].sy)
    ymax = max(ymax, cv[i].sy)
  # facing from the screen-space winding: anticlockwise (Y up) is the front;
  # zero area (line segments) has no sides and always renders
  var area = 0'i64
  for i in 0 ..< n:
    let a = cv[i]
    let b = cv[(i + 1) mod n]
    area += int64(a.sx) * (-b.sy) - int64(b.sx) * (-a.sy)
  if area > 0 and (attr and 0x80) == 0 or area < 0 and (attr and 0x40) == 0:
    g.strip_shared = false
    return
  # 1-dot polygons: hidden when every vertex is beyond DISP_1DOT_DEPTH
  if (attr and 0x2000) == 0:
    var dot = true
    for i in 1 ..< n:
      if cv[i].sx != cv[0].sx or cv[i].sy != cv[0].sy: dot = false
    if dot:
      var near = false
      for i in 0 ..< n:
        if uint32(max(0'i32, cv[i].w) shr 9) <= g.one_dot_depth: near = true
      if not near:
        g.strip_shared = false
        return
  # Polygon/Vertex RAM: unclipped strip polygons share their earlier vertices
  let new_verts = if in_strip and g.strip_shared and not clipped:
                    (if g.prim == 2: 1 else: 2)
                  else: n
  if g.polys.len >= MAX_POLYS or g.vram_count + new_verts > MAX_VERTS:
    g.overflow = true
    return
  g.vram_count += new_verts
  g.strip_shared = not clipped
  let alpha = (attr shr 16) and 31
  let fmt = (g.teximage shr 26) and 7
  var p = Polygon(first: int32(g.verts.len), count: int32(n), attr: attr,
                  tex: g.teximage, pltt: g.pltt_base, ymin: ymin, ymax: ymax)
  p.translucent = (alpha in 1'u32..30'u32) or fmt == 1 or fmt == 6
  for i in 0 ..< n: g.verts.add cv[i]
  g.polys.add p

proc add_vertex(g: Geometry; v: Vertex) =
  g.vbuf[g.nbuf] = v
  inc g.nbuf
  case g.prim
  of 0:
    if g.nbuf == 3:
      g.emit_polygon(g.vbuf.toOpenArray(0, 2), false)
      g.nbuf = 0
  of 1:
    if g.nbuf == 4:
      g.emit_polygon(g.vbuf.toOpenArray(0, 3), false)
      g.nbuf = 0
  of 2:
    if g.nbuf == 3:
      # every second strip triangle arrives clockwise: swap its first two
      if g.strip_odd: g.emit_polygon([g.vbuf[1], g.vbuf[0], g.vbuf[2]], true)
      else: g.emit_polygon(g.vbuf.toOpenArray(0, 2), true)
      g.strip_odd = not g.strip_odd
      g.vbuf[0] = g.vbuf[1]
      g.vbuf[1] = g.vbuf[2]
      g.nbuf = 2
  else:
    if g.nbuf == 4:
      # quad strips run up-down: v0 v1 v3 v2 is anticlockwise
      g.emit_polygon([g.vbuf[0], g.vbuf[1], g.vbuf[3], g.vbuf[2]], true)
      g.vbuf[0] = g.vbuf[2]
      g.vbuf[1] = g.vbuf[3]
      g.nbuf = 2

proc transform(g: Geometry; x, y, z: int32): array[4, int32] =
  ## (x, y, z, 1.0) * ClipMatrix
  let m = g.clip
  for c in 0..3:
    result[c] = lo32((int64(x) * m[c] + int64(y) * m[4 + c] + int64(z) * m[8 + c] +
                      int64(ONE) * m[12 + c]) shr 12)

proc submit_vertex(g: Geometry) =
  if (g.teximage shr 30) == 3:
    # texcoord from the vertex: (V, 1.0) * texture matrix, S, T as row 3;
    # the shift is TEXGEN_VERTEX_SHIFT
    let m = g.tex
    g.s = wrap16(((int64(g.vx) * m[0] + int64(g.vy) * m[4] + int64(g.vz) * m[8]) shr TEXGEN_VERTEX_SHIFT) + g.s_in)
    g.t = wrap16(((int64(g.vx) * m[1] + int64(g.vy) * m[5] + int64(g.vz) * m[9]) shr TEXGEN_VERTEX_SHIFT) + g.t_in)
  let c = g.transform(g.vx, g.vy, g.vz)
  g.add_vertex(Vertex(x: c[0], y: c[1], z: c[2], w: c[3], r: g.cr, g: g.cg, b: g.cb,
                      s: g.s, t: g.t))

# ---------------------------------------------------------------------------
# Tests

proc box_test(g: Geometry; p: openArray[uint32]) =
  ## True if any face of the box reaches into the view volume.
  let x = sext16(p[0]); let y = sext16(p[0] shr 16); let z = sext16(p[1])
  let w = sext16(p[1] shr 16); let h = sext16(p[2]); let d = sext16(p[2] shr 16)
  var c: array[8, Vertex]
  for i in 0..7:
    let t = g.transform(wrap16(int64(x) + (if (i and 1) != 0: w else: 0)),
                        wrap16(int64(y) + (if (i and 2) != 0: h else: 0)),
                        wrap16(int64(z) + (if (i and 4) != 0: d else: 0)))
    c[i] = Vertex(x: t[0], y: t[1], z: t[2], w: t[3])
  const FACES = [[0, 1, 3, 2], [4, 5, 7, 6], [0, 1, 5, 4], [2, 3, 7, 6], [0, 2, 6, 4], [1, 3, 7, 5]]
  g.box_result = false
  var tmp: array[MAX_CLIP, Vertex]
  for f in FACES:
    if clip_polygon([c[f[0]], c[f[1]], c[f[2]], c[f[3]]], tmp) > 0:
      g.box_result = true
      return

# ---------------------------------------------------------------------------
# Command execution (SWAP_BUFFERS is the FIFO owner's: it stalls the queue)

proc execute*(g: Geometry; cmd: uint8; p: openArray[uint32]) =
  case cmd
  of 0x10: g.mode = int(p[0] and 3)
  of 0x11: g.mtx_push()
  of 0x12: g.mtx_pop(p[0])
  of 0x13: g.mtx_store(p[0])
  of 0x14: g.mtx_restore(p[0])
  of 0x15: g.set_current(IDENTITY, false)
  of 0x16, 0x17: g.set_current(load_param_mat(p, cmd), false)
  of 0x18, 0x19, 0x1A, 0x1C: g.set_current(load_param_mat(p, cmd), true)
  of 0x1B: g.set_current(load_param_mat(p, cmd), true, pos_only = true)
  of 0x20:
    let c = rgb5(p[0], 0)
    g.cr = c[0]; g.cg = c[1]; g.cb = c[2]
  of 0x21: g.apply_normal(p[0])
  of 0x22:
    g.s_in = sext16(p[0])
    g.t_in = sext16(p[0] shr 16)
    if (g.teximage shr 30) == 1:
      # (S, T, 1/16, 1/16) * texture matrix
      let m = g.tex
      g.s = wrap16((int64(g.s_in) * m[0] + int64(g.t_in) * m[4] + int64(m[8]) + m[12]) shr 12)
      g.t = wrap16((int64(g.s_in) * m[1] + int64(g.t_in) * m[5] + int64(m[9]) + m[13]) shr 12)
    else:
      g.s = g.s_in
      g.t = g.t_in
  of 0x23:
    g.vx = sext16(p[0]); g.vy = sext16(p[0] shr 16); g.vz = sext16(p[1])
    g.submit_vertex()
  of 0x24:
    # 4.6 components to 4.12
    g.vx = sext10(p[0]) shl 6; g.vy = sext10(p[0] shr 10) shl 6; g.vz = sext10(p[0] shr 20) shl 6
    g.submit_vertex()
  of 0x25: (g.vx = sext16(p[0]); g.vy = sext16(p[0] shr 16); g.submit_vertex())
  of 0x26: (g.vx = sext16(p[0]); g.vz = sext16(p[0] shr 16); g.submit_vertex())
  of 0x27: (g.vy = sext16(p[0]); g.vz = sext16(p[0] shr 16); g.submit_vertex())
  of 0x28:
    # 0.9 differences divided by 8 = the same integers as 0.12 fractions
    g.vx = wrap16(int64(g.vx) + sext10(p[0]))
    g.vy = wrap16(int64(g.vy) + sext10(p[0] shr 10))
    g.vz = wrap16(int64(g.vz) + sext10(p[0] shr 20))
    g.submit_vertex()
  of 0x29: g.attr_next = p[0]
  of 0x2A: g.teximage = p[0]
  of 0x2B: g.pltt_base = p[0] and 0x1FFF
  of 0x30:
    g.diffuse = rgb5(p[0], 0)
    g.ambient = rgb5(p[0], 16)
    if (p[0] and 0x8000) != 0:
      g.cr = g.diffuse[0]; g.cg = g.diffuse[1]; g.cb = g.diffuse[2]
  of 0x31:
    g.specular = rgb5(p[0], 0)
    g.emission = rgb5(p[0], 16)
    g.shine_table_on = (p[0] and 0x8000) != 0
  of 0x32: g.set_light_vector(p[0])
  of 0x33: g.light_col[int(p[0] shr 30)] = rgb5(p[0], 0)
  of 0x34:
    for i in 0..31:
      for b in 0..3: g.shine[i * 4 + b] = uint8((p[i] shr (8 * b)) and 0xFF)
  of 0x40:
    g.attr = g.attr_next
    g.prim = int(p[0] and 3)
    g.nbuf = 0
    g.strip_odd = false
    g.strip_shared = false
  of 0x41: discard   # END_VTXS has no effect
  of 0x60:
    g.vp_x1 = int32(p[0] and 0xFF); g.vp_y1 = int32((p[0] shr 8) and 0xFF)
    g.vp_x2 = int32((p[0] shr 16) and 0xFF); g.vp_y2 = int32(p[0] shr 24)
  of 0x70: g.box_test(p)
  of 0x71:
    # overwrites the VTX registers, so a following VTX_DIFF is relative to it
    g.vx = sext16(p[0]); g.vy = sext16(p[0] shr 16); g.vz = sext16(p[1])
    g.pos_result = g.transform(g.vx, g.vy, g.vz)
  of 0x72:
    let r = g.vec_mul3(sext10(p[0]) shl 3, sext10(p[0] shr 10) shl 3, sext10(p[0] shr 20) shl 3)
    for i in 0..2:
      # 4-bit sign, 12-bit fraction: values reaching 1.0 wrap
      g.vec_result[i] = cast[int16](uint16((cast[int32](uint32(r[i]) shl 19) shr 19) and 0xFFFF))
  else: discard

{.pop.}
