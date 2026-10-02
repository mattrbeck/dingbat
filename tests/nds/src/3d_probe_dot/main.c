// 3d_probe_dot: 1-dot polygons and DISP_1DOT_DEPTH (GBATEK "DS 3D Display
// Control": a polygon whose vertices all land on one dot is drawn only if a
// vertex has w <= DISP_1DOT_DEPTH, unless POLYGON_ATTR.13; only the 0x0
// size is checked). The projection makes w = 3 + z, so each row of dots
// (z = -1.5 + 0.75 r, w = 1.5 .. 8.25) sits at another depth;
// DISP_1DOT_DEPTH = w 4.0. Per row, left to right in pairs (attr bit 13
// off, on): a 1-dot triangle, a 1-dot quad, a 2-dot (1x0) and a 1x2 (0x1)
// triangle, and a 1-dot triangle whose first vertex is near and the others
// far (same dot). White rear plane parts are black; dots white / red.
#include "t3d.h"

static void proj(void) {
  static const s32 m[16] = {
    6144, 0, 0, 0,
    0, -8192, 0, 0,
    0, 0, -1536, 4096,
    -12288, 12288, 0, 12288,
  };
  mtx_mode(0);
  mtx_load44(m);
  mtx_mode(1);
  mtx_identity();
}

static void tri(int x, int y, int x1, int y1, int x2, int y2, s32 z0, s32 z) {
  begin(TRIS);
  vtx16(PX(x), PX(y), z0); vtx16(PX(x1), PX(y1), z); vtx16(PX(x2), PX(y2), z);
}

int main(void) {
  t3d_init("3d_probe_dot");
  clear_color(0, 31, 63, 0);
  R16(0x04000610) = 0x20;   // DISP_1DOT_DEPTH: w 4.0
  while (1) {
    proj();
    for (int r = 0; r < 10; r++) {
      s32 z = FX(-1.5 + 0.75 * r);
      int y = 20 + r * 16;
      for (int k = 0; k < 10; k++) {
        int x = 20 + k * 20;
        poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(1) | ((k & 1) ? PA_DOT_RENDER : 0));
        color(k & 1 ? RGB(31, 0, 0) : RGB(31, 31, 31));
        switch (k / 2) {
        case 0: tri(x, y, x, y, x, y, z, z); break;
        case 1: begin(QUADS); for (int i = 0; i < 4; i++) vtx16(PX(x), PX(y), z); break;
        case 2: tri(x, y, x + 1, y, x, y, z, z); break;
        case 3: tri(x, y, x, y + 1, x, y, z, z); break;
        case 4: tri(x, y, x, y, x, y, FX(-2.5), z); break;
        }
      }
    }
    t3d_frame(0);
  }
}
