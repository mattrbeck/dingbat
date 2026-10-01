#include "t3d.h"

// 3x5 glyphs drawn 2x wide in rows 1-5 of an 8x8 tile (as common2d's)
static const char GLYPH_CHARS[] = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:-!_/,()+=><";
static const char *const GLYPHS[] = {
  "... ... ... ... ...",
  "### #.# #.# #.# ###", ".#. ##. .#. .#. ###", "### ..# ### #.. ###", "### ..# ### ..# ###",
  "#.# #.# ### ..# ..#", "### #.. ### ..# ###", "### #.. ### #.# ###", "### ..# ..# ..# ..#",
  "### #.# ### #.# ###", "### #.# ### ..# ###",
  "### #.# ### #.# #.#", "##. #.# ##. #.# ##.", "### #.. #.. #.. ###", "##. #.# #.# #.# ##.",
  "### #.. ### #.. ###", "### #.. ### #.. #..", "### #.. #.# #.# ###", "#.# #.# ### #.# #.#",
  "### .#. .#. .#. ###", "..# ..# ..# #.# ###", "#.# #.# ##. #.# #.#", "#.. #.. #.. #.. ###",
  "#.# ### ### #.# #.#", "##. #.# #.# #.# #.#", "### #.# #.# #.# ###", "### #.# ### #.. #..",
  "### #.# #.# ### ..#", "### #.# ##. #.# #.#", "### #.. ### ..# ###", "### .#. .#. .#. .#.",
  "#.# #.# #.# #.# ###", "#.# #.# #.# #.# .#.", "#.# #.# ### ### #.#", "#.# #.# .#. #.# #.#",
  "#.# #.# .#. .#. .#.", "### ..# .#. #.. ###",
  "... ... ... ... .#.", "... .#. ... .#. ...", "... ... ### ... ...", ".#. .#. .#. ... .#.",
  "... ... ... ... ###", "..# ..# .#. #.. #..", "... ... ... .#. #..", ".#. #.. #.. #.. .#.",
  ".#. ..# ..# ..# .#.", "... .#. ### .#. ...", "... ### ... ### ...", "#.. .#. ..# .#. #..",
  "..# .#. #.. .#. ..#",
};
#define NGLYPHS ((int)(sizeof GLYPHS / sizeof GLYPHS[0]))
#define TEXT_CHARS 0x06200000u   // engine B BG VRAM (bank H), char base 0
#define TEXT_MAP 0x06207800u     // screen base 15

void *memcpy(void *d, const void *s, unsigned n) {
  u8 *dd = d;
  const u8 *ss = s;
  while (n--) *dd++ = *ss++;
  return d;
}

void *memset(void *d, int v, unsigned n) {
  u8 *dd = d;
  while (n--) *dd++ = (u8)v;
  return d;
}

static void text_init(void) {
  VRAMCNT(8) = 0x81;                 // H: engine B BG
  R32(0x04001000) = 0x10100;         // engine B: mode 0, BG0 on
  R16(0x04001008) = 15 << 8;         // BG0: 4bpp, char base 0, screen base 15
  ((vu16 *)0x05000400)[0] = 0;
  ((vu16 *)0x05000400)[1] = 0x7FFF;
  for (int t = 0; t < NGLYPHS; t++)
    for (int row = 0; row < 8; row++) {
      u32 word = 0;
      if (row >= 1 && row <= 5) {
        const char *g = GLYPHS[t] + (row - 1) * 4;
        for (int c = 0; c < 3; c++)
          if (g[c] == '#') word |= 0x11u << ((c * 2 + 1) * 4);
      }
      R32(TEXT_CHARS + t * 32 + row * 4) = word;
    }
  for (int i = 0; i < 32 * 32; i++) R16(TEXT_MAP + i * 2) = 0;
}

void t3d_print(int col, int row, const char *s) {
  for (; *s; s++) {
    if (*s == '\n') {
      row++;
      col = 0;
      continue;
    }
    char ch = *s;
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    int t = 0;
    for (int i = 0; GLYPH_CHARS[i]; i++)
      if (GLYPH_CHARS[i] == ch) t = i;
    if (col < 32 && row < 24) R16(TEXT_MAP + (row * 32 + col) * 2) = t;
    col++;
  }
}

void t3d_hex(int col, int row, u32 v, int digits) {
  char buf[9];
  for (int i = 0; i < digits; i++) buf[i] = "0123456789ABCDEF"[(v >> ((digits - 1 - i) * 4)) & 15];
  buf[digits] = 0;
  t3d_print(col, row, buf);
}

void wait_vblank(void) {
  while (VCOUNT == 192) {}
  while (VCOUNT != 192) {}
}

void t3d_init(const char *title) {
  POWCNT1 = 0x820F;                  // LCDs, 2D A, 3D render + geometry, 2D B, A on top
  R32(0x04000000) = 0x10108;         // engine A: mode 0, BG0 on, BG0 = 3D
  R16(0x04000008) = 0;               // BG0 priority 0
  BLDCNT_A = 0;
  PAL_A_BG[0] = 0;
  text_init();
  t3d_print(0, 0, title);

  while (GXSTAT & (1u << 27)) {}
  GXSTAT = 1u << 15;                 // acknowledge a stack error
  DISP3DCNT = 1u << 12 | 1u << 13;   // acknowledge both flags, all features off
  clear_color(0, 31, 0, 0);
  clear_depth(0x7FFF);
  R16(0x04000356) = 0;
  R16(0x04000610) = 0x7FFF;          // DISP_1DOT_DEPTH
  alpha_ref(0);
  for (int i = 0; i < 8; i++) edge_color(i, 0);
  for (int i = 0; i < 32; i++) toon_color(i, 0);
  for (int i = 0; i < 32; i += 2) R16(0x04000360 + i) = 0;   // fog table
  fog_color(0, 0);
  fog_offset(0);
  viewport(0, 0, 255, 191);
  mtx_mode(0);
  mtx_identity();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_ALPHA(31));
  tex_param(0);
  pltt_base(0);
  color(0x7FFF);
}

// sin/cos by a Taylor series after reduction to [-pi, pi]; enough for
// placing test geometry, and deterministic (soft-float on the ARM9)
float sinf(float x) {
  const float PI = 3.14159265f;
  while (x > PI) x -= 2 * PI;
  while (x < -PI) x += 2 * PI;
  float x2 = x * x, term = x, sum = x;
  for (int k = 1; k < 8; k++) {
    term *= -x2 / (float)((2 * k) * (2 * k + 1));
    sum += term;
  }
  return sum;
}

float cosf(float x) { return sinf(x + 1.57079633f); }
float tanf(float x) { return sinf(x) / cosf(x); }

float sqrtf(float x) {
  if (x <= 0) return 0;
  float r = x > 1 ? x : 1;
  for (int i = 0; i < 30; i++) r = 0.5f * (r + x / r);
  return r;
}

void t3d_reset_matrices(void) {
  mtx_mode(2);   // position + vector
  mtx_identity();
  mtx_mode(3);   // texture
  mtx_identity();
  mtx_mode(1);
}

void t3d_proj_px(void) {
  // clip = (x * 1.5 - 3, -2y + 3, -z * 0.375, 3) for raw x = PX(px), y = PX(py):
  // larger z is nearer, z = +-8.0 reach the near/far planes
  static const s32 m[16] = {
    6144, 0, 0, 0,
    0, -8192, 0, 0,
    0, 0, -1536, 0,
    -12288, 12288, 0, 12288,
  };
  mtx_mode(0);
  mtx_load44(m);
  mtx_mode(1);
}

void t3d_proj_persp(float fovy_deg, float aspect, float n, float f) {
  float t = 1.0f / tanf(fovy_deg * 3.14159265f / 360.0f);
  s32 m[16] = {0};
  m[0] = FX(t / aspect);
  m[5] = FX(t);
  m[10] = FX(-(f + n) / (f - n));
  m[11] = FX(-1.0);
  m[14] = FX(-2.0f * f * n / (f - n));
  mtx_mode(0);
  mtx_load44(m);
  mtx_mode(1);
}

void t3d_wait_idle(void) {
  while (GXSTAT & (1u << 27)) {}
}

void t3d_frame(u32 swap_param) {
  swap_buffers(swap_param);
  wait_vblank();
}

u8 *t3d_tex_begin(void) {
  for (int b = 0; b < 4; b++) VRAMCNT(b) = 0x80;   // A-D: LCDC
  return (u8 *)0x06800000;
}

void t3d_tex_end(int nslots) {
  for (int b = 0; b < nslots; b++) VRAMCNT(b) = 0x83 | (b << 3);   // texture slot b
}

u16 *t3d_pal_begin(void) {
  VRAMCNT(4) = 0x80;                 // E: LCDC
  return (u16 *)0x06880000;
}

void t3d_pal_end(void) { VRAMCNT(4) = 0x83; }   // E: texture palette slots 0-3

void t3d_copy16(void *dst, const void *src, int bytes) {
  vu16 *d = (vu16 *)dst;
  const u8 *s = (const u8 *)src;
  for (int i = 0; i < bytes; i += 2) d[i >> 1] = s[i] | (s[i + 1] << 8);
}

u16 t3d_hue(int i, int n) {
  // walk the colour cube's six edges: red, yellow, green, cyan, blue, magenta
  int h = (i % n) * 6 * 32 / n;
  int seg = h >> 5, f = h & 31;
  int r, g, b;
  switch (seg) {
  case 0: r = 31; g = f; b = 0; break;
  case 1: r = 31 - f; g = 31; b = 0; break;
  case 2: r = 0; g = 31; b = f; break;
  case 3: r = 0; g = 31 - f; b = 31; break;
  case 4: r = f; g = 0; b = 31; break;
  default: r = 31; g = 0; b = 31 - f; break;
  }
  return RGB(r, g, b);
}

void quad_px(int x0, int y0, int x1, int y1, s32 z) {
  begin(QUADS);
  vtx16(PX(x0), PX(y0), z);
  vtx16(PX(x0), PX(y1), z);
  vtx16(PX(x1), PX(y1), z);
  vtx16(PX(x1), PX(y0), z);
}

void quad_tex_px(int x0, int y0, int x1, int y1, s32 z, int s0, int t0, int s1, int t1) {
  begin(QUADS);
  texcoord(s0 * 16, t0 * 16); vtx16(PX(x0), PX(y0), z);
  texcoord(s0 * 16, t1 * 16); vtx16(PX(x0), PX(y1), z);
  texcoord(s1 * 16, t1 * 16); vtx16(PX(x1), PX(y1), z);
  texcoord(s1 * 16, t0 * 16); vtx16(PX(x1), PX(y0), z);
}

void tri_px(int x0, int y0, int x1, int y1, int x2, int y2, s32 z) {
  begin(TRIS);
  vtx16(PX(x0), PX(y0), z);
  vtx16(PX(x1), PX(y1), z);
  vtx16(PX(x2), PX(y2), z);
}
