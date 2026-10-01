// 3d_texwrap: texture clamp / repeat / flip (GBATEK "DS 3D Texture
// Attributes", TEXIMAGE_PARAM bits 16-19) on an 8x16 direct-colour texture
// with marker texels, one texel per dot. A 4x4 grid of cells: the column
// picks the S mode, the row the T mode, each of
//   clamp, repeat, repeat + flip, flip without repeat
// The quads run s = -14..42 and t = -12..28 (texels) across 56x40 dots.
#include "t3d.h"

static u16 tex[8 * 16];

static const u32 MODES[4] = {0, TP_REPS, TP_REPS | TP_FLIPS, TP_FLIPS};

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31));
  color(0x7FFF);
  for (int row = 0; row < 4; row++)
    for (int col = 0; col < 4; col++) {
      u32 t = MODES[row] << 1;   // the T bits sit one above the S bits
      tex_param(TP_ADDR(0) | TP_SIZE(0, 1) | TP_FMT(FMT_DIRECT) | MODES[col] | t);
      int x = col * 64, y = row * 48;
      quad_tex_px(x + 4, y + 4, x + 60, y + 44, 0, -14, -12, 42, 28);
    }
}

int main(void) {
  t3d_init("3d_texwrap: clamp/repeat/flip\ncolumns: S clamp, rep, rep+flip,\n flip only; rows: same for T");
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 8; x++) {
      u16 c = RGB(x * 4 + 3, y * 2 + 1, 10);
      if (x == 1 && y == 1) c = RGB(31, 31, 31);
      if (x == 6 && y == 2) c = RGB(0, 0, 0);
      if (y == 13 && x >= 2) c = RGB(0, 0, 31);
      tex[y * 8 + x] = c | 0x8000;
    }
  u8 *v = t3d_tex_begin();
  t3d_copy16(v, tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = D3_TEX;
  clear_color(RGB(6, 0, 6), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
