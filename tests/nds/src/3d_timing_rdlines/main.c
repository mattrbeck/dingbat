// 3d_timing_rdlines: RDLINES_COUNT (0x4000320) and the DISP3DCNT underflow
// / overflow flags (bits 12, 13) under growing rendering loads (GBATEK "DS
// 3D Status": the minimum number of buffered lines minus 2 in the previous
// frame, 46 when the renderer keeps up; "DS 3D Overview": a 48-line cache
// filled from line 214). Each scene is drawn for 4 frames, the flags are
// acknowledged after the second, and RDLINES and DISP3DCNT are read after
// the fourth.
// Printed on the bottom screen in hex: RDLINES / DISP3DCNT bits 12-13 per
// scene.
//   0  nothing
//   1  one full-screen quad
//   2  16 full-screen quads (opaque, nearer each time)
//   3  64 full-screen quads
//   4  200 full-screen quads
//   5  1000 tiny triangles spread over the screen
//   6  2000 tiny triangles in rows 80-111 only
//   7  190 full-width quads 2 lines high, stacked down the screen, x 8
//   8  64 full-screen translucent quads (alpha 16, blending on)
//   9  1 full-screen quad again (recovery)
// The last scene stays on screen so frames compare.
#include "t3d.h"
#include "tm.h"

static int scene;

static void draw(int s) {
  t3d_proj_px();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  switch (s) {
  case 0: break;
  case 1:
  case 9:
    color(RGB(31, 0, 0));
    quad_px(0, 0, 256, 192, 0);
    break;
  case 2:
  case 3:
  case 4: {
    int n = s == 2 ? 16 : s == 3 ? 64 : 200;
    for (int i = 0; i < n; i++) {
      color(t3d_hue(i, 16));
      quad_px(0, 0, 256, 192, i * 64);
    }
    break;
  }
  case 5:
    for (int i = 0; i < 1000; i++) {
      color(t3d_hue(i, 16));
      int x = (i * 37) & 255, y = (i * 11) % 190;
      tri_px(x, y, x, y + 2, x + 2, y + 1, 0);
    }
    break;
  case 6:
    for (int i = 0; i < 2000; i++) {
      color(t3d_hue(i, 16));
      int x = (i * 37) & 255, y = 80 + (i % 30);
      tri_px(x, y, x, y + 2, x + 2, y + 1, 0);
    }
    break;
  case 7:
    for (int k = 0; k < 8; k++)
      for (int i = 0; i < 95; i++) {
        color(t3d_hue(i + k, 16));
        quad_px(0, i * 2, 256, i * 2 + 2, k * 64);
      }
    break;
  case 8:
    poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(16) | PA_ID(2));
    for (int i = 0; i < 64; i++) {
      color(t3d_hue(i, 16));
      quad_px(0, 0, 256, 192, i * 64);
    }
    break;
  }
  end_vtxs();
}

int main(void) {
  t3d_init("3d_timing_rdlines");
  icache_on();
  u32 v[2];
  DISP3DCNT = 1u << 12 | 1u << 13;
  for (scene = 0; scene < 10; scene++) {
    // the frame on screen while a scene is first sent is still the last
    // one: acknowledge the flags after two frames, read after four
    for (int f = 0; f < 4; f++) {
      if (f == 2) DISP3DCNT = (scene == 8 ? D3_BLEND : 0) | 1u << 12 | 1u << 13;
      draw(scene);
      t3d_frame(0);
    }
    v[0] = RDLINES & 0x3F;
    v[1] = (DISP3DCNT >> 12) & 3;
    char label[3] = {'S', (char)('0' + scene), 0};
    tm_line(label, v, 2, 4);
  }
  while (1) {
    draw(9);
    t3d_frame(0);
  }
}
