// 3d_probe_zmap: how a vertex's clip-space z and w become its 24-bit
// Z-buffer depth. GBATEK gives the depth buffer's range (0..FFFFFFh) and how
// CLEAR_DEPTH's 15-bit value D widens to 24 bits (D * 200h, plus 1FFh for
// 7FFFh), but not the mapping from z / w; this ROM reads it off against the
// clear depth.
//
// Twelve bands of 16 lines, one clip-space w each; 32 cells of 8 dots, cell
// c a flat quad at clip z = zc0 + c. Each cell shows its quad iff the depth
// test against the rear plane passes, so a band's visible cells bracket the
// depth at that z / w: the bias added to z / w (in 14-bit units), the
// rounding of the division for negative and inexact quotients, and the
// clamp at both ends of the range.
//   MODE 0 (3d_probe_zmap):      "less" against 4000h, z / w around 0
//   MODE 1 (3d_probe_zmap_eq):   "equal" (POLYGON_ATTR.14) against 4000h:
//                                the +-200h tolerance shows a window, its
//                                width the tolerance's ends, its place the
//                                bias
//   MODE 2 (3d_probe_zmap_far):  "less" against 7FFFh (FFFFFFh), z up to w
//   MODE 3 (3d_probe_zmap_near): "less" against 0001h (200h), z from -w
//
// The projection puts screen dot (x, y) at raw PX(x), PX(y) for any w (as
// t3d_proj_px), takes no z from the vertex (row 2 of the matrix is zero) and
// adds the band's z through the translation row, so the vertex's clip z is
// exactly zc and its clip w exactly W.
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static const s32 ws[12] = {
  0x4000, 0x3000, 0x5000, 0x1800, 0x2000, 0x2345,
  0x3333, 0x1001, 0x6000, 0x7FFF, 0x0C00, 0x4001,
};

static s32 zc0(s32 w) {
  if (MODE == 2) return w - 31;
  if (MODE == 3) return -w;
  return -(s32)(((long long)16 * w) >> 14);
}

static void proj(s32 w, s32 zc) {
  s32 m[16] = {
    w / 2, 0, 0, 0,
    0, -(2 * w) / 3, 0, 0,
    0, 0, 0, 0,
    -w, w, zc, w,
  };
  mtx_mode(0);
  mtx_load44(m);
  mtx_mode(1);
}

int main(void) {
  static const char *names[4] = {"3d_probe_zmap", "3d_probe_zmap_eq", "3d_probe_zmap_far", "3d_probe_zmap_near"};
  t3d_init(names[MODE]);
  t3d_print(0, 2, "z/w -> 24-bit depth against");
  t3d_print(0, 3, "the clear depth, 12 w bands");
  clear_color(RGB(4, 4, 4), 31, 0, 0);
  clear_depth(MODE == 2 ? 0x7FFF : MODE == 3 ? 0x0001 : 0x4000);
  while (1) {
    for (int b = 0; b < 12; b++) {
      for (int c = 0; c < 32; c++) {
        proj(ws[b], zc0(ws[b]) + c);
        mtx_identity();
        poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1) | (MODE == 1 ? PA_DEPTH_EQ : 0));
        color(t3d_hue(b, 12));
        quad_px(c * 8 + 1, b * 16 + 2, c * 8 + 7, b * 16 + 14, 0);
      }
    }
    t3d_frame(0);
  }
}
