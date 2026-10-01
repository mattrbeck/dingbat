// 3d_probe_clip: clipping probe. Pseudo-random vertex-coloured triangles
// reaching past the screen edges (pixel-space projection, whole-dot
// vertices), so the clipper's new vertices and their colours show.
//   4 triangles on the left edge (one vertex at x -80..-1, y bands of 48)
//   4 on the right edge (one vertex at x 257..336)
//   3 on the top edge (x bands of 45 from 60, one vertex at y -80..-1)
//   3 on the bottom edge (one vertex at y 193..272)
// Each has its other two vertices inside its band. MODE 1
// (3d_probe_clip_persp): the same with per-vertex w as 3d_probe_persp.
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static u32 seed;
static int rnd(int n) {
  seed = seed * 1103515245u + 12345u;
  return ((seed >> 16) & 0x7FFF) % n;
}

static void vert(int x, int y, int m) {
  if (MODE == 0) vtx16(PX(x), PX(y), 0);
  else vtx16(3 * m * (x - 128), 4 * m * (96 - y), 384 * m);
}

static void tri(int x[3], int y[3]) {
  int m[3];
  for (int i = 0; i < 3; i++) m[i] = 2 + rnd(20);
  begin(TRIS);
  for (int i = 0; i < 3; i++) {
    color(i == 0 ? RGB(31, 0, 0) : i == 1 ? RGB(0, 31, 0) : RGB(0, 0, 31));
    vert(x[i], y[i], m[i]);
  }
}

static void scene(void) {
  if (MODE == 0) {
    t3d_proj_px();
  } else {
    static const s32 proj[16] = {4096, 0, 0, 0, 0, 4096, 0, 0, 0, 0, 0, 4096, 0, 0, 0, 0};
    mtx_mode(0);
    mtx_load44(proj);
    mtx_mode(1);
  }
  mtx_identity();
  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
  seed = 7;
  int x[3], y[3];
  for (int b = 0; b < 4; b++) {       // left / right
    for (int side = 0; side < 2; side++) {
      for (int i = 0; i < 3; i++) {
        y[i] = b * 48 + 2 + rnd(44);
        x[i] = i == 0 ? (side ? 257 + rnd(80) : -80 + rnd(80)) : (side ? 206 + rnd(50) : rnd(50));
      }
      tri(x, y);
    }
  }
  for (int b = 0; b < 3; b++) {       // top / bottom
    for (int side = 0; side < 2; side++) {
      for (int i = 0; i < 3; i++) {
        x[i] = 60 + b * 45 + rnd(44);
        y[i] = i == 0 ? (side ? 193 + rnd(80) : -80 + rnd(80)) : (side ? 152 + rnd(40) : rnd(40));
      }
      tri(x, y);
    }
  }
}

int main(void) {
  t3d_init("3d_probe_clip");
  clear_color(RGB(1, 1, 1), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
