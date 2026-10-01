// 3d_tex4x4: 4x4-texel compressed textures (GBATEK "DS 3D Texture Formats",
// format 5). Two 32x32 textures of 64 blocks each, every block a different
// pair/quad of pseudo-random palette colours, modes cycling 0-3 per block:
//   left:  texel blocks in slot 0 (index data in slot 1's lower half),
//          palette base 0
//   right: texel blocks in slot 2 (index data in slot 1's upper half),
//          palette base 0xF000
// Each is drawn at 3 dots per texel (top) and 1 dot per texel (below), over
// a grey backdrop so mode 0/1 texel 3 (transparent) shows through.
#include "t3d.h"

static u8 blocks[64 * 4];
static u8 index_data[64 * 2];
static u16 pal[256];
static u32 seed = 12345;

static u32 rnd(void) {
  seed = seed * 1103515245u + 12345u;
  return seed >> 16;
}

static void make(void) {
  for (int b = 0; b < 64; b++) {
    u32 bits = rnd() | (rnd() << 16);
    for (int k = 0; k < 4; k++) blocks[b * 4 + k] = bits >> (8 * k);
    u16 info = (b * 2) | ((b & 3) << 14);
    index_data[b * 2] = info;
    index_data[b * 2 + 1] = info >> 8;
  }
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  color(RGB(12, 12, 12));
  tex_param(0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  quad_px(0, 0, 256, 192, FX(-4));
  color(0x7FFF);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(2));
  const u32 left = TP_ADDR(0x1000) | TP_SIZE(2, 2) | TP_FMT(FMT_4X4);
  const u32 right = TP_ADDR(0x40800) | TP_SIZE(2, 2) | TP_FMT(FMT_4X4);
  tex_param(left);
  pltt_base(0);
  quad_tex_px(16, 8, 112, 104, 0, 0, 0, 32, 32);
  quad_tex_px(48, 128, 80, 160, 0, 0, 0, 32, 32);
  tex_param(right);
  pltt_base(0xF000 / 16);
  quad_tex_px(144, 8, 240, 104, 0, 0, 0, 32, 32);
  quad_tex_px(176, 128, 208, 160, 0, 0, 0, 32, 32);
}

int main(void) {
  t3d_init("3d_tex4x4: compressed textures\nblock modes cycle 0,1,2,3\nleft: slot 0, right: slot 2");
  u8 *v = t3d_tex_begin();
  make();
  t3d_copy16(v + 0x1000, blocks, sizeof blocks);
  t3d_copy16(v + 0x20000 + 0x1000 / 2, index_data, sizeof index_data);
  for (int i = 0; i < 256; i++) pal[i] = rnd() & 0x7FFF;
  u16 *p = t3d_pal_begin();
  t3d_copy16(p, pal, sizeof pal);
  make();
  t3d_copy16(v + 0x40800, blocks, sizeof blocks);
  t3d_copy16(v + 0x20000 + 0x10000 + 0x800 / 2, index_data, sizeof index_data);
  for (int i = 0; i < 256; i++) pal[i] = rnd() & 0x7FFF;
  t3d_copy16((u8 *)p + 0xF000, pal, sizeof pal);
  t3d_tex_end(3);
  t3d_pal_end();
  DISP3DCNT = D3_TEX;
  while (1) {
    scene();
    t3d_frame(0);
  }
}
