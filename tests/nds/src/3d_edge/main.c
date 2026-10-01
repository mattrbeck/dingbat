// 3d_edge: edge marking (GBATEK "DS 3D Toon, Edge, Fog, Alpha-Blending,
// Anti-Aliasing", EDGE_COLOR). Edge colours 0-7 = white, red, green,
// blue, yellow, cyan, magenta, orange. Rear plane ID 0, clear depth max.
//   A  ID 8 grey quad, B ID 9 quad overlapping it nearer (both colour 1)
//   C  two touching quads with the same ID 16 (no edge between them)
//   D  ID 24 quad flush with the left screen border (edge vs rear plane ID)
//   E  ID 0 quad flush with the right border (same ID as the rear plane)
//   F  ID 32 triangle and a ID 40 rotated quad (slanted edges)
//   G  ID 48 quad half covered by a translucent ID 50 quad (a16)
//   H  ID 56 wire-frame quad (alpha 0) and wire-frame triangle
//   I  ID 33 quad BEHIND ID 32's triangle (edges only where it is nearer)
#include "t3d.h"

static void q(int x0, int y0, int x1, int y1, s32 z, u16 c, int id, int alpha) {
  poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(id));
  color(c);
  quad_px(x0, y0, x1, y1, z);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  q(20, 10, 80, 60, 0, RGB(16, 16, 16), 8, 31);           // A
  q(50, 35, 110, 80, FX(1), RGB(20, 20, 12), 9, 31);      // B
  q(130, 10, 170, 50, 0, RGB(12, 16, 20), 16, 31);        // C
  q(170, 10, 210, 50, 0, RGB(12, 20, 16), 16, 31);
  q(0, 90, 40, 130, 0, RGB(20, 12, 12), 24, 31);          // D
  q(216, 70, 256, 110, 0, RGB(12, 12, 20), 0, 31);        // E
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(32));         // F
  color(RGB(24, 24, 8));
  tri_px(60, 100, 70, 170, 120, 130, FX(1));
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(40));
  color(RGB(8, 24, 24));
  begin(QUADS);
  vtx16(PX(150), PX(80), 0); vtx16(PX(135), PX(120), 0);
  vtx16(PX(175), PX(135), 0); vtx16(PX(190), PX(95), 0);
  q(20, 140, 90, 185, 0, RGB(12, 12, 12), 33, 31);         // I
  q(140, 140, 200, 185, 0, RGB(24, 16, 24), 48, 31);       // G
  q(170, 150, 230, 176, FX(2), RGB(0, 31, 0), 50, 16);
  poly_attr(PA_FRONT | PA_ALPHA(0) | PA_ID(56));           // H
  color(RGB(31, 31, 31));
  quad_px(210, 120, 250, 140, FX(1));
  tri_px(215, 10, 220, 60, 250, 30, FX(1));
}

int main(void) {
  t3d_init("3d_edge: edge marking");
  static const u16 ec[8] = {
    RGB(31, 31, 31), RGB(31, 0, 0), RGB(0, 31, 0), RGB(0, 0, 31),
    RGB(31, 31, 0), RGB(0, 31, 31), RGB(31, 0, 31), RGB(31, 16, 0),
  };
  for (int i = 0; i < 8; i++) edge_color(i, ec[i]);
  DISP3DCNT = D3_EDGE | D3_BLEND;
  clear_color(RGB(4, 4, 8), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
