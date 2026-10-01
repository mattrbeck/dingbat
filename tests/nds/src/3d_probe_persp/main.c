// 3d_probe_persp: perspective-correct interpolation probe. The triangles of
// 3d_probe_tri (same LCG, seed 1, whole-dot screen positions, red / green /
// blue vertices) but each vertex gets its own w: the projection passes
// (x, y) through and sets clip w = vertex z, clip z = 0, and each vertex is
// sent as (3m(sx - 128), 4m(96 - sy), 384m) for a random m in 2..21, so it
// lands exactly on dot (sx, sy) with w = 384m / 4096.
//   MODE 0: vertex colours   MODE 1 (3d_probe_persp_tex): a 32x32 direct
//   texture with texcoords (0,0), (32,0), (0,32) per vertex, colour white
// WSCALE 16 / 256 (3d_probe_persp_w16 / _w256): w 16 / 256 times larger.
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif
#ifndef WSCALE
#define WSCALE 1   // the projection scales x, y and w by this (same dots, bigger w)
#endif

static u32 seed;
static int rnd(int n) {
  seed = seed * 1103515245u + 12345u;
  return ((seed >> 16) & 0x7FFF) % n;
}

static u16 tex[32 * 32];

static void scene(void) {
  static const s32 proj[16] = {
    4096 * WSCALE, 0, 0, 0,
    0, 4096 * WSCALE, 0, 0,
    0, 0, 0, 4096 * WSCALE,
    0, 0, 0, 0,
  };
  mtx_mode(0);
  mtx_load44(proj);
  mtx_mode(1);
  mtx_identity();
  seed = 1;
  for (int k = 0; k < 48; k++) {
    int cx = (k % 8) * 32, cy = (k / 8) * 32;
    int x[3], y[3];
    for (int i = 0; i < 3; i++) {
      x[i] = cx + 2 + rnd(28);
      y[i] = cy + 2 + rnd(28);
    }
    int m[3];
    for (int i = 0; i < 3; i++) m[i] = 2 + rnd(20);
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(k & 63));
    if (MODE == 1) {
      tex_param(TP_ADDR(0) | TP_SIZE(2, 2) | TP_FMT(FMT_DIRECT));
      color(0x7FFF);
    }
    begin(TRIS);
    for (int i = 0; i < 3; i++) {
      if (MODE == 0) color(i == 0 ? RGB(31, 0, 0) : i == 1 ? RGB(0, 31, 0) : RGB(0, 0, 31));
      else texcoord(i == 1 ? 32 * 16 : 0, i == 2 ? 32 * 16 : 0);
      vtx16(3 * m[i] * (x[i] - 128), 4 * m[i] * (96 - y[i]), 384 * m[i]);
    }
  }
}

int main(void) {
  t3d_init("3d_probe_persp");
  for (int y = 0; y < 32; y++)
    for (int x = 0; x < 32; x++) tex[y * 32 + x] = RGB(x, y, (x ^ y) & 31) | 0x8000;
  t3d_copy16(t3d_tex_begin(), tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = MODE == 1 ? D3_TEX : 0;
  clear_color(RGB(1, 1, 1), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
