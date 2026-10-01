// 3d_shadow: shadow polygons (GBATEK "DS 3D Shadow Polygons"), seen from
// straight above with the pixel-space projection, manual translucent order.
// A floor (z -2, ID 1, a grid of two greys) carries a raised box (z +1,
// ID 5, orange). Each shadow volume is a top quad (front face, z_top) and
// a bottom quad (back face, z_bot); the mask pass draws the bottom with
// ID 0, the render pass both faces with the volume's ID.
//   A (40..140, 30..130): z +3 .. -4, black a16, ID 5: shades the floor,
//      not the box (same ID)
//   B (100..200, 70..150): z +3 .. 0, black a16, ID 6: bottom above the
//      floor, below the box top: shades only the box
//   C (150..230, 20..100): z +3 .. -4, blue a12, ID 7, overlaps A's ID-5
//      region nowhere but B's: a coloured "spotlight" volume
//   D (8..60, 140..184): mask only (no render pass): must leave no trace
//   E (180..250, 120..188): render pass only, no mask: draws everywhere it
//      is in front, except on ID 9
#include "t3d.h"

static void face(int x0, int y0, int x1, int y1, s32 z, int back) {
  begin(QUADS);
  if (back) {   // clockwise on screen
    vtx16(PX(x0), PX(y0), z); vtx16(PX(x1), PX(y0), z);
    vtx16(PX(x1), PX(y1), z); vtx16(PX(x0), PX(y1), z);
  } else {
    vtx16(PX(x0), PX(y0), z); vtx16(PX(x0), PX(y1), z);
    vtx16(PX(x1), PX(y1), z); vtx16(PX(x1), PX(y0), z);
  }
}

static void mask(int x0, int y0, int x1, int y1, s32 zbot) {
  poly_attr(PA_SHADOW | PA_BACK | PA_ALPHA(16) | PA_ID(0));
  color(0);
  face(x0, y0, x1, y1, zbot, 1);
}

static void render(int x0, int y0, int x1, int y1, s32 ztop, s32 zbot, u16 c, int alpha, int id) {
  poly_attr(PA_SHADOW | PA_BOTH | PA_ALPHA(alpha) | PA_ID(id));
  color(c);
  face(x0, y0, x1, y1, ztop, 0);
  face(x0, y0, x1, y1, zbot, 1);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  for (int y = 0; y < 192; y += 16)
    for (int x = 0; x < 256; x += 16) {
      color(((x + y) & 16) ? RGB(22, 22, 20) : RGB(16, 16, 14));
      quad_px(x, y, x + 16, y + 16, FX(-2));
    }
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(5));
  color(RGB(31, 16, 0));
  quad_px(90, 50, 170, 120, FX(1));
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(9));
  color(RGB(0, 24, 8));
  quad_px(200, 150, 236, 176, FX(1));

  mask(40, 30, 140, 130, FX(-4));
  render(40, 30, 140, 130, FX(3), FX(-4), 0, 16, 5);
  mask(100, 70, 200, 150, 0);
  render(100, 70, 200, 150, FX(3), 0, 0, 16, 6);
  mask(150, 20, 230, 100, FX(-4));
  render(150, 20, 230, 100, FX(3), FX(-4), RGB(0, 0, 31), 12, 7);
  mask(8, 140, 60, 184, FX(-4));
  render(180, 120, 250, 188, FX(3), FX(-4), RGB(31, 0, 0), 16, 9);
}

int main(void) {
  t3d_init("3d_shadow: shadow volumes");
  DISP3DCNT = D3_BLEND;
  clear_color(RGB(0, 0, 8), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(1);
  }
}
