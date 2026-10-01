// 3d_probe_aa2: when anti-aliasing applies between polygons. Each row of
// cells pairs a white triangle with a slanted edge against a grey neighbour
// (black rear plane, ID 63), anti-aliasing on:
//   col 0: neighbour shares the edge, same ID, same depth (a mesh seam)
//   col 1: neighbour shares the edge, different ID, same depth
//   col 2: white triangle in front (z +2) of a grey quad, same ID
//   col 3: white in front of grey, different ID
//   col 4: white behind (z -2) a grey quad that covers half of it, same ID
//   col 5: as 4, different ID
// Row 0: x-major slanted edge, row 1: y-major, row 2: edge order reversed
// (grey drawn first).
#include "t3d.h"

static void cell(int col, int row) {
  int ox = col * 42 + 4, oy = row * 60 + 6;
  int same = (col % 2) == 0;
  s32 zw = (col == 2 || col == 3) ? FX(2) : (col >= 4 ? FX(-2) : 0);
  int ax = ox, ay = oy, bx, by;   // slanted edge from (ax, ay) to (bx, by)
  if (row == 1) { bx = ox + 13; by = oy + 47; } else { bx = ox + 36; by = oy + 17; }
  for (int pass = 0; pass < 2; pass++) {
    int white = row == 2 ? pass == 1 : pass == 0;
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(white ? 1 : (same ? 1 : 2)));
    color(white ? RGB(31, 31, 31) : RGB(12, 12, 12));
    begin(TRIS);
    if (white) {
      vtx16(PX(ax), PX(ay), zw); vtx16(PX(ax), PX(by + 4), zw); vtx16(PX(bx), PX(by), zw);
    } else if (col < 2) {
      vtx16(PX(ax), PX(ay), 0); vtx16(PX(bx), PX(by), 0); vtx16(PX(bx), PX(ay), 0);
    } else {
      // a grey quad under / over the whole cell
      begin(QUADS);
      vtx16(PX(ox), PX(oy), 0); vtx16(PX(ox), PX(oy + 52), 0);
      vtx16(PX(ox + 38), PX(oy + 52), 0); vtx16(PX(ox + 38), PX(oy), 0);
    }
  }
}

int main(void) {
  t3d_init("3d_probe_aa2");
  DISP3DCNT = D3_AA;
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 6; c++) cell(c, r);
    t3d_frame(0);
  }
}
