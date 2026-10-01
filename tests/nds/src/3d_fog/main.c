// 3d_fog: fog (GBATEK "DS 3D Toon, Edge, Fog, Alpha-Blending,
// Anti-Aliasing"). Pixel-space projection: every quad's z falls linearly
// from +7 (top row, near) to -7 (bottom, far), so the Z-buffer depth runs
// 0x07FF..0x77FF down the screen. FOG_SHIFT 1 (step 0x200), FOG_OFFSET
// 0x1C00, density table a quadratic ramp with density[0] = 8 and a dip at
// entries 20-21; fog colour (20, 24, 31), fog alpha 20.
// Columns (32 dots each, x = 0..255):
//   0 fog on, opaque     1 fog off, opaque
//   2 translucent a16 fog on over column 0's floor (drawn again at z+0.25)
//   3 translucent a16 fog OFF over a fog-on floor (flags AND: no fog)
//   4 rear plane (fog flag on, clear depth 0x6000)
//   5 opaque fog on at z = constant 0 (one density)
//   6 translucent a16 with depth update, fog on, over fog-on floor
//   7 rear plane strip with a fog-off opaque quad covering its lower half
// Engine A blends BG0 over a dark red backdrop so 3D alpha shows.
// 3d_fog_alpha: the same with DISP3DCNT.6 (alpha only).
#include "t3d.h"

#ifndef FOG_MODE
#define FOG_MODE 0
#endif

static void slope_quad(int x0, int x1, s32 dz, u32 attr, u16 c) {
  poly_attr(attr);
  color(c);
  begin(QUADS);
  vtx16(PX(x0), PX(0), FX(7) + dz);
  vtx16(PX(x0), PX(192), FX(-7) + dz);
  vtx16(PX(x1), PX(192), FX(-7) + dz);
  vtx16(PX(x1), PX(0), FX(7) + dz);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  const u16 floor = RGB(31, 16, 4);
  slope_quad(0, 32, 0, PA_FRONT | PA_ALPHA(31) | PA_ID(1) | PA_FOG, floor);
  slope_quad(32, 64, 0, PA_FRONT | PA_ALPHA(31) | PA_ID(2), floor);
  slope_quad(64, 96, 0, PA_FRONT | PA_ALPHA(31) | PA_ID(3) | PA_FOG, RGB(4, 16, 4));
  slope_quad(96, 128, 0, PA_FRONT | PA_ALPHA(31) | PA_ID(4) | PA_FOG, RGB(4, 16, 4));
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(5) | PA_FOG);
  color(RGB(31, 31, 0));
  quad_px(160, 0, 192, 192, 0);
  slope_quad(192, 224, 0, PA_FRONT | PA_ALPHA(31) | PA_ID(6) | PA_FOG, RGB(4, 16, 4));
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(7));
  color(RGB(0, 31, 31));
  quad_px(224, 96, 256, 192, FX(5));
  slope_quad(64, 96, FX(0.25), PA_FRONT | PA_ALPHA(16) | PA_ID(10) | PA_FOG, RGB(31, 0, 31));
  slope_quad(96, 128, FX(0.25), PA_FRONT | PA_ALPHA(16) | PA_ID(11), RGB(31, 0, 31));
  slope_quad(192, 224, FX(0.25), PA_FRONT | PA_ALPHA(16) | PA_ID(12) | PA_FOG | PA_XLU_DEPTH,
             RGB(31, 0, 31));
}

int main(void) {
  t3d_init(FOG_MODE ? "3d_fog_alpha: fog, alpha only" : "3d_fog: fog colour + alpha");
  for (int k = 0; k < 32; k++) {
    int d = 8 + k * k * 119 / 961;
    if (k == 20 || k == 21) d -= 30;
    fog_density(k, d);
  }
  fog_color(RGB(20, 24, 31), 20);
  fog_offset(0x1C00);
  clear_color(RGB(10, 0, 20), 31, 0, 1);
  clear_depth(0x6000);
  PAL_A_BG[0] = RGB(12, 0, 0);
  BLDCNT_A = BLD_ALPHA_BG0_OVER_BACKDROP;
  BLDALPHA_A = 8 | (8 << 8);
  DISP3DCNT = D3_BLEND | D3_FOG | D3_FOG_SHIFT(1) | (FOG_MODE ? D3_FOG_ALPHA : 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
