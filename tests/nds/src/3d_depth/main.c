// 3d_depth: depth buffering (GBATEK "DS 3D Polygon Attributes" depth test,
// SWAP_BUFFERS bit 1). Perspective projection (fovy 60, near 0.5, far 12).
// 3d_depth: Z-buffer; 3d_depth_w: W-buffer.
//   left:   two quads intersecting along a slanted line (one tilted about
//           Y, the other about X)
//   centre: a grey quad at z -3; over it, same plane: red with the depth-
//           equal test, green with equal at a z offset of +0.002 (inside
//           the tolerance in Z mode), blue equal at +0.06 (outside), and
//           yellow with the normal less test at the same depth (fails)
//   right:  a rotated cube (opaque faces of 6 colours, IDs differ)
//   bottom: a far quad at z -11 partly behind the clear depth 0x7E00, and
//           a long floor strip from z -1 to -11
#include "t3d.h"

#ifndef WBUF
#define WBUF 0
#endif

static void qz(float x0, float y0, float x1, float y1, float z) {
  begin(QUADS);
  vtx16(FX(x0), FX(y0), FX(z)); vtx16(FX(x0), FX(y1), FX(z));
  vtx16(FX(x1), FX(y1), FX(z)); vtx16(FX(x1), FX(y0), FX(z));
}

static void cube(void) {
  static const s8 f[6][4][3] = {
    {{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}},
    {{1, -1, -1}, {-1, -1, -1}, {-1, 1, -1}, {1, 1, -1}},
    {{1, -1, 1}, {1, -1, -1}, {1, 1, -1}, {1, 1, 1}},
    {{-1, -1, -1}, {-1, -1, 1}, {-1, 1, 1}, {-1, 1, -1}},
    {{-1, 1, 1}, {1, 1, 1}, {1, 1, -1}, {-1, 1, -1}},
    {{-1, -1, -1}, {1, -1, -1}, {1, -1, 1}, {-1, -1, 1}},
  };
  for (int i = 0; i < 6; i++) {
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(10 + i));
    color(t3d_hue(i, 6));
    begin(QUADS);
    for (int k = 0; k < 4; k++) vtx16(f[i][k][0] * FX(0.5), f[i][k][1] * FX(0.5), f[i][k][2] * FX(0.5));
  }
}

static void scene(void) {
  t3d_proj_persp(60, 256.0f / 192.0f, 0.5f, 12.0f);
  mtx_identity();
  // intersecting pair
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  mtx_push();
  mtx_trans(FX(-2.0), FX(0.6), FX(-3.5));
  static const s32 ry[9] = {3547, 0, -2048, 0, 4096, 0, 2048, 0, 3547};   // 30 deg about Y
  static const s32 rx[9] = {4096, 0, 0, 0, 3547, 2048, 0, -2048, 3547};   // 30 deg about X
  mtx_push();
  mtx_mult33(ry);
  color(RGB(31, 20, 0));
  qz(-0.7, -0.7, 0.7, 0.7, 0);
  mtx_pop(1);
  mtx_mult33(rx);
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(2));
  color(RGB(0, 20, 31));
  qz(-0.7, -0.7, 0.7, 0.7, 0);
  mtx_pop(1);

  // equal tests
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(3));
  color(RGB(14, 14, 14));
  qz(-0.9, -0.3, 0.9, 1.3, -3);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(4) | PA_DEPTH_EQ);
  color(RGB(31, 0, 0));
  qz(-0.8, 0.5, -0.1, 1.2, -3);
  color(RGB(0, 31, 0));
  qz(0.1, 0.5, 0.8, 1.2, -3 + 0.002);
  color(RGB(0, 0, 31));
  qz(-0.8, -0.2, -0.1, 0.4, -3 + 0.06);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(5));
  color(RGB(31, 31, 0));
  qz(0.1, -0.2, 0.8, 0.4, -3);

  // cube
  mtx_push();
  mtx_trans(FX(1.9), FX(0.5), FX(-3.2));
  static const s32 r1[9] = {3547, 1024, -1773, 0, 3547, 2048, 2048, -1773, 3072};
  mtx_mult33(r1);
  cube();
  mtx_pop(1);

  // far
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(20));
  color(RGB(31, 0, 31));
  mtx_push();
  mtx_trans(0, 0, FX(-11));   // vertices stop at +-8.0
  qz(-7, -6, 7, -2, 0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(21));
  mtx_trans(0, 0, FX(5));
  begin(QUADS);
  color(RGB(31, 31, 31)); vtx16(FX(-0.6), FX(-1.2), FX(5));
  color(RGB(31, 31, 31)); vtx16(FX(0.6), FX(-1.2), FX(5));
  color(RGB(0, 0, 0)); vtx16(FX(0.6), FX(-1.2), FX(-5));
  color(RGB(0, 0, 0)); vtx16(FX(-0.6), FX(-1.2), FX(-5));
  mtx_pop(1);
}

int main(void) {
  t3d_init(WBUF ? "3d_depth_w: W-buffer" : "3d_depth: Z-buffer");
  clear_color(RGB(4, 6, 4), 31, 0, 0);
  clear_depth(0x7E00);
  while (1) {
    scene();
    t3d_frame(WBUF ? 2 : 0);
  }
}
