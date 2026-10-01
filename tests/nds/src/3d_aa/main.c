// 3d_aa: anti-aliasing (GBATEK "DS 3D Toon, Edge, Fog, Alpha-Blending,
// Anti-Aliasing"), DISP3DCNT.4 and .3 on, rear plane dark blue alpha 31.
//   top-left:  white triangle with a shallow top edge, a steep left edge
//              and a 45-degree edge, over the rear plane
//   top-mid:   red quad rotated 10 degrees over a green opaque quad
//              (edges over a polygon), plus the same rotation at 30 deg
//   top-right: translucent (a20) rotated quad: no anti-aliasing
//   bottom-left: opaque line segments (degenerate triangles) at 5 slopes,
//              opaque wire-frame triangle, single 1-dot polygon
//   bottom-mid: the same lines and wire-frame at alpha 30
//   bottom-right: a fan of thin opaque slivers meeting at a point, and a
//              two-triangle quad (the shared diagonal must stay solid)
#include "t3d.h"

static void rquad(float cx, float cy, float hw, float hh, float deg, s32 z) {
  float a = deg * 3.14159265f / 180.0f, c = cosf(a), s = sinf(a);
  float xs[4] = {-hw, -hw, hw, hw}, ys[4] = {-hh, hh, hh, -hh};
  begin(QUADS);
  for (int k = 0; k < 4; k++)
    vtx16((s32)((cx + xs[k] * c - ys[k] * s) * 64), (s32)((cy + xs[k] * s + ys[k] * c) * 64), z);
}

static void line(int x0, int y0, int x1, int y1) {
  begin(TRIS);
  vtx16(PX(x0), PX(y0), FX(1)); vtx16(PX(x1), PX(y1), FX(1)); vtx16(PX(x1), PX(y1), FX(1));
}

static void lines(int ox, int alpha) {
  poly_attr(PA_BOTH | PA_ALPHA(alpha) | PA_ID(20 + alpha / 10));
  color(RGB(31, 31, 0));
  line(ox + 4, 104, ox + 80, 108);
  line(ox + 4, 112, ox + 60, 130);
  line(ox + 4, 136, ox + 44, 176);
  line(ox + 70, 120, ox + 76, 186);
  line(ox + 84, 110, ox + 84, 186);
  poly_attr(PA_BOTH | PA_ALPHA(0) | PA_ID(30));
  color(RGB(0, 31, 31));
  if (alpha == 30) poly_attr(PA_BOTH | PA_ALPHA(0) | PA_ID(31));
  tri_px(ox + 20, 150, ox + 30, 186, ox + 60, 160, FX(1));
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  color(RGB(31, 31, 31));
  tri_px(6, 30, 50, 90, 80, 8, 0);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(2));
  color(RGB(0, 20, 0));
  quad_px(90, 4, 170, 90, 0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(3));
  color(RGB(31, 0, 0));
  rquad(115, 30, 18, 18, 10, FX(1));
  rquad(145, 64, 18, 18, 30, FX(1));

  poly_attr(PA_FRONT | PA_ALPHA(20) | PA_ID(4));
  color(RGB(31, 16, 31));
  rquad(212, 48, 30, 30, 20, FX(1));

  lines(0, 31);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(5));
  color(RGB(31, 31, 31));
  tri_px(50, 100, 50, 100, 50, 100, FX(1));
  lines(90, 30);

  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(6));
  for (int k = 0; k < 6; k++) {
    color(t3d_hue(k, 6));
    float a0 = k * 0.26f, a1 = a0 + 0.13f;
    begin(TRIS);
    vtx16(PX(186), PX(186), 0);
    vtx16((s32)((186 - 70 * cosf(a0)) * 64), (s32)((186 - 70 * sinf(a0)) * 64), 0);
    vtx16((s32)((186 - 70 * cosf(a1)) * 64), (s32)((186 - 70 * sinf(a1)) * 64), 0);
  }
  color(RGB(16, 16, 31));
  begin(TRIS);
  vtx16(PX(224), PX(110), 0); vtx16(PX(218), PX(170), 0); vtx16(PX(252), PX(150), 0);
  vtx16(PX(224), PX(110), 0); vtx16(PX(252), PX(150), 0); vtx16(PX(250), PX(104), 0);
}

int main(void) {
  t3d_init("3d_aa: anti-aliasing");
  DISP3DCNT = D3_AA | D3_BLEND;
  clear_color(RGB(0, 0, 10), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
