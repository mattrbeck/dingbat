// 3d_geom: geometry commands (GBATEK "DS 3D Geometry Commands" through
// "DS 3D Polygon Definitions by Vertices"). A 6x4 grid of cells (42x48
// dots); each draws the same letter F (a 6x32 bar, a 18x6 top arm, a 12x6
// middle arm, in dots, from the cell's (8, 8)) through a different command
// path, so a wrong command shows as a misplaced or distorted F. Cell index
// = row * 6 + column:
//   0 MTX_TRANS + VTX_16          1 MTX_LOAD_4x3 + VTX_10
//   2 VTX_XY / VTX_XZ / VTX_YZ    3 MTX_SCALE x8 + VTX_DIFF
//   4 packed GXFIFO (NOP padding) 5 PUSH x3, POP 2, POP -1 (re-pop)
//   6 STORE 5 / STORE 30, RESTORE 7 MTX_MULT_4x4 shear
//   8 MTX_MULT_4x3 rotate 90      9 MTX_SCALE in MTX_MODE 2
//  10 projection PUSH/LOAD/POP   11 triangle strip
//  12 quad strip                 13 separate triangles
//  14 MTX_MULT_3x3 (1/3 scale) x3 then MTX_SCALE 27
//  15 translate in MTX_MODE 2    16 texture-matrix stack (texcoord mode 1)
//  17 POS_TEST between VTX_16 and VTX_XY (POS_TEST resets the VTX regs)
//  18 unpacked GXFIFO (STM)      19 END_VTXS between vertices
//  20 COLOR per vertex           21 two half-size F (MTX_SCALE 0.5)
//  22 MTX_IDENTITY mid-list      23 MTX_LOAD_4x4 with w = 2.0
#include "t3d.h"

static u16 tex[64];

// F as three quads in 1/64 units (dots), anticlockwise
static const s16 FQ[3][4] = {{0, 0, 6, 32}, {6, 0, 24, 6}, {6, 13, 18, 19}};

static void f16(void) {
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUADS);
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[0] * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[3] * 64, 0); vtx16(r[2] * 64, r[1] * 64, 0);
  }
}

static void to_cell(int c) {
  mtx_identity();
  mtx_trans(PX((c % 6) * 42 + 8), PX((c / 6) * 48 + 8), 0);
}

#define GXFIFO R32(0x04000400)

static void scene(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  tex_param(0);
  color(RGB(31, 31, 31));

  to_cell(0);
  f16();

  {   // 1
    s32 m[12] = {FX(1), 0, 0, 0, FX(1), 0, 0, 0, FX(1), PX(1 * 42 + 8), PX(8), 0};
    mtx_load43(m);
    for (int i = 0; i < 3; i++) {
      const s16 *r = FQ[i];
      begin(QUADS);
      vtx10(r[0], r[1], 0); vtx10(r[0], r[3], 0); vtx10(r[2], r[3], 0); vtx10(r[2], r[1], 0);
    }
  }

  to_cell(2);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUADS);
    vtx16(r[0] * 64, r[1] * 64, FX(0.5));
    vtx_xy(r[0] * 64, r[3] * 64);
    vtx_xz(r[2] * 64, FX(-0.5));
    vtx_yz(r[1] * 64, 0);
  }

  to_cell(3);   // x8: a VTX_DIFF step of 1/4096 is 1/8 dot
  mtx_scale(FX(8), FX(8), FX(1));
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    int h = (r[3] - r[1]) * 8, w = (r[2] - r[0]) * 8;
    begin(QUADS);
    vtx16(r[0] * 8, r[1] * 8, 0);
    vtx_diff(0, h, 0);
    vtx_diff(w, 0, 0);
    vtx_diff(0, -h, 0);
  }

  {   // 4: packed: TRANS, then per quad BEGIN + 4 VTX_16
    mtx_identity();
    GXFIFO = 0x1C;   // unpacked MTX_TRANS
    GXFIFO = PX(4 * 42 + 8); GXFIFO = PX(8); GXFIFO = 0;
    for (int i = 0; i < 3; i++) {
      const s16 *r = FQ[i];
      GXFIFO = 0x00002340;   // BEGIN_VTXS, VTX_16
      GXFIFO = QUADS;
      GXFIFO = (u16)(r[0] * 64) | ((u32)(u16)(r[1] * 64) << 16); GXFIFO = 0;
      GXFIFO = 0x2323;   // VTX_16, VTX_16
      GXFIFO = (u16)(r[0] * 64) | ((u32)(u16)(r[3] * 64) << 16); GXFIFO = 0;
      GXFIFO = (u16)(r[2] * 64) | ((u32)(u16)(r[3] * 64) << 16); GXFIFO = 0;
      GXFIFO = 0x00230041;   // END_VTXS, NOP, VTX_16
      GXFIFO = (u16)(r[2] * 64) | ((u32)(u16)(r[1] * 64) << 16); GXFIFO = 0;
    }
  }

  {   // 5
    to_cell(5);
    mtx_push();              // [0] = cell 5
    mtx_trans(PX(50), 0, 0);
    mtx_push();              // [1] = wrong
    mtx_trans(PX(50), 0, 0);
    mtx_push();              // [2] = wrong
    mtx_pop(2);              // S = 1, current = [1]
    mtx_pop(-1);             // S = 2, current = [2]
    mtx_pop(2);              // S = 0, current = [0] = cell 5
    f16();
  }

  {   // 6
    to_cell(6);
    mtx_store(5);
    mtx_identity();
    mtx_trans(PX(100), PX(100), 0);
    mtx_store(30);
    mtx_restore(5);
    f16();
    mtx_restore(30);
  }

  {   // 7 shear: x += y / 4
    to_cell(7);
    s32 m[16] = {FX(1), 0, 0, 0, FX(0.25), FX(1), 0, 0, 0, 0, FX(1), 0, 0, 0, 0, FX(1)};
    mtx_mult44(m);
    f16();
  }

  {   // 8 rotate 90 about z around the F's corner (32 down: x' = -y + 32)
    to_cell(8);
    s32 m[12] = {0, FX(1), 0, FX(-1), 0, 0, 0, 0, FX(1), PX(32), 0, 0};
    mtx_mult43(m);
    f16();
  }

  {   // 9 scale in mode 2 hits the position matrix only
    mtx_mode(2);
    to_cell(9);
    mtx_scale(FX(1.5), FX(0.75), FX(1));
    f16();
    mtx_identity();
    mtx_mode(1);
  }

  {   // 10 projection stack: push, load a mirrored projection, draw an F that
      // lands mirrored into the cell, pop
    mtx_mode(0);
    mtx_push();
    static const s32 mir[16] = {-6144, 0, 0, 0, 0, -8192, 0, 0, 0, 0, -1536, 0,
                                12288, 12288, 0, 12288};
    mtx_load44(mir);
    mtx_mode(1);
    mtx_identity();
    mtx_trans(PX(256 - (4 * 42 + 8) - 24), PX(48 + 8), 0);
    f16();
    mtx_mode(0);
    mtx_pop(1);
    mtx_mode(1);
  }

  to_cell(11);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(TRI_STRIP);
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[0] * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[1] * 64, 0); vtx16(r[2] * 64, r[3] * 64, 0);
  }
  to_cell(12);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUAD_STRIP);
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[0] * 64, r[3] * 64, 0);
    int mx = (r[0] + r[2]) / 2;
    vtx16(mx * 64, r[1] * 64, 0); vtx16(mx * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[1] * 64, 0); vtx16(r[2] * 64, r[3] * 64, 0);
  }
  to_cell(13);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(TRIS);
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[0] * 64, r[3] * 64, 0); vtx16(r[2] * 64, r[3] * 64, 0);
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[2] * 64, r[3] * 64, 0); vtx16(r[2] * 64, r[1] * 64, 0);
  }

  {   // 14
    to_cell(14);
    s32 third[9] = {FX(1.0 / 3), 0, 0, 0, FX(1.0 / 3), 0, 0, 0, FX(1)};
    mtx_mult33(third); mtx_mult33(third); mtx_mult33(third);
    mtx_scale(FX(27), FX(27), FX(1));
    f16();
  }

  {   // 15
    mtx_mode(2);
    mtx_identity();
    mtx_trans(PX(3 * 42 + 8), PX(2 * 48 + 8), 0);
    f16();
    mtx_identity();
    mtx_mode(1);
  }

  {   // 16 texture matrix stack: a textured F whose texcoords shift via mode 1
    to_cell(16);
    mtx_mode(3);
    mtx_identity();
    mtx_push();
    mtx_trans(4 * 16 * 4096, 0, 0);   // would shift by 4 texels
    mtx_pop(1);                        // ...popped: identity again
    mtx_mode(1);
    tex_param(TP_ADDR(0) | TP_SIZE(0, 0) | TP_FMT(FMT_DIRECT) | TP_REPS | TP_REPT | TP_XFORM(1));
    for (int i = 0; i < 3; i++) {
      const s16 *r = FQ[i];
      begin(QUADS);
      texcoord(r[0] * 16, r[1] * 16); vtx16(r[0] * 64, r[1] * 64, 0);
      texcoord(r[0] * 16, r[3] * 16); vtx16(r[0] * 64, r[3] * 64, 0);
      texcoord(r[2] * 16, r[3] * 16); vtx16(r[2] * 64, r[3] * 64, 0);
      texcoord(r[2] * 16, r[1] * 16); vtx16(r[2] * 64, r[1] * 64, 0);
    }
    tex_param(0);
  }

  to_cell(17);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUADS);
    vtx16(r[0] * 64, r[1] * 64, 0);
    pos_test(r[0] * 64, 0, FX(1));   // y (and z) now come from here
    vtx_xy(r[0] * 64, r[3] * 64);
    vtx16(r[2] * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[1] * 64, 0);
  }

  to_cell(18);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    vu32 *p = (vu32 *)0x04000400;
    begin(QUADS);
    u32 w[3];
    w[0] = 0x23;
    w[1] = (u16)(r[0] * 64) | ((u32)(u16)(r[1] * 64) << 16);
    w[2] = 0;
    asm volatile("ldmia %0, {r4-r6}\n stmia %1, {r4-r6}" ::"r"(w), "r"(p) : "r4", "r5", "r6", "memory");
    vtx16(r[0] * 64, r[3] * 64, 0);
    end_vtxs();
    vtx16(r[2] * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[1] * 64, 0);
  }

  to_cell(19);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUADS);
    vtx16(r[0] * 64, r[1] * 64, 0); end_vtxs(); vtx16(r[0] * 64, r[3] * 64, 0); end_vtxs();
    vtx16(r[2] * 64, r[3] * 64, 0); end_vtxs(); vtx16(r[2] * 64, r[1] * 64, 0); end_vtxs();
  }

  to_cell(20);
  for (int i = 0; i < 3; i++) {
    const s16 *r = FQ[i];
    begin(QUADS);
    color(RGB(31, 0, 0)); vtx16(r[0] * 64, r[1] * 64, 0);
    color(RGB(0, 31, 0)); vtx16(r[0] * 64, r[3] * 64, 0);
    color(RGB(0, 0, 31)); vtx16(r[2] * 64, r[3] * 64, 0);
    color(RGB(31, 31, 31)); vtx16(r[2] * 64, r[1] * 64, 0);
  }

  to_cell(21);
  mtx_scale(FX(0.5), FX(0.5), FX(1));
  f16();
  mtx_trans(PX(32), PX(32), 0);
  f16();

  to_cell(22);
  begin(QUADS);
  vtx16(0, 0, 0); vtx16(0, PX(32), 0); vtx16(PX(6), PX(32), 0); vtx16(PX(6), 0, 0);
  mtx_identity();   // mid-list: the arms are placed from the screen origin
  mtx_trans(PX(5 * 42 + 8), PX(3 * 48 + 8), 0);
  for (int i = 1; i < 3; i++) {
    const s16 *r = FQ[i];
    vtx16(r[0] * 64, r[1] * 64, 0); vtx16(r[0] * 64, r[3] * 64, 0);
    vtx16(r[2] * 64, r[3] * 64, 0); vtx16(r[2] * 64, r[1] * 64, 0);
  }

  {   // 23: w = 2.0 instead of 3.0: dots scale by 1.5 about (-64, -48)
    mtx_mode(0);
    mtx_push();
    static const s32 p2[16] = {6144, 0, 0, 0, 0, -8192, 0, 0, 0, 0, -1536, 0, -12288, 12288, 0, 8192};
    mtx_load44(p2);
    mtx_mode(1);
    mtx_identity();
    mtx_trans(PX(188), PX(133), 0);
    mtx_scale(FX(0.5), FX(0.5), FX(1));
    f16();
    mtx_mode(0);
    mtx_pop(1);
    mtx_mode(1);
  }
}

int main(void) {
  t3d_init("3d_geom: geometry commands\n(24 cells, each an F)");
  for (int i = 0; i < 64; i++) tex[i] = (i & 1 ? RGB(31, 31, 31) : RGB(31, 8, 8)) | 0x8000;
  t3d_copy16(t3d_tex_begin(), tex, sizeof tex);
  t3d_tex_end(1);
  DISP3DCNT = D3_TEX;
  clear_color(RGB(0, 4, 8), 31, 0, 0);
  while (1) {
    scene();
    t3d_frame(0);
  }
}
