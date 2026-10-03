// 3d_probe_aa_rear: anti-aliased edges over a transparent rear plane. The
// rear plane is blue (0,0,31), ID 63, the 2D backdrop green; white opaque
// polygons, anti-aliasing on, depth equal.
//   col 0: a lone triangle, slanted x-major edges
//   col 1: a lone triangle, slanted y-major edges
//   col 2: a T-junction: a quad whose right edge runs (14,0) -> (13,34)
//          against two quads on its right whose left edges run (14,0) ->
//          (14,23) and (14,23) -> (13,34) (Pokemon SoulSilver's ground,
//          one ID), so dots on the long edge are covered by one side only
//   col 3: as 2 with the right-hand quads grey and another ID
//   col 4: as 2, the right-hand quads drawn first
// A white quad from x 240 to the right border, top to bottom row, shows the
// screen-border edges (edge marking compares them against the rear plane).
// Row 0: the cells as listed, row 1: the same 4 dots lower and 0.5 right
// (other coverages).
//   MODE 0 (3d_probe_aa_rear):     rear alpha 0, BLDCNT 0 (no 2nd target)
//   MODE 1 (3d_probe_aa_rear_bld): rear alpha 0, BLDCNT BG0 1st, backdrop 2nd
//   MODE 2 (3d_probe_aa_rear_opq): rear alpha 31 (the known case)
//   MODE 3 (3d_probe_aa_rear_edge): as 1 with edge marking too (edge colour
//          red for IDs 0-7, yellow for 8-15; col 3's grey quads ID 10)
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static void quad(int x0, int y0, int x1, int y1, int x2, int y2, int x3, int y3) {
  begin(QUADS);
  vtx16(x0, y0, 0); vtx16(x1, y1, 0); vtx16(x2, y2, 0); vtx16(x3, y3, 0);
}

static void tjunction(int ox, int oy, int col) {
  // coordinates in 1/64 dot
  int ax = PX(ox + 14), ay = PX(oy), mx = PX(ox + 14), my = PX(oy + 23), bx = PX(ox + 13), by = PX(oy + 34);
  for (int pass = 0; pass < 2; pass++) {
    int left = col == 4 ? pass == 1 : pass == 0;
    if (left) {
      poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
      color(RGB(31, 31, 31));
      quad(PX(ox), ay, PX(ox), by, bx, by, ax, ay);
    } else {
      poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(col == 3 ? 10 : 1));
      color(col == 3 ? RGB(12, 12, 12) : RGB(31, 31, 31));
      quad(ax, ay, mx, my, PX(ox + 30), my, PX(ox + 30), ay);
      quad(mx, my, bx, by, PX(ox + 30), by, PX(ox + 30), my);
    }
  }
}

static void cell(int col, int row) {
  int ox = col * 46 + 6, oy = row * 70 + 10;
  int sub = row ? 32 : 0;   // half a dot right on row 1
  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
  color(RGB(31, 31, 31));
  if (col == 0) {
    begin(TRIS);
    vtx16(PX(ox) + sub, PX(oy + 10), 0); vtx16(PX(ox + 36) + sub, PX(oy + 40), 0);
    vtx16(PX(ox + 34) + sub, PX(oy + 3), 0);
  } else if (col == 1) {
    begin(TRIS);
    vtx16(PX(ox + 4) + sub, PX(oy), 0); vtx16(PX(ox + 12) + sub, PX(oy + 50), 0);
    vtx16(PX(ox + 30) + sub, PX(oy + 6), 0);
  } else {
    tjunction(ox, oy + row * 3, col);
  }
}

int main(void) {
  t3d_init("3d_probe_aa_rear");
  PAL_A_BG[0] = RGB(0, 31, 0);
  BLDCNT_A = MODE == 1 || MODE == 3 ? 0x2001 : 0;
  BLDALPHA_A = 0x0808;
  DISP3DCNT = D3_AA | (MODE == 3 ? D3_EDGE : 0);
  edge_color(0, RGB(31, 0, 0));
  edge_color(1, RGB(31, 31, 0));
  clear_color(RGB(0, 0, 31), MODE == 2 ? 31 : 0, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    for (int r = 0; r < 2; r++)
      for (int c = 0; c < 5; c++) cell(c, r);
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
    color(RGB(31, 31, 31));
    quad(PX(240), PX(0), PX(240), PX(191), PX(255), PX(191), PX(255), PX(0));
    t3d_frame(0);
  }
}
