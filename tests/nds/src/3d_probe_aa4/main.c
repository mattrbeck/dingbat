// 3d_probe_aa4: anti-aliasing coverage along long, shallow x-major edges
// (floors and walls meeting in games). White opaque polygons, black rear
// plane (alpha 31, ID 63), anti-aliasing on. Band r (24 rows from y = 24r)
// holds one thin triangle 16 rows tall whose two right (type 0) or left
// (type 1) edges are long x-major ones:
//   type 0: (x0, y) (x0+dx, y+dy) (x0, y+16)   top edge rising to the right
//   type 1: (x0+dx, y) (x0, y+dy) (x0+dx, y+16) the mirror image
// with type = r % 2, dy = 1, 2, 3, 5 and dx = 250, 200, 152, 100 for
// r / 2 = 0..3, x0 = 3.
#include "t3d.h"

int main(void) {
  t3d_init("3d_probe_aa4");
  DISP3DCNT = D3_AA;
  clear_color(0, 31, 63, 0);
  static const int dys[4] = {1, 2, 3, 5}, dxs[4] = {250, 200, 152, 100};
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
    color(RGB(31, 31, 31));
    for (int r = 0; r < 8; r++) {
      int y = r * 24 + 2, dy = dys[r / 2], dx = dxs[r / 2], x0 = 3;
      if (r % 2 == 0) tri_px(x0, y, x0 + dx, y + dy, x0, y + 16, 0);
      else tri_px(x0 + dx, y, x0, y + dy, x0 + dx, y + 16, 0);
    }
    t3d_frame(0);
  }
}
