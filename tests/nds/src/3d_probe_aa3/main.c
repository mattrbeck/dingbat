// 3d_probe_aa3: what an anti-aliased (and/or edge-marked) edge mixes with
// when polygons overlap. Every cell holds a red front quad (ID 1, z +2)
// with a vertical left edge, an x-major top edge, a y-major right edge
// and a flat bottom, and a blue back quad (z 0) under the whole cell; all
// opaque polygons of a cell span the same rows, so they are drawn in the
// order submitted. Black rear plane, alpha 31, ID 63.
//   col 0: back, front
//   col 1: front, back
//   col 2: front, back, green middle quad (z +1)
//   col 3: front, green middle quad, back
//   col 4: front, back, then a translucent green quad (alpha 16, ID 5)
//          over the whole cell at z +3
//   col 5: front, back, then a white quad at z +4 over the cell's right half
// Row 0: back ID 10 (another edge colour group), row 1: back ID 1 (the
// front's), row 2: back ID 10 translucent (alpha 16).
//   MODE 0 (3d_probe_aa3):      anti-aliasing
//   MODE 1 (3d_probe_aa3_edge): anti-aliasing + edge marking
//   MODE 2 (3d_probe_aa3_em):   edge marking
// Edge colours: group 0 (ID 1) grey (8,8,8), group 1 (ID 10) yellow.
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static void quad4(int ox, int oy, int x0, int y0, int x1, int y1, int x2, int y2, int x3, int y3, s32 z) {
  begin(QUADS);
  vtx16(PX(ox + x0), PX(oy + y0), z); vtx16(PX(ox + x1), PX(oy + y1), z);
  vtx16(PX(ox + x2), PX(oy + y2), z); vtx16(PX(ox + x3), PX(oy + y3), z);
}

static void front(int ox, int oy) {
  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
  color(RGB(31, 0, 0));
  // (6,7) -> (6,52) -> (32,52) -> (37,0): left vertical, top x-major, right y-major
  quad4(ox, oy, 6, 7, 6, 52, 32, 52, 37, 0, FX(2));
}

static void back(int ox, int oy, int row) {
  poly_attr(PA_BOTH | PA_ALPHA(row == 2 ? 16 : 31) | PA_ID(row == 1 ? 1 : 10));
  color(RGB(0, 0, 31));
  quad4(ox, oy, 0, 0, 0, 52, 40, 52, 40, 0, 0);
}

static void cell(int col, int row) {
  int ox = col * 42 + 2, oy = row * 62 + 4;
  if (col == 0) back(ox, oy, row);
  front(ox, oy);
  if (col == 2 || col == 4 || col == 5) back(ox, oy, row);
  if (col == 2 || col == 3) {
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(20));
    color(RGB(0, 31, 0));
    quad4(ox, oy, 0, 0, 0, 52, 40, 52, 40, 0, FX(1));
  }
  if (col == 3) back(ox, oy, row);
  if (col == 1) back(ox, oy, row);
  if (col == 4) {
    poly_attr(PA_BOTH | PA_ALPHA(16) | PA_ID(5));
    color(RGB(0, 31, 0));
    quad4(ox, oy, 0, 0, 0, 52, 40, 52, 40, 0, FX(3));
  }
  if (col == 5) {
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(30));
    color(RGB(31, 31, 31));
    quad4(ox, oy, 22, 0, 22, 52, 40, 52, 40, 0, FX(4));
  }
}

int main(void) {
  t3d_init("3d_probe_aa3");
  edge_color(0, RGB(8, 8, 8));
  edge_color(1, RGB(31, 31, 0));
  for (int i = 2; i < 8; i++) edge_color(i, RGB(0, 31, 31));
  DISP3DCNT = MODE == 0 ? D3_AA | D3_BLEND : MODE == 1 ? D3_AA | D3_EDGE | D3_BLEND : D3_EDGE | D3_BLEND;
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 6; c++) cell(c, r);
    t3d_frame(0);
  }
}
