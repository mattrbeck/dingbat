// 3d_rearbitmap: the rear-plane bitmap (GBATEK "DS 3D Rear-Plane"),
// DISP3DCNT.14. Colour bitmap in texture slot 2 (bank C), depth + fog
// bitmap in slot 3 (bank D), CLRIMAGE_OFFSET x 37, y 99.
//   colour: a hue per 16x16 block, with transparent (bit 15 clear) dots on a
//           diagonal lattice and a white cross at bitmap (0,0)
//   depth:  ramps 0..0x7FFF left to right across the bitmap, fog bit set in
//           bitmap rows 128..255
// Two constant-depth quads cross the depth ramp (z = 0 -> 0x3FFF, and
// z = +4 -> 0x1FFF) so the depth test cuts them where the bitmap is nearer.
// Fog on (colour white, density ramp, offset 0, shift 0) for fog-flagged
// rear dots and the fogged right quad.
#include "t3d.h"

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  color(RGB(31, 31, 0));
  quad_px(10, 20, 120, 170, 0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(2) | PA_FOG);
  color(RGB(0, 31, 31));
  quad_px(136, 20, 246, 170, FX(4));
}

int main(void) {
  t3d_init("3d_rearbitmap: rear-plane bitmap");
  u8 *v = t3d_tex_begin();
  vu16 *col = (vu16 *)(v + 0x40000);
  vu16 *dep = (vu16 *)(v + 0x60000);
  for (int y = 0; y < 256; y++)
    for (int x = 0; x < 256; x++) {
      u16 c = t3d_hue((x >> 4) + (y >> 4) * 3, 16);
      if (x < 8 && y < 8 && (x == 3 || y == 3)) c = 0x7FFF;
      int hole = ((x + y) % 23) == 0;
      col[y * 256 + x] = c | (hole ? 0 : 0x8000);
      dep[y * 256 + x] = (x * 0x7FFF / 255) | (y >= 128 ? 0x8000 : 0);
    }
  t3d_tex_end(4);
  for (int k = 0; k < 32; k++) fog_density(k, k * 4);
  fog_color(RGB(31, 31, 31), 31);
  fog_offset(0);
  R16(0x04000356) = 37 | (99 << 8);
  clear_color(0, 31, 7, 0);
  DISP3DCNT = D3_REAR_BITMAP | D3_FOG | D3_FOG_SHIFT(0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
