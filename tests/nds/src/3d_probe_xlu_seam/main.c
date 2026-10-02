// 3d_probe_xlu_seam: seams between translucent polygons that share edges
// (the classic DS look: full-size translucent polygons overlap on their
// shared edges and blend twice there unless they have the same ID).
// Each band is a fan/strip mesh of alpha-16 triangles over a grey opaque
// quad, black rear plane:
//   band 0: a 6x2 grid of quads split into triangles, one ID for all
//   band 1: the same grid, IDs alternating per triangle
//   band 2: the grid with depth update (POLYGON_ATTR.11), IDs alternating
//   band 3: a fan of 8 slivers around a centre, IDs alternating, and the
//           same fan with one ID
//   MODE 0 (3d_probe_xlu_seam):    blending on
//   MODE 1 (3d_probe_xlu_seam_nb): blending off (small polygons)
#include "t3d.h"

#ifndef MODE
#define MODE 0
#endif

static void grid(int oy, int ids, u32 extra) {
  int n = 0;
  for (int j = 0; j < 2; j++)
    for (int i = 0; i < 6; i++) {
      int x0 = 10 + i * 38, y0 = oy + j * 20, x1 = x0 + 38, y1 = y0 + 20;
      // slant the inner vertices so that the shared edges are diagonal
      int sx = (i & 1) ? 7 : -7;
      for (int t = 0; t < 2; t++, n++) {
        poly_attr(PA_BOTH | PA_ALPHA(16) | PA_ID(ids ? 1 + (n & 7) : 1) | extra);
        color(t3d_hue(n, 24));
        begin(TRIS);
        if (t == 0) { vtx16(PX(x0), PX(y0), FX(1)); vtx16(PX(x1 + sx), PX(y0), FX(1)); vtx16(PX(x0 - sx), PX(y1), FX(1)); }
        else { vtx16(PX(x1 + sx), PX(y0), FX(1)); vtx16(PX(x1 - sx), PX(y1), FX(1)); vtx16(PX(x0 - sx), PX(y1), FX(1)); }
      }
    }
}

static void fan(int cx, int cy, int ids) {
  for (int k = 0; k < 8; k++) {
    poly_attr(PA_BOTH | PA_ALPHA(16) | PA_ID(ids ? 10 + (k & 1) : 10));
    color(t3d_hue(k, 8));
    float a0 = k * 0.785398f, a1 = a0 + 0.785398f;
    begin(TRIS);
    vtx16(PX(cx), PX(cy), FX(1));
    vtx16((s32)((cx + 20 * cosf(a0)) * 64), (s32)((cy + 20 * sinf(a0)) * 64), FX(1));
    vtx16((s32)((cx + 20 * cosf(a1)) * 64), (s32)((cy + 20 * sinf(a1)) * 64), FX(1));
  }
}

int main(void) {
  t3d_init("3d_probe_xlu_seam");
  DISP3DCNT = MODE == 0 ? D3_BLEND : 0;
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_BOTH | PA_ALPHA(31) | PA_ID(40));
    color(RGB(10, 10, 10));
    quad_px(0, 0, 256, 192, 0);
    grid(4, 0, 0);
    grid(50, 1, 0);
    grid(96, 1, PA_XLU_DEPTH);
    fan(60, 166, 1);
    fan(160, 166, 0);
    t3d_frame(0);
  }
}
