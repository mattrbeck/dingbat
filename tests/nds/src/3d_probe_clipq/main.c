// 3d_probe_clipq: clipped-vertex colours. 32 rectangles 4 rows high (one
// per 6-row band) from x = -L to x = R (pixel space, w equal), left
// vertices red + blue 10, right vertices green: the left side is clipped
// at x = 0, so dot (0, y) shows the clipped vertices' colour directly.
// L = 1 + 5k (k = band), R = 8 + 7 * (k % 8). Bands 16..31 repeat the
// shapes clipped at the right edge (x = 256) instead, mirrored.
#include "t3d.h"

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  for (int k = 0; k < 32; k++) {
    int j = k & 15;
    int L = 1 + 5 * j, R = 8 + 7 * (j % 8);
    int y = (k >> 1) * 12 + (k & 1) * 6;
    int x0 = k < 16 ? -L : 256 - R, x1 = k < 16 ? R : 256 + L;
    u16 cl = k < 16 ? RGB(31, 0, 10) : RGB(0, 31, 0);
    u16 cr = k < 16 ? RGB(0, 31, 0) : RGB(31, 0, 10);
    begin(QUADS);
    color(cl); vtx16(PX(x0), PX(y), 0);
    color(cl); vtx16(PX(x0), PX(y + 4), 0);
    color(cr); vtx16(PX(x1), PX(y + 4), 0);
    color(cr); vtx16(PX(x1), PX(y), 0);
  }
}

int main(void) {
  t3d_init("3d_probe_clipq");
  clear_color(RGB(1, 1, 1), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
