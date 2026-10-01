// 3d_sort: polygon drawing order (GBATEK "DS 3D Display Control",
// SWAP_BUFFERS bit 0: translucent Y-sorting auto/manual). Everything at the
// same depth, so with the "less" depth test the first polygon drawn at a
// dot keeps it, and translucent blending shows the order.
// 3d_sort: auto sort; 3d_sort_manual: manual (submission order).
//   left (opaque): four overlapping quads submitted bottom-most first,
//          two of them with identical Y extents
//   right (translucent a16, distinct IDs): six overlapping quads submitted
//          bottom-most first: different bottoms, equal bottoms with
//          different tops, and an identical pair (submission order)
//   bottom: translucent triangles vs quads with equal bottom rows
#include "t3d.h"

#ifndef MANUAL
#define MANUAL 0
#endif

static void q(int x0, int y0, int x1, int y1, u16 c, int alpha, int id) {
  poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(id));
  color(c);
  quad_px(x0, y0, x1, y1, 0);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  q(10, 70, 70, 120, RGB(31, 0, 0), 31, 1);
  q(30, 50, 90, 100, RGB(0, 31, 0), 31, 2);
  q(50, 50, 110, 100, RGB(0, 0, 31), 31, 3);
  q(20, 10, 80, 60, RGB(31, 31, 0), 31, 4);

  q(140, 90, 200, 130, RGB(31, 0, 0), 16, 10);
  q(160, 70, 220, 130, RGB(0, 31, 0), 16, 11);
  q(180, 50, 240, 110, RGB(0, 0, 31), 16, 12);
  q(150, 30, 210, 80, RGB(31, 31, 0), 16, 13);
  q(170, 10, 230, 60, RGB(0, 31, 31), 16, 14);
  q(190, 10, 250, 60, RGB(31, 0, 31), 16, 15);

  poly_attr(PA_FRONT | PA_ALPHA(16) | PA_ID(20));
  color(RGB(31, 31, 31));
  tri_px(20, 180, 120, 180, 70, 140, 0);
  q(40, 150, 100, 180, RGB(31, 16, 0), 16, 21);
  poly_attr(PA_FRONT | PA_ALPHA(16) | PA_ID(22));
  color(RGB(0, 16, 31));
  tri_px(150, 145, 140, 182, 240, 182, 0);
  q(160, 160, 220, 182, RGB(16, 31, 0), 16, 23);
}

int main(void) {
  t3d_init(MANUAL ? "3d_sort_manual: manual order" : "3d_sort: auto Y-sort");
  DISP3DCNT = D3_BLEND;
  clear_color(RGB(8, 8, 8), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(MANUAL ? 1 : 0);
  }
}
