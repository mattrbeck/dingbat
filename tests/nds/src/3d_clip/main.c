// 3d_clip: clipping (GBATEK "DS 3D Polygon Definitions by Vertices",
// Clipping; POLYGON_ATTR.12 far-plane polygons; VIEWPORT).
// Viewport (24, 16)-(231, 175) (bottom-up y), perspective fovy 70,
// near 1, far 8; a white frame at the viewport bounds drawn afterwards
// with the full viewport.
//   floor: a 16x16-texel checker quad from z +2 (behind the eye) to -7,
//          8 wide: clipped by the near and side planes
//   left:  an RGB triangle with one vertex in front of the near plane
//   right: two quads reaching past the far plane: magenta with
//          POLYGON_ATTR.12 (clipped), yellow without (hidden)
//   top:   a strip of 4 triangles crossing the top plane, vertex colours
#include "t3d.h"

static u16 tex[256];

static void scene(void) {
  viewport(24, 16, 231, 175);
  t3d_proj_persp(70, 208.0f / 160.0f, 1.0f, 8.0f);
  mtx_identity();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  color(0x7FFF);
  tex_param(TP_ADDR(0) | TP_SIZE(1, 1) | TP_FMT(FMT_DIRECT) | TP_REPS | TP_REPT);
  begin(QUADS);
  texcoord(0, 0); vtx16(FX(-4), FX(-1), FX(2));
  texcoord(64 * 16, 0); vtx16(FX(4), FX(-1), FX(2));
  texcoord(64 * 16, 72 * 16); vtx16(FX(4), FX(-1), FX(-7));
  texcoord(0, 72 * 16); vtx16(FX(-4), FX(-1), FX(-7));
  tex_param(0);

  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(2));
  begin(TRIS);
  color(RGB(31, 0, 0)); vtx16(FX(-1.6), FX(-0.5), FX(-3));
  color(RGB(0, 31, 0)); vtx16(FX(-0.4), FX(-0.2), FX(0.5));
  color(RGB(0, 0, 31)); vtx16(FX(-1.2), FX(1.2), FX(-3));

  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(3) | PA_FAR_RENDER);
  color(RGB(31, 0, 31));
  begin(QUADS);
  vtx16(FX(0.6), FX(0.0), FX(-5)); vtx16(FX(0.6), FX(-0.6), FX(-5));
  vtx16(FX(1.6), FX(-0.6), FX(-7.9)); vtx16(FX(1.6), FX(0.0), FX(-7.9));
  mtx_push();
  mtx_trans(0, 0, FX(-4));
  vtx16(FX(0.6), FX(0.2), FX(-1)); vtx16(FX(0.6), FX(0.8), FX(-1));
  vtx16(FX(2.0), FX(0.8), FX(-6)); vtx16(FX(2.0), FX(0.2), FX(-6));
  mtx_pop(1);
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(4));
  color(RGB(31, 31, 0));
  mtx_push();
  mtx_trans(0, 0, FX(-4));
  begin(QUADS);
  vtx16(FX(0.6), FX(1.0), FX(-1)); vtx16(FX(0.6), FX(1.6), FX(-1));
  vtx16(FX(2.2), FX(1.6), FX(-6)); vtx16(FX(2.2), FX(1.0), FX(-6));
  mtx_pop(1);

  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(5));
  begin(TRI_STRIP);
  for (int i = 0; i < 6; i++) {
    color(t3d_hue(i, 6));
    vtx16(FX(-1.0 + 0.4 * i), i & 1 ? FX(2.4) : FX(1.3), FX(-3));
  }

  viewport(0, 0, 255, 191);
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_BOTH | PA_ALPHA(0) | PA_ID(6));
  color(0x7FFF);
  quad_px(23, 15, 232, 176, FX(7));
}

int main(void) {
  t3d_init("3d_clip: clipping + viewport");
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 16; x++)
      tex[y * 16 + x] = (((x >> 2) ^ (y >> 2)) & 1 ? RGB(31, 31, 31) : RGB(6, 12, 6)) |
                        (x == 0 || y == 0 ? RGB(31, 0, 0) : 0) | 0x8000;
  t3d_copy16(t3d_tex_begin(), tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = D3_TEX;
  clear_color(RGB(4, 2, 8), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
