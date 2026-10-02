// 3d_probe_degen: zero-width and other degenerate polygons (all vertices on
// one line), as games draw them where two walls meet. Vertex colours red,
// green, blue (then yellow) in submission order show whose attributes a
// dot takes. ID 1, z +1; black rear plane (ID 63).
//   col 0: vertical, three vertices (x,10) (x,50) (x,30)
//   col 1: vertical, a folded quad (x,50) (x,24) (x,10) (x,36)
//   col 2: vertical, (x,10) (x,30) (x,50) (the other order of col 0)
//   col 3: a vertical line segment (x,10) (x,50) (x,50)
//   col 4: slanted y-major, three vertices (x,10) (x+10,50) (x+5,30)
//   col 5: slanted x-major, (x-16,20) (x+16,28) (x,24)
//   col 6: a 1-dot polygon (x,30) x3, and a 1x1 triangle (x,40) (x+1,40) (x,41)
// Row 0: over the rear plane. Row 1: a grey quad (ID 2, z 0) from x to
// x+14 behind (the line on its left border); row 2: the grey quad from
// x-14 to x (the line on its right border). The quads span rows 4..50,
// so they are drawn first (same bottom, higher top).
//   MODE 0 (3d_probe_degen):      plain
//   MODE 1 (3d_probe_degen_aa):   anti-aliasing
//   MODE 2 (3d_probe_degen_edge): edge marking (edge colour white)
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static const u16 cols[4] = {RGB(31, 0, 0), RGB(0, 31, 0), RGB(0, 0, 31), RGB(31, 31, 0)};

static void poly(int n, const int *xy, s32 z) {
  begin(n == 4 ? QUADS : TRIS);
  for (int i = 0; i < n; i++) {
    color(cols[i]);
    vtx16(PX(xy[2 * i]), PX(xy[2 * i + 1]), z);
  }
}

static void cell(int col, int row) {
  int ox = col * 36, oy = row * 62 + 2;
  int x = ox + 18;
  if (row > 0) {
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(2));
    color(RGB(12, 12, 12));
    if (row == 1) quad_px(x, oy + 4, x + 14, oy + 50, 0);
    else quad_px(x - 14, oy + 4, x, oy + 50, 0);
  }
  poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1));
  s32 z = FX(1);
  switch (col) {
  case 0: { int v[] = {x, oy + 10, x, oy + 50, x, oy + 30}; poly(3, v, z); break; }
  case 1: { int v[] = {x, oy + 50, x, oy + 24, x, oy + 10, x, oy + 36}; poly(4, v, z); break; }
  case 2: { int v[] = {x, oy + 10, x, oy + 30, x, oy + 50}; poly(3, v, z); break; }
  case 3: { int v[] = {x, oy + 10, x, oy + 50, x, oy + 50}; poly(3, v, z); break; }
  case 4: { int v[] = {x, oy + 10, x + 10, oy + 50, x + 5, oy + 30}; poly(3, v, z); break; }
  case 5: { int v[] = {x - 16, oy + 20, x + 16, oy + 28, x, oy + 24}; poly(3, v, z); break; }
  case 6: {
    int v[] = {x, oy + 30, x, oy + 30, x, oy + 30}; poly(3, v, z);
    int w[] = {x, oy + 40, x + 1, oy + 40, x, oy + 41}; poly(3, w, z);
    break;
  }
  }
}

int main(void) {
  t3d_init("3d_probe_degen");
  for (int i = 0; i < 8; i++) edge_color(i, RGB(31, 31, 31));
  DISP3DCNT = MODE == 1 ? D3_AA : MODE == 2 ? D3_EDGE : 0;
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 7; c++) cell(c, r);
    t3d_frame(0);
  }
}
