// --- DS 3D on the host GPU (docs/nds/gpu3d.md): WebGL2 ---
//
// Draws the scene the core exports (src/dingbat/nds/gpu3d/gpuexport.nim) at
// k x 256x192 and composites it with engine A's 2D layers (the planes from
// engine2d.nim gpu_paint_line), for display only: the core's own 1x
// picture stays the machine's.
//
// The rasteriser is render.nim's, run per dot: each fragment walks the
// polygons binned to its row band in the hardware's drawing order and, for
// each, works out from that polygon's row (draw_polygon's edge chains,
// runs, swapped rows and fill rules) whether and how it plots this dot,
// then applies plot_k's rules to the dot's state (colour, depth, IDs,
// flags, AA coverage and the layer behind), which lives in registers. So
// the translucent-ID rule, blending over a transparent rear plane, shadow
// stencils, the depth-equal tolerance and the AA layer behind are the
// hardware's, and polygons are interpolated along edges and spans, not
// split into triangles. The 64-bit arithmetic is done on two 32-bit words
// where it needs to be (see the helpers), so the result can match the
// software HD renderer (RendererOf[k]) dot for dot.
//
// Passes: raster (RGBA32UI: colour, depth, layer behind, IDs/flags/
// coverage), post (anti-aliasing, edge marking, fog: R32UI in the core's
// pixel format), composite (R16UI BGR555, both screens top over bottom,
// engine A's 3D lines by hd_dot's rules). Textures are decoded in the
// shader from the texture and palette slot images.

const HEADER = 48, POLY_WORDS = 4, VERT_WORDS = 8;
const MAX_POLYS = 2048, MAX_VERTS = 6144;
const ROW = 1024;                    // data textures are 1024 texels wide
const TILE_W = 32, TILE_H = 8;       // the rasteriser's bins, in dots at k (RASTER)
const MAX_BINS = 1 << 22;

const VERT = `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const COMMON = `#version 300 es
precision highp float;
precision highp int;
precision highp usampler2D;
precision highp isampler2D;
uniform uvec4 uRegs[10];   // 0x4000320-0x40003BF
uniform uint uDisp;        // DISP3DCNT
uniform int uK;

ivec2 at1024(int i) { return ivec2(i & 1023, i >> 10); }
uint reg(int word) { return uRegs[word >> 2][word & 3]; }
uint reg16(int off) { int i = off - 0x320; return (reg(i >> 2) >> uint(8 * (i & 2))) & 0xFFFFu; }
uint reg8(int off) { int i = off - 0x320; return (reg(i >> 2) >> uint(8 * (i & 3))) & 0xFFu; }
uint expand6(uint c5) { return c5 * 2u + (c5 + 31u) / 32u; }
uint rgb6(uint c) {
  return expand6(c & 31u) | (expand6((c >> 5) & 31u) << 8) | (expand6((c >> 10) & 31u) << 16);
}
int ch(uint c, int i) { return int((c >> uint(8 * i)) & 0x3Fu); }
uint pack4(int r, int g, int b, int a) {
  return uint(r) | (uint(g) << 8) | (uint(b) << 16) | (uint(a) << 24);
}
const uint FLAG_FOG = 1u, FLAG_EDGE = 2u, FLAG_STENCIL = 4u;
`;

const ROWS = COMMON + `
uniform usampler2D uPolys;    // per polygon: attr, tex, pltt, first | count << 16 | translucent << 24 | forward-left << 25
uniform isampler2D uPolyGeo;  // per polygon: (xmin - 1, xmax + 1, ymin, last row), (top, flags, ymax, first record)
uniform uint uSwap;
const uint NO_ID = 255u;
const uint ROLE_LEFT = 8u, ROLE_RIGHT = 16u, ROLE_TOP = 32u, ROLE_BOTTOM = 64u;
int WS, HS;
uniform usampler2D uVram, uPal;   // (plot's, unused here)
uniform isampler2D uVerts;    // per vertex: (x, y, Z, w), (r | g << 8 | b << 16, s, t, 0); x, y in dots at k
uniform int uAblate;
// --- 64-bit values as (low, high) words, two's complement
uvec2 mulu64(uint a, uint b) {
  uint a0 = a & 0xFFFFu, a1 = a >> 16, b0 = b & 0xFFFFu, b1 = b >> 16;
  uint p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint mid = (p00 >> 16) + (p01 & 0xFFFFu) + (p10 & 0xFFFFu);
  return uvec2((p00 & 0xFFFFu) | (mid << 16), p11 + (p01 >> 16) + (p10 >> 16) + (mid >> 16));
}
uvec2 neg64(uvec2 x) { uint lo = ~x.x + 1u; return uvec2(lo, ~x.y + (lo == 0u ? 1u : 0u)); }
uvec2 add64(uvec2 a, uvec2 b) { uint lo = a.x + b.x; return uvec2(lo, a.y + b.y + (lo < a.x ? 1u : 0u)); }
uvec2 muls64(int a, int b) {
  uvec2 p = mulu64(uint(abs(a)), uint(abs(b)));
  return ((a < 0) != (b < 0)) ? neg64(p) : p;
}
bool isneg64(uvec2 x) { return int(x.y) < 0; }
bool ltu64(uvec2 a, uvec2 b) { return a.y < b.y || (a.y == b.y && a.x < b.x); }
uvec2 shl64(uvec2 x, int s) { return uvec2(x.x << uint(s), (x.y << uint(s)) | (x.x >> uint(32 - s))); }
// x >> s (arithmetic, 0 < s < 32) where the result fits in 32 bits
int ashr64(uvec2 x, int s) { return int((x.x >> uint(s)) | (x.y << uint(32 - s))); }
uvec2 mul64x32(uvec2 b, uint q) { uvec2 p = mulu64(b.x, q); return uvec2(p.x, p.y + b.y * q); }

int floordiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }   // b > 0
int truncdiv2(int a) { return a >= 0 ? a / 2 : -((-a) / 2); }
// a + floor((b - a) * n / d), exactly (render.nim lin / edge_end's li), d > 0
int lin(int a, int b, int n, int d) {
  int dd = b - a;
  int q = floordiv(dd, d);
  int r = dd - q * d;
  return a + q * n + floordiv(r * n, d);
}
// render.nim pfac: floor(n * w0 * 2^P / (n * w0 + (d - n) * w1)), truncated toward zero
int pfac(int n, int d, int w0, int w1, int P) {
  uvec2 num = muls64(n, w0);
  uvec2 den = add64(num, muls64(d - n, w1));
  if (den.x == 0u && den.y == 0u) return 0;
  uvec2 N = shl64(num, P);
  bool sn = isneg64(N), sd = isneg64(den);
  uvec2 a = sn ? neg64(N) : N;
  uvec2 b = sd ? neg64(den) : den;
  float fa = float(a.y) * 4294967296.0 + float(a.x);
  float fb = float(b.y) * 4294967296.0 + float(b.x);
  int q = int(min(fa / fb, 1073741824.0));
  for (int i = 0; i < 4; i++) {
    uvec2 qb = mul64x32(b, uint(q));
    if (ltu64(a, qb)) { q--; continue; }
    if (!ltu64(a, add64(qb, b))) { q++; continue; }
    break;
  }
  return sn != sd ? -q : q;
}

// --- texture memory (render.nim tex8/pal16, texel_uv)
uint tex8(int a) { a &= 0x7FFFF; return texelFetch(uVram, ivec2(a & 1023, a >> 10), 0).r; }
uint tex16(int a) { return tex8(a) | (tex8(a + 1) << 8); }
uint pal8(int a) {
  a &= 0x1FFFF;
  return a >= 0x18000 ? 0u : texelFetch(uPal, ivec2(a & 1023, a >> 10), 0).r;
}
uint pal16(int a) { return pal8(a) | (pal8(a + 1) << 8); }
uint mix5(uint c0, uint c1, int k0, int k1, int sh) {
  uint r = 0u;
  for (int i = 0; i < 3; i++) {
    int a = int((c0 >> uint(5 * i)) & 31u), b = int((c1 >> uint(5 * i)) & 31u);
    r |= uint((a * k0 + b * k1) >> sh) << uint(5 * i);
  }
  return r;
}
uint texel_uv(uint tex, uint pltt, int u, int v) {
  int sw = 8 << int((tex >> 20) & 7u);
  int base = int(tex & 0xFFFFu) * 8;
  int pbase = int(pltt) * 16;
  bool zc = (tex & 0x20000000u) != 0u;
  int i = v * sw + u;
  uint fmt = (tex >> 26) & 7u;
  if (fmt == 1u) {
    uint b = tex8(base + i);
    uint a = (b >> 5) * 4u + (b >> 6);
    return rgb6(pal16(pbase + int(b & 31u) * 2)) | (a << 24);
  } else if (fmt == 2u) {
    uint idx = (tex8(base + (i >> 2)) >> uint((i & 3) * 2)) & 3u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(int(pltt) * 8 + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 3u) {
    uint idx = (tex8(base + (i >> 1)) >> uint((i & 1) * 4)) & 15u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 4u) {
    uint idx = tex8(base + i);
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 5u) {
    int blk = base + ((v >> 2) * (sw >> 2) + (u >> 2)) * 4;
    uint bits = (tex8(blk + (v & 3)) >> uint((u & 3) * 2)) & 3u;
    int slot = (blk >> 17) & 3;
    int ia = 0x20000 + ((blk & 0x1FFFF) >> 1) + (slot == 2 ? 0x10000 : 0);
    uint info = tex16(ia);
    int pa = pbase + int(info & 0x3FFFu) * 4;
    uint c0 = pal16(pa), c1 = pal16(pa + 2);
    uint m = info >> 14, c;
    if (m == 0u) c = bits == 3u ? 0x8000u : pal16(pa + int(bits) * 2);
    else if (m == 1u) c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 1, 1, 1) : 0x8000u;
    else if (m == 2u) c = pal16(pa + int(bits) * 2);
    else c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 5, 3, 3) : mix5(c0, c1, 3, 5, 3);
    return c == 0x8000u ? 0u : rgb6(c & 0x7FFFu) | (31u << 24);
  } else if (fmt == 6u) {
    uint b = tex8(base + i);
    return rgb6(pal16(pbase + int(b & 7u) * 2)) | ((b >> 3) << 24);
  } else if (fmt == 7u) {
    uint c = tex16(base + i * 2);
    return rgb6(c) | ((c & 0x8000u) == 0u ? 0u : 31u << 24);
  }
  return 0u;
}
int wrap_coord(int c, int size, bool rep, int fmask) {
  if (!rep) return c < 0 ? 0 : c > size - 1 ? size - 1 : c;
  int m = c & (size - 1);
  return (c & size) != 0 ? (m ^ fmask) : m;
}

// --- a dot's state (render.nim Px and colour)
struct Px { uint color, depth, below, bdepth, oid, tid, flags, aacov; };

struct Ctx {
  uint attr, tex, pltt, id, mode;
  int alpha, aref, sw, th, fmask_s, fmask_t;
  bool textured, fog, wbuffer, highlight, blend, aa, wire, curse, rep_s, rep_t;
};

struct End { int x; ivec3 c; int s, t, z, w; };

uint blend_texel(Ctx c, int vr, int vg, int vb, uint tx) {
  int av = c.alpha;
  int tr = 63, tg = 63, tb = 63, ta = 31;
  if (c.textured) { tr = ch(tx, 0); tg = ch(tx, 1); tb = ch(tx, 2); ta = int(tx >> 24); }
  if (c.mode == 1u) {
    if (!c.textured || ta == 0) return pack4(vr, vg, vb, av);
    if (ta == 31) return pack4(tr, tg, tb, av);
    return pack4((tr * ta + vr * (31 - ta)) >> 5, (tg * ta + vg * (31 - ta)) >> 5,
                 (tb * ta + vb * (31 - ta)) >> 5, av);
  }
  if (c.mode == 2u) {
    uint sc = rgb6(reg16(0x380 + (vr >> 1) * 2));
    int sr = ch(sc, 0), sg = ch(sc, 1), sb = ch(sc, 2);
    int rr, gg, bb;
    if (c.highlight) {
      rr = min(63, (((tr + 1) * (vr + 1) - 1) >> 6) + sr);
      gg = min(63, (((tg + 1) * (vr + 1) - 1) >> 6) + sg);
      bb = min(63, (((tb + 1) * (vr + 1) - 1) >> 6) + sb);
    } else {
      rr = ((tr + 1) * (sr + 1) - 1) >> 6;
      gg = ((tg + 1) * (sg + 1) - 1) >> 6;
      bb = ((tb + 1) * (sb + 1) - 1) >> 6;
    }
    return pack4(rr, gg, bb, ((ta + 1) * (av + 1) - 1) >> 5);
  }
  return pack4(((tr + 1) * (vr + 1) - 1) >> 6, ((tg + 1) * (vg + 1) - 1) >> 6,
               ((tb + 1) * (vb + 1) - 1) >> 6, ((ta + 1) * (av + 1) - 1) >> 5);
}

uint blend_into(Ctx c, uint dst, uint px) {
  int a = int(px >> 24), oa = int(dst >> 24);
  if (c.blend && oa != 0) {
    return pack4((ch(px, 0) * (a + 1) + ch(dst, 0) * (31 - a)) >> 5,
                 (ch(px, 1) * (a + 1) + ch(dst, 1) * (31 - a)) >> 5,
                 (ch(px, 2) * (a + 1) + ch(dst, 2) * (31 - a)) >> 5, max(a, oa));
  }
  return px;
}

// plot_k with nothing known (K = 0): one dot of the span from L to R
void plot(Ctx c, int x, int y, End L, End R, bool edge, int cov, uint role, inout Px p) {
  if ((uAblate & 1) != 0) { p.color ^= uint(L.z + R.w); return; }
  int d = R.x - L.x, n = x - L.x;
  bool eqw = L.w == R.w;
  int z, w, f8 = 0;
  if (d <= 0) { z = L.z; w = L.w; }
  else if ((uAblate & 4) != 0) { z = L.z; w = L.w; }
  else {
    int zk = (1 << 18) / d;
    z = L.z + ashr64(muls64(R.z - L.z, n * zk), 18);
    if (eqw) w = L.w;
    else { f8 = pfac(n, d, L.w, R.w, 8); w = L.w + ashr64(muls64(R.w - L.w, f8), 8); }
  }
  int dv = c.wbuffer ? w : z;
  uint dval = uint(clamp(dv, 0, 0xFFFFFF));
  bool pass = (c.attr & 0x4000u) != 0u ? abs(int(dval) - int(p.depth)) <= 0x200 : dval < p.depth;
  if (c.curse && role != 0u && p.oid == c.id && p.tid == NO_ID) {
    uint was = p.flags;
    if ((role == ROLE_LEFT && (was & ROLE_RIGHT) != 0u) || (role == ROLE_TOP && (was & ROLE_BOTTOM) != 0u)) pass = true;
    else if ((role == ROLE_RIGHT && (was & ROLE_LEFT) != 0u) || (role == ROLE_BOTTOM && (was & ROLE_TOP) != 0u)) pass = false;
  }
  if (c.mode == 3u) {
    if (c.id == 0u) { if (!pass) p.flags |= FLAG_STENCIL; return; }
    if ((p.flags & FLAG_STENCIL) == 0u) return;
    p.flags &= ~FLAG_STENCIL;
    if (!pass || p.oid == c.id) return;
  } else if (!pass) {
    if (!c.aa || (p.aacov >= 31u && (p.flags & FLAG_EDGE) == 0u) || dval >= p.bdepth) return;
  }
  #define AT(a, b) (d <= 0 ? (a) : eqw ? lin((a), (b), n, d) : (a) + ((((b) - (a)) * f8) >> 8))
  int vr = clamp(AT(L.c.x, R.c.x) >> 3, 0, 63);
  int vg = clamp(AT(L.c.y, R.c.y) >> 3, 0, 63);
  int vb = clamp(AT(L.c.z, R.c.z) >> 3, 0, 63);
  uint tx = 0u;
  if (c.textured) {
    int s = AT(L.s, R.s), t = AT(L.t, R.t);
    int u = wrap_coord(s >> 4, c.sw, c.rep_s, c.fmask_s);
    int v = wrap_coord(t >> 4, c.th, c.rep_t, c.fmask_t);
    tx = (uAblate & 2) != 0 ? uint(u * v) | 0xFF000000u : texel_uv(c.tex, c.pltt, u, v);
  }
  #undef AT
  uint px = blend_texel(c, vr, vg, vb, tx);
  if (c.wire) px |= 31u << 24;
  int a = int(px >> 24);
  if (a <= c.aref) return;
  if (!pass) {
    if (a == 31) { p.below = px; p.bdepth = dval; }
    else { p.below = blend_into(c, p.below, px); if ((c.attr & 0x800u) != 0u) p.bdepth = dval; }
    return;
  }
  if (a == 31 && c.mode != 3u) {
    p.below = p.color; p.bdepth = p.depth; p.aacov = uint(cov);
    p.color = px; p.depth = dval; p.oid = c.id; p.tid = NO_ID;
    p.flags = (c.fog ? FLAG_FOG : 0u) | (edge ? FLAG_EDGE | role : 0u);
  } else {
    if (p.tid == c.id) return;
    p.color = blend_into(c, p.color, px);
    if (c.aa && (p.aacov < 31u || (p.flags & FLAG_EDGE) != 0u)) p.below = blend_into(c, p.below, px);
    if ((c.attr & 0x800u) != 0u) p.depth = dval;
    p.tid = c.id;
    if (!c.fog) p.flags &= ~FLAG_FOG;
  }
}

Ctx make_ctx(uvec4 pw) {
  bool translucent = (pw.w & (1u << 24)) != 0u;
  Ctx c;
  c.attr = pw.x; c.tex = pw.y; c.pltt = pw.z;
  uint fmt = (c.tex >> 26) & 7u;
  int alpha = int((c.attr >> 16) & 31u);
  c.wire = alpha == 0;
  c.id = (c.attr >> 24) & 0x3Fu;
  c.alpha = c.wire ? 31 : alpha;
  c.mode = (c.attr >> 4) & 3u;
  c.textured = (uDisp & 1u) != 0u && fmt != 0u;
  c.fog = (c.attr & 0x8000u) != 0u;
  c.wbuffer = (uSwap & 2u) != 0u;
  c.highlight = (uDisp & 2u) != 0u;
  c.blend = (uDisp & 8u) != 0u;
  c.aref = (uDisp & 4u) != 0u ? int(reg8(0x340) & 31u) : 0;
  c.aa = (uDisp & 0x10u) != 0u;
  c.curse = (uDisp & 0x30u) == 0x20u && !translucent && c.mode != 3u;
  c.sw = 8 << int((c.tex >> 20) & 7u);
  c.th = 8 << int((c.tex >> 23) & 7u);
  c.rep_s = (c.tex & 0x10000u) != 0u;
  c.rep_t = (c.tex & 0x20000u) != 0u;
  c.fmask_s = (c.tex & 0x40000u) != 0u ? c.sw - 1 : 0;
  c.fmask_t = (c.tex & 0x80000u) != 0u ? c.th - 1 : 0;
  return c;
}
// --- edges (render.nim Edge, make_edge, edge_x, edge_run, edge_end, aa_cov)
int SX[16], SY[16];
int FIRST;
struct Edge { int x0, y0, x1, y1, a, b, slope; bool xmaj, amaj, dec, vert; };
struct Run { int s, e; bool xmaj, inc, vert; };

Edge make_edge(int a, int b) {
  if (!(SY[a] < SY[b])) { int t = a; a = b; b = t; }
  Edge e;
  e.x0 = SX[a]; e.y0 = SY[a]; e.x1 = SX[b]; e.y1 = SY[b]; e.a = a; e.b = b;
  int dx = e.x1 - e.x0, dy = e.y1 - e.y0;
  e.slope = abs(dx) == dy ? (dx > 0 ? (1 << 18) : -(1 << 18)) : dy == 0 ? 0 : dx * ((1 << 18) / dy);
  e.xmaj = abs(dx) > dy; e.amaj = abs(dx) >= dy; e.dec = dx < 0; e.vert = dx == 0;
  return e;
}
int edge_x(Edge e, int y) { return (e.x0 << 18) + e.slope * (y - e.y0) - (e.dec ? 1 : 0); }
Run edge_run(Edge e, int y, bool right) {
  if (e.vert) {
    if (right) return Run(e.x0 - 1, e.x0, false, false, true);
    return Run(e.x0, e.x0 + 1, false, false, true);
  }
  int xa = edge_x(e, y);
  if (e.xmaj) {
    int st = abs(e.slope) & ~511;
    int xb = e.dec ? xa - st : xa + st;
    return Run((min(xa, xb) + (1 << 17)) >> 18, (max(xa, xb) + (1 << 17)) >> 18, true, !e.dec, false);
  }
  int q = xa >> 18;
  return Run(q, q + 1, false, !e.dec, false);
}
void vattr(int i, out ivec3 c, out int s, out int t, out int z, out int w) {
  ivec4 v0 = texelFetch(uVerts, at1024((FIRST + i) * 2), 0);
  ivec4 v1 = texelFetch(uVerts, at1024((FIRST + i) * 2 + 1), 0);
  ivec3 c5 = ivec3(v1.x & 0xFF, (v1.x >> 8) & 0xFF, (v1.x >> 16) & 0xFF);
  // 5-bit colours carry 9 bits: x * 16 + 15, zero staying zero
  c = ivec3(c5.x == 0 ? 0 : c5.x * 16 + 15, c5.y == 0 ? 0 : c5.y * 16 + 15, c5.z == 0 ? 0 : c5.z * 16 + 15);
  s = v1.y; t = v1.z; z = v0.z; w = v0.w;
}
End vend(int i, int x) {
  End r; r.x = x;
  vattr(i, r.c, r.s, r.t, r.z, r.w);
  return r;
}
End edge_end(Edge e, int y, int x) {
  ivec3 ac, bc; int as_, at_, az, aw, bs, bt, bz, bw;
  vattr(e.a, ac, as_, at_, az, aw);
  vattr(e.b, bc, bs, bt, bz, bw);
  int n = y - e.y0, d = e.y1 - e.y0;
  End r; r.x = x;
  r.z = lin(az, bz, n, d);
  if (aw == bw) {
    r.c = ivec3(lin(ac.x, bc.x, n, d), lin(ac.y, bc.y, n, d), lin(ac.z, bc.z, n, d));
    r.s = lin(as_, bs, n, d); r.t = lin(at_, bt, n, d); r.w = aw;
  } else {
    int f = pfac(n, d, aw, bw, 9);
    r.c = ac + (((bc - ac) * f) >> 9);
    r.s = as_ + (((bs - as_) * f) >> 9);
    r.t = at_ + (((bt - at_) * f) >> 9);
    r.w = aw + ashr64(muls64(bw - aw, f), 9);
  }
  return r;
}
int aa_cov(Edge e, int y, int x, bool right, int lend) {
  if (e.vert) return 31;
  if (!e.xmaj) {
    int xm = truncdiv2(edge_x(e, y) + edge_x(e, y + 1)) - (x << 18);
    int num = clamp(right ? xm : (1 << 18) - xm, 0, 1 << 18);
    if (right) return min(31, (32 * num) >> 18);
    return clamp(31 - ((32 * ((1 << 18) - num)) >> 18), 0, 31);
  }
  // ((2^28 - 1) dy) div (|dx| 2^18), as one 32-bit division
  int inc = ((e.y1 - e.y0) * 1024 - 1) / abs(e.x1 - e.x0);
  int start = min(edge_x(e, y), edge_x(e, y + 1));
  if (right) start = max(start, lend << 18);
  int h = ashr64(muls64((x << 18) + (1 << 17) - start, inc), 18);
  int v = right ? 1023 - h : h;
  return clamp(v >> 5, 0, 31);
}


// draw_polygon's row setup, once per (polygon, row): which dots of the
// row it plots and how (render.nim draw_polygon), for the dot pass.
// Record (5 texels): (L.x | R.x << 16, L colour, L.s, L.t), (L.z, L.w,
// R colour, R.s), (R.t, R.z, R.w, flags), (left edge dots, the run
// between, right edge dots: each lo | hi << 16), (left AA a, b, right AA
// a, b). flags: bit 0 the run's dots count as edge dots, 1-7 / 8-14 /
// 15-21 the left / right / run roles, 22-23 / 24-25 the left / right AA
// mode (0 whole, 1 fixed coverage a, 2 y-major X(y + 1/2) a, 3 x-major
// start a, step b).
uniform usampler2D uRecPoly;  // per record: its polygon
uniform int uTotal;
layout(location = 0) out ivec4 o0;
layout(location = 1) out ivec4 o1;
layout(location = 2) out ivec4 o2;
layout(location = 3) out ivec4 o3;
layout(location = 4) out ivec4 o4;
int packc(ivec3 c) { return c.x | (c.y << 9) | (c.z << 18); }
int range(int lo, int hi) { return lo < hi ? (lo & 0xFFFF) | (hi << 16) : 0; }
void emit(End L, End R, int rl, int rf, int rr, int flags, ivec4 aa) {
  o0 = ivec4((L.x & 0xFFFF) | (R.x << 16), packc(L.c), L.s, L.t);
  o1 = ivec4(L.z, L.w, packc(R.c), R.s);
  o2 = ivec4(R.t, R.z, R.w, flags);
  o3 = ivec4(rl, rf, rr, 0);
  o4 = aa;
}
// an edge's run of dots, for aa_cov per dot in the dot pass
ivec2 aa_mode(Edge e, int y, bool right, int lend, out int mode) {
  if (e.vert) { mode = 0; return ivec2(0); }
  if (!e.xmaj) { mode = 2; return ivec2(truncdiv2(edge_x(e, y) + edge_x(e, y + 1)), 0); }
  mode = 3;
  int inc = ((e.y1 - e.y0) * 1024 - 1) / abs(e.x1 - e.x0);
  int start = min(edge_x(e, y), edge_x(e, y + 1));
  if (right) start = max(start, lend << 18);
  return ivec2(start, inc);
}
void main() {
  WS = 256 * uK; HS = 192 * uK;
  o0 = ivec4(0); o1 = ivec4(0); o2 = ivec4(0); o3 = ivec4(0); o4 = ivec4(0);
  int rec = int(gl_FragCoord.y) * 1024 + int(gl_FragCoord.x);
  if (rec >= uTotal) return;
  int pi = int(texelFetch(uRecPoly, at1024(rec), 0).x);
  ivec4 g0 = texelFetch(uPolyGeo, at1024(pi * 2), 0);
  ivec4 g1 = texelFetch(uPolyGeo, at1024(pi * 2 + 1), 0);
  int y = max(0, g0.z) + rec - g1.w;
  uvec4 pw = texelFetch(uPolys, at1024(pi), 0);
  FIRST = int(pw.w & 0xFFFFu);
  int n = int((pw.w >> 16) & 0xFFu);
  bool translucent = (pw.w & (1u << 24)) != 0u;
  bool fwd_left = (pw.w & (1u << 25)) != 0u;
  Ctx c = make_ctx(pw);
  for (int i = 0; i < 16; i++) {
    if (i >= n) break;
    ivec4 v0 = texelFetch(uVerts, at1024((FIRST + i) * 2), 0);
    SX[i] = v0.x; SY[i] = v0.y;
  }
  int top = g1.x, ymax = g1.z, ymin = g0.z;
  bool line = (g1.y & 1) != 0, flat_bottom = (g1.y & 2) != 0;
  bool full = c.wire || line || (uDisp & 0x30u) != 0u || (translucent && c.blend);
  bool aa = (uDisp & 0x10u) != 0u && !translucent;
  if (ymin == ymax) {
    int li = 0, ri = 0;
    int i1 = 1 % n, i2 = n - 1;
    if (SX[i1] < SX[li]) li = i1;
    if (SX[i1] > SX[ri]) ri = i1;
    if (SX[i2] < SX[li]) li = i2;
    if (SX[i2] > SX[ri]) ri = i2;
    emit(vend(li, SX[li]), vend(ri, SX[ri]), 0, range(max(0, SX[li]), min(WS, max(SX[ri], SX[li] + 1))), 0,
         1, ivec4(0));
    return;
  }
  // the two chains from the top vertex (advance, from the top each time)
  int fc = top, fn = (top + 1) % n, bc = top, bn = (top + n - 1) % n;
  for (int g = 0; g < 16; g++) {
    if (g >= n || SY[fn] > y) break;
    fc = fn; fn = (fn + 1) % n;
  }
  for (int g = 0; g < 16; g++) {
    if (g >= n || SY[bn] > y) break;
    bc = bn; bn = (bn + n - 1) % n;
  }
  if (SY[fn] <= y || SY[bn] <= y) return;
  Edge ef = make_edge(fc, fn), eb = make_edge(bc, bn);
  Edge le0 = ef, re0 = eb;
  if (!fwd_left) { le0 = eb; re0 = ef; }
  bool rfull = full || (le0.x0 == re0.x0 && le0.y0 == re0.y0 && le0.x1 == re0.x1 && le0.y1 == re0.y1);
  bool rim = y == ymin || y == ymax - 1;
  bool last_flat = flat_bottom && y == ymax - 1;
  int xl = edge_x(le0, y), xr = edge_x(re0, y);
  if (xl > xr || (xl == xr && le0.slope > re0.slope)) {
    // a swapped row
    Edge pl = re0, pr = le0;
    Run lr = edge_run(pl, y, true);
    if (pl.vert && lr.s < 0) lr = Run(0, 1, false, false, true);
    Run rr = edge_run(pr, y, false);
    bool lfill = rfull || !(pl.xmaj && !pl.dec);
    bool rfill = pr.xmaj ? (rfull || !pr.dec) : (rfull || pl.vert);
    int xs = lfill ? (pl.xmaj ? lr.e - 1 : lr.s) : lr.e;
    int xe = rfill ? rr.s : rr.s - 1;
    if (xs <= xe + 1) {
      bool rdot, between = false;
      int a = xs, b = xe;
      if (xs > xe) rdot = rfill;
      else if (c.wire && y != ymin && !last_flat) rdot = rfill && xe != xs;
      else {
        rdot = rfill && !(lfill && xe == xs);
        a = lfill ? xs + 1 : xs;
        b = rdot ? xe - 1 : xe;
        between = true;
      }
      int rl = lfill ? range(max(0, xs), min(WS, xs + 1)) : 0;
      int rf = between ? range(max(0, a), min(WS - 1, b) + 1) : 0;
      int rrr = rdot ? range(max(0, xe), min(WS, xe + 1)) : 0;
      int covl = !aa ? 31 : pl.vert ? 0 : aa_cov(pl, y, pl.xmaj ? lr.s : xs, false, 0);
      int covr = !aa ? 31 : pr.vert ? 0 : aa_cov(pr, y, xe, true, 0);
      emit(edge_end(pl, y, xs), edge_end(pr, y, xe + 1), rl, rf, rrr,
           (rim ? 1 : 0) | (1 << 22) | (1 << 24), ivec4(covl, 0, covr, 0));
      return;
    }
  }
  Run L = edge_run(le0, y, false), R = edge_run(re0, y, true);
  int rl = range(max(0, L.s), min(WS, L.e));
  int rf = range(max(0, L.e), min(WS, R.s));
  int rrr = range(max(0, max(R.s, L.e)), min(WS, R.e));
  if (c.wire && y != ymin && !last_flat) rf = 0;
  else if (!aa) {
    bool ldraw = rfull || !(L.xmaj && L.inc) || last_flat;
    bool rdraw = rfull || (R.xmaj && R.inc) || R.vert || (last_flat && R.xmaj);
    if (!ldraw) rl = 0;
    if (!rdraw) rrr = 0;
  }
  int yl = (le0.amaj && le0.dec) ? y + 1 : y;
  int yr = (re0.amaj && !re0.dec && !re0.vert) ? y + 1 : y;
  uint lrole = L.xmaj ? (L.inc ? ROLE_BOTTOM : ROLE_TOP) : ROLE_LEFT;
  uint rrole = R.xmaj ? (R.inc ? ROLE_TOP : ROLE_BOTTOM) : ROLE_RIGHT;
  uint mrole = y == ymin ? ROLE_TOP : y == ymax - 1 ? ROLE_BOTTOM : 0u;
  int ml = 0, mr = 0;
  ivec2 al = ivec2(0), ar = ivec2(0);
  if (aa) { al = aa_mode(le0, y, false, 0, ml); ar = aa_mode(re0, y, true, L.e, mr); }
  emit(edge_end(le0, yl, L.s), edge_end(re0, yr, R.e), rl, rf, rrr,
       (rim ? 1 : 0) | int(lrole << 1) | int(rrole << 8) | int(mrole << 15) | (ml << 22) | (mr << 24),
       ivec4(al, ar));
}
`;

const RASTER = COMMON + `
uniform usampler2D uPolys;    // per polygon: attr, tex, pltt, first | count << 16 | translucent << 24 | forward-left << 25
uniform isampler2D uPolyGeo;  // per polygon: (xmin - 1, xmax + 1, ymin, last row), (top, flags, ymax, first record)
uniform uint uSwap;
const uint NO_ID = 255u;
const uint ROLE_LEFT = 8u, ROLE_RIGHT = 16u, ROLE_TOP = 32u, ROLE_BOTTOM = 64u;
int WS, HS;
uniform usampler2D uBins;     // polygon numbers, each tile's in drawing order
uniform usampler2D uBinHead;  // per tile (TILE_W x TILE_H dots): first, count
uniform usampler2D uVram;     // texture slots, 1024 x 512 bytes
uniform usampler2D uPal;      // palette slots, 1024 x 96 bytes
uniform isampler2D uRec0, uRec1, uRec2, uRec3, uRec4;   // the rows pass's records
uniform int uAblate;   // (measurements only) 1: no plot, 2: no texture decode, 4: no depth/w math
out uvec4 oPx;
const int TILE_W = 32, TILE_H = 8;
// --- 64-bit values as (low, high) words, two's complement
uvec2 mulu64(uint a, uint b) {
  uint a0 = a & 0xFFFFu, a1 = a >> 16, b0 = b & 0xFFFFu, b1 = b >> 16;
  uint p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint mid = (p00 >> 16) + (p01 & 0xFFFFu) + (p10 & 0xFFFFu);
  return uvec2((p00 & 0xFFFFu) | (mid << 16), p11 + (p01 >> 16) + (p10 >> 16) + (mid >> 16));
}
uvec2 neg64(uvec2 x) { uint lo = ~x.x + 1u; return uvec2(lo, ~x.y + (lo == 0u ? 1u : 0u)); }
uvec2 add64(uvec2 a, uvec2 b) { uint lo = a.x + b.x; return uvec2(lo, a.y + b.y + (lo < a.x ? 1u : 0u)); }
uvec2 muls64(int a, int b) {
  uvec2 p = mulu64(uint(abs(a)), uint(abs(b)));
  return ((a < 0) != (b < 0)) ? neg64(p) : p;
}
bool isneg64(uvec2 x) { return int(x.y) < 0; }
bool ltu64(uvec2 a, uvec2 b) { return a.y < b.y || (a.y == b.y && a.x < b.x); }
uvec2 shl64(uvec2 x, int s) { return uvec2(x.x << uint(s), (x.y << uint(s)) | (x.x >> uint(32 - s))); }
// x >> s (arithmetic, 0 < s < 32) where the result fits in 32 bits
int ashr64(uvec2 x, int s) { return int((x.x >> uint(s)) | (x.y << uint(32 - s))); }
uvec2 mul64x32(uvec2 b, uint q) { uvec2 p = mulu64(b.x, q); return uvec2(p.x, p.y + b.y * q); }

int floordiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }   // b > 0
int truncdiv2(int a) { return a >= 0 ? a / 2 : -((-a) / 2); }
// a + floor((b - a) * n / d), exactly (render.nim lin / edge_end's li), d > 0
int lin(int a, int b, int n, int d) {
  int dd = b - a;
  int q = floordiv(dd, d);
  int r = dd - q * d;
  return a + q * n + floordiv(r * n, d);
}
// render.nim pfac: floor(n * w0 * 2^P / (n * w0 + (d - n) * w1)), truncated toward zero
int pfac(int n, int d, int w0, int w1, int P) {
  uvec2 num = muls64(n, w0);
  uvec2 den = add64(num, muls64(d - n, w1));
  if (den.x == 0u && den.y == 0u) return 0;
  uvec2 N = shl64(num, P);
  bool sn = isneg64(N), sd = isneg64(den);
  uvec2 a = sn ? neg64(N) : N;
  uvec2 b = sd ? neg64(den) : den;
  float fa = float(a.y) * 4294967296.0 + float(a.x);
  float fb = float(b.y) * 4294967296.0 + float(b.x);
  int q = int(min(fa / fb, 1073741824.0));
  for (int i = 0; i < 4; i++) {
    uvec2 qb = mul64x32(b, uint(q));
    if (ltu64(a, qb)) { q--; continue; }
    if (!ltu64(a, add64(qb, b))) { q++; continue; }
    break;
  }
  return sn != sd ? -q : q;
}

// --- texture memory (render.nim tex8/pal16, texel_uv)
uint tex8(int a) { a &= 0x7FFFF; return texelFetch(uVram, ivec2(a & 1023, a >> 10), 0).r; }
uint tex16(int a) { return tex8(a) | (tex8(a + 1) << 8); }
uint pal8(int a) {
  a &= 0x1FFFF;
  return a >= 0x18000 ? 0u : texelFetch(uPal, ivec2(a & 1023, a >> 10), 0).r;
}
uint pal16(int a) { return pal8(a) | (pal8(a + 1) << 8); }
uint mix5(uint c0, uint c1, int k0, int k1, int sh) {
  uint r = 0u;
  for (int i = 0; i < 3; i++) {
    int a = int((c0 >> uint(5 * i)) & 31u), b = int((c1 >> uint(5 * i)) & 31u);
    r |= uint((a * k0 + b * k1) >> sh) << uint(5 * i);
  }
  return r;
}
uint texel_uv(uint tex, uint pltt, int u, int v) {
  int sw = 8 << int((tex >> 20) & 7u);
  int base = int(tex & 0xFFFFu) * 8;
  int pbase = int(pltt) * 16;
  bool zc = (tex & 0x20000000u) != 0u;
  int i = v * sw + u;
  uint fmt = (tex >> 26) & 7u;
  if (fmt == 1u) {
    uint b = tex8(base + i);
    uint a = (b >> 5) * 4u + (b >> 6);
    return rgb6(pal16(pbase + int(b & 31u) * 2)) | (a << 24);
  } else if (fmt == 2u) {
    uint idx = (tex8(base + (i >> 2)) >> uint((i & 3) * 2)) & 3u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(int(pltt) * 8 + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 3u) {
    uint idx = (tex8(base + (i >> 1)) >> uint((i & 1) * 4)) & 15u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 4u) {
    uint idx = tex8(base + i);
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 5u) {
    int blk = base + ((v >> 2) * (sw >> 2) + (u >> 2)) * 4;
    uint bits = (tex8(blk + (v & 3)) >> uint((u & 3) * 2)) & 3u;
    int slot = (blk >> 17) & 3;
    int ia = 0x20000 + ((blk & 0x1FFFF) >> 1) + (slot == 2 ? 0x10000 : 0);
    uint info = tex16(ia);
    int pa = pbase + int(info & 0x3FFFu) * 4;
    uint c0 = pal16(pa), c1 = pal16(pa + 2);
    uint m = info >> 14, c;
    if (m == 0u) c = bits == 3u ? 0x8000u : pal16(pa + int(bits) * 2);
    else if (m == 1u) c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 1, 1, 1) : 0x8000u;
    else if (m == 2u) c = pal16(pa + int(bits) * 2);
    else c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 5, 3, 3) : mix5(c0, c1, 3, 5, 3);
    return c == 0x8000u ? 0u : rgb6(c & 0x7FFFu) | (31u << 24);
  } else if (fmt == 6u) {
    uint b = tex8(base + i);
    return rgb6(pal16(pbase + int(b & 7u) * 2)) | ((b >> 3) << 24);
  } else if (fmt == 7u) {
    uint c = tex16(base + i * 2);
    return rgb6(c) | ((c & 0x8000u) == 0u ? 0u : 31u << 24);
  }
  return 0u;
}
int wrap_coord(int c, int size, bool rep, int fmask) {
  if (!rep) return c < 0 ? 0 : c > size - 1 ? size - 1 : c;
  int m = c & (size - 1);
  return (c & size) != 0 ? (m ^ fmask) : m;
}

// --- a dot's state (render.nim Px and colour)
struct Px { uint color, depth, below, bdepth, oid, tid, flags, aacov; };

struct Ctx {
  uint attr, tex, pltt, id, mode;
  int alpha, aref, sw, th, fmask_s, fmask_t;
  bool textured, fog, wbuffer, highlight, blend, aa, wire, curse, rep_s, rep_t;
};

struct End { int x; ivec3 c; int s, t, z, w; };

uint blend_texel(Ctx c, int vr, int vg, int vb, uint tx) {
  int av = c.alpha;
  int tr = 63, tg = 63, tb = 63, ta = 31;
  if (c.textured) { tr = ch(tx, 0); tg = ch(tx, 1); tb = ch(tx, 2); ta = int(tx >> 24); }
  if (c.mode == 1u) {
    if (!c.textured || ta == 0) return pack4(vr, vg, vb, av);
    if (ta == 31) return pack4(tr, tg, tb, av);
    return pack4((tr * ta + vr * (31 - ta)) >> 5, (tg * ta + vg * (31 - ta)) >> 5,
                 (tb * ta + vb * (31 - ta)) >> 5, av);
  }
  if (c.mode == 2u) {
    uint sc = rgb6(reg16(0x380 + (vr >> 1) * 2));
    int sr = ch(sc, 0), sg = ch(sc, 1), sb = ch(sc, 2);
    int rr, gg, bb;
    if (c.highlight) {
      rr = min(63, (((tr + 1) * (vr + 1) - 1) >> 6) + sr);
      gg = min(63, (((tg + 1) * (vr + 1) - 1) >> 6) + sg);
      bb = min(63, (((tb + 1) * (vr + 1) - 1) >> 6) + sb);
    } else {
      rr = ((tr + 1) * (sr + 1) - 1) >> 6;
      gg = ((tg + 1) * (sg + 1) - 1) >> 6;
      bb = ((tb + 1) * (sb + 1) - 1) >> 6;
    }
    return pack4(rr, gg, bb, ((ta + 1) * (av + 1) - 1) >> 5);
  }
  return pack4(((tr + 1) * (vr + 1) - 1) >> 6, ((tg + 1) * (vg + 1) - 1) >> 6,
               ((tb + 1) * (vb + 1) - 1) >> 6, ((ta + 1) * (av + 1) - 1) >> 5);
}

uint blend_into(Ctx c, uint dst, uint px) {
  int a = int(px >> 24), oa = int(dst >> 24);
  if (c.blend && oa != 0) {
    return pack4((ch(px, 0) * (a + 1) + ch(dst, 0) * (31 - a)) >> 5,
                 (ch(px, 1) * (a + 1) + ch(dst, 1) * (31 - a)) >> 5,
                 (ch(px, 2) * (a + 1) + ch(dst, 2) * (31 - a)) >> 5, max(a, oa));
  }
  return px;
}

// plot_k with nothing known (K = 0): one dot of the span from L to R
void plot(Ctx c, int x, int y, End L, End R, bool edge, int cov, uint role, inout Px p) {
  if ((uAblate & 1) != 0) { p.color ^= uint(L.z + R.w); return; }
  int d = R.x - L.x, n = x - L.x;
  bool eqw = L.w == R.w;
  int z, w, f8 = 0;
  if (d <= 0) { z = L.z; w = L.w; }
  else if ((uAblate & 4) != 0) { z = L.z; w = L.w; }
  else {
    int zk = (1 << 18) / d;
    z = L.z + ashr64(muls64(R.z - L.z, n * zk), 18);
    if (eqw) w = L.w;
    else { f8 = pfac(n, d, L.w, R.w, 8); w = L.w + ashr64(muls64(R.w - L.w, f8), 8); }
  }
  int dv = c.wbuffer ? w : z;
  uint dval = uint(clamp(dv, 0, 0xFFFFFF));
  bool pass = (c.attr & 0x4000u) != 0u ? abs(int(dval) - int(p.depth)) <= 0x200 : dval < p.depth;
  if (c.curse && role != 0u && p.oid == c.id && p.tid == NO_ID) {
    uint was = p.flags;
    if ((role == ROLE_LEFT && (was & ROLE_RIGHT) != 0u) || (role == ROLE_TOP && (was & ROLE_BOTTOM) != 0u)) pass = true;
    else if ((role == ROLE_RIGHT && (was & ROLE_LEFT) != 0u) || (role == ROLE_BOTTOM && (was & ROLE_TOP) != 0u)) pass = false;
  }
  if (c.mode == 3u) {
    if (c.id == 0u) { if (!pass) p.flags |= FLAG_STENCIL; return; }
    if ((p.flags & FLAG_STENCIL) == 0u) return;
    p.flags &= ~FLAG_STENCIL;
    if (!pass || p.oid == c.id) return;
  } else if (!pass) {
    if (!c.aa || (p.aacov >= 31u && (p.flags & FLAG_EDGE) == 0u) || dval >= p.bdepth) return;
  }
  #define AT(a, b) (d <= 0 ? (a) : eqw ? lin((a), (b), n, d) : (a) + ((((b) - (a)) * f8) >> 8))
  int vr = clamp(AT(L.c.x, R.c.x) >> 3, 0, 63);
  int vg = clamp(AT(L.c.y, R.c.y) >> 3, 0, 63);
  int vb = clamp(AT(L.c.z, R.c.z) >> 3, 0, 63);
  uint tx = 0u;
  if (c.textured) {
    int s = AT(L.s, R.s), t = AT(L.t, R.t);
    int u = wrap_coord(s >> 4, c.sw, c.rep_s, c.fmask_s);
    int v = wrap_coord(t >> 4, c.th, c.rep_t, c.fmask_t);
    tx = (uAblate & 2) != 0 ? uint(u * v) | 0xFF000000u : texel_uv(c.tex, c.pltt, u, v);
  }
  #undef AT
  uint px = blend_texel(c, vr, vg, vb, tx);
  if (c.wire) px |= 31u << 24;
  int a = int(px >> 24);
  if (a <= c.aref) return;
  if (!pass) {
    if (a == 31) { p.below = px; p.bdepth = dval; }
    else { p.below = blend_into(c, p.below, px); if ((c.attr & 0x800u) != 0u) p.bdepth = dval; }
    return;
  }
  if (a == 31 && c.mode != 3u) {
    p.below = p.color; p.bdepth = p.depth; p.aacov = uint(cov);
    p.color = px; p.depth = dval; p.oid = c.id; p.tid = NO_ID;
    p.flags = (c.fog ? FLAG_FOG : 0u) | (edge ? FLAG_EDGE | role : 0u);
  } else {
    if (p.tid == c.id) return;
    p.color = blend_into(c, p.color, px);
    if (c.aa && (p.aacov < 31u || (p.flags & FLAG_EDGE) != 0u)) p.below = blend_into(c, p.below, px);
    if ((c.attr & 0x800u) != 0u) p.depth = dval;
    p.tid = c.id;
    if (!c.fog) p.flags &= ~FLAG_FOG;
  }
}

Ctx make_ctx(uvec4 pw) {
  bool translucent = (pw.w & (1u << 24)) != 0u;
  Ctx c;
  c.attr = pw.x; c.tex = pw.y; c.pltt = pw.z;
  uint fmt = (c.tex >> 26) & 7u;
  int alpha = int((c.attr >> 16) & 31u);
  c.wire = alpha == 0;
  c.id = (c.attr >> 24) & 0x3Fu;
  c.alpha = c.wire ? 31 : alpha;
  c.mode = (c.attr >> 4) & 3u;
  c.textured = (uDisp & 1u) != 0u && fmt != 0u;
  c.fog = (c.attr & 0x8000u) != 0u;
  c.wbuffer = (uSwap & 2u) != 0u;
  c.highlight = (uDisp & 2u) != 0u;
  c.blend = (uDisp & 8u) != 0u;
  c.aref = (uDisp & 4u) != 0u ? int(reg8(0x340) & 31u) : 0;
  c.aa = (uDisp & 0x10u) != 0u;
  c.curse = (uDisp & 0x30u) == 0x20u && !translucent && c.mode != 3u;
  c.sw = 8 << int((c.tex >> 20) & 7u);
  c.th = 8 << int((c.tex >> 23) & 7u);
  c.rep_s = (c.tex & 0x10000u) != 0u;
  c.rep_t = (c.tex & 0x20000u) != 0u;
  c.fmask_s = (c.tex & 0x40000u) != 0u ? c.sw - 1 : 0;
  c.fmask_t = (c.tex & 0x80000u) != 0u ? c.th - 1 : 0;
  return c;
}
// render.nim clear: the rear plane
Px clear_px(int x, int y) {
  Px p;
  uint cc = reg(0x30 >> 2);
  p.oid = (cc >> 24) & 0x3Fu; p.tid = NO_ID; p.aacov = 31u;
  if ((uDisp & 0x4000u) != 0u) {
    uint ofs = reg16(0x356);
    int yy = (y / uK + int((ofs >> 8) & 0xFFu)) & 0xFF;
    int xx = (x / uK + int(ofs & 0xFFu)) & 0xFF;
    uint col = tex16(0x40000 + (yy * 256 + xx) * 2);
    uint dd = tex16(0x60000 + (yy * 256 + xx) * 2);
    p.color = rgb6(col) | ((col & 0x8000u) != 0u ? 31u << 24 : 0u);
    uint d15 = dd & 0x7FFFu;
    p.depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    p.flags = (dd & 0x8000u) != 0u ? FLAG_FOG : 0u;
  } else {
    p.color = rgb6(cc) | (((cc >> 16) & 31u) << 24);
    uint d15 = reg16(0x354) & 0x7FFFu;
    p.depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    p.flags = (cc & 0x8000u) != 0u ? FLAG_FOG : 0u;
  }
  p.below = p.color; p.bdepth = p.depth;
  return p;
}

int sx16(int v) { return (v << 16) >> 16; }
bool inrange(int r, int x) { return x >= (r & 0xFFFF) && x < (r >> 16); }
ivec3 unpackc(int c) { return ivec3(c & 511, (c >> 9) & 511, (c >> 18) & 511); }
// render.nim aa_cov from the rows pass's per-row data
int cov_at(int mode, int a, int b, int x, bool right) {
  if (mode == 0) return 31;
  if (mode == 1) return a;
  if (mode == 2) {
    int xm = a - (x << 18);
    int num = clamp(right ? xm : (1 << 18) - xm, 0, 1 << 18);
    if (right) return min(31, (32 * num) >> 18);
    return clamp(31 - ((32 * ((1 << 18) - num)) >> 18), 0, 31);
  }
  int h = ashr64(muls64((x << 18) + (1 << 17) - a, b), 18);
  return clamp((right ? 1023 - h : h) >> 5, 0, 31);
}

void main() {
  WS = 256 * uK; HS = 192 * uK;
  int x = int(gl_FragCoord.x), y = int(gl_FragCoord.y);   // row = line (no flip)
  Px p = clear_px(x, y);
  int tiles_x = (WS + TILE_W - 1) / TILE_W;
  uvec2 head = texelFetch(uBinHead, at1024((y / TILE_H) * tiles_x + x / TILE_W), 0).xy;
  for (uint i = 0u; i < head.y; i++) {
    int pi = int(texelFetch(uBins, at1024(int(head.x + i)), 0).x);
    ivec4 g0 = texelFetch(uPolyGeo, at1024(pi * 2), 0);
    if (x < g0.x || x > g0.y || y < g0.z || y > g0.w) continue;
    ivec2 ra = at1024(texelFetch(uPolyGeo, at1024(pi * 2 + 1), 0).w + y - max(0, g0.z));
    ivec4 r3 = texelFetch(uRec3, ra, 0);
    int kind = inrange(r3.x, x) ? 1 : inrange(r3.y, x) ? 2 : inrange(r3.z, x) ? 3 : 0;
    if (kind == 0) continue;
    ivec4 r0 = texelFetch(uRec0, ra, 0), r1 = texelFetch(uRec1, ra, 0), r2 = texelFetch(uRec2, ra, 0);
    End L, R;
    L.x = sx16(r0.x); L.c = unpackc(r0.y); L.s = r0.z; L.t = r0.w; L.z = r1.x; L.w = r1.y;
    R.x = r0.x >> 16; R.c = unpackc(r1.z); R.s = r1.w; R.t = r2.x; R.z = r2.y; R.w = r2.z;
    int flags = r2.w;
    Ctx c = make_ctx(texelFetch(uPolys, at1024(pi), 0));
    if (kind == 2) {
      plot(c, x, y, L, R, (flags & 1) != 0, 31, uint((flags >> 15) & 0x7F), p);
    } else {
      ivec4 r4 = texelFetch(uRec4, ra, 0);
      bool right = kind == 3;
      int mode = (flags >> (right ? 24 : 22)) & 3;
      int cov = cov_at(mode, right ? r4.z : r4.x, right ? r4.w : r4.y, x, right);
      plot(c, x, y, L, R, true, cov, uint((flags >> (right ? 8 : 1)) & 0x7F), p);
    }
  }
  oPx = uvec4(p.color, p.depth, p.below, p.oid | (p.tid << 8) | (p.flags << 16) | (p.aacov << 24));
}
`;

const POST = COMMON + `
uniform usampler2D uRaster;
out uint oColor;
void main() {
  ivec2 q = ivec2(gl_FragCoord.xy);
  ivec2 sz = textureSize(uRaster, 0);
  uvec4 r = texelFetch(uRaster, q, 0);
  uint color = r.x, depth = r.y, below = r.z;
  uint oid = r.w & 0xFFu, flags = (r.w >> 16) & 0xFFu;
  int cov = int(r.w >> 24);
  bool aa = (uDisp & 0x10u) != 0u;
  if (aa && cov < 31) {
    // render.nim anti_alias
    uint o = below, px = color;
    if (cov == 0) color = o;
    else if ((o >> 24) == 0u) color = (px & 0xFFFFFFu) | (uint(cov) << 24);
    else color = pack4((ch(px, 0) * (cov + 1) + ch(o, 0) * (31 - cov)) >> 5,
                       (ch(px, 1) * (cov + 1) + ch(o, 1) * (31 - cov)) >> 5,
                       (ch(px, 2) * (cov + 1) + ch(o, 2) * (31 - cov)) >> 5, 31);
  }
  if ((uDisp & 0x20u) != 0u && (flags & FLAG_EDGE) != 0u) {
    // render.nim edge_mark
    uint cc = reg(0x30 >> 2);
    uint clear_id = (cc >> 24) & 0x3Fu;
    uint d15 = reg16(0x354) & 0x7FFFu;
    uint clear_depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    bool marked = false;
    ivec2 nb[4] = ivec2[4](ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1));
    for (int i = 0; i < 4; i++) {
      ivec2 m = q + nb[i];
      if (m.x < 0 || m.y < 0 || m.x >= sz.x || m.y >= sz.y) marked = marked || (oid != clear_id && depth < clear_depth);
      else { uvec4 o = texelFetch(uRaster, m, 0); marked = marked || (oid != (o.w & 0xFFu) && depth < o.y); }
    }
    if (marked) {
      uint ec = rgb6(reg16(0x330 + int(oid >> 3) * 2));
      if (aa) {
        uint o = below;
        color = (o >> 24) == 0u ? ec | (16u << 24)
              : pack4((ch(ec, 0) * 17 + ch(o, 0) * 15) >> 5, (ch(ec, 1) * 17 + ch(o, 1) * 15) >> 5,
                      (ch(ec, 2) * 17 + ch(o, 2) * 15) >> 5, 0) | (color & 0xFF000000u);
      } else color = ec | (color & 0xFF000000u);
    }
  }
  if ((uDisp & 0x80u) != 0u && (flags & FLAG_FOG) != 0u) {
    // render.nim fog
    uint fc = reg(0x38 >> 2);
    int fr = int(expand6(fc & 31u)), fg = int(expand6((fc >> 5) & 31u)), fb = int(expand6((fc >> 10) & 31u));
    int fa = int((fc >> 16) & 31u);
    int shift = int((uDisp >> 8) & 15u);
    int step = 0x400 >> shift;
    int offset = int(reg16(0x35C) & 0x7FFFu);
    int dd = int(depth >> 9);
    int dens;
    if (step == 0) dens = int(reg8(dd < offset + step ? 0x360 : 0x360 + 31) & 0x7Fu);
    else {
      int k = (dd - offset) / step - 1;
      if (dd - offset < 0) k = -((offset - dd + step - 1) / step) - 1;   // Nim div truncates; offsets below 0 only reach table[0]
      if (k < 0) dens = int(reg8(0x360) & 0x7Fu);
      else if (k >= 31) dens = int(reg8(0x360 + 31) & 0x7Fu);
      else {
        int frac = (dd - offset) - (k + 1) * step;
        dens = (int(reg8(0x360 + k) & 0x7Fu) * (step - frac) + int(reg8(0x360 + k + 1) & 0x7Fu) * frac) / step;
      }
    }
    if (dens >= 127) dens = 128;
    int oa = int(color >> 24);
    int na = (fa * dens + oa * (128 - dens)) >> 7;
    if ((uDisp & 0x40u) != 0u) color = (color & 0xFFFFFFu) | (uint(na) << 24);
    else color = pack4((fr * dens + ch(color, 0) * (128 - dens)) >> 7, (fg * dens + ch(color, 1) * (128 - dens)) >> 7,
                       (fb * dens + ch(color, 2) * (128 - dens)) >> 7, na);
  }
  oColor = color;
}`;

// The 1x 3D frame scaled to k (the "just upscale" variant): nearest, or
// smoothed between the four nearest dots that show 3D (alpha > 0).
const UPSCALE = COMMON + `
uniform usampler2D uFrame;   // 256 x 192, the core's pixel format
uniform int uSmooth;
out uint oColor;
void main() {
  ivec2 q = ivec2(gl_FragCoord.xy);
  if (uSmooth == 0) { oColor = texelFetch(uFrame, q / uK, 0).x; return; }
  vec2 f = (vec2(q) + 0.5) / float(uK) - 0.5;
  ivec2 b = ivec2(floor(f));
  vec2 t = f - vec2(b);
  uint near = texelFetch(uFrame, clamp(ivec2(floor(f + 0.5)), ivec2(0), ivec2(255, 191)), 0).x;
  vec3 sum = vec3(0.0); float wsum = 0.0;
  for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
    uint p = texelFetch(uFrame, clamp(b + ivec2(i, j), ivec2(0), ivec2(255, 191)), 0).x;
    float w = (i == 0 ? 1.0 - t.x : t.x) * (j == 0 ? 1.0 - t.y : t.y);
    if ((p >> 24) == 0u) continue;
    sum += w * vec3(ch(p, 0), ch(p, 1), ch(p, 2));
    wsum += w;
  }
  if ((near >> 24) == 0u || wsum == 0.0) { oColor = near; return; }
  ivec3 c = ivec3(sum / wsum + 0.5);
  oColor = pack4(c.x, c.y, c.z, int(near >> 24));
}`;

// Engine A at HD (gpu.nim hd_line): its composite per HD dot by hd_dot's
// rules (engine2d.nim effect_dot / bright_dot), VRAM display from the
// banks' HD copies, and display capture into them.
const COMPOSE = COMMON + `
uniform usampler2D uScreens;  // 256 x 384 BGR555, top over bottom
uniform usampler2D uPlane;    // 256 x 192: gpu_paint_line's 4 words a dot
uniform usampler2D uPlane2;   // 256 x 192: gpu_valid's 4 words a dot
uniform usampler2D uLines;    // 384 x 1: gpu_line's 8 words a line
uniform usampler2D u3d;       // 256k x 192k, the core's pixel format
uniform usampler2D uCap0, uCap1, uCap2, uCap3;   // banks A-D's HD copies (BGR555 + bit 15)
const int LAYER_OBJ = 4;
const uint OBJ_SEMI = 0x10u, OBJ_BITMAP = 0x20u;
uvec4 line0(int y) { return texelFetch(uLines, ivec2(y * 2, 0), 0); }
uvec4 line1(int y) { return texelFetch(uLines, ivec2(y * 2 + 1, 0), 0); }
uint ch6(uint c, uint lo, int i) { return (((c >> uint(5 * i)) & 0x1Fu) << 1) | ((lo >> uint(i)) & 1u); }
uint pack6(uint r, uint g, uint b, out uint lo) {
  lo = (r & 1u) | ((g & 1u) << 1) | ((b & 1u) << 2);
  return (r >> 1) | ((g >> 1) << 5) | ((b >> 1) << 10);
}
uint blend_alpha(uint a, uint la, uint b, uint lb, uint eva, uint evb, out uint lo) {
  uint r = min(63u, (ch6(a, la, 0) * eva + ch6(b, lb, 0) * evb + 8u) >> 4);
  uint g = min(63u, (ch6(a, la, 1) * eva + ch6(b, lb, 1) * evb + 8u) >> 4);
  uint bb = min(63u, (ch6(a, la, 2) * eva + ch6(b, lb, 2) * evb + 8u) >> 4);
  return pack6(r, g, bb, lo);
}
uint brighten(uint a, uint la, uint evy, out uint lo) {
  uint r = ch6(a, la, 0), g = ch6(a, la, 1), b = ch6(a, la, 2);
  return pack6(r + (((63u - r) * evy + 8u) >> 4), g + (((63u - g) * evy + 8u) >> 4),
               b + (((63u - b) * evy + 8u) >> 4), lo);
}
uint darken(uint a, uint la, uint evy, out uint lo) {
  return pack6((ch6(a, la, 0) * (16u - evy) + 8u) >> 4, (ch6(a, la, 1) * (16u - evy) + 8u) >> 4,
               (ch6(a, la, 2) * (16u - evy) + 8u) >> 4, lo);
}
uint blend_3d(uint p, uint below, uint lb, out uint lo) {
  uint a = (p >> 24) & 31u;
  uint r = (((p) & 0x3Fu) * (a + 1u) + ch6(below, lb, 0) * (31u - a) + 16u) >> 5;
  uint g = (((p >> 8) & 0x3Fu) * (a + 1u) + ch6(below, lb, 1) * (31u - a) + 16u) >> 5;
  uint b = (((p >> 16) & 0x3Fu) * (a + 1u) + ch6(below, lb, 2) * (31u - a) + 16u) >> 5;
  return pack6(r, g, b, lo);
}
// MASTER_BRIGHT on one dot (bright_dot); mode 0 or 3, or factor 0: none
uint bright(uint c, uint lo, uint mb) {
  uint mode = mb >> 14, f = min(16u, mb & 0x1Fu);
  if (mode == 0u || mode == 3u || f == 0u) return c;
  uint r = ch6(c, lo, 0), g = ch6(c, lo, 1), b = ch6(c, lo, 2);
  if (mode == 1u) {
    r = (r * 16u + (63u - r) * f) >> 4; g = (g * 16u + (63u - g) * f) >> 4; b = (b * 16u + (63u - b) * f) >> 4;
  } else {
    r = (r * (16u - f)) >> 4; g = (g * (16u - f)) >> 4; b = (b * (16u - f)) >> 4;
  }
  return (r >> 1) | ((g >> 1) << 5) | ((b >> 1) << 10);
}
uint to_bgr555(uint p) { return ((p >> 1) & 31u) | (((p >> 9) & 31u) << 5) | (((p >> 17) & 31u) << 10); }
uint lsb3d(uint p) { return (p & 1u) | ((p >> 7) & 2u) | ((p >> 14) & 4u); }
// sub-dot (i, j) of halfword d of a bank's HD copy
uint cap_at(int bank, int d, int i, int j) {
  ivec2 t = ivec2((d & 255) * uK + i, (d >> 8) * uK + j);
  if (bank == 0) return texelFetch(uCap0, t, 0).x;
  if (bank == 1) return texelFetch(uCap1, t, 0).x;
  if (bank == 2) return texelFetch(uCap2, t, 0).x;
  return texelFetch(uCap3, t, 0).x;
}
// Engine A's composite of dot x on line y at sub-dot (i, j): the graphics
// (capture source A, before master brightness) or the display dot.
uint compose(int x, int y, int i, int j, bool gfx) {
  uvec4 li = line0(y);
  uvec4 pl = texelFetch(uPlane, ivec2(x, y), 0);
  uint one = gfx ? texelFetch(uPlane2, ivec2(x, y), 0).x & 0xFFFFu : pl.z >> 16;   // the 1x dot
  if ((li.x & 1u) == 0u) return one;
  int sx = (x + int((li.w >> 8) & 511u)) & 511;
  if (sx >= 256) return one;
  uint p = texelFetch(u3d, ivec2(sx * uK + i, y * uK + j), 0).x;
  if ((p >> 24) == 0u) return gfx ? pl.w & 0xFFFFu : pl.z & 0xFFFFu;
  int l0 = int(pl.y & 0xFFu), l1 = int((pl.y >> 8) & 0xFFu);
  if (l0 != 0 && l1 != 0) return one;
  uint m = (pl.y >> 16) & 0xFFu, attr = pl.y >> 24;
  uint bld = li.y & 0xFFFFu, mode = li.y >> 16;
  uint eva = li.z & 0xFFu, evb = (li.z >> 8) & 0xFFu, evy = (li.z >> 16) & 0xFFu, bmode = li.z >> 24;
  uint bfactor = li.w & 0xFFu;
  uint c3 = to_bgr555(p);
  uint ctop = l0 == 0 ? c3 : pl.x & 0xFFFFu;
  uint csec = l1 == 0 ? c3 : pl.x >> 16;
  uint lo0 = l0 == 0 ? lsb3d(p) : 0u, lo1 = l1 == 0 ? lsb3d(p) : 0u;
  uint lo = lo0;
  uint c = ctop;
  if ((m & 0x20u) != 0u) {
    bool bot_second = l1 != 0xFF && (bld & (0x100u << uint(l1))) != 0u;
    if (l0 == LAYER_OBJ && (attr & (OBJ_SEMI | OBJ_BITMAP)) != 0u && bot_second) {
      if ((attr & OBJ_BITMAP) != 0u) { uint a = attr & 0xFu; c = blend_alpha(c, lo0, csec, lo1, a + 1u, 15u - a, lo); }
      else c = blend_alpha(c, lo0, csec, lo1, eva, evb, lo);
    } else if (l0 == 0 && bot_second) c = blend_3d(p, csec, lo1, lo);
    else if (l0 < 32 && (bld & (1u << uint(l0))) != 0u) {
      if (mode == 1u) { if (bot_second) c = blend_alpha(c, lo0, csec, lo1, eva, evb, lo); }
      else if (mode == 2u) c = brighten(c, lo0, evy, lo);
      else if (mode == 3u) c = darken(c, lo0, evy, lo);
    }
  }
  if (gfx) return c;
  return bmode == 0u ? c : bright(c, lo, (bmode << 14) | bfactor);
}
`;

// Both screens at k: engine A's lines composited at HD where they show 3D
// or VRAM display; everything else is the 1x screens' dot.
const COMPOSITE = COMPOSE + `
out uint oColor;
void main() {
  ivec2 q = ivec2(gl_FragCoord.xy);
  int k = uK;
  int scr = q.y >= 192 * k ? 1 : 0;
  int Y = q.y - scr * 192 * k;
  int y = Y / k, x = q.x / k, i = q.x % k, j = Y % k;
  uvec4 li = line0(y);
  oColor = texelFetch(uScreens, ivec2(x, scr * 192 + y), 0).x;
  if ((scr == 0) != ((li.x & 2u) != 0u)) return;
  if ((li.x & 5u) == 5u) oColor = compose(x, y, i, j, false);
  else if ((li.x & 8u) != 0u && (texelFetch(uPlane2, ivec2(x, y), 0).z & 1u) != 0u) {
    uvec4 l1 = line1(y);
    oColor = bright(cap_at(int(l1.y), y * 256 + x, i, j) & 0x7FFFu, 0u, l1.z);
  }
}`;

// Display capture at k (gpu.nim hd_line's capture part): every sub-dot of
// the destination bank's HD copy, the captured halfwords' from this
// frame's lines, the rest as they were (uCapCur, the same bank).
const CAPTURE = COMPOSE + `
uniform usampler2D uCapCur;
uniform uint uCapc;
out uint oColor;
const ivec2 CAPTURE_SIZE[4] = ivec2[4](ivec2(128, 128), ivec2(256, 64), ivec2(256, 128), ivec2(256, 192));
void main() {
  ivec2 q = ivec2(gl_FragCoord.xy);
  int wd = (q.y / uK) * 256 + q.x / uK, i = q.x % uK, j = q.y % uK;
  ivec2 size = CAPTURE_SIZE[(uCapc >> 20) & 3u];
  int rel = (wd - int((uCapc >> 18) & 3u) * 0x4000) & 0xFFFF;
  int y = rel / size.x, x = rel % size.x;
  oColor = texelFetch(uCapCur, q, 0).x;
  if (y >= size.y || (line0(y).x & 16u) == 0u) return;
  uint capc = line1(y).x;
  uint csrc = (capc >> 29) & 3u;
  uint eva = min(16u, capc & 0x1Fu), evb = min(16u, (capc >> 8) & 0x1Fu);
  uvec4 p2 = texelFetch(uPlane2, ivec2(x, y), 0);
  uint ca = 0u, cb = 0u;
  if (csrc != 1u) {
    if ((capc & (1u << 24)) != 0u) {
      uint p = texelFetch(u3d, ivec2(x * uK + i, y * uK + j), 0).x;
      ca = to_bgr555(p) | ((p >> 24) != 0u ? 0x8000u : 0u);
    } else ca = compose(x, y, i, j, true) | 0x8000u;
  }
  if (csrc != 0u) {
    if ((capc & (1u << 25)) != 0u) cb = p2.y >> 16;
    else if ((p2.z & 2u) != 0u) {
      int dm = int((line0(y).x >> 8) & 3u);
      int roff = dm == 2 ? 0 : int((capc >> 26) & 3u) * 0x8000;
      int rd = ((roff + y * size.x * 2 + x * 2) & 0x1FFFF) >> 1;
      cb = cap_at(int(line1(y).y), rd, i, j);
    } else cb = p2.y & 0xFFFFu;
  }
  if (csrc == 0u) { oColor = ca; return; }
  if (csrc == 1u) { oColor = cb; return; }
  uint aa = (ca & 0x8000u) != 0u ? eva : 0u;
  uint ab = (cb & 0x8000u) != 0u ? evb : 0u;
  uint c = 0u;
  for (int s = 0; s < 15; s += 5)
    c |= min(31u, (((ca >> uint(s)) & 0x1Fu) * aa + ((cb >> uint(s)) & 0x1Fu) * ab) >> 4) << uint(s);
  oColor = c | (aa > 0u || ab > 0u ? 0x8000u : 0u);
}`;

// BGR555 screens to the canvas (flipped: texture row 0 is the top line)
const PRESENT = `#version 300 es
precision highp float;
precision highp usampler2D;
uniform usampler2D uScreens;
uniform vec2 uOut;
out vec4 o;
void main() {
  ivec2 sz = textureSize(uScreens, 0);
  vec2 uv = vec2(gl_FragCoord.x, uOut.y - gl_FragCoord.y) / uOut;
  uint c = texelFetch(uScreens, ivec2(uv * vec2(sz)), 0).x;
  o = vec4(float(c & 31u), float((c >> 5) & 31u), float((c >> 10) & 31u), 31.0) / 31.0;
}`;

export class NdsGpu3d {
  constructor(gl) {
    this.gl = gl;
    this.k = 0;
    const prog = (fs) => {
      const p = gl.createProgram();
      for (const [type, src] of [[gl.VERTEX_SHADER, VERT], [gl.FRAGMENT_SHADER, fs]]) {
        const s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
        gl.attachShader(p, s);
      }
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      const loc = {};
      const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
      for (let i = 0; i < n; i++) {
        const name = gl.getActiveUniform(p, i).name.replace(/\[0\]$/, "");
        loc[name] = gl.getUniformLocation(p, name);
      }
      return { p, loc };
    };
    this.rowsProg = prog(ROWS);
    this.raster = prog(RASTER);
    this.rowsFbo = gl.createFramebuffer();
    this.post = prog(POST);
    this.upscaleProg = prog(UPSCALE);
    this.compositeProg = prog(COMPOSITE);
    this.captureProg = prog(CAPTURE);
    this.presentProg = prog(PRESENT);
    this.vao = gl.createVertexArray();
    this.fbo = gl.createFramebuffer();
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    // (textures are made and filled on a unit no pass binds, so that doing
    // it while a pass is being set up leaves that pass's inputs alone)
    this.scratchUnit = gl.TEXTURE0 + gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS) - 1;
    const tex = (w, h, fmt) => {
      const t = gl.createTexture();
      gl.activeTexture(this.scratchUnit);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texStorage2D(gl.TEXTURE_2D, 1, fmt, w, h);
      for (const p of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, p, gl.NEAREST);
      for (const p of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T]) gl.texParameteri(gl.TEXTURE_2D, p, gl.CLAMP_TO_EDGE);
      return { t, w, h, fmt };
    };
    this.tex = tex;
    this.polys = tex(ROW, MAX_POLYS / ROW, gl.RGBA32UI);
    this.polyGeo = tex(ROW, (MAX_POLYS * 2) / ROW, gl.RGBA32I);
    this.verts = tex(ROW, (MAX_VERTS * 2) / ROW, gl.RGBA32I);
    this.bins = tex(ROW, MAX_BINS / ROW, gl.R32UI);
    this.binHead = null;   // per scale (setScale)
    this.vram = tex(1024, 512, gl.R8UI);
    this.pal = tex(1024, 96, gl.R8UI);
    this.frame1x = tex(256, 192, gl.R32UI);
    this.screens1x = tex(256, 384, gl.R16UI);
    this.plane = tex(256, 192, gl.RGBA32UI);
    this.plane2 = tex(256, 192, gl.RGBA32UI);
    this.lines = tex(384, 1, gl.RGBA32UI);
    this.lineData = null;
    this.regs = new Uint32Array(40);
    this.disp = 0;
    this.swap = 0;
    this.texVer = -1;
    this.polyData = new Uint32Array(MAX_POLYS * 4);
    this.geoData = new Int32Array(MAX_POLYS * 8);
    this.vertData = new Int32Array(MAX_VERTS * 8);
    this.binData = new Uint32Array(MAX_BINS);
    this.timer = gl.getExtension("EXT_disjoint_timer_query_webgl2");
  }

  setScale(k) {
    if (k === this.k) return;
    const gl = this.gl;
    for (const t of [this.rasterOut, this.out3d, this.screens, this.binHead]) if (t) gl.deleteTexture(t.t);
    for (const b of this.caps || []) if (b) { gl.deleteTexture(b.cur.t); gl.deleteTexture(b.next.t); }
    // banks A-D's HD copies (display capture), made when first captured into
    this.caps = [null, null, null, null];
    this.k = k;
    this.tilesX = Math.ceil((256 * k) / TILE_W);
    this.tilesY = Math.ceil((192 * k) / TILE_H);
    const nt = this.tilesX * this.tilesY;
    this.binHead = this.tex(ROW, Math.ceil(nt / ROW), gl.RG32UI);
    this.headData = new Uint32Array(Math.ceil(nt / ROW) * ROW * 2);
    this.tileCounts = new Uint32Array(nt);
    this.rasterOut = this.tex(256 * k, 192 * k, gl.RGBA32UI);
    this.out3d = this.tex(256 * k, 192 * k, gl.R32UI);
    this.screens = this.tex(256 * k, 384 * k, gl.R16UI);
  }

  upload(t, data, w, h, format, type) {
    const gl = this.gl;
    gl.activeTexture(this.scratchUnit);
    gl.bindTexture(gl.TEXTURE_2D, t.t);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, format, type, data);
  }

  // The scene words (gpuexport.nim); tex/pal when the scene's texture
  // generation is new. Returns the JS time spent (ms).
  setScene(scene, texImage, palImage) {
    const t0 = performance.now();
    const gl = this.gl, k = this.k, HS = 192 * k;
    const np = scene[1], nv = scene[2];
    this.disp = scene[3];
    this.swap = scene[4];
    this.regs.set(scene.subarray(8, 48));
    const texVer = scene[7];
    if (texImage && texVer !== this.texVer) {
      this.upload(this.vram, texImage, 1024, 512, gl.RED_INTEGER, gl.UNSIGNED_BYTE);
      this.upload(this.pal, palImage, 1024, 96, gl.RED_INTEGER, gl.UNSIGNED_BYTE);
      this.texVer = texVer;
    }
    // vertices at k: floor(position * k / 192), render_hd's placement
    const V0 = HEADER + np * POLY_WORDS;
    const vd = this.vertData;
    for (let i = 0; i < nv; i++) {
      const o = V0 + i * VERT_WORDS;
      vd[i * 8] = Math.floor(((scene[o] | 0) * k) / 192);
      vd[i * 8 + 1] = Math.floor(((scene[o + 1] | 0) * k) / 192);
      vd[i * 8 + 2] = scene[o + 2] | 0;
      vd[i * 8 + 3] = scene[o + 3] | 0;
      vd[i * 8 + 4] = scene[o + 4] | 0;
      vd[i * 8 + 5] = scene[o + 5] | 0;
      vd[i * 8 + 6] = scene[o + 6] | 0;
      vd[i * 8 + 7] = 0;
    }
    // per polygon: its extent, top vertex, line / flat-bottom flags, and
    // the tiles its bounding box touches
    const pd = this.polyData, gd = this.geoData, head = this.headData;
    pd.set(scene.subarray(HEADER, HEADER + np * POLY_WORDS));
    const WS = 256 * k, tx = this.tilesX, counts = this.tileCounts;
    counts.fill(0);
    const box = new Int32Array(np * 4);
    const grow = (a, n) => {
      if (a && a.length >= n) return a;
      const b = new Uint32Array(Math.max(n, 2 * (a ? a.length : 0), ROW * 64));
      if (a) b.set(a);
      return b;
    };
    let recs = 0;
    for (let p = 0; p < np; p++) {
      const w3 = scene[HEADER + p * 4 + 3];
      const first = w3 & 0xFFFF, n = (w3 >>> 16) & 0xFF;
      let xmin = 1 << 30, xmax = -(1 << 30), ymin = 1 << 30, ymax = -(1 << 30), top = 0;
      let line = true, o = -1, bx = -1, flat = false;
      for (let i = 0; i < n; i++) {
        const x = vd[(first + i) * 8], y = vd[(first + i) * 8 + 1];
        xmin = Math.min(xmin, x); xmax = Math.max(xmax, x);
        ymin = Math.min(ymin, y); ymax = Math.max(ymax, y);
        if (i > 0 && y < vd[(first + top) * 8 + 1]) top = i;
        if (i > 0 && (x !== vd[first * 8] || y !== vd[first * 8 + 1])) {
          if (o < 0) o = i;
          else if (x !== vd[(first + o) * 8] || y !== vd[(first + o) * 8 + 1]) line = false;
        }
      }
      for (let i = 0; i < n; i++) {
        if (vd[(first + i) * 8 + 1] !== ymax) continue;
        const x = vd[(first + i) * 8];
        if (bx < 0) bx = x; else if (x !== bx) flat = true;
      }
      const last = ymin === ymax ? ymin : ymax - 1;
      gd.set([xmin - 1, xmax + 1, ymin, last, top, (line ? 1 : 0) | (flat ? 2 : 0), ymax, 0], p * 8);
      // (dots lie within one of the vertices' columns: a vertical right
      // edge covers the dot left of it)
      const x0 = Math.max(0, xmin - 1), x1 = Math.min(WS - 1, xmax + 1);
      const y0 = Math.max(0, ymin), y1 = Math.min(HS - 1, last);
      // its rows' records for the rows pass: from recs on, one per row
      gd[p * 8 + 7] = recs;
      if (n < 1 || n > 16 || x0 > x1 || y0 > y1) { box[p * 4] = 1; box[p * 4 + 1] = 0; continue; }
      this.recPolyData = grow(this.recPolyData, recs + y1 - y0 + 1);
      this.recPolyData.fill(p, recs, recs + y1 - y0 + 1);
      recs += y1 - y0 + 1;
      box.set([Math.floor(x0 / TILE_W), Math.floor(x1 / TILE_W), Math.floor(y0 / TILE_H), Math.floor(y1 / TILE_H)], p * 4);
      for (let ty = box[p * 4 + 2]; ty <= box[p * 4 + 3]; ty++)
        for (let t = box[p * 4]; t <= box[p * 4 + 1]; t++) counts[ty * tx + t]++;
    }
    let total = 0;
    for (let t = 0; t < counts.length; t++) { head[t * 2] = total; head[t * 2 + 1] = 0; total += counts[t]; }
    if (total > MAX_BINS) throw new Error(`gpu3d: ${total} bin entries`);
    const bins = this.binData;
    for (let p = 0; p < np; p++) {
      for (let ty = box[p * 4 + 2]; ty <= box[p * 4 + 3]; ty++)
        for (let t = box[p * 4]; t <= box[p * 4 + 1]; t++) {
          const i = ty * tx + t;
          bins[head[i * 2] + head[i * 2 + 1]++] = p;
        }
    }
    const rows = (n) => Math.max(1, Math.ceil(n / ROW));
    this.upload(this.polys, pd, ROW, rows(np), gl.RGBA_INTEGER, gl.UNSIGNED_INT);
    this.upload(this.polyGeo, gd, ROW, rows(np * 2), gl.RGBA_INTEGER, gl.INT);
    this.upload(this.verts, vd, ROW, rows(nv * 2), gl.RGBA_INTEGER, gl.INT);
    this.upload(this.bins, bins, ROW, rows(total), gl.RED_INTEGER, gl.UNSIGNED_INT);
    this.upload(this.binHead, head, ROW, this.binHead.h, gl.RG_INTEGER, gl.UNSIGNED_INT);
    this.binTotal = total;
    // the records' textures, grown to fit (5 RGBA32I texels a record)
    const recRows = rows(recs);
    if (!this.recPoly || this.recPoly.h < recRows) {
      for (const t of [this.recPoly, ...(this.rec || [])]) if (t) gl.deleteTexture(t.t);
      const h = Math.max(64, 2 ** Math.ceil(Math.log2(recRows)));
      this.recPoly = this.tex(ROW, h, gl.R32UI);
      this.rec = [0, 1, 2, 3, 4].map(() => this.tex(ROW, h, gl.RGBA32I));
    }
    if (recs > 0) this.upload(this.recPoly, this.recPolyData, ROW, recRows, gl.RED_INTEGER, gl.UNSIGNED_INT);
    this.recTotal = recs;
    return performance.now() - t0;
  }

  bindTex(prog, name, unit, t) {
    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, t.t);
    gl.uniform1i(prog.loc[name], unit);
  }

  pass(prog, target, setup) {
    const gl = this.gl;
    gl.useProgram(prog.p);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target.t, 0);
    gl.viewport(0, 0, target.w, target.h);
    if (prog.loc.uRegs) gl.uniform4uiv(prog.loc.uRegs, this.regs);
    if (prog.loc.uDisp) gl.uniform1ui(prog.loc.uDisp, this.disp);
    if (prog.loc.uK) gl.uniform1i(prog.loc.uK, this.k);
    setup(prog);
    gl.bindVertexArray(this.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // A frame's 3D (the core's exports): the frame's render, then any later
  // ones a render-register write made mid-frame, each for its lines on
  // (late: [{ scene, line }], gpu3d.nim export_gpu).
  drawFrame(scene, texImage, palImage, late = []) {
    this.setScene(scene, texImage, palImage);
    this.render(0, 0, late.length ? late[0].line : 192);
    late.forEach((part, i) => {
      this.setScene(part.scene, null, null);
      this.render(0, part.line, i + 1 < late.length ? late[i + 1].line : 192);
    });
  }

  // The scene at k: raster, then the post passes, into out3d (its lines
  // from .. to-1, at 1x: the rest stay as they were).
  render(ablate = 0, from = 0, to = 192) {
    const gl = this.gl;
    if (this.recTotal > 0) {
      // the rows pass: one fragment per record, five targets
      const rp = this.rowsProg;
      gl.useProgram(rp.p);
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.rowsFbo);
      this.rec.forEach((t, i) =>
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0 + i, gl.TEXTURE_2D, t.t, 0));
      gl.drawBuffers(this.rec.map((_, i) => gl.COLOR_ATTACHMENT0 + i));
      gl.viewport(0, 0, ROW, Math.ceil(this.recTotal / ROW));
      gl.uniform4uiv(rp.loc.uRegs, this.regs);
      gl.uniform1ui(rp.loc.uDisp, this.disp);
      gl.uniform1i(rp.loc.uK, this.k);
      gl.uniform1ui(rp.loc.uSwap, this.swap);
      gl.uniform1i(rp.loc.uTotal, this.recTotal);
      this.bindTex(rp, "uPolys", 0, this.polys);
      this.bindTex(rp, "uPolyGeo", 1, this.polyGeo);
      this.bindTex(rp, "uVerts", 2, this.verts);
      this.bindTex(rp, "uRecPoly", 3, this.recPoly);
      gl.bindVertexArray(this.vao);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    this.pass(this.raster, this.rasterOut, (p) => {
      gl.uniform1ui(p.loc.uSwap, this.swap);
      gl.uniform1i(p.loc.uAblate, ablate);
      this.bindTex(p, "uPolys", 0, this.polys);
      this.bindTex(p, "uPolyGeo", 1, this.polyGeo);
      this.bindTex(p, "uBins", 3, this.bins);
      this.bindTex(p, "uBinHead", 4, this.binHead);
      this.bindTex(p, "uVram", 5, this.vram);
      this.bindTex(p, "uPal", 6, this.pal);
      for (let i = 0; i < 5; i++) this.bindTex(p, `uRec${i}`, 7 + i, this.rec[i]);
    });
    const part = from > 0 || to < 192;
    if (part) {
      gl.enable(gl.SCISSOR_TEST);
      gl.scissor(0, from * this.k, 256 * this.k, (to - from) * this.k);
    }
    this.pass(this.post, this.out3d, (p) => this.bindTex(p, "uRaster", 0, this.rasterOut));
    if (part) gl.disable(gl.SCISSOR_TEST);
  }

  // The "just upscale" variant: the core's 1x 3D frame scaled into out3d.
  upscale(frame3d, smooth) {
    const gl = this.gl;
    this.upload(this.frame1x, frame3d, 256, 192, gl.RED_INTEGER, gl.UNSIGNED_INT);
    this.pass(this.upscaleProg, this.out3d, (p) => {
      gl.uniform1i(p.loc.uSmooth, smooth ? 1 : 0);
      this.bindTex(p, "uFrame", 0, this.frame1x);
    });
  }

  // An HD 3D frame from elsewhere (the software renderer's, for checks).
  set3d(hd3d) {
    const gl = this.gl;
    this.upload(this.out3d, hd3d, 256 * this.k, 192 * this.k, gl.RED_INTEGER, gl.UNSIGNED_INT);
  }

  // A bank's HD copy (display capture): two textures, the current one
  // and the one the next capture writes.
  bank(b) {
    if (!this.caps[b]) {
      const gl = this.gl, n = 256 * this.k;
      const t = () => {
        const x = this.tex(n, n, gl.R16UI);
        this.upload(x, new Uint16Array(n * n), n, n, gl.RED_INTEGER, gl.UNSIGNED_SHORT);
        return x;
      };
      this.caps[b] = { cur: t(), next: t() };
    }
    return this.caps[b];
  }

  bindCompose(p) {
    this.bindTex(p, "uScreens", 0, this.screens1x);
    this.bindTex(p, "uPlane", 1, this.plane);
    this.bindTex(p, "uPlane2", 2, this.plane2);
    this.bindTex(p, "uLines", 3, this.lines);
    this.bindTex(p, "u3d", 4, this.out3d);
    for (let b = 0; b < 4; b++) this.bindTex(p, `uCap${b}`, 5 + b, this.bank(b).cur);
  }

  // Both screens at k from the 1x screens, engine A's planes and out3d,
  // then display capture into the banks' HD copies (gpu.nim gpu_line's
  // exports; null arguments keep what was uploaded last). screens1x: both
  // screens (256 x 384), or [top, bottom].
  composite(screens1x, plane, plane2, lines, capture = true) {
    const gl = this.gl;
    if (Array.isArray(screens1x)) {
      gl.activeTexture(this.scratchUnit);
      gl.bindTexture(gl.TEXTURE_2D, this.screens1x.t);
      screens1x.forEach((s, i) =>
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 192 * i, 256, 192, gl.RED_INTEGER, gl.UNSIGNED_SHORT, s));
    } else if (screens1x) this.upload(this.screens1x, screens1x, 256, 384, gl.RED_INTEGER, gl.UNSIGNED_SHORT);
    if (plane) this.upload(this.plane, plane, 256, 192, gl.RGBA_INTEGER, gl.UNSIGNED_INT);
    if (plane2) this.upload(this.plane2, plane2, 256, 192, gl.RGBA_INTEGER, gl.UNSIGNED_INT);
    if (lines) {
      this.upload(this.lines, lines, 384, 1, gl.RGBA_INTEGER, gl.UNSIGNED_INT);
      this.lineData = lines;
    }
    this.pass(this.compositeProg, this.screens, (p) => this.bindCompose(p));
    // capture: the first captured line's settings say where
    const ld = this.lineData;
    let y = 0;
    while (ld && y < 192 && !(ld[y * 8] & 16)) y++;
    if (!capture || !ld || y === 192) return;
    const capc = ld[y * 8 + 4] >>> 0, dst = (capc >>> 16) & 3;
    const bank = this.bank(dst);
    this.pass(this.captureProg, bank.next, (p) => {
      this.bindCompose(p);
      this.bindTex(p, "uCapCur", 9, bank.cur);
      gl.uniform1ui(p.loc.uCapc, capc);
    });
    [bank.cur, bank.next] = [bank.next, bank.cur];
  }

  // Leave the context as a presenter sharing it expects: the default
  // framebuffer and vertex array, texture unit 0, its unpack alignment.
  restore() {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.bindVertexArray(null);
    gl.activeTexture(gl.TEXTURE0);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
  }

  present(w, h) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, w, h);
    gl.useProgram(this.presentProg.p);
    this.bindTex(this.presentProg, "uScreens", 0, this.screens);
    gl.uniform2f(this.presentProg.loc.uOut, w, h);
    gl.bindVertexArray(this.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // Read back a target (row 0 = the top line): Uint32Array for R32UI,
  // Uint16Array (from 32-bit reads) for R16UI.
  read(t) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.t, 0);
    const out = new Uint32Array(t.w * t.h * 4);
    gl.readPixels(0, 0, t.w, t.h, gl.RGBA_INTEGER, gl.UNSIGNED_INT, out);
    const one = t.fmt === gl.R16UI ? new Uint16Array(t.w * t.h) : new Uint32Array(t.w * t.h);
    for (let i = 0; i < one.length; i++) one[i] = out[i * 4];
    return one;
  }
}
