// 3d_texcoord: texture coordinate transformation modes 1-3 (GBATEK "DS 3D
// Texture Coordinates"), all on a 16x16 direct-colour texture with
// repeat + flip in both directions.
//   top-left     mode 1 (TexCoord source): rotate 30 deg, scale 1.5,
//                translate (5.25, -3.5) texels
//   top-right    mode 2 (Normal source): 4x3 quads whose vertex normals
//                bulge like a sphere; texture matrix scale 8.0, 0.75 on Nz,
//                TEXCOORD (8, 8) as the bottom row
//   bottom-left  mode 3 (Vertex source): a 4x3 grid of quads tilted in z,
//                matrix maps one vertex unit to 64 texels, rotated, with
//                TEXCOORD (3.5, -2) as the bottom row
//   bottom-right mode 1 near the 16-bit S'/T' limit: scale 2.0 with
//                coordinates around +-1000 texels, so the results wrap
#include "t3d.h"

static u16 tex[256];

static const u32 TP = TP_ADDR(0) | TP_SIZE(1, 1) | TP_FMT(FMT_DIRECT) |
                      TP_REPS | TP_REPT | TP_FLIPS | TP_FLIPT;

static void tex_matrix(s32 m0, s32 m1, s32 m4, s32 m5, s32 m8, s32 m9, s32 m12, s32 m13) {
  s32 m[16] = {m0, m1, 0, 0, m4, m5, 0, 0, m8, m9, FX(1), 0, m12, m13, 0, FX(1)};
  mtx_mode(3);
  mtx_load44(m);
  mtx_mode(1);
}

static void mode1(void) {
  float a = 30.0f * 3.14159265f / 180.0f, k = 1.5f;
  tex_matrix(FX(k * cosf(a)), FX(k * sinf(a)), FX(-k * sinf(a)), FX(k * cosf(a)), 0, 0,
             (s32)(5.25 * 16 * 4096), (s32)(-3.5 * 16 * 4096));
  tex_param(TP | TP_XFORM(1));
  quad_tex_px(8, 8, 120, 88, 0, 0, 0, 32, 24);
}

static void mode2(void) {
  tex_matrix(FX(8), 0, 0, FX(8), FX(0.75), FX(-0.75), 0, 0);
  tex_param(TP | TP_XFORM(2));
  for (int gy = 0; gy < 3; gy++)
    for (int gx = 0; gx < 4; gx++) {
      int xs[4] = {gx, gx, gx + 1, gx + 1}, ys[4] = {gy, gy + 1, gy + 1, gy};
      begin(QUADS);
      for (int k = 0; k < 4; k++) {
        // normal from the vertex position on a unit hemisphere
        float nx = (xs[k] - 2) * 0.45f, ny = (1.5f - ys[k]) * 0.45f;
        float nz = sqrtf(1.0f - nx * nx - ny * ny);
        texcoord(8 * 16, 8 * 16);
        normal((int)(nx * 511), (int)(ny * 511), (int)(nz * 511));
        vtx16(PX(136 + xs[k] * 28), PX(8 + ys[k] * 26), 0);
      }
    }
}

static void mode3(void) {
  float a = 20.0f * 3.14159265f / 180.0f;
  tex_matrix(FX(64 * cosf(a)), FX(64 * sinf(a)), FX(-64 * sinf(a)), FX(64 * cosf(a)),
             FX(16), FX(-8), 0, 0);
  tex_param(TP | TP_XFORM(3));
  texcoord((s16)(3.5 * 16), -2 * 16);
  for (int gy = 0; gy < 3; gy++)
    for (int gx = 0; gx < 4; gx++) {
      int xs[4] = {gx, gx, gx + 1, gx + 1}, ys[4] = {gy, gy + 1, gy + 1, gy};
      begin(QUADS);
      for (int k = 0; k < 4; k++)
        vtx16(PX(8 + xs[k] * 28), PX(104 + ys[k] * 26), FX(0.25) * ys[k] - FX(0.1) * xs[k]);
    }
}

static void mode1_wrap(void) {
  tex_matrix(FX(2), 0, 0, FX(-2), 0, 0, 0, 0);
  tex_param(TP | TP_XFORM(1));
  begin(QUADS);
  texcoord(1000 * 16, -1010 * 16); vtx16(PX(136), PX(104), 0);
  texcoord(1000 * 16, -1034 * 16); vtx16(PX(136), PX(184), 0);
  texcoord(1040 * 16, -1034 * 16); vtx16(PX(248), PX(184), 0);
  texcoord(1040 * 16, -1010 * 16); vtx16(PX(248), PX(104), 0);
}

int main(void) {
  t3d_init("3d_texcoord: texcoord modes\nTL mode 1, TR mode 2 (normal)\nBL mode 3 (vertex), BR mode 1\nwrapping at 16 bits");
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 16; x++) {
      u16 c = RGB(x * 2, y * 2, (x ^ y) & 1 ? 31 : 8);
      if (x == 2 && y == 3) c = 0x7FFF;
      tex[y * 16 + x] = c | 0x8000;
    }
  t3d_copy16(t3d_tex_begin(), tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = D3_TEX;
  clear_color(RGB(0, 6, 6), 31, 0, 0);
  while (1) {
    t3d_proj_px();
    mtx_identity();
    poly_attr(PA_FRONT | PA_ALPHA(31));
    spe_emi(0x7FFFu << 16);   // with no lights, NORMAL sets the colour to the emission
    color(0x7FFF);
    mode1();
    mode2();
    mode3();
    mode1_wrap();
    t3d_frame(0);
  }
}
