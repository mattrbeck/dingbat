// 3d_lines: line segments and wire-frames (GBATEK "DS 3D Polygon
// Definitions by Vertices": a triangle with a repeated vertex is a line,
// always drawn; "DS 3D Polygon Attributes": alpha 0 = wire-frame).
//   left:   a star of 24 opaque lines from (64, 64), radius 56, both
//           vertex orders alternating, colours by angle
//   right:  wire-frame triangle, quad, thin sliver, axis-aligned quad, a
//           quad strip (alpha 0), and a textured wire-frame quad (direct
//           texture, every third texel transparent)
//   bottom: translucent (a16) line star half over an opaque bar; lines
//           drawn as degenerate quads (two vertices twice); lines with a
//           sub-dot fractional start (1/64 steps)
#include "t3d.h"

static u16 tex[64];

static void line(s32 x0, s32 y0, s32 x1, s32 y1, s32 z) {
  begin(TRIS);
  vtx16(x0, y0, z); vtx16(x1, y1, z); vtx16(x1, y1, z);
}

static void star(int cx, int cy, int r, int n, int alpha) {
  for (int k = 0; k < n; k++) {
    float a = k * 6.2831853f / n + 0.05f;
    s32 x = (s32)((cx + r * cosf(a)) * 64), y = (s32)((cy + r * sinf(a)) * 64);
    poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(k & 1 ? 1 : 2));
    color(t3d_hue(k, n));
    if (k & 1) line(PX(cx), PX(cy), x, y, 0);
    else line(x, y, PX(cx), PX(cy), 0);
  }
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  tex_param(0);
  star(64, 64, 56, 24, 31);

  poly_attr(PA_BOTH | PA_ALPHA(0) | PA_ID(3));
  color(RGB(31, 31, 31));
  tri_px(140, 10, 150, 60, 200, 30, 0);
  begin(QUADS);
  vtx16(PX(210), PX(8), 0); vtx16(PX(205), PX(50), 0); vtx16(PX(250), PX(56), 0); vtx16(PX(244), PX(14), 0);
  color(RGB(31, 31, 0));
  tri_px(140, 70, 141, 120, 250, 75, 0);
  quad_px(150, 85, 190, 110, 0);
  color(RGB(0, 31, 31));
  begin(QUAD_STRIP);
  for (int i = 0; i < 4; i++) {
    vtx16(PX(196 + i * 18), PX(84), 0);
    vtx16(PX(196 + i * 18 + 4), PX(118), 0);
  }
  color(0x7FFF);
  tex_param(TP_ADDR(0) | TP_SIZE(0, 0) | TP_FMT(FMT_DIRECT) | TP_REPS | TP_REPT);
  quad_tex_px(140, 126, 180, 156, 0, 0, 0, 40, 30);
  tex_param(0);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(4));
  color(RGB(10, 10, 20));
  quad_px(0, 150, 128, 170, FX(-1));
  star(64, 160, 30, 12, 16);

  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(5));
  color(RGB(31, 0, 0));
  begin(QUADS);
  vtx16(PX(190), PX(130), 0); vtx16(PX(250), PX(150), 0); vtx16(PX(250), PX(150), 0); vtx16(PX(190), PX(130), 0);
  color(RGB(0, 31, 0));
  for (int k = 0; k < 8; k++)
    line(PX(190) + k * 9, PX(160) + k * 7, PX(250) + k * 5, PX(170) + k * 3, 0);
}

int main(void) {
  t3d_init("3d_lines: lines + wire-frames");
  for (int i = 0; i < 64; i++) tex[i] = t3d_hue(i, 64) | ((i % 3) ? 0x8000 : 0);
  t3d_copy16(t3d_tex_begin(), tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = D3_TEX | D3_BLEND;
  clear_color(RGB(2, 2, 6), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
