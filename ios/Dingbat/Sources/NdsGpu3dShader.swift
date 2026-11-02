// The Metal kernels of NdsGpu3d.swift: web/nds/gpu3d.js's shaders ported
// to the Metal shading language (docs/nds/gpu3d.md). The logic per dot is
// the WebGL renderer's line for line, so the two (and the software HD
// renderer, RendererOf[k]) agree dot for dot; what differs is the plumbing:
// compute kernels over buffers in place of fragment passes over 1024-wide
// data textures. Compiled at run time, as PresentShader.swift is.
//
// Kernels: rows (one thread per (polygon, row) record: draw_polygon's row
// setup), raster (one per dot at k: the binned polygons in drawing order),
// post (anti-aliasing, edge marking, fog), composite (both screens at k,
// BGR555, into the presenter's texture) and capture (display capture into
// a bank's HD copy).

let ndsGpu3dShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct U {
  uint4 regs[10];   // 0x4000320-0x40003BF
  uint disp;        // DISP3DCNT
  int k;
  uint swap;
  int total;        // rows: the records
  uint capc;        // capture: DISPCAPCNT of the first captured line
  int tilesX;
  int from_, to_;   // post: lines [from_, to_) at 1x
};

constant uint FLAG_FOG = 1u, FLAG_EDGE = 2u, FLAG_STENCIL = 4u;
constant uint NO_ID = 255u;
constant uint ROLE_LEFT = 8u, ROLE_RIGHT = 16u, ROLE_TOP = 32u, ROLE_BOTTOM = 64u;
constant int TILE_W = 32, TILE_H = 8;

// (GLSL's int arithmetic wraps; in C++ terms a left shift of a negative
// value is undefined, so those go through uint)
static inline int shl(int a, int s) { return as_type<int>(as_type<uint>(a) << uint(s)); }

static inline uint reg(constant U& u, int word) { return u.regs[word >> 2][word & 3]; }
static inline uint reg16(constant U& u, int off) { int i = off - 0x320; return (reg(u, i >> 2) >> uint(8 * (i & 2))) & 0xFFFFu; }
static inline uint reg8(constant U& u, int off) { int i = off - 0x320; return (reg(u, i >> 2) >> uint(8 * (i & 3))) & 0xFFu; }
static inline uint expand6(uint c5) { return c5 * 2u + (c5 + 31u) / 32u; }
static inline uint rgb6(uint c) {
  return expand6(c & 31u) | (expand6((c >> 5) & 31u) << 8) | (expand6((c >> 10) & 31u) << 16);
}
static inline int ch(uint c, int i) { return int((c >> uint(8 * i)) & 0x3Fu); }
static inline uint pack4(int r, int g, int b, int a) {
  return uint(r) | (uint(g) << 8) | (uint(b) << 16) | (uint(a) << 24);
}

// --- 64-bit values as (low, high) words, two's complement
static inline uint2 mulu64(uint a, uint b) {
  uint a0 = a & 0xFFFFu, a1 = a >> 16, b0 = b & 0xFFFFu, b1 = b >> 16;
  uint p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint mid = (p00 >> 16) + (p01 & 0xFFFFu) + (p10 & 0xFFFFu);
  return uint2((p00 & 0xFFFFu) | (mid << 16), p11 + (p01 >> 16) + (p10 >> 16) + (mid >> 16));
}
static inline uint2 neg64(uint2 x) { uint lo = ~x.x + 1u; return uint2(lo, ~x.y + (lo == 0u ? 1u : 0u)); }
static inline uint2 add64(uint2 a, uint2 b) { uint lo = a.x + b.x; return uint2(lo, a.y + b.y + (lo < a.x ? 1u : 0u)); }
static inline uint2 muls64(int a, int b) {
  uint2 p = mulu64(uint(abs(a)), uint(abs(b)));
  return ((a < 0) != (b < 0)) ? neg64(p) : p;
}
static inline bool isneg64(uint2 x) { return as_type<int>(x.y) < 0; }
static inline bool ltu64(uint2 a, uint2 b) { return a.y < b.y || (a.y == b.y && a.x < b.x); }
static inline uint2 shl64(uint2 x, int s) { return uint2(x.x << uint(s), (x.y << uint(s)) | (x.x >> uint(32 - s))); }
// x >> s (arithmetic, 0 < s < 32) where the result fits in 32 bits
static inline int ashr64(uint2 x, int s) { return as_type<int>((x.x >> uint(s)) | (x.y << uint(32 - s))); }
static inline uint2 mul64x32(uint2 b, uint q) { uint2 p = mulu64(b.x, q); return uint2(p.x, p.y + b.y * q); }

static inline int floordiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }   // b > 0
static inline int truncdiv2(int a) { return a >= 0 ? a / 2 : -((-a) / 2); }
// a + floor((b - a) * n / d), exactly (render.nim lin / edge_end's li), d > 0
static inline int lin(int a, int b, int n, int d) {
  int dd = b - a;
  int q = floordiv(dd, d);
  int r = dd - q * d;
  return a + q * n + floordiv(r * n, d);
}
// render.nim pfac: floor(n * w0 * 2^P / (n * w0 + (d - n) * w1)), truncated toward zero
static int pfac(int n, int d, int w0, int w1, int P) {
  uint2 num = muls64(n, w0);
  uint2 den = add64(num, muls64(d - n, w1));
  if (den.x == 0u && den.y == 0u) return 0;
  uint2 N = shl64(num, P);
  bool sn = isneg64(N), sd = isneg64(den);
  uint2 a = sn ? neg64(N) : N;
  uint2 b = sd ? neg64(den) : den;
  float fa = float(a.y) * 4294967296.0f + float(a.x);
  float fb = float(b.y) * 4294967296.0f + float(b.x);
  int q = int(min(fa / fb, 1073741824.0f));
  for (int i = 0; i < 4; i++) {
    uint2 qb = mul64x32(b, uint(q));
    if (ltu64(a, qb)) { q--; continue; }
    if (!ltu64(a, add64(qb, b))) { q++; continue; }
    break;
  }
  return sn != sd ? -q : q;
}

// --- texture memory (render.nim tex8/pal16, texel_uv)
struct Mem { device const uchar* vram; device const uchar* pal; };
static inline uint tex8(Mem m, int a) { return m.vram[a & 0x7FFFF]; }
static inline uint tex16(Mem m, int a) { return tex8(m, a) | (tex8(m, a + 1) << 8); }
static inline uint pal8(Mem m, int a) { a &= 0x1FFFF; return a >= 0x18000 ? 0u : uint(m.pal[a]); }
static inline uint pal16(Mem m, int a) { return pal8(m, a) | (pal8(m, a + 1) << 8); }
static inline uint mix5(uint c0, uint c1, int k0, int k1, int sh) {
  uint r = 0u;
  for (int i = 0; i < 3; i++) {
    int a = int((c0 >> uint(5 * i)) & 31u), b = int((c1 >> uint(5 * i)) & 31u);
    r |= uint((a * k0 + b * k1) >> sh) << uint(5 * i);
  }
  return r;
}
static uint texel_uv(Mem m, uint tex, uint pltt, int u, int v) {
  int sw = 8 << int((tex >> 20) & 7u);
  int base = int(tex & 0xFFFFu) * 8;
  int pbase = int(pltt) * 16;
  bool zc = (tex & 0x20000000u) != 0u;
  int i = v * sw + u;
  uint fmt = (tex >> 26) & 7u;
  if (fmt == 1u) {
    uint b = tex8(m, base + i);
    uint a = (b >> 5) * 4u + (b >> 6);
    return rgb6(pal16(m, pbase + int(b & 31u) * 2)) | (a << 24);
  } else if (fmt == 2u) {
    uint idx = (tex8(m, base + (i >> 2)) >> uint((i & 3) * 2)) & 3u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(m, int(pltt) * 8 + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 3u) {
    uint idx = (tex8(m, base + (i >> 1)) >> uint((i & 1) * 4)) & 15u;
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(m, pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 4u) {
    uint idx = tex8(m, base + i);
    if (idx == 0u && zc) return 0u;
    return rgb6(pal16(m, pbase + int(idx) * 2)) | (31u << 24);
  } else if (fmt == 5u) {
    int blk = base + ((v >> 2) * (sw >> 2) + (u >> 2)) * 4;
    uint bits = (tex8(m, blk + (v & 3)) >> uint((u & 3) * 2)) & 3u;
    int slot = (blk >> 17) & 3;
    int ia = 0x20000 + ((blk & 0x1FFFF) >> 1) + (slot == 2 ? 0x10000 : 0);
    uint info = tex16(m, ia);
    int pa = pbase + int(info & 0x3FFFu) * 4;
    uint c0 = pal16(m, pa), c1 = pal16(m, pa + 2);
    uint mm = info >> 14, c;
    if (mm == 0u) c = bits == 3u ? 0x8000u : pal16(m, pa + int(bits) * 2);
    else if (mm == 1u) c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 1, 1, 1) : 0x8000u;
    else if (mm == 2u) c = pal16(m, pa + int(bits) * 2);
    else c = bits == 0u ? c0 : bits == 1u ? c1 : bits == 2u ? mix5(c0, c1, 5, 3, 3) : mix5(c0, c1, 3, 5, 3);
    return c == 0x8000u ? 0u : rgb6(c & 0x7FFFu) | (31u << 24);
  } else if (fmt == 6u) {
    uint b = tex8(m, base + i);
    return rgb6(pal16(m, pbase + int(b & 7u) * 2)) | ((b >> 3) << 24);
  } else if (fmt == 7u) {
    uint c = tex16(m, base + i * 2);
    return rgb6(c) | ((c & 0x8000u) == 0u ? 0u : 31u << 24);
  }
  return 0u;
}
static inline int wrap_coord(int c, int size, bool rep, int fmask) {
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

struct End { int x; int3 c; int s, t, z, w; };

static uint blend_texel(constant U& u, Ctx c, int vr, int vg, int vb, uint tx) {
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
    uint sc = rgb6(reg16(u, 0x380 + (vr >> 1) * 2));
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

static inline uint blend_into(Ctx c, uint dst, uint px) {
  int a = int(px >> 24), oa = int(dst >> 24);
  if (c.blend && oa != 0) {
    return pack4((ch(px, 0) * (a + 1) + ch(dst, 0) * (31 - a)) >> 5,
                 (ch(px, 1) * (a + 1) + ch(dst, 1) * (31 - a)) >> 5,
                 (ch(px, 2) * (a + 1) + ch(dst, 2) * (31 - a)) >> 5, max(a, oa));
  }
  return px;
}

// lin(a, b, n, d) from rd = 1 / d, exactly: a float estimate of
// floor((b - a) n / d) corrected in 64-bit integers, the divisions only
// where it is off by more than two. (Not in the WebGL renderer, which has
// no 64-bit integers: a span's five lin calls are ten integer divisions a
// dot there, about 30 % of the GS title's GPU time at 4x here.)
static inline int lin_r(int a, int b, int n, int d, float rd) {
  long p = long(b - a) * long(n);
  long q = long(floor(float(p) * rd));
  long r = p - q * long(d);
  if (r < 0) { q--; r += d; }
  if (r < 0) { q--; r += d; }
  if (r >= d) { q++; r -= d; }
  if (r >= d) { q++; r -= d; }
  if (r < 0 || r >= d) return lin(a, b, n, d);
  return a + int(q);
}

// plot_k with nothing known (K = 0): one dot of the span from L to R
static void plot(constant U& u, Mem m, Ctx c, int x, int y, End L, End R, bool edge, int cov, uint role, thread Px& p) {
  int d = R.x - L.x, n = x - L.x;
  bool eqw = L.w == R.w;
  int z, w, f8 = 0;
  if (d <= 0) { z = L.z; w = L.w; }
  else {
    int zk = (1 << 18) / d;
    z = L.z + int((long(R.z - L.z) * long(n * zk)) >> 18);
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
  float rd = d > 0 ? 1.0f / float(d) : 0.0f;
  #define AT(a, b) (d <= 0 ? (a) : eqw ? lin_r((a), (b), n, d, rd) : (a) + ((((b) - (a)) * f8) >> 8))
  int vr = clamp(AT(L.c.x, R.c.x) >> 3, 0, 63);
  int vg = clamp(AT(L.c.y, R.c.y) >> 3, 0, 63);
  int vb = clamp(AT(L.c.z, R.c.z) >> 3, 0, 63);
  uint tx = 0u;
  if (c.textured) {
    int s = AT(L.s, R.s), t = AT(L.t, R.t);
    int uu = wrap_coord(s >> 4, c.sw, c.rep_s, c.fmask_s);
    int vv = wrap_coord(t >> 4, c.th, c.rep_t, c.fmask_t);
    tx = texel_uv(m, c.tex, c.pltt, uu, vv);
  }
  #undef AT
  uint px = blend_texel(u, c, vr, vg, vb, tx);
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

static Ctx make_ctx(constant U& u, uint4 pw) {
  bool translucent = (pw.w & (1u << 24)) != 0u;
  Ctx c;
  c.attr = pw.x; c.tex = pw.y; c.pltt = pw.z;
  uint fmt = (c.tex >> 26) & 7u;
  int alpha = int((c.attr >> 16) & 31u);
  c.wire = alpha == 0;
  c.id = (c.attr >> 24) & 0x3Fu;
  c.alpha = c.wire ? 31 : alpha;
  c.mode = (c.attr >> 4) & 3u;
  c.textured = (u.disp & 1u) != 0u && fmt != 0u;
  c.fog = (c.attr & 0x8000u) != 0u;
  c.wbuffer = (u.swap & 2u) != 0u;
  c.highlight = (u.disp & 2u) != 0u;
  c.blend = (u.disp & 8u) != 0u;
  c.aref = (u.disp & 4u) != 0u ? int(reg8(u, 0x340) & 31u) : 0;
  c.aa = (u.disp & 0x10u) != 0u;
  c.curse = (u.disp & 0x30u) == 0x20u && !translucent && c.mode != 3u;
  c.sw = 8 << int((c.tex >> 20) & 7u);
  c.th = 8 << int((c.tex >> 23) & 7u);
  c.rep_s = (c.tex & 0x10000u) != 0u;
  c.rep_t = (c.tex & 0x20000u) != 0u;
  c.fmask_s = (c.tex & 0x40000u) != 0u ? c.sw - 1 : 0;
  c.fmask_t = (c.tex & 0x80000u) != 0u ? c.th - 1 : 0;
  return c;
}

// --- edges (render.nim Edge, make_edge, edge_x, edge_run, edge_end, aa_cov)
struct Poly { device const int4* verts; int first; int SX[16]; int SY[16]; };
struct Edge { int x0, y0, x1, y1, a, b, slope; bool xmaj, amaj, dec, vert; };
struct Run { int s, e; bool xmaj, inc, vert; };

static Edge make_edge(thread const Poly& P, int a, int b) {
  if (!(P.SY[a] < P.SY[b])) { int t = a; a = b; b = t; }
  Edge e;
  e.x0 = P.SX[a]; e.y0 = P.SY[a]; e.x1 = P.SX[b]; e.y1 = P.SY[b]; e.a = a; e.b = b;
  int dx = e.x1 - e.x0, dy = e.y1 - e.y0;
  e.slope = abs(dx) == dy ? (dx > 0 ? (1 << 18) : -(1 << 18)) : dy == 0 ? 0 : dx * ((1 << 18) / dy);
  e.xmaj = abs(dx) > dy; e.amaj = abs(dx) >= dy; e.dec = dx < 0; e.vert = dx == 0;
  return e;
}
static inline int edge_x(Edge e, int y) { return shl(e.x0, 18) + e.slope * (y - e.y0) - (e.dec ? 1 : 0); }
static Run edge_run(Edge e, int y, bool right) {
  if (e.vert) {
    if (right) return Run{e.x0 - 1, e.x0, false, false, true};
    return Run{e.x0, e.x0 + 1, false, false, true};
  }
  int xa = edge_x(e, y);
  if (e.xmaj) {
    int st = abs(e.slope) & ~511;
    int xb = e.dec ? xa - st : xa + st;
    return Run{(min(xa, xb) + (1 << 17)) >> 18, (max(xa, xb) + (1 << 17)) >> 18, true, !e.dec, false};
  }
  int q = xa >> 18;
  return Run{q, q + 1, false, !e.dec, false};
}
static void vattr(thread const Poly& P, int i, thread int3& c, thread int& s, thread int& t, thread int& z, thread int& w) {
  int4 v0 = P.verts[(P.first + i) * 2];
  int4 v1 = P.verts[(P.first + i) * 2 + 1];
  int3 c5 = int3(v1.x & 0xFF, (v1.x >> 8) & 0xFF, (v1.x >> 16) & 0xFF);
  // 5-bit colours carry 9 bits: x * 16 + 15, zero staying zero
  c = int3(c5.x == 0 ? 0 : c5.x * 16 + 15, c5.y == 0 ? 0 : c5.y * 16 + 15, c5.z == 0 ? 0 : c5.z * 16 + 15);
  s = v1.y; t = v1.z; z = v0.z; w = v0.w;
}
static End vend(thread const Poly& P, int i, int x) {
  End r; r.x = x;
  vattr(P, i, r.c, r.s, r.t, r.z, r.w);
  return r;
}
static End edge_end(thread const Poly& P, Edge e, int y, int x) {
  int3 ac, bc; int as_, at_, az, aw, bs, bt, bz, bw;
  vattr(P, e.a, ac, as_, at_, az, aw);
  vattr(P, e.b, bc, bs, bt, bz, bw);
  int n = y - e.y0, d = e.y1 - e.y0;
  End r; r.x = x;
  r.z = lin(az, bz, n, d);
  if (aw == bw) {
    r.c = int3(lin(ac.x, bc.x, n, d), lin(ac.y, bc.y, n, d), lin(ac.z, bc.z, n, d));
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
static int aa_cov(Edge e, int y, int x, bool right, int lend) {
  if (e.vert) return 31;
  if (!e.xmaj) {
    int xm = truncdiv2(edge_x(e, y) + edge_x(e, y + 1)) - shl(x, 18);
    int num = clamp(right ? xm : (1 << 18) - xm, 0, 1 << 18);
    if (right) return min(31, (32 * num) >> 18);
    return clamp(31 - ((32 * ((1 << 18) - num)) >> 18), 0, 31);
  }
  // ((2^28 - 1) dy) div (|dx| 2^18), as one 32-bit division
  int inc = ((e.y1 - e.y0) * 1024 - 1) / abs(e.x1 - e.x0);
  int start = min(edge_x(e, y), edge_x(e, y + 1));
  if (right) start = max(start, shl(lend, 18));
  int h = ashr64(muls64(shl(x, 18) + (1 << 17) - start, inc), 18);
  int v = right ? 1023 - h : h;
  return clamp(v >> 5, 0, 31);
}

// draw_polygon's row setup, once per (polygon, row): which dots of the
// row it plots and how (render.nim draw_polygon), for the dot pass.
// Record (5 int4s): (L.x | R.x << 16, L colour, L.s, L.t), (L.z, L.w,
// R colour, R.s), (R.t, R.z, R.w, flags), (left edge dots, the run
// between, right edge dots: each lo | hi << 16), (left AA a, b, right AA
// a, b). flags: bit 0 the run's dots count as edge dots, 1-7 / 8-14 /
// 15-21 the left / right / run roles, 22-23 / 24-25 the left / right AA
// mode (0 whole, 1 fixed coverage a, 2 y-major X(y + 1/2) a, 3 x-major
// start a, step b).
static inline int packc(int3 c) { return c.x | shl(c.y, 9) | shl(c.z, 18); }
static inline int range(int lo, int hi) { return lo < hi ? (lo & 0xFFFF) | shl(hi, 16) : 0; }
static void emit(device int4* o, End L, End R, int rl, int rf, int rr, int flags, int4 aa) {
  o[0] = int4((L.x & 0xFFFF) | shl(R.x, 16), packc(L.c), L.s, L.t);
  o[1] = int4(L.z, L.w, packc(R.c), R.s);
  o[2] = int4(R.t, R.z, R.w, flags);
  o[3] = int4(rl, rf, rr, 0);
  o[4] = aa;
}
// an edge's run of dots, for aa_cov per dot in the dot pass
static int2 aa_mode(Edge e, int y, bool right, int lend, thread int& mode) {
  if (e.vert) { mode = 0; return int2(0); }
  if (!e.xmaj) { mode = 2; return int2(truncdiv2(edge_x(e, y) + edge_x(e, y + 1)), 0); }
  mode = 3;
  int inc = ((e.y1 - e.y0) * 1024 - 1) / abs(e.x1 - e.x0);
  int start = min(edge_x(e, y), edge_x(e, y + 1));
  if (right) start = max(start, shl(lend, 18));
  return int2(start, inc);
}

kernel void nds_rows(constant U& u [[buffer(0)]],
                     device const uint4* polys [[buffer(1)]],
                     device const int4* geo [[buffer(2)]],
                     device const int4* verts [[buffer(3)]],
                     device const uint* recPoly [[buffer(4)]],
                     device int4* recs [[buffer(5)]],
                     uint rec [[thread_position_in_grid]]) {
  if (int(rec) >= u.total) return;
  int WS = 256 * u.k;
  device int4* o = recs + rec * 5;
  for (int i = 0; i < 5; i++) o[i] = int4(0);
  int pi = int(recPoly[rec]);
  int4 g0 = geo[pi * 2];
  int4 g1 = geo[pi * 2 + 1];
  int y = max(0, g0.z) + int(rec) - g1.w;
  uint4 pw = polys[pi];
  Poly P;
  P.verts = verts;
  P.first = int(pw.w & 0xFFFFu);
  int n = int((pw.w >> 16) & 0xFFu);
  bool translucent = (pw.w & (1u << 24)) != 0u;
  bool fwd_left = (pw.w & (1u << 25)) != 0u;
  Ctx c = make_ctx(u, pw);
  for (int i = 0; i < 16; i++) {
    if (i >= n) break;
    int4 v0 = verts[(P.first + i) * 2];
    P.SX[i] = v0.x; P.SY[i] = v0.y;
  }
  int top = g1.x, ymax = g1.z, ymin = g0.z;
  bool line = (g1.y & 1) != 0, flat_bottom = (g1.y & 2) != 0;
  bool full = c.wire || line || (u.disp & 0x30u) != 0u || (translucent && c.blend);
  bool aa = (u.disp & 0x10u) != 0u && !translucent;
  if (ymin == ymax) {
    int li = 0, ri = 0;
    int i1 = 1 % n, i2 = n - 1;
    if (P.SX[i1] < P.SX[li]) li = i1;
    if (P.SX[i1] > P.SX[ri]) ri = i1;
    if (P.SX[i2] < P.SX[li]) li = i2;
    if (P.SX[i2] > P.SX[ri]) ri = i2;
    emit(o, vend(P, li, P.SX[li]), vend(P, ri, P.SX[ri]), 0,
         range(max(0, P.SX[li]), min(WS, max(P.SX[ri], P.SX[li] + 1))), 0, 1, int4(0));
    return;
  }
  // the two chains from the top vertex (advance, from the top each time)
  int fc = top, fn = (top + 1) % n, bc = top, bn = (top + n - 1) % n;
  for (int g = 0; g < 16; g++) {
    if (g >= n || P.SY[fn] > y) break;
    fc = fn; fn = (fn + 1) % n;
  }
  for (int g = 0; g < 16; g++) {
    if (g >= n || P.SY[bn] > y) break;
    bc = bn; bn = (bn + n - 1) % n;
  }
  if (P.SY[fn] <= y || P.SY[bn] <= y) return;
  Edge ef = make_edge(P, fc, fn), eb = make_edge(P, bc, bn);
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
    if (pl.vert && lr.s < 0) lr = Run{0, 1, false, false, true};
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
      emit(o, edge_end(P, pl, y, xs), edge_end(P, pr, y, xe + 1), rl, rf, rrr,
           (rim ? 1 : 0) | (1 << 22) | (1 << 24), int4(covl, 0, covr, 0));
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
  int2 al = int2(0), ar = int2(0);
  if (aa) { al = aa_mode(le0, y, false, 0, ml); ar = aa_mode(re0, y, true, L.e, mr); }
  emit(o, edge_end(P, le0, yl, L.s), edge_end(P, re0, yr, R.e), rl, rf, rrr,
       (rim ? 1 : 0) | int(lrole << 1) | int(rrole << 8) | int(mrole << 15) | (ml << 22) | (mr << 24),
       int4(al, ar));
}

// render.nim clear: the rear plane
static Px clear_px(constant U& u, Mem m, int x, int y) {
  Px p;
  uint cc = reg(u, 0x30 >> 2);
  p.oid = (cc >> 24) & 0x3Fu; p.tid = NO_ID; p.aacov = 31u;
  if ((u.disp & 0x4000u) != 0u) {
    uint ofs = reg16(u, 0x356);
    int yy = (y / u.k + int((ofs >> 8) & 0xFFu)) & 0xFF;
    int xx = (x / u.k + int(ofs & 0xFFu)) & 0xFF;
    uint col = tex16(m, 0x40000 + (yy * 256 + xx) * 2);
    uint dd = tex16(m, 0x60000 + (yy * 256 + xx) * 2);
    p.color = rgb6(col) | ((col & 0x8000u) != 0u ? 31u << 24 : 0u);
    uint d15 = dd & 0x7FFFu;
    p.depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    p.flags = (dd & 0x8000u) != 0u ? FLAG_FOG : 0u;
  } else {
    p.color = rgb6(cc) | (((cc >> 16) & 31u) << 24);
    uint d15 = reg16(u, 0x354) & 0x7FFFu;
    p.depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    p.flags = (cc & 0x8000u) != 0u ? FLAG_FOG : 0u;
  }
  p.below = p.color; p.bdepth = p.depth;
  return p;
}

static inline int sx16(int v) { return as_type<int>(as_type<uint>(v) << 16) >> 16; }
static inline bool inrange(int r, int x) { return x >= (r & 0xFFFF) && x < (r >> 16); }
static inline int3 unpackc(int c) { return int3(c & 511, (c >> 9) & 511, (c >> 18) & 511); }
// render.nim aa_cov from the rows pass's per-row data
static int cov_at(int mode, int a, int b, int x, bool right) {
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

kernel void nds_raster(constant U& u [[buffer(0)]],
                       device const uint4* polys [[buffer(1)]],
                       device const int4* geo [[buffer(2)]],
                       device const uint* bins [[buffer(3)]],
                       device const uint2* head [[buffer(4)]],
                       device const uchar* vram [[buffer(5)]],
                       device const uchar* pal [[buffer(6)]],
                       device const int4* recs [[buffer(7)]],
                       device uint4* out [[buffer(8)]],
                       uint2 gid [[thread_position_in_grid]]) {
  int WS = 256 * u.k, HS = 192 * u.k;
  int x = int(gid.x), y = int(gid.y);
  if (x >= WS || y >= HS) return;
  Mem m = { vram, pal };
  Px p = clear_px(u, m, x, y);
  uint2 hd = head[(y / TILE_H) * u.tilesX + x / TILE_W];
  for (uint i = 0u; i < hd.y; i++) {
    int pi = int(bins[hd.x + i]);
    int4 g0 = geo[pi * 2];
    if (x < g0.x || x > g0.y || y < g0.z || y > g0.w) continue;
    device const int4* r = recs + (geo[pi * 2 + 1].w + y - max(0, g0.z)) * 5;
    int4 r3 = r[3];
    int kind = inrange(r3.x, x) ? 1 : inrange(r3.y, x) ? 2 : inrange(r3.z, x) ? 3 : 0;
    if (kind == 0) continue;
    int4 r0 = r[0], r1 = r[1], r2 = r[2];
    End L, R;
    L.x = sx16(r0.x); L.c = unpackc(r0.y); L.s = r0.z; L.t = r0.w; L.z = r1.x; L.w = r1.y;
    R.x = r0.x >> 16; R.c = unpackc(r1.z); R.s = r1.w; R.t = r2.x; R.z = r2.y; R.w = r2.z;
    int flags = r2.w;
    Ctx c = make_ctx(u, polys[pi]);
    if (kind == 2) {
      plot(u, m, c, x, y, L, R, (flags & 1) != 0, 31, uint((flags >> 15) & 0x7F), p);
    } else {
      int4 r4 = r[4];
      bool right = kind == 3;
      int mode = (flags >> (right ? 24 : 22)) & 3;
      int cov = cov_at(mode, right ? r4.z : r4.x, right ? r4.w : r4.y, x, right);
      plot(u, m, c, x, y, L, R, true, cov, uint((flags >> (right ? 8 : 1)) & 0x7F), p);
    }
  }
  out[y * WS + x] = uint4(p.color, p.depth, p.below, p.oid | (p.tid << 8) | (p.flags << 16) | (p.aacov << 24));
}

kernel void nds_post(constant U& u [[buffer(0)]],
                     device const uint4* rast [[buffer(1)]],
                     device uint* out [[buffer(2)]],
                     uint2 gid [[thread_position_in_grid]]) {
  int2 sz = int2(256 * u.k, 192 * u.k);
  int2 q = int2(gid);
  if (q.x >= sz.x || q.y >= sz.y || q.y < u.from_ * u.k || q.y >= u.to_ * u.k) return;
  uint4 r = rast[q.y * sz.x + q.x];
  uint color = r.x, depth = r.y, below = r.z;
  uint oid = r.w & 0xFFu, flags = (r.w >> 16) & 0xFFu;
  int cov = int(r.w >> 24);
  bool aa = (u.disp & 0x10u) != 0u;
  if (aa && cov < 31) {
    // render.nim anti_alias
    uint o = below, px = color;
    if (cov == 0) color = o;
    else if ((o >> 24) == 0u) color = (px & 0xFFFFFFu) | (uint(cov) << 24);
    else color = pack4((ch(px, 0) * (cov + 1) + ch(o, 0) * (31 - cov)) >> 5,
                       (ch(px, 1) * (cov + 1) + ch(o, 1) * (31 - cov)) >> 5,
                       (ch(px, 2) * (cov + 1) + ch(o, 2) * (31 - cov)) >> 5, 31);
  }
  if ((u.disp & 0x20u) != 0u && (flags & FLAG_EDGE) != 0u) {
    // render.nim edge_mark
    uint cc = reg(u, 0x30 >> 2);
    uint clear_id = (cc >> 24) & 0x3Fu;
    uint d15 = reg16(u, 0x354) & 0x7FFFu;
    uint clear_depth = d15 * 0x200u + ((d15 + 1u) / 0x8000u) * 0x1FFu;
    bool marked = false;
    const int2 nb[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    for (int i = 0; i < 4; i++) {
      int2 mm = q + nb[i];
      if (mm.x < 0 || mm.y < 0 || mm.x >= sz.x || mm.y >= sz.y) marked = marked || (oid != clear_id && depth < clear_depth);
      else { uint4 o = rast[mm.y * sz.x + mm.x]; marked = marked || (oid != (o.w & 0xFFu) && depth < o.y); }
    }
    if (marked) {
      uint ec = rgb6(reg16(u, 0x330 + int(oid >> 3) * 2));
      if (aa) {
        uint o = below;
        color = (o >> 24) == 0u ? ec | (16u << 24)
              : pack4((ch(ec, 0) * 17 + ch(o, 0) * 15) >> 5, (ch(ec, 1) * 17 + ch(o, 1) * 15) >> 5,
                      (ch(ec, 2) * 17 + ch(o, 2) * 15) >> 5, 0) | (color & 0xFF000000u);
      } else color = ec | (color & 0xFF000000u);
    }
  }
  if ((u.disp & 0x80u) != 0u && (flags & FLAG_FOG) != 0u) {
    // render.nim fog
    uint fc = reg(u, 0x38 >> 2);
    int fr = int(expand6(fc & 31u)), fg = int(expand6((fc >> 5) & 31u)), fb = int(expand6((fc >> 10) & 31u));
    int fa = int((fc >> 16) & 31u);
    int shift = int((u.disp >> 8) & 15u);
    int step = 0x400 >> shift;
    int offset = int(reg16(u, 0x35C) & 0x7FFFu);
    int dd = int(depth >> 9);
    int dens;
    if (step == 0) dens = int(reg8(u, dd < offset + step ? 0x360 : 0x360 + 31) & 0x7Fu);
    else {
      int k = (dd - offset) / step - 1;
      if (dd - offset < 0) k = -((offset - dd + step - 1) / step) - 1;   // Nim div truncates; offsets below 0 only reach table[0]
      if (k < 0) dens = int(reg8(u, 0x360) & 0x7Fu);
      else if (k >= 31) dens = int(reg8(u, 0x360 + 31) & 0x7Fu);
      else {
        int frac = (dd - offset) - (k + 1) * step;
        dens = (int(reg8(u, 0x360 + k) & 0x7Fu) * (step - frac) + int(reg8(u, 0x360 + k + 1) & 0x7Fu) * frac) / step;
      }
    }
    if (dens >= 127) dens = 128;
    int oa = int(color >> 24);
    int na = (fa * dens + oa * (128 - dens)) >> 7;
    if ((u.disp & 0x40u) != 0u) color = (color & 0xFFFFFFu) | (uint(na) << 24);
    else color = pack4((fr * dens + ch(color, 0) * (128 - dens)) >> 7, (fg * dens + ch(color, 1) * (128 - dens)) >> 7,
                       (fb * dens + ch(color, 2) * (128 - dens)) >> 7, na);
  }
  out[q.y * sz.x + q.x] = color;
}

// Engine A at HD (gpu.nim hd_line): its composite per HD dot by hd_dot's
// rules (engine2d.nim effect_dot / bright_dot), VRAM display from the
// banks' HD copies, and display capture into them.
struct Comp {
  device const ushort* screens1x;   // 256 x 384 BGR555, top over bottom
  device const uint4* plane;        // 256 x 192: gpu_paint_line's 4 words a dot
  device const uint4* plane2;       // 256 x 192: gpu_valid's 4 words a dot
  device const uint4* lines;        // 384: gpu_line's 8 words a line
  device const uint* d3;            // 256k x 192k, the core's pixel format
  device const ushort* cap0;        // banks A-D's HD copies (BGR555 + bit 15), 256k x 256k
  device const ushort* cap1;
  device const ushort* cap2;
  device const ushort* cap3;
  int k;
};
constant int LAYER_OBJ = 4;
constant uint OBJ_SEMI = 0x10u, OBJ_BITMAP = 0x20u;
static inline uint4 line0(Comp C, int y) { return C.lines[y * 2]; }
static inline uint4 line1(Comp C, int y) { return C.lines[y * 2 + 1]; }
static inline uint ch6(uint c, uint lo, int i) { return (((c >> uint(5 * i)) & 0x1Fu) << 1) | ((lo >> uint(i)) & 1u); }
static inline uint pack6(uint r, uint g, uint b, thread uint& lo) {
  lo = (r & 1u) | ((g & 1u) << 1) | ((b & 1u) << 2);
  return (r >> 1) | ((g >> 1) << 5) | ((b >> 1) << 10);
}
static inline uint blend_alpha(uint a, uint la, uint b, uint lb, uint eva, uint evb, thread uint& lo) {
  uint r = min(63u, (ch6(a, la, 0) * eva + ch6(b, lb, 0) * evb + 8u) >> 4);
  uint g = min(63u, (ch6(a, la, 1) * eva + ch6(b, lb, 1) * evb + 8u) >> 4);
  uint bb = min(63u, (ch6(a, la, 2) * eva + ch6(b, lb, 2) * evb + 8u) >> 4);
  return pack6(r, g, bb, lo);
}
static inline uint brighten(uint a, uint la, uint evy, thread uint& lo) {
  uint r = ch6(a, la, 0), g = ch6(a, la, 1), b = ch6(a, la, 2);
  return pack6(r + (((63u - r) * evy + 8u) >> 4), g + (((63u - g) * evy + 8u) >> 4),
               b + (((63u - b) * evy + 8u) >> 4), lo);
}
static inline uint darken(uint a, uint la, uint evy, thread uint& lo) {
  return pack6((ch6(a, la, 0) * (16u - evy) + 8u) >> 4, (ch6(a, la, 1) * (16u - evy) + 8u) >> 4,
               (ch6(a, la, 2) * (16u - evy) + 8u) >> 4, lo);
}
static inline uint blend_3d(uint p, uint below, uint lb, thread uint& lo) {
  uint a = (p >> 24) & 31u;
  uint r = (((p) & 0x3Fu) * (a + 1u) + ch6(below, lb, 0) * (31u - a) + 16u) >> 5;
  uint g = (((p >> 8) & 0x3Fu) * (a + 1u) + ch6(below, lb, 1) * (31u - a) + 16u) >> 5;
  uint b = (((p >> 16) & 0x3Fu) * (a + 1u) + ch6(below, lb, 2) * (31u - a) + 16u) >> 5;
  return pack6(r, g, b, lo);
}
// MASTER_BRIGHT on one dot (bright_dot); mode 0 or 3, or factor 0: none
static inline uint bright(uint c, uint lo, uint mb) {
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
static inline uint to_bgr555(uint p) { return ((p >> 1) & 31u) | (((p >> 9) & 31u) << 5) | (((p >> 17) & 31u) << 10); }
static inline uint lsb3d(uint p) { return (p & 1u) | ((p >> 7) & 2u) | ((p >> 14) & 4u); }
// sub-dot (i, j) of halfword d of a bank's HD copy
static inline uint cap_at(Comp C, int bank, int d, int i, int j) {
  int n = 256 * C.k;
  int at = ((d >> 8) * C.k + j) * n + (d & 255) * C.k + i;
  if (bank == 0) return C.cap0[at];
  if (bank == 1) return C.cap1[at];
  if (bank == 2) return C.cap2[at];
  return C.cap3[at];
}
// Engine A's composite of dot x on line y at sub-dot (i, j): the graphics
// (capture source A, before master brightness) or the display dot.
static uint compose(Comp C, int x, int y, int i, int j, bool gfx) {
  uint4 li = line0(C, y);
  uint4 pl = C.plane[y * 256 + x];
  uint one = gfx ? C.plane2[y * 256 + x].x & 0xFFFFu : pl.z >> 16;   // the 1x dot
  if ((li.x & 1u) == 0u) return one;
  int sx = (x + int((li.w >> 8) & 511u)) & 511;
  if (sx >= 256) return one;
  uint p = C.d3[(y * C.k + j) * 256 * C.k + sx * C.k + i];
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

#define COMP_ARGS \
  device const ushort* screens1x [[buffer(1)]], device const uint4* plane [[buffer(2)]], \
  device const uint4* plane2 [[buffer(3)]], device const uint4* lines [[buffer(4)]], \
  device const uint* d3 [[buffer(5)]], device const ushort* cap0 [[buffer(6)]], \
  device const ushort* cap1 [[buffer(7)]], device const ushort* cap2 [[buffer(8)]], \
  device const ushort* cap3 [[buffer(9)]]

// Both screens at k: engine A's lines composited at HD where they show 3D
// or VRAM display; everything else is the 1x screens' dot.
kernel void nds_composite(constant U& u [[buffer(0)]], COMP_ARGS,
                          texture2d<ushort, access::write> screens [[texture(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
  int k = u.k;
  int2 q = int2(gid);
  if (q.x >= 256 * k || q.y >= 384 * k) return;
  Comp C = { screens1x, plane, plane2, lines, d3, cap0, cap1, cap2, cap3, k };
  int scr = q.y >= 192 * k ? 1 : 0;
  int Y = q.y - scr * 192 * k;
  int y = Y / k, x = q.x / k, i = q.x % k, j = Y % k;
  uint4 li = line0(C, y);
  uint o = screens1x[(scr * 192 + y) * 256 + x];
  if ((scr == 0) == ((li.x & 2u) != 0u)) {
    if ((li.x & 5u) == 5u) o = compose(C, x, y, i, j, false);
    else if ((li.x & 8u) != 0u && (plane2[y * 256 + x].z & 1u) != 0u) {
      uint4 l1 = line1(C, y);
      o = bright(cap_at(C, int(l1.y), y * 256 + x, i, j) & 0x7FFFu, 0u, l1.z);
    }
  }
  screens.write(ushort(o), gid);
}

// Display capture at k (gpu.nim hd_line's capture part): every sub-dot of
// the destination bank's HD copy, the captured halfwords' from this
// frame's lines, the rest as they were (capCur, the same bank).
constant int2 CAPTURE_SIZE[4] = { int2(128, 128), int2(256, 64), int2(256, 128), int2(256, 192) };
kernel void nds_capture(constant U& u [[buffer(0)]], COMP_ARGS,
                        device const ushort* capCur [[buffer(10)]],
                        device ushort* capNext [[buffer(11)]],
                        uint2 gid [[thread_position_in_grid]]) {
  int k = u.k, n = 256 * k;
  int2 q = int2(gid);
  if (q.x >= n || q.y >= n) return;
  Comp C = { screens1x, plane, plane2, lines, d3, cap0, cap1, cap2, cap3, k };
  int wd = (q.y / k) * 256 + q.x / k, i = q.x % k, j = q.y % k;
  int2 size = CAPTURE_SIZE[(u.capc >> 20) & 3u];
  int rel = (wd - int((u.capc >> 18) & 3u) * 0x4000) & 0xFFFF;
  int y = rel / size.x, x = rel % size.x;
  uint o = capCur[q.y * n + q.x];
  if (y < size.y && (line0(C, y).x & 16u) != 0u) {
    uint capc = line1(C, y).x;
    uint csrc = (capc >> 29) & 3u;
    uint eva = min(16u, capc & 0x1Fu), evb = min(16u, (capc >> 8) & 0x1Fu);
    uint4 p2 = plane2[y * 256 + x];
    uint ca = 0u, cb = 0u;
    if (csrc != 1u) {
      if ((capc & (1u << 24)) != 0u) {
        uint p = d3[(y * k + j) * n + x * k + i];
        ca = to_bgr555(p) | ((p >> 24) != 0u ? 0x8000u : 0u);
      } else ca = compose(C, x, y, i, j, true) | 0x8000u;
    }
    if (csrc != 0u) {
      if ((capc & (1u << 25)) != 0u) cb = p2.y >> 16;
      else if ((p2.z & 2u) != 0u) {
        int dm = int((line0(C, y).x >> 8) & 3u);
        int roff = dm == 2 ? 0 : int((capc >> 26) & 3u) * 0x8000;
        int rd = ((roff + y * size.x * 2 + x * 2) & 0x1FFFF) >> 1;
        cb = cap_at(C, int(line1(C, y).y), rd, i, j);
      } else cb = p2.y & 0xFFFFu;
    }
    if (csrc == 0u) o = ca;
    else if (csrc == 1u) o = cb;
    else {
      uint aa = (ca & 0x8000u) != 0u ? eva : 0u;
      uint ab = (cb & 0x8000u) != 0u ? evb : 0u;
      uint c = 0u;
      for (int s = 0; s < 15; s += 5)
        c |= min(31u, (((ca >> uint(s)) & 0x1Fu) * aa + ((cb >> uint(s)) & 0x1Fu) * ab) >> 4) << uint(s);
      o = c | (aa > 0u || ab > 0u ? 0x8000u : 0u);
    }
  }
  capNext[q.y * n + q.x] = ushort(o);
}
"""#
