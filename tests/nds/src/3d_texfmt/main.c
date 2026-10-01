// 3d_texfmt: every texture format (GBATEK "DS 3D Texture Formats"), each a
// 16x16 texture on a 48x48 quad (3 dots per texel) over a vertex-coloured
// backdrop, blending on so the translucent formats show what is beneath.
//   row 0: A3I5, 4-colour, 16-colour, 256-colour
//   row 1: 4x4 compressed (16 blocks cycling modes 0-3), A5I3, direct,
//          4-colour with colour 0 transparent
//   row 2: 16-colour and 256-colour with colour 0 transparent, direct at
//          41x37 (non-integer texel steps), untextured white
#include "t3d.h"

static u8 tex[0x900];
static u8 idx4x4[32];
static u16 pal[0x280];

enum {
  T_A3I5 = 0x000, T_4 = 0x100, T_16 = 0x200, T_256 = 0x300, T_A5I3 = 0x400,
  T_DIRECT = 0x500, T_4X4 = 0x800,
};
enum {   // palette byte offsets
  P_A3I5 = 0x000, P_4 = 0x040, P_16 = 0x080, P_256 = 0x100, P_A5I3 = 0x300, P_4X4 = 0x400,
};

static void build(void) {
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 16; x++) {
      int i = y * 16 + x;
      tex[T_A3I5 + i] = ((x + y * 2) & 31) | ((y >> 1) << 5);
      tex[T_4 + (i >> 2)] |= (((x >> 2) + (y >> 2) + (x & 1)) & 3) << ((i & 3) * 2);
      tex[T_16 + (i >> 1)] |= ((x ^ y) & 15) << ((i & 1) * 4);
      tex[T_256 + i] = i;
      tex[T_A5I3 + i] = (x & 7) | ((y * 2 + (x >> 3)) << 3);
      int r = x * 2, g = y * 2, b = 31 - x - y;
      if (b < 0) b = 0;
      u16 c = RGB(r, g, b) | (((x + y) % 5) ? 0x8000 : 0);
      tex[T_DIRECT + i * 2] = c;
      tex[T_DIRECT + i * 2 + 1] = c >> 8;
      // 4x4: block (x/4, y/4), texel value (x + y) & 3
      int blk = (y >> 2) * 4 + (x >> 2);
      tex[T_4X4 + blk * 4 + (y & 3)] |= ((x + y) & 3) << ((x & 3) * 2);
    }
  for (int blk = 0; blk < 16; blk++) {
    u16 info = (blk * 2) | ((blk & 3) << 14);   // palette offset in 4-byte steps, mode
    idx4x4[blk * 2] = info;
    idx4x4[blk * 2 + 1] = info >> 8;
  }
  for (int i = 0; i < 32; i++) pal[P_A3I5 / 2 + i] = t3d_hue(i, 32);
  pal[P_4 / 2 + 0] = RGB(31, 0, 0);
  pal[P_4 / 2 + 1] = RGB(0, 31, 0);
  pal[P_4 / 2 + 2] = RGB(0, 0, 31);
  pal[P_4 / 2 + 3] = RGB(31, 31, 31);
  for (int i = 0; i < 16; i++) pal[P_16 / 2 + i] = t3d_hue(i * 5, 16) ^ (i & 1 ? 0x0C63 : 0);
  for (int i = 0; i < 256; i++) pal[P_256 / 2 + i] = RGB(i & 31, (i >> 3) & 31, 31 - (i & 31));
  for (int i = 0; i < 8; i++) pal[P_A5I3 / 2 + i] = t3d_hue(i, 8);
  for (int i = 0; i < 64; i++) pal[P_4X4 / 2 + i] = t3d_hue(i * 7, 64);
}

static void cell(int col, int row, u32 tp, u32 pltt) {
  tex_param(tp);
  pltt_base(pltt);
  quad_tex_px(col * 64 + 8, row * 64 + 8, col * 64 + 56, row * 64 + 56, 0, 0, 0, 16, 16);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  // backdrop: four-colour quad behind everything
  tex_param(0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  begin(QUADS);
  color(RGB(8, 8, 8)); vtx16(PX(0), PX(0), FX(-7));
  color(RGB(31, 31, 0)); vtx16(PX(0), PX(192), FX(-7));
  color(RGB(0, 8, 31)); vtx16(PX(256), PX(192), FX(-7));
  color(RGB(31, 31, 31)); vtx16(PX(256), PX(0), FX(-7));

  color(0x7FFF);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(2));
  const u32 s16 = TP_SIZE(1, 1);
  cell(0, 0, TP_ADDR(T_A3I5) | s16 | TP_FMT(FMT_A3I5), P_A3I5 / 16);
  cell(1, 0, TP_ADDR(T_4) | s16 | TP_FMT(FMT_4), P_4 / 8);
  cell(2, 0, TP_ADDR(T_16) | s16 | TP_FMT(FMT_16), P_16 / 16);
  cell(3, 0, TP_ADDR(T_256) | s16 | TP_FMT(FMT_256), P_256 / 16);
  cell(0, 1, TP_ADDR(T_4X4) | s16 | TP_FMT(FMT_4X4), P_4X4 / 16);
  cell(1, 1, TP_ADDR(T_A5I3) | s16 | TP_FMT(FMT_A5I3), P_A5I3 / 16);
  cell(2, 1, TP_ADDR(T_DIRECT) | s16 | TP_FMT(FMT_DIRECT), 0);
  cell(3, 1, TP_ADDR(T_4) | s16 | TP_FMT(FMT_4) | TP_COL0, P_4 / 8);
  cell(0, 2, TP_ADDR(T_16) | s16 | TP_FMT(FMT_16) | TP_COL0, P_16 / 16);
  cell(1, 2, TP_ADDR(T_256) | s16 | TP_FMT(FMT_256) | TP_COL0, P_256 / 16);
  tex_param(TP_ADDR(T_DIRECT) | s16 | TP_FMT(FMT_DIRECT));
  quad_tex_px(2 * 64 + 8, 2 * 64 + 8, 2 * 64 + 49, 2 * 64 + 45, 0, 0, 0, 16, 16);
  tex_param(0);
  quad_px(3 * 64 + 8, 2 * 64 + 8, 3 * 64 + 56, 2 * 64 + 56, 0);
}

int main(void) {
  t3d_init("3d_texfmt: texture formats");
  build();
  u8 *vram = t3d_tex_begin();
  t3d_copy16(vram, tex, sizeof tex);
  t3d_copy16(vram + 0x20000 + T_4X4 / 2, idx4x4, sizeof idx4x4);
  t3d_tex_end(2);
  t3d_copy16(t3d_pal_begin(), pal, sizeof pal);
  t3d_pal_end();
  DISP3DCNT = D3_TEX | D3_BLEND;
  clear_color(RGB(4, 4, 4), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
