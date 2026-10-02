// 3d_probe_zinterp: how Z-buffer depth is interpolated, read off where
// flat strips start to win against a sloped polygon. A grey quad A (rows
// 20..180) gets 1/64-dot-unit steps of depth: its z falls from 0 at the top
// to -80/4096 at the bottom, i.e. its 24-bit depth rises 0x80 per row
// (z24 = ((z << 14) / w + 0x3FFF) * 0x200 at w = 3). Then 40 coloured strips
// k = 0..39, 6 dots wide, flat at z = -2k/4096 (depth 0x200 k above A's
// top) are drawn over it: strip k shows where its depth is less than A's,
// so its first row gives A's depth on that row to a quarter row.
//   MODE 0 (3d_probe_zinterp):    A's left/right edges vertical (depth
//                                 from the edges, constant across a row)
//   MODE 1 (3d_probe_zinterp_x):  A turned: depth rising 0x80 per dot from
//                                 x 8 to x 248, strips horizontal
//   MODE 2 (3d_probe_zinterp_s):  A a triangle with slanted edges (apex at
//                                 the top centre), strips vertical
//   MODE 3 (3d_probe_zinterp_y2): as 0 with the strips drawn first (they end
//                                 a row above A), so ties go the other way
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

int main(void) {
  t3d_init("3d_probe_zinterp");
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
    color(RGB(10, 10, 10));
    begin(MODE == 2 ? TRIS : QUADS);
    if (MODE == 0) {
      vtx16(PX(8), PX(20), 0); vtx16(PX(8), PX(180), -80);
      vtx16(PX(248), PX(180), -80); vtx16(PX(248), PX(20), 0);
    } else if (MODE == 1) {
      vtx16(PX(8), PX(4), 0); vtx16(PX(8), PX(188), 0);
      vtx16(PX(248), PX(188), -120); vtx16(PX(248), PX(4), -120);
    } else {
      vtx16(PX(128), PX(20), 0); vtx16(PX(8), PX(180), -80); vtx16(PX(248), PX(180), -80);
    }
    for (int k = 0; k < 40; k++) {
      poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(2));
      color(t3d_hue(k, 40));
      if (MODE == 1) quad_px(0, 4 + k * 4, 256, 8 + k * 4, -2 * k);   // drawn before A (bottom row higher)
      else if (MODE == 3) quad_px(8 + k * 6, 0, 14 + k * 6, 179, -2 * k);
      else quad_px(8 + k * 6, 0, 14 + k * 6, 190, -2 * k);
    }
    t3d_frame(0);
  }
}
