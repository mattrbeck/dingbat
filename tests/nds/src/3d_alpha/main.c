// 3d_alpha: translucency (GBATEK "DS 3D Toon, Edge, Fog, Alpha-Blending,
// Anti-Aliasing", "DS 3D Polygon Attributes"). Manual translucent order
// (SWAP_BUFFERS bit 0), alpha test on with ALPHA_TEST_REF 15.
// The rear plane has alpha 0; the left half is covered by an opaque
// checkerboard, the right half shows the rear plane. Engine A blends BG0
// (1st target) over its backdrop (dark green, 2nd target), so the 3D
// alpha of every pixel shows.
//   row 0 (left over the checkers, right over the rear plane):
//     red ID 10 a16, blue ID 10 a16 (same ID: no blend over red),
//     green ID 11 a16 (blends over both), grey ID 12 a10 (alpha test: gone)
//   row 1: A5I3 alpha ramp on an alpha-31 polygon (alpha test cuts <= 15),
//          A3I5 ramp on an alpha-24 polygon
//   row 2: translucent depth update: yellow a20 near WITH depth update, then
//          cyan a20 behind it (hidden where yellow wrote depth); magenta a20
//          near WITHOUT, then white a20 behind (blends over magenta)
// 3d_alpha_noblend: the same with DISP3DCNT.3 (alpha blending) off.
#include "t3d.h"

#ifndef BLEND
#define BLEND D3_BLEND
#endif

static u8 a5i3[256], a3i5[256];
static u16 pal[32];

static void xquad(int x, int y, int w, int h, s32 z, u16 c, int alpha, int id, u32 extra) {
  poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(id) | extra);
  color(c);
  quad_px(x, y, x + w, y + h, z);
}

static void group(int ox) {
  tex_param(0);
  xquad(ox + 8, 8, 48, 40, FX(1), RGB(31, 0, 0), 16, 10, 0);
  xquad(ox + 32, 24, 48, 40, FX(1.5), RGB(0, 0, 31), 16, 10, 0);
  xquad(ox + 56, 8, 40, 48, FX(2), RGB(0, 31, 0), 16, 11, 0);
  xquad(ox + 92, 36, 30, 24, FX(2.5), RGB(20, 20, 20), 10, 12, 0);

  color(0x7FFF);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(13));
  tex_param(TP_ADDR(0) | TP_SIZE(1, 1) | TP_FMT(FMT_A5I3));
  quad_tex_px(ox + 8, 72, ox + 56, 120, 0, 0, 0, 16, 16);
  poly_attr(PA_FRONT | PA_ALPHA(24) | PA_ID(14));
  tex_param(TP_ADDR(0x100) | TP_SIZE(1, 1) | TP_FMT(FMT_A3I5));
  quad_tex_px(ox + 68, 72, ox + 116, 120, 0, 0, 0, 16, 16);

  tex_param(0);
  xquad(ox + 8, 132, 40, 36, FX(3), RGB(31, 31, 0), 20, 20, PA_XLU_DEPTH);
  xquad(ox + 24, 148, 36, 36, FX(1), RGB(0, 31, 31), 20, 21, 0);
  xquad(ox + 66, 132, 40, 36, FX(3), RGB(31, 0, 31), 20, 22, 0);
  xquad(ox + 82, 148, 36, 36, FX(1), RGB(31, 31, 31), 20, 23, 0);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  tex_param(0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  for (int y = 0; y < 192; y += 12)
    for (int x = 0; x < 128; x += 12) {
      color(((x + y) / 12 & 1) ? RGB(24, 24, 24) : RGB(8, 8, 12));
      quad_px(x, y, x + 12, y + 12, FX(-4));
    }
  group(0);
  group(128);
}

int main(void) {
  t3d_init(BLEND ? "3d_alpha: translucency" : "3d_alpha_noblend: blending off");
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 16; x++) {
      a5i3[y * 16 + x] = (x & 7) | ((y * 2 + (x >> 3)) << 3);
      a3i5[y * 16 + x] = ((x * 2) & 31) | ((y >> 1) << 5);
    }
  for (int i = 0; i < 32; i++) pal[i] = t3d_hue(i, 32);
  u8 *v = t3d_tex_begin();
  t3d_copy16(v, a5i3, sizeof a5i3);
  t3d_copy16(v + 0x100, a3i5, sizeof a3i5);
  t3d_tex_end(1);
  t3d_copy16(t3d_pal_begin(), pal, sizeof pal);
  t3d_pal_end();
  PAL_A_BG[0] = RGB(0, 10, 4);
  BLDCNT_A = BLD_ALPHA_BG0_OVER_BACKDROP;
  BLDALPHA_A = 8 | (8 << 8);
  DISP3DCNT = D3_TEX | D3_ALPHATEST | BLEND;
  alpha_ref(15);
  clear_color(RGB(31, 0, 0), 0, 0, 0);
  while (1) {
    pltt_base(0);
    scene();
    t3d_frame(1);
  }
}
