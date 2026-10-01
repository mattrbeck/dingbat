// 3d_small: polygon size rules and 1-dot polygons (GBATEK "DS 3D Toon,
// Edge, Fog, Alpha-Blending, Anti-Aliasing" Polygon Size;
// DISP_1DOT_DEPTH 0x4000610).
// Each row repeats one set of shapes at x = 8 + 20k: squares 1x1..4x4,
// 1x4, 4x1, 0x0 (one vertex thrice), a 3-dot right triangle, a 5-dot
// diamond, the 2x2 square at +1/2 dot, a 2x6 quad whose right edge leans.
//   row 0: opaque
//   row 1: translucent a16 (blending on: full size)
//   row 2: opaque, adjacent 3x3 quads tiled in a 4x2 block, and a strip
//   row 3: 1-dot polygons under a perspective projection at w = 1, 2, 3,
//          4, 6 with DISP_1DOT_DEPTH = 2.5 (0x14): w <= 2.5 drawn; the same
//          five with POLYGON_ATTR.13 (all drawn)
//   row 4: as row 0, but each shape a different vertex colour at its
//          first vertex (a 1-dot polygon takes its first vertex's colour)
#include "t3d.h"

static void shapes(int y, u32 attr, int multicolour) {
  poly_attr(attr);
  for (int k = 0; k < 11; k++) {
    int x = 8 + 20 * k;
    color(multicolour ? t3d_hue(k, 11) : RGB(31, 31, 31));
    switch (k) {
    case 0: case 1: case 2: case 3: quad_px(x, y, x + k + 1, y + k + 1, 0); break;
    case 4: quad_px(x, y, x + 1, y + 4, 0); break;
    case 5: quad_px(x, y, x + 4, y + 1, 0); break;
    case 6: tri_px(x, y, x, y, x, y, 0); break;
    case 7: tri_px(x, y, x, y + 3, x + 3, y + 3, 0); break;
    case 8:
      begin(QUADS);
      vtx16(PX(x + 2), PX(y), 0); vtx16(PX(x), PX(y + 2), 0);
      vtx16(PX(x + 2), PX(y + 5), 0); vtx16(PX(x + 5), PX(y + 2), 0);
      break;
    case 9:
      begin(QUADS);
      vtx16(PX(x) + 32, PX(y) + 32, 0); vtx16(PX(x) + 32, PX(y + 2) + 32, 0);
      vtx16(PX(x + 2) + 32, PX(y + 2) + 32, 0); vtx16(PX(x + 2) + 32, PX(y) + 32, 0);
      break;
    default:
      begin(QUADS);
      vtx16(PX(x), PX(y), 0); vtx16(PX(x), PX(y + 6), 0);
      vtx16(PX(x + 3), PX(y + 6), 0); vtx16(PX(x + 2), PX(y), 0);
      break;
    }
  }
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  shapes(8, PA_FRONT | PA_ALPHA(31) | PA_ID(1), 0);
  shapes(28, PA_FRONT | PA_ALPHA(16) | PA_ID(2), 0);
  shapes(132, PA_FRONT | PA_ALPHA(31) | PA_ID(4), 1);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(3));
  for (int j = 0; j < 2; j++)
    for (int i = 0; i < 4; i++) {
      color((i + j) & 1 ? RGB(31, 16, 0) : RGB(0, 16, 31));
      quad_px(8 + i * 3, 50 + j * 3, 11 + i * 3, 53 + j * 3, 0);
    }
  color(RGB(31, 31, 0));
  begin(TRI_STRIP);
  for (int i = 0; i < 10; i++) vtx16(PX(40 + i * 4), PX(i & 1 ? 58 : 50), 0);

  // 1-dot polygons in perspective: x spread by w so they land apart
  t3d_proj_persp(90, 256.0f / 192.0f, 0.5f, 16.0f);
  static const float ws[5] = {1, 2, 3, 4, 6};
  for (int r = 0; r < 2; r++) {
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(5) | (r ? PA_DOT_RENDER : 0));
    for (int i = 0; i < 5; i++) {
      float w = ws[i];
      float x = (-0.9f + 0.1f * i + r * 0.6f) * w * (256.0f / 192.0f), y = -0.1f * w;
      color(t3d_hue(i, 5));
      mtx_identity();
      mtx_trans(FX(x), FX(y), FX(-w));
      begin(TRIS);
      vtx16(0, 0, 0); vtx16(0, 0, 0); vtx16(0, 0, 0);
    }
  }
}

int main(void) {
  t3d_init("3d_small: polygon size, 1-dot");
  DISP3DCNT = D3_BLEND;
  R16(0x04000610) = 0x14;
  clear_color(RGB(0, 0, 6), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
