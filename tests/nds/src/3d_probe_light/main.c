// 3d_probe_light: lighting probe. 16x12 flat quads (16x16 dots), each lit
// with one NORMAL before each of its vertices, so the quad's colour is the
// NORMAL command's result for that normal. The normal of the quad at
// (col, row) is (n(col), n(row), sqrt(1 - x^2 - y^2)) with
// n(i) = (i - 7.5) * 0.11 (rows downwards: y negated), as 1.9 values.
// Light 0 only, colour white, vector (-0.3, -0.4, -0.866) under an
// identity vector matrix.
//   MODE 0 (3d_probe_light):      diffuse (31,31,31) only
//   MODE 1 (3d_probe_light_spec): specular (31,31,31) only, linear table
//   MODE 2 (3d_probe_light_tab):  specular with a shininess table
//                                 entry i = 255 - 2i (descending, so the
//                                 index shows directly)
//   MODE 3 (3d_probe_light_sum):  diffuse (20,24,28) + ambient (10,6,4) +
//                                 emission (4,8,12) + specular (12,10,8):
//                                 sums and the clamp at 31
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static s16 nx[16], ny[12];
static s16 nz[12][16];
static u32 table[32];

static void scene(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  mtx_mode(2);
  mtx_identity();
  light_vector(0, (int)(-0.3 * 511), (int)(-0.4 * 511), (int)(-0.866 * 511));
  mtx_mode(1);
  light_color(0, RGB(31, 31, 31));
  if (MODE == 2) shininess(table);
  switch (MODE) {
  case 0: dif_amb(RGB(31, 31, 31)); spe_emi(0); break;
  case 1: dif_amb(0); spe_emi(RGB(31, 31, 31)); break;
  case 2: dif_amb(0); spe_emi(RGB(31, 31, 31) | 0x8000); break;
  default:
    dif_amb(RGB(20, 24, 28) | ((u32)RGB(10, 6, 4) << 16));
    spe_emi(RGB(12, 10, 8) | ((u32)RGB(4, 8, 12) << 16));
    break;
  }
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1) | PA_LIGHTS(1));
  for (int r = 0; r < 12; r++)
    for (int c = 0; c < 16; c++) {
      begin(QUADS);
      int xs[4] = {0, 0, 16, 16}, ys[4] = {0, 16, 16, 0};
      for (int k = 0; k < 4; k++) {
        normal(nx[c], ny[r], nz[r][c]);
        vtx16(PX(c * 16 + xs[k]), PX(r * 16 + ys[k]), 0);
      }
    }
}

int main(void) {
  t3d_init("3d_probe_light");
  for (int c = 0; c < 16; c++) nx[c] = (s16)((c - 7.5f) * 0.11f * 511);
  for (int r = 0; r < 12; r++) ny[r] = (s16)(-(r - 5.5f) * 0.11f * 511);
  for (int r = 0; r < 12; r++)
    for (int c = 0; c < 16; c++) {
      float x = nx[c] / 511.0f, y = ny[r] / 511.0f;
      float z2 = 1.0f - x * x - y * y;
      nz[r][c] = (s16)(sqrtf(z2 > 0 ? z2 : 0) * 511);
    }
  for (int i = 0; i < 128; i += 4) {
    u32 w = 0;
    for (int b = 0; b < 4; b++) w |= (u32)((255 - 2 * (i + b)) & 0xFF) << (8 * b);
    table[i / 4] = w;
  }
  clear_color(RGB(1, 1, 1), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
