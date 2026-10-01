// 3d_blendmodes: texture blending (GBATEK "DS 3D Texture Blending").
// Rows: modulate, decal, toon (3d_highlight: highlight, DISP3DCNT.1).
// Columns: untextured; direct texture (1-bit alpha); A5I3 (alpha ramp);
// 16-colour; untextured at polygon alpha 16. Each quad's vertex colours run
// red 0 -> 31 left to right (the toon index) with green/blue corners, over
// a checkered backdrop, alpha blending on. The toon table is a hue ramp.
#include "t3d.h"

#ifndef HIGHLIGHT
#define HIGHLIGHT 0
#endif

static u16 direct[256];
static u8 a5i3[256];
static u8 c16[128];
static u16 pal[32];

static void cell(int col, int row, u32 mode, u32 tp, int alpha) {
  int x = col * 51 + 3, y = row * 64 + 6;
  tex_param(tp);
  poly_attr(PA_FRONT | mode | PA_ALPHA(alpha) | PA_ID(row * 8 + col + 1));
  begin(QUADS);
  color(RGB(0, 31, 0)); texcoord(0, 0); vtx16(PX(x), PX(y), 0);
  color(RGB(0, 0, 31)); texcoord(0, 16 * 16); vtx16(PX(x), PX(y + 52), 0);
  color(RGB(31, 0, 31)); texcoord(16 * 16, 16 * 16); vtx16(PX(x + 46), PX(y + 52), 0);
  color(RGB(31, 31, 0)); texcoord(16 * 16, 0); vtx16(PX(x + 46), PX(y), 0);
}

static void scene(void) {
  t3d_proj_px();
  mtx_identity();
  tex_param(0);
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(63));
  for (int y = 0; y < 192; y += 16)
    for (int x = 0; x < 256; x += 16) {
      color(((x + y) & 16) ? RGB(20, 20, 20) : RGB(6, 6, 6));
      quad_px(x, y, x + 16, y + 16, FX(-4));
    }
  static const u32 modes[3] = {PA_MODULATE, PA_DECAL, PA_TOON};
  for (int row = 0; row < 3; row++) {
    cell(0, row, modes[row], 0, 31);
    cell(1, row, modes[row], TP_ADDR(0) | TP_SIZE(1, 1) | TP_FMT(FMT_DIRECT), 31);
    cell(2, row, modes[row], TP_ADDR(0x200) | TP_SIZE(1, 1) | TP_FMT(FMT_A5I3), 31);
    cell(3, row, modes[row], TP_ADDR(0x300) | TP_SIZE(1, 1) | TP_FMT(FMT_16), 31);
    cell(4, row, modes[row], TP_ADDR(0) | TP_SIZE(1, 1) | TP_FMT(FMT_DIRECT), 16);
  }
}

int main(void) {
  t3d_init(HIGHLIGHT ? "3d_highlight: blending, rows\nmodulate, decal, highlight"
                     : "3d_blendmodes: blending, rows\nmodulate, decal, toon");
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 16; x++) {
      int i = y * 16 + x;
      direct[i] = RGB(31 - x * 2, y * 2, (x * 3 + y) & 31) | (((x + y) % 3) ? 0x8000 : 0);
      a5i3[i] = (x & 7) | ((y * 2 + (x >> 3)) << 3);
      c16[i >> 1] |= ((x / 4 + y / 4 * 4) & 15) << ((i & 1) * 4);
    }
  for (int i = 0; i < 16; i++) pal[i] = t3d_hue(i * 3, 16);
  u8 *v = t3d_tex_begin();
  t3d_copy16(v, direct, sizeof direct);
  t3d_copy16(v + 0x200, a5i3, sizeof a5i3);
  t3d_copy16(v + 0x300, c16, sizeof c16);
  t3d_tex_end(1);
  t3d_copy16(t3d_pal_begin(), pal, sizeof pal);
  t3d_pal_end();
  for (int i = 0; i < 32; i++) toon_color(i, t3d_hue(i, 32) & (i & 1 ? 0x7FFF : 0x3DEF));
  DISP3DCNT = D3_TEX | D3_BLEND | (HIGHLIGHT ? D3_HIGHLIGHT : 0);
  clear_color(0, 31, 0, 0);
  while (1) {
    pltt_base(0);
    scene();
    t3d_frame(0);
  }
}
