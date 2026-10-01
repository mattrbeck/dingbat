// 3d_light: lighting (GBATEK "DS 3D Polygon Light Parameters"). Four
// spheres (12 x 10 quads, per-vertex normals), pixel-space projection,
// light vectors set under a vector matrix rotated 20 degrees about Y
// (MTX_MODE 2), the spheres themselves rotated 15 degrees about X.
//   top-left:     light 0 only (white), diffuse (31,31,31), no ambient
//   top-right:    lights 0-3 (white, red, green, blue from four
//                 directions), diffuse grey, ambient (6,6,6)
//   bottom-left:  light 0, diffuse (20,0,0), specular (31,31,31) with the
//                 linear table, emission (0,0,8)
//   bottom-right: as bottom-left with SPE_EMI.15: the shininess table
//                 (entry i = i*i/64, so 0..254)
// Each vertex normal is issued before its vertex, so the colour comes from
// the NORMAL command (DIF_AMB bit 15 off).
#include "t3d.h"

#define RINGS 10
#define SEGS 12
static s16 nrm[RINGS + 1][SEGS + 1][3];
static s16 pos[RINGS + 1][SEGS + 1][3];
static u32 shine[32];

static void build(void) {
  for (int i = 0; i <= RINGS; i++)
    for (int j = 0; j <= SEGS; j++) {
      float t = i * 3.14159265f / RINGS, p = j * 3.14159265f / SEGS;   // front hemisphere
      float nx = -cosf(p) * sinf(t), ny = -cosf(t), nz = sinf(p) * sinf(t);
      nrm[i][j][0] = (s16)(nx * 511); nrm[i][j][1] = (s16)(ny * 511); nrm[i][j][2] = (s16)(nz * 511);
      pos[i][j][0] = (s16)(nx * 40 * 64); pos[i][j][1] = (s16)(ny * 40 * 64); pos[i][j][2] = (s16)(nz * 40 * 64);
    }
  for (int i = 0; i < 128; i += 4) {
    u32 w = 0;
    for (int b = 0; b < 4; b++) w |= (u32)(((i + b) * (i + b) / 64) & 0xFF) << (8 * b);
    shine[i / 4] = w;
  }
}

static void sphere(int cx, int cy) {
  static const s32 rx[9] = {4096, 0, 0, 0, 3956, 1060, 0, -1060, 3956};   // 15 deg about X
  mtx_mode(2);
  mtx_push();
  mtx_trans(PX(cx), PX(cy), 0);
  mtx_mult33(rx);
  for (int i = 0; i < RINGS; i++) {
    begin(QUAD_STRIP);
    for (int j = 0; j <= SEGS; j++)
      for (int k = 0; k < 2; k++) {
        s16 *n = nrm[i + k][j], *v = pos[i + k][j];
        normal(n[0], n[1], n[2]);
        vtx16(v[0], v[1], v[2]);
      }
  }
  mtx_pop(1);
  mtx_mode(1);
}

static void lights(void) {
  static const s32 ry[9] = {3849, 0, -1401, 0, 4096, 0, 1401, 0, 3849};   // 20 deg about Y
  mtx_mode(2);
  mtx_identity();
  mtx_mult33(ry);
  light_vector(0, 280, 300, -300);
  light_vector(1, -400, 100, -300);
  light_vector(2, 0, -440, -250);
  light_vector(3, 300, -200, -330);
  mtx_identity();
  mtx_mode(1);
  light_color(0, RGB(31, 31, 31));
  light_color(1, RGB(31, 0, 0));
  light_color(2, RGB(0, 31, 0));
  light_color(3, RGB(0, 0, 31));
}

static void scene(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  lights();
  shininess(shine);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1) | PA_LIGHTS(1));
  dif_amb(RGB(31, 31, 31));
  spe_emi(0);
  sphere(64, 50);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(2) | PA_LIGHTS(15));
  dif_amb(RGB(20, 20, 20) | ((u32)RGB(6, 6, 6) << 16));
  spe_emi(0);
  sphere(192, 50);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(3) | PA_LIGHTS(1));
  dif_amb(RGB(20, 0, 0));
  spe_emi(RGB(31, 31, 31) | ((u32)RGB(0, 0, 8) << 16));
  sphere(64, 142);

  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(4) | PA_LIGHTS(1));
  spe_emi(RGB(31, 31, 31) | ((u32)RGB(0, 0, 8) << 16) | 0x8000);
  sphere(192, 142);
}

int main(void) {
  t3d_init("3d_light: lighting");
  build();
  clear_color(RGB(3, 3, 3), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
