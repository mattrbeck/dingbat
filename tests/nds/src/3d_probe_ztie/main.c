// 3d_probe_ztie: where polygons meet at equal depth, which one a dot shows
// (the depth of a polygon's first row / first dot against a neighbour's).
// Each cell: a grey flat quad A (ID 2, z 0) and a red triangle B (ID 1)
// whose apex has z 0 too, the rest of B nearer (+Z) or further (-Z).
// Depth test "less": a tie keeps the polygon drawn first.
//   col 0: B apex on top (20,10), base at row 50, nearer;  A drawn first
//   col 1: as 0, B further
//   col 2: as 0, B drawn first (A one row taller, so later)
//   col 3: B apex on the left (4,30), base at x 36, nearer; A first
//   col 4: as 3, B further
//   col 5: B apex at the bottom (20,50), base at row 10, nearer; A first
// Row 0: Z = 2.0, row 1: Z = 0.25, row 2: Z = 1/64 (the smallest step).
// Black rear plane.
#include "t3d.h"

static void cell(int col, int row) {
  int ox = col * 42 + 2, oy = row * 62 + 4;
  s32 dz = row == 0 ? FX(2) : row == 1 ? FX(0.25) : 64;
  if (col == 1 || col == 4) dz = -dz;
  int a_first = col != 2;
  for (int pass = 0; pass < 2; pass++) {
    if ((pass == 0) == a_first) {
      poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(2));
      color(RGB(12, 12, 12));
      // A: rows 10..50 (51 when drawn after B, sorted by bottom row)
      quad_px(ox + 2, oy + 10, ox + 38, oy + (a_first ? 50 : 51), 0);
    } else {
      poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
      color(RGB(31, 0, 0));
      begin(TRIS);
      if (col == 3 || col == 4) {
        vtx16(PX(ox + 4), PX(oy + 30), 0);
        vtx16(PX(ox + 36), PX(oy + 10), dz);
        vtx16(PX(ox + 36), PX(oy + 50), dz);
      } else if (col == 5) {
        vtx16(PX(ox + 20), PX(oy + 50), 0);
        vtx16(PX(ox + 4), PX(oy + 10), dz);
        vtx16(PX(ox + 36), PX(oy + 10), dz);
      } else {
        vtx16(PX(ox + 20), PX(oy + 10), 0);
        vtx16(PX(ox + 4), PX(oy + 50), dz);
        vtx16(PX(ox + 36), PX(oy + 50), dz);
      }
    }
  }
}

int main(void) {
  t3d_init("3d_probe_ztie");
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 6; c++) cell(c, r);
    t3d_frame(0);
  }
}
