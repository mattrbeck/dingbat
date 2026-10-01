// 3d_probe_tri: rasteriser probe. 48 pseudo-random triangles, one per
// 32x32 cell (8 columns x 6 rows), vertices on whole dots in 2..29 of the
// cell, pixel-space projection, both faces drawn. The vertex list is a
// simple LCG (seed below) so a model of the rasteriser can be run on the
// same triangles and compared dot for dot.
//   MODE 0 (3d_probe_tri):     flat colour per triangle, opaque
//   MODE 1 (3d_probe_tri_rgb): vertices red / green / blue, opaque
//   MODE 2 (3d_probe_tri_xlu): flat colour, alpha 16 with blending on
//   MODE 3 (3d_probe_tri_edge): flat colour, opaque, edge marking on
//           (edge colours equal to the polygon colour's group: all white)
//   MODE 4 (3d_probe_line): line segments: the third vertex repeats the second
//   MODE 5 (3d_probe_wire): wire-frame (alpha 0)
// SEED picks another set; FLAT keeps each triangle's rows within 4.
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif
#ifndef SEED
#define SEED 1
#endif
#ifndef FLAT
#define FLAT 0   // 1: vertex y within 0..3 of each other (thin, 1-4 row polygons)
#endif

static u32 seed;
static int rnd(int n) {
  seed = seed * 1103515245u + 12345u;
  return ((seed >> 16) & 0x7FFF) % n;
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  seed = SEED;
  for (int k = 0; k < 48; k++) {
    int cx = (k % 8) * 32, cy = (k / 8) * 32;
    int x[3], y[3];
    for (int i = 0; i < 3; i++) {
      x[i] = cx + 2 + rnd(28);
      y[i] = FLAT ? (i == 0 ? cy + 2 + rnd(25) : y[0] + rnd(4)) : cy + 2 + rnd(28);
    }
    if (MODE == 4) {
      x[2] = x[1];
      y[2] = y[1];
    }
    poly_attr(PA_BOTH | PA_ALPHA(MODE == 2 ? 16 : MODE == 5 ? 0 : 31) | PA_ID(k & 63));
    begin(TRIS);
    for (int i = 0; i < 3; i++) {
      if (MODE == 1) color(i == 0 ? RGB(31, 0, 0) : i == 1 ? RGB(0, 31, 0) : RGB(0, 0, 31));
      else color(t3d_hue(k, 48));
      vtx16(PX(x[i]), PX(y[i]), 0);
    }
  }
}

int main(void) {
  t3d_init("3d_probe_tri");
  for (int i = 0; i < 8; i++) edge_color(i, 0x7FFF);
  DISP3DCNT = MODE == 2 ? D3_BLEND : MODE == 3 ? D3_EDGE : 0;
  clear_color(RGB(2, 2, 2), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
