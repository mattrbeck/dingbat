// 3d_probe_lerp: colour interpolation probe (pixel-space projection, all
// w equal, opaque, no edge marking). Each shape is a rectangle quad, so
// its edges are vertical and the dot at a row's left end shows the left
// edge's colour at that row.
//   band A (y 2..): 31 quads 6 wide, heights 2..32: red runs 0 -> 31 down
//     both edges, blue 31 -> 0, green 0 -> 31 left to right (span of 6)
//   band B (y 40..): rows of 4-high quads with widths 2..72: green
//     0 -> 31 left to right, red 31 -> 0, blue 9 -> 22
//   band C (y 118..): heights 33..48 (16 quads, 8 wide): red 0 -> 31,
//     blue 5 -> 26, green 31 -> 0 across
#include "t3d.h"

static void rect(int x0, int y0, int x1, int y1, u16 tl, u16 bl, u16 br, u16 tr) {
  begin(QUADS);
  color(tl); vtx16(PX(x0), PX(y0), 0);
  color(bl); vtx16(PX(x0), PX(y1), 0);
  color(br); vtx16(PX(x1), PX(y1), 0);
  color(tr); vtx16(PX(x1), PX(y0), 0);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  for (int i = 0; i < 31; i++) {
    int h = i + 2, x = 2 + i * 8;
    rect(x, 2, x + 6, 2 + h, RGB(0, 0, 31), RGB(31, 0, 0), RGB(31, 31, 0), RGB(0, 31, 31));
  }
  int x = 2, y = 40;
  for (int w = 2; w <= 72; w++) {
    if (x + w > 254) {
      x = 2;
      y += 6;
    }
    rect(x, y, x + w, y + 4, RGB(31, 0, 9), RGB(31, 0, 9), RGB(0, 31, 22), RGB(0, 31, 22));
    x += w + 2;
  }
  for (int i = 0; i < 16; i++) {
    int h = 33 + i, xx = 2 + i * 12;
    rect(xx, 118, xx + 8, 118 + h, RGB(0, 31, 5), RGB(31, 31, 26), RGB(31, 0, 26), RGB(0, 0, 5));
  }
}

int main(void) {
  t3d_init("3d_probe_lerp");
  clear_color(RGB(1, 1, 1), 31, 63, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
