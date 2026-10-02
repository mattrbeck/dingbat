// 3d_probe_hwline: lines whose hardware display captures exist
// (StrikerX3/nds-interp TL-<dx>x<dy>: a white wire-frame line from (0,0)
// to (dx, dy), two vertices on the start), drawn the same way but each
// from its own start dot, so the result can be laid over the capture.
// The first six are lines where the hardware leaves out one dot of an
// x-major run (x(y+1) just above a half dot); the last is drawn whole by
// the hardware with x(y+1) exactly on a half dot. Black rear plane.
#include "t3d.h"

static const int L[7][4] = {   // start x, start y, dx, dy
  {2, 2, 69, 49}, {130, 2, 92, 37}, {2, 60, 114, 37}, {130, 60, 102, 41},
  {2, 110, 120, 41}, {130, 110, 71, 61}, {2, 170, 97, 16},
};

int main(void) {
  t3d_init("3d_probe_hwline");
  clear_color(0, 31, 63, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_BOTH | PA_ALPHA(0) | PA_ID(0));
    color(0x7FFF);
    for (int k = 0; k < 7; k++) {
      begin(TRIS);
      vtx16(PX(L[k][0]), PX(L[k][1]), 0);
      vtx16(PX(L[k][0]), PX(L[k][1]), 0);
      vtx16(PX(L[k][0] + L[k][2]), PX(L[k][1] + L[k][3]), 0);
    }
    t3d_frame(0);
  }
}
