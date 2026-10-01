// 3d_vcolor: vertex colour interpolation (Gouraud) and the 5->6 bit colour
// expansion (GBATEK "DS 3D Polygon Attributes", COLOR).
//   top-left:     RGB triangle
//   top-middle:   four-colour trapezoid (quad)
//   top-right:    triangle strip of 6 vertices, alternating colours
//   bottom-left:  a quad tilted away under a perspective projection
//                 (perspective-correct colour), black/white/red/blue corners
//   bottom-right: slivers: long thin triangles at shallow and steep slopes,
//                 and a 1-step ramp quad (colour 0..31 across 32 dots)
#include "t3d.h"

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  tex_param(0);
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31));
  begin(TRIS);
  color(RGB(31, 0, 0)); vtx16(PX(8), PX(88), 0);
  color(RGB(0, 31, 0)); vtx16(PX(80), PX(80), 0);
  color(RGB(0, 0, 31)); vtx16(PX(30), PX(6), 0);

  begin(QUADS);
  color(RGB(31, 31, 0)); vtx16(PX(100), PX(10), 0);
  color(RGB(0, 31, 31)); vtx16(PX(88), PX(86), 0);
  color(RGB(31, 0, 31)); vtx16(PX(170), PX(86), 0);
  color(RGB(31, 31, 31)); vtx16(PX(150), PX(10), 0);

  begin(TRI_STRIP);
  for (int i = 0; i < 6; i++) {
    color(i & 1 ? RGB(31, 16, 0) : RGB(0, 16, 31));
    vtx16(PX(180 + (i / 2) * 30 + (i & 1) * 9), PX(i & 1 ? 84 : 10), 0);
  }

  // slivers
  begin(TRIS);
  color(RGB(31, 31, 31)); vtx16(PX(130), PX(100), 0);
  color(RGB(0, 0, 0)); vtx16(PX(132), PX(104), 0);
  color(RGB(31, 0, 0)); vtx16(PX(250), PX(108), 0);
  color(RGB(0, 31, 0)); vtx16(PX(240), PX(112), 0);
  color(RGB(0, 0, 31)); vtx16(PX(236), PX(186), 0);
  color(RGB(31, 31, 0)); vtx16(PX(243), PX(186), 0);
  begin(QUADS);
  color(RGB(0, 0, 0)); vtx16(PX(140), PX(150), 0); vtx16(PX(140), PX(160), 0);
  color(RGB(31, 31, 31)); vtx16(PX(172), PX(160), 0); vtx16(PX(172), PX(150), 0);
  color(RGB(0, 0, 0)); vtx16(PX(140), PX(166), 0); vtx16(PX(140), PX(176), 0);
  color(RGB(0, 31, 0)); vtx16(PX(204), PX(176), 0); vtx16(PX(204), PX(166), 0);

  // perspective quad
  t3d_proj_persp(60, 256.0f / 192.0f, 0.25f, 16.0f);
  mtx_identity();
  mtx_trans(FX(-1.1), FX(-0.6), FX(-2.6));
  static const s32 rot[9] = {4096, 0, 0, 0, 1024, -3965, 0, 3965, 1024};   // ~ -75.5 deg about X
  mtx_mult33(rot);
  begin(QUADS);
  color(RGB(0, 0, 0)); vtx16(FX(-0.6), FX(-1.6), 0);
  color(RGB(31, 31, 31)); vtx16(FX(0.6), FX(-1.6), 0);
  color(RGB(31, 0, 0)); vtx16(FX(0.6), FX(1.6), 0);
  color(RGB(0, 0, 31)); vtx16(FX(-0.6), FX(1.6), 0);
}

int main(void) {
  t3d_init("3d_vcolor: vertex colours");
  clear_color(RGB(4, 4, 4), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
