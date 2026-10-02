// 3d_probe_edge2: edge-marking cases 3d_edge leaves out. Rear plane black,
// alpha 31, ID 5 (edge group 0), clear depth 0x6000 (polygons at z <= 0
// lie in front of it). Edge colours 0-7: white, red, green, blue, yellow,
// cyan, magenta, orange (group = ID / 8).
//   A  ID 8 quad on the top border, ID 16 quad on the bottom border
//   B  ID 5 quad (the rear plane's ID) on the top border and in the middle
//   C  two quads at equal depth side by side, IDs 24 and 32
//   D  ID 40 quad, a translucent (a16) ID 48 quad over its right half that
//      updates depth (POLYGON_ATTR.11), nearer
//   E  as D, the translucent quad without the depth update
//   F  ID 56 quad with a translucent ID 8 quad FURTHER away beside it,
//      updating depth
//   G  ID 16 quad half behind a translucent ID 24 quad drawn nearer,
//      depth update, and the translucent quad's own edges (none: only
//      opaque polygons are marked)
//   H  ID 32 quad at z just in front of the clear depth vs one behind it
//      (hidden), and a quad crossing the left border at x -10
#include "t3d.h"

static void q(int x0, int y0, int x1, int y1, s32 z, u16 c, int id, int alpha, u32 extra) {
  poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(id) | extra);
  color(c);
  quad_px(x0, y0, x1, y1, z);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  q(10, 0, 50, 30, 0, RGB(16, 16, 16), 8, 31, 0);                 // A
  q(10, 162, 50, 192, 0, RGB(16, 16, 16), 16, 31, 0);
  q(60, 0, 100, 30, 0, RGB(16, 12, 12), 5, 31, 0);                // B
  q(60, 40, 100, 70, 0, RGB(16, 12, 12), 5, 31, 0);
  q(110, 10, 140, 50, 0, RGB(12, 16, 12), 24, 31, 0);             // C
  q(140, 10, 170, 50, 0, RGB(12, 12, 16), 32, 31, 0);
  q(180, 10, 240, 50, 0, RGB(16, 16, 8), 40, 31, 0);              // D
  q(210, 20, 250, 40, FX(1), RGB(31, 0, 31), 48, 16, PA_XLU_DEPTH);
  q(180, 60, 240, 100, 0, RGB(16, 16, 8), 40, 31, 0);             // E
  q(210, 70, 250, 90, FX(1), RGB(31, 0, 31), 48, 16, 0);
  q(10, 60, 50, 100, 0, RGB(8, 16, 16), 56, 31, 0);               // F
  q(50, 60, 90, 100, FX(-1), RGB(31, 31, 0), 8, 16, PA_XLU_DEPTH);
  q(100, 70, 160, 120, 0, RGB(16, 8, 16), 16, 31, 0);             // G
  q(130, 60, 170, 130, FX(1), RGB(0, 31, 31), 24, 16, PA_XLU_DEPTH);
  q(20, 120, 60, 150, FX(-1), RGB(20, 20, 20), 32, 31, 0);        // H
  q(70, 120, 90, 150, FX(-6), RGB(20, 20, 20), 32, 31, 0);
  q(-10, 155, 30, 160, 0, RGB(20, 20, 20), 40, 31, 0);
}

int main(void) {
  t3d_init("3d_probe_edge2");
  static const u16 ec[8] = {RGB(31, 31, 31), RGB(31, 0, 0), RGB(0, 31, 0), RGB(0, 0, 31),
                            RGB(31, 31, 0), RGB(0, 31, 31), RGB(31, 0, 31), RGB(31, 16, 0)};
  for (int i = 0; i < 8; i++) edge_color(i, ec[i]);
  DISP3DCNT = D3_EDGE | D3_BLEND;
  clear_color(0, 31, 5, 0);
  clear_depth(0x6000);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
