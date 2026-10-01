// 3d_status: geometry engine registers read back (GBATEK "DS 3D Status",
// "DS 3D Tests", "DS 3D Matrix Stack", "DS 3D I/O Map"), printed on the
// bottom screen in hex once at start-up; the top screen draws a scene sent
// by DMA mode 7 (GX FIFO) plus a polygon-RAM overflow (2100 strip
// triangles: the last 52 are dropped).
// Lines (label: values):
//   GX0   GXSTAT after reset
//   PUSH  GXSTAT after 3 MTX_PUSH (mode 1), then after 30 more (error),
//         then after acknowledging bit 15
//   PROJ  GXSTAT after 2 projection pushes; after acknowledge
//   POS   POS_RESULT x y z w for (0.5, -0.25, 1.0) under a known clip matrix
//   VEC   VEC_RESULT x y z for (0.5, 0.25, -0.75) under a rotated vector
//         matrix, and for 1.0 (overflow to -1.0)
//   BOX   BOX_TEST result for inside / outside / straddling / enclosing
//   CLIP  CLIPMTX_RESULT 0, 5, 10, 12..15; VECM VECMTX_RESULT 0, 4, 8
//   CNT1  RAM_COUNT after 3 tris + 1 quad + a 4-triangle strip + a
//         clipped triangle + a fully off-screen quad
//   OVF   after 1600 separate quads: RAM_COUNT, DISP3DCNT; after a swap
//         and V-blank: RAM_COUNT, DISP3DCNT; after acknowledging bit 13
//   FIFO  GXSTAT right after SWAP_BUFFERS + 40 MTX_IDENTITY, + 300 more,
//         and after the V-blank
//   IRQ   IF bit 21 with GXSTAT IRQ mode 2 (empty), after writing IF,
//         mode 1, mode 0 then writing IF
//   DMA   GXSTAT after the DMA mode 7 burst started, and DMA0CNT
//   RDL   RDLINES_COUNT after 5 frames; DISP3DCNT readback after writing
//         0x7FFF (bits 12/13 acknowledge)
#include "t3d.h"

#define DMA0SAD R32(0x040000B0)
#define DMA0DAD R32(0x040000B4)
#define DMA0CNT R32(0x040000B8)

static int row = 1;
static u32 list[512];
static int nlist;

static void line(const char *label, const u32 *v, int n, int digits) {
  t3d_print(0, row, label);
  int col = 5;
  for (int i = 0; i < n; i++) {
    t3d_hex(col, row, v[i], digits);
    col += digits + 1;
    if (col + digits > 32) {
      row++;
      col = 5;
    }
  }
  row++;
}

static void L(u32 w) { list[nlist++] = w; }

static void build_list(void) {
  // unpacked commands for DMA: a 6-colour fan of quads at the top-left
  nlist = 0;
  for (int i = 0; i < 6; i++) {
    L(0x20); L(t3d_hue(i, 6));
    L(0x40); L(QUADS);
    int x = 8 + i * 20;
    L(0x23); L((u16)PX(x) | ((u32)(u16)PX(8) << 16)); L(0);
    L(0x23); L((u16)PX(x) | ((u32)(u16)PX(40) << 16)); L(0);
    L(0x23); L((u16)PX(x + 16) | ((u32)(u16)PX(40) << 16)); L(0);
    L(0x23); L((u16)PX(x + 16) | ((u32)(u16)PX(8) << 16)); L(0);
  }
}

static void overflow_strips(void) {
  // 2100 triangles in strips of 100 across the lower screen
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(2));
  for (int s = 0; s < 21; s++) {
    color(t3d_hue(s, 21));
    begin(TRI_STRIP);
    for (int i = 0; i < 102; i++)
      vtx16(PX(4) + i * 155, PX(52 + s * 6 + (i & 1) * 5), 0);
  }
}

int main(void) {
  t3d_init("3d_status: GX registers");
  u32 v[16];

  v[0] = GXSTAT;
  line("GX0", v, 1, 8);

  mtx_mode(1);
  for (int i = 0; i < 3; i++) mtx_push();
  t3d_wait_idle();
  v[0] = GXSTAT;
  for (int i = 0; i < 30; i++) mtx_push();
  t3d_wait_idle();
  v[1] = GXSTAT;
  GXSTAT = 1u << 15;
  v[2] = GXSTAT;
  mtx_pop(33);
  t3d_wait_idle();
  v[3] = GXSTAT;
  line("PUSH", v, 4, 8);

  mtx_mode(0);
  mtx_push();
  mtx_push();
  t3d_wait_idle();
  v[0] = GXSTAT;
  GXSTAT = 1u << 15;
  v[1] = GXSTAT;
  mtx_pop(1);
  t3d_wait_idle();
  v[2] = GXSTAT;
  GXSTAT = 1u << 15;
  line("PROJ", v, 3, 8);

  t3d_proj_persp(60, 1.333f, 0.5f, 10.0f);
  mtx_identity();
  mtx_trans(FX(0.25), FX(0.5), FX(-3));
  pos_test(FX(0.5), FX(-0.25), FX(1.0));
  t3d_wait_idle();
  for (int i = 0; i < 4; i++) v[i] = ((vu32 *)0x04000620)[i];
  line("POS", v, 4, 8);

  mtx_mode(2);
  static const s32 rz[9] = {3547, 2048, 0, -2048, 3547, 0, 0, 0, 4096};
  mtx_identity();
  mtx_mult33(rz);
  vec_test(256, 128, -384);
  t3d_wait_idle();
  v[0] = ((vu16 *)0x04000630)[0];
  v[1] = ((vu16 *)0x04000630)[1];
  v[2] = ((vu16 *)0x04000630)[2];
  mtx_identity();
  vec_test(511, 0, 0);
  t3d_wait_idle();
  v[3] = ((vu16 *)0x04000630)[0];
  mtx_mode(1);
  line("VEC", v, 4, 4);

  // box tests under the perspective above, position = identity
  mtx_identity();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_FAR_RENDER | PA_DOT_RENDER);
  begin(TRIS);
  end_vtxs();
  box_test(FX(-0.5), FX(-0.5), FX(-3), FX(1), FX(1), FX(1));
  t3d_wait_idle();
  v[0] = GXSTAT & 3;
  box_test(FX(5), FX(5), FX(-3), FX(1), FX(1), FX(1));
  t3d_wait_idle();
  v[1] = GXSTAT & 3;
  box_test(FX(1), FX(-0.5), FX(-3), FX(3), FX(1), FX(1));
  t3d_wait_idle();
  v[2] = GXSTAT & 3;
  box_test(FX(-7), FX(-7), FX(-7), FX(7.9), FX(7.9), FX(7.9));
  t3d_wait_idle();
  v[3] = GXSTAT & 3;
  box_test(FX(-1), FX(-1), FX(0.2), FX(2), FX(2), FX(-0.6));
  t3d_wait_idle();
  v[4] = GXSTAT & 3;
  line("BOX", v, 5, 1);

  mtx_trans(FX(1), FX(2), FX(3));
  t3d_wait_idle();
  static const int ci[7] = {0, 5, 10, 12, 13, 14, 15};
  for (int i = 0; i < 7; i++) v[i] = ((vu32 *)0x04000640)[ci[i]];
  line("CLIP", v, 7, 8);
  mtx_mode(2);
  mtx_identity();
  mtx_mult33(rz);
  mtx_scale(FX(2), FX(2), FX(2));
  t3d_wait_idle();
  v[0] = ((vu32 *)0x04000680)[0];
  v[1] = ((vu32 *)0x04000680)[1];
  v[2] = ((vu32 *)0x04000680)[3];
  v[3] = ((vu32 *)0x04000680)[4];
  mtx_mode(1);
  line("VECM", v, 4, 8);

  // RAM_COUNT for a mixed list, then a swap to empty it
  t3d_proj_px();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  for (int i = 0; i < 3; i++) tri_px(10 + i * 10, 10, 10 + i * 10, 20, 18 + i * 10, 15, 0);
  quad_px(50, 10, 60, 20, 0);
  begin(TRI_STRIP);
  for (int i = 0; i < 6; i++) vtx16(PX(70 + i * 5), PX(i & 1 ? 20 : 10), 0);
  tri_px(-20, 30, -20, 40, 10, 35, 0);     // clipped by the left edge
  quad_px(300, 10, 320, 20, 0);            // fully outside
  t3d_wait_idle();
  v[0] = RAM_COUNT;
  line("CNT1", v, 1, 8);
  swap_buffers(0);
  wait_vblank();

  for (int i = 0; i < 1600; i++) quad_px(i & 255, 100, (i & 255) + 1, 101, 0);
  t3d_wait_idle();
  v[0] = RAM_COUNT;
  v[1] = DISP3DCNT;
  swap_buffers(0);
  wait_vblank();
  t3d_wait_idle();
  v[2] = RAM_COUNT;
  v[3] = DISP3DCNT;
  DISP3DCNT = 1u << 13;
  v[4] = DISP3DCNT;
  line("OVF", v, 5, 8);

  // FIFO fill behind a pending swap
  wait_vblank();
  swap_buffers(0);
  for (int i = 0; i < 40; i++) mtx_identity();
  v[0] = GXSTAT;
  for (int i = 0; i < 300; i++) mtx_identity();
  v[1] = GXSTAT;
  wait_vblank();
  t3d_wait_idle();
  v[2] = GXSTAT;
  line("FIFO", v, 3, 8);

  IME = 0;
  IF9 = 1u << 21;
  GXSTAT = 2u << 30;
  v[0] = (IF9 >> 21) & 1;
  IF9 = 1u << 21;
  v[1] = (IF9 >> 21) & 1;
  GXSTAT = 1u << 30;
  v[2] = (IF9 >> 21) & 1;
  GXSTAT = 0;
  IF9 = 1u << 21;
  v[3] = (IF9 >> 21) & 1;
  line("IRQ", v, 4, 1);

  build_list();
  wait_vblank();
  t3d_proj_px();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
  t3d_wait_idle();
  DMA0SAD = (u32)list;
  DMA0DAD = 0x04000400;
  DMA0CNT = nlist | (1u << 31) | (7u << 27) | (1u << 26) | (2u << 21);   // 32-bit, dst fixed, GX FIFO
  v[0] = GXSTAT;
  while (DMA0CNT & (1u << 31)) {}
  v[1] = DMA0CNT;
  t3d_wait_idle();
  overflow_strips();
  t3d_wait_idle();
  v[2] = RAM_COUNT;
  v[3] = DISP3DCNT;
  line("DMA", v, 4, 8);
  swap_buffers(0);
  wait_vblank();

  for (int f = 0; f < 5; f++) {
    // from now on the same scene every frame, sent by the CPU
    t3d_proj_px();
    t3d_reset_matrices();
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
    for (int i = 0; i < nlist; i++) R32(0x04000400) = list[i];
    overflow_strips();
    t3d_frame(0);
  }
  v[0] = R32(0x04000320) & 0xFF;
  DISP3DCNT = 0x7FFF;
  v[1] = DISP3DCNT;
  DISP3DCNT = 0;
  v[2] = DISP3DCNT;
  line("RDL", v, 3, 4);

  while (1) {
    t3d_proj_px();
    t3d_reset_matrices();
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
    for (int i = 0; i < nlist; i++) R32(0x04000400) = list[i];
    overflow_strips();
    t3d_frame(0);
  }
}
