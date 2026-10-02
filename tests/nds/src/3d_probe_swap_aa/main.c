// 3d_probe_swap_aa: anti-aliasing of an x-major edge in swapped rows
// (polyrastertest 56). White opaque quads, black rear plane (alpha 31,
// ID 63), anti-aliasing on. Each quad is (X, Y) (X, Y+20) (X+40, Y+20)
// (X-dx, Y+dy): its first three vertices put the vertical edge on the left
// chain, so every row above Y+dy is swapped and the x-major edge (X, Y) to
// (X-dx, Y+dy) shows only its inner dot. Plus polyrastertest's scene 56
// itself (its projection and vertices, clipped at x = 0).
#include "t3d.h"

static const s32 prt_proj[16] = {131586, 0, 0, 0, 0, -175677, 0, 0, 0, 0, -1024, 0, 16, 21, -4096, 4096};
static const int shapes[11][4] = {   // X, Y, dx, dy
  {60, 4, 18, 7}, {190, 4, 30, 12}, {60, 30, 40, 9}, {190, 30, 25, 10},
  {60, 56, 50, 8}, {190, 56, 9, 4}, {200, 88, 12, 5}, {60, 124, 35, 6},
  {190, 124, 20, 3}, {60, 150, 45, 11}, {190, 150, 16, 7},
};

int main(void) {
  t3d_init("3d_probe_swap_aa");
  DISP3DCNT = D3_AA;
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
    color(RGB(31, 31, 31));
    for (int i = 0; i < 11; i++) {
      int x = shapes[i][0], y = shapes[i][1], dx = shapes[i][2], dy = shapes[i][3];
      begin(QUADS);
      vtx16(PX(x), PX(y), 0);
      vtx16(PX(x), PX(y + 20), 0);
      vtx16(PX(x + 40), PX(y + 20), 0);
      vtx16(PX(x - dx), PX(y + dy), 0);
    }
    mtx_mode(0);
    mtx_load44(prt_proj);
    mtx_mode(1);
    mtx_identity();
    begin(QUADS);
    vtx16(-110, -12, 0);
    vtx16(-110, 24, 0);
    vtx16(0, 24, 0);
    vtx16(-140, 0, 0);
    t3d_frame(0);
  }
}
