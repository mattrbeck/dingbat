// 3d_timing_cmds: geometry command execution times (GBATEK "DS 3D Geometry
// Commands", the cycle column) and GXSTAT read mid-command (GBATEK "DS 3D
// Status"). Printed on the bottom screen in hex once at start-up.
//
// A cost row is T(144 commands) - T(48 commands) in bus cycles (33.51 MHz,
// timers 0+1), from the first write until GXSTAT.27 clears, with the I-cache
// on so the CPU writes faster than the engine drains: the difference is the
// engine time of 96 commands, the FIFO keeping it busy throughout (both
// counts are multiples of 3 so vertex lists end on whole triangles).
// GBATEK's cycles per command are given beside each label (x 96 = the
// expected reading). Commands cheaper than the CPU's write loop show the
// loop instead (MODE: the write rate itself).
//   MODE  MTX_MODE (1)
//   IDNT  MTX_IDENTITY (19)
//   PUPO  48 x (MTX_PUSH 17 + MTX_POP 36); 48 x (MTX_STORE 17 + MTX_RESTORE 36)
//   SCAL  MTX_SCALE (22) in modes 1, 2; MTX_TRANS (22, +30 in mode 2);
//         MTX_MULT_3x3 (28, +30)
//   M43   MTX_MULT_4x3 (31, +30); MTX_MULT_4x4 (35, +30); MTX_LOAD_4x3 (30),
//         MTX_LOAD_4x4 (34)
//   NRM   NORMAL with 0, 1, 2, 3, 4 lights (9..12)
//   V16   VTX_16 (9) as visible triangles, as clipped-away ones; VTX_10,
//         VTX_XY, VTX_DIFF (8)
//   TEST  BOX_TEST (103), POS_TEST (9), VEC_TEST (5)
//   MATL  DIF_AMB (4), SPE_EMI (4), LIGHT_VECTOR (6), LIGHT_COLOR (1)
//   MISC  COLOR, TEXCOORD, POLYGON_ATTR, BEGIN_VTXS (1 each); SHININESS (32)
//   MID   GXSTAT right after BOX_TEST, POS_TEST, VEC_TEST, MTX_PUSH,
//         MTX_POP, MTX_STORE, MTX_IDENTITY were written
//   LAT   bus cycles from the last parameter write to GXSTAT.0 clearing:
//         BOX_TEST, POS_TEST, VEC_TEST; then to GXSTAT.14 clearing after
//         MTX_PUSH, MTX_POP; then two clock reads back to back
#include "t3d.h"
#include "tm.h"

// gx_burst(cmd, nparams, reps, vals): `reps` times, write the command word
// `cmd` to GXFIFO (unpacked, or a packed word) and then `nparams`
// parameter words from vals[0..7] (repeating after 8), all with STM / STR
// from registers, so the CPU outruns every command that costs more than a
// few cycles per word.
void gx_burst(u32 cmd, u32 nparams, u32 reps, const u32 *vals);
__asm__(
    "  .text\n"
    "  .arm\n"
    "  .global gx_burst\n"
    "gx_burst:\n"
    "  push {r4-r11, lr}\n"
    "  ldmia r3, {r4-r11}\n"
    "  mov r12, #0x04000000\n"
    "  add r12, r12, #0x400\n"
    "1:str r0, [r12]\n"
    "  mov r3, r1\n"
    "2:cmp r3, #8\n"
    "  blt 3f\n"
    "  stmia r12, {r4-r11}\n"
    "  sub r3, r3, #8\n"
    "  b 2b\n"
    "3:rsb lr, r3, #8\n"
    "  add pc, pc, lr, lsl #2\n"
    "  nop\n"
    "  str r4, [r12]\n"
    "  str r5, [r12]\n"
    "  str r6, [r12]\n"
    "  str r7, [r12]\n"
    "  str r8, [r12]\n"
    "  str r9, [r12]\n"
    "  str r10, [r12]\n"
    "  str r11, [r12]\n"
    "  subs r2, r2, #1\n"
    "  bne 1b\n"
    "  pop {r4-r11, pc}\n");

// port_burst(port, n, vals): n writes of vals[0..7] (cycling) to one
// command port, 8 STRs per loop pass: the fastest way to send commands with
// one parameter (or none: a dummy write each).
void port_burst(u32 port, u32 n, const u32 *vals);
__asm__(
    "  .text\n"
    "  .arm\n"
    "  .global port_burst\n"
    "port_burst:\n"
    "  push {r4-r11, lr}\n"
    "  ldmia r2, {r4-r11}\n"
    "1:str r4, [r0]\n"
    "  str r5, [r0]\n"
    "  str r6, [r0]\n"
    "  str r7, [r0]\n"
    "  str r8, [r0]\n"
    "  str r9, [r0]\n"
    "  str r10, [r0]\n"
    "  str r11, [r0]\n"
    "  subs r1, r1, #8\n"
    "  bgt 1b\n"
    "  pop {r4-r11, pc}\n");

static u32 prun(u32 port, u32 np, const u32 *vals, u32 k) {
  t3d_wait_idle();
  u32 t0 = clock_now();
  port_burst(port, np * k, vals);
  t3d_wait_idle();
  return clock_now() - t0;
}

// commands sent through their port: np words each (1 for none); np * 48
// must be a multiple of 8
static u32 pcost(u32 cmd, u32 np, const u32 *vals) {
  u32 port = 0x04000400 + cmd * 4;
  u32 a = prun(port, np, vals, 48);
  u32 b = prun(port, np, vals, 144);
  return b - a;
}

static u32 run(u32 cmd, u32 np, const u32 *vals, u32 k) {
  t3d_wait_idle();
  u32 t0 = clock_now();
  gx_burst(cmd, np, k, vals);
  t3d_wait_idle();
  return clock_now() - t0;
}

static u32 cost(u32 cmd, u32 np, const u32 *vals) {
  u32 a = run(cmd, np, vals, 48);
  u32 b = run(cmd, np, vals, 144);
  return b - a;
}

static const u32 IDENT8[8] = {4096, 0, 0, 0, 0, 4096, 0, 0};
static const u32 ONES[8] = {1, 1, 1, 1, 1, 1, 1, 1};
static const u32 ZERO[8];
static const u32 SCALE1[8] = {4096, 4096, 4096, 0, 0, 0, 0, 0};
static const u32 BOX[8] = {0, 64u << 16, 64 | (64u << 16), 0, 0, 0, 0, 0};
static const u32 NRM[8] = {0x1FF00000, 0, 0, 0, 0, 0, 0, 0};          // (0, 0, -1/512)
static const u32 VTX_ON[8] = {0x18002000, 0, 0x18002000, 0, 0x18002000, 0, 0x18002000, 0};   // dot (128, 96)
static const u32 VTX_OFF[8] = {0x70000000, 0, 0x70000000, 0, 0x70000000, 0, 0x70000000, 0};   // dot row 448: clipped
static const u32 VEC[8] = {0x0FF00000, 0, 0, 0, 0, 0, 0, 0};
static const u32 WHITE[8] = {0x7FFF7FFF, 0x7FFF, 0x7FFF, 0, 0, 0, 0, 0};

static void fresh_frame(void) {
  // empty polygon RAM between vertex measurements
  end_vtxs();
  t3d_frame(0);
  t3d_proj_px();
  t3d_reset_matrices();
}

int main(void) {
  t3d_init("3d_timing_cmds");
  icache_on();
  clock_start();
  u32 v[8];

  v[0] = pcost(0x10, 1, ONES);
  tm_line("MODE", v, 1, 4);
  v[0] = pcost(0x15, 1, ZERO);
  tm_line("IDNT", v, 1, 4);
  mtx_mode(1);
  v[0] = cost(0x1211, 1, ONES);     // packed PUSH, POP(1)
  v[1] = cost(0x1413, 2, ONES);     // packed STORE(1), RESTORE(1)
  tm_line("PUPO", v, 2, 4);

  for (int m = 1; m <= 2; m++) {
    mtx_mode(m);
    v[m - 1] = pcost(0x1B, 3, SCALE1);
    v[m + 1] = pcost(0x1C, 3, ZERO);
    v[m + 3] = cost(0x1A, 9, IDENT8);
    t3d_reset_matrices();
  }
  tm_line("SCAL", v, 6, 4);   // scale m1 m2, trans m1 m2, mult3x3 m1 m2
  for (int m = 1; m <= 2; m++) {
    mtx_mode(m);
    v[m - 1] = cost(0x19, 12, IDENT8);
    v[m + 1] = cost(0x18, 16, IDENT8);
    t3d_reset_matrices();
  }
  mtx_mode(1);
  v[4] = cost(0x17, 12, IDENT8);
  v[5] = cost(0x16, 16, IDENT8);
  tm_line("M43", v, 6, 4);    // mult4x3 m1 m2, mult4x4 m1 m2, load4x3, load4x4
  t3d_reset_matrices();

  static const int masks[5] = {0, 1, 3, 7, 15};
  for (int i = 0; i < 5; i++) {
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_LIGHTS(masks[i]));
    begin(TRIS);
    v[i] = pcost(0x21, 1, NRM);
    end_vtxs();
  }
  tm_line("NRM", v, 5, 4);

  fresh_frame();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31));
  begin(TRIS);
  v[0] = pcost(0x23, 2, VTX_ON);
  fresh_frame();
  begin(TRIS);
  v[1] = pcost(0x23, 2, VTX_OFF);
  fresh_frame();
  begin(TRIS);
  v[2] = pcost(0x24, 1, VTX_ON);
  fresh_frame();
  begin(TRIS);
  v[3] = pcost(0x25, 1, VTX_ON);
  fresh_frame();
  begin(TRIS);
  v[4] = pcost(0x28, 1, VTX_ON);
  fresh_frame();
  tm_line("V16", v, 5, 4);    // vtx16 visible, clipped away; vtx10, vtx_xy, vtx_diff

  mtx_mode(2);
  v[0] = pcost(0x70, 3, BOX);
  v[1] = pcost(0x71, 2, ZERO);
  v[2] = pcost(0x72, 1, VEC);
  tm_line("TEST", v, 3, 4);
  v[0] = pcost(0x30, 1, WHITE);
  v[1] = pcost(0x31, 1, ZERO);
  v[2] = pcost(0x32, 1, NRM);
  v[3] = pcost(0x33, 1, WHITE);
  tm_line("MATL", v, 4, 4);
  mtx_mode(1);
  v[0] = pcost(0x20, 1, WHITE);
  v[1] = pcost(0x22, 1, ZERO);
  v[2] = pcost(0x29, 1, ZERO);
  v[3] = pcost(0x40, 1, ZERO);
  end_vtxs();
  v[4] = cost(0x34, 32, ZERO);
  tm_line("MISC", v, 5, 4);   // color, texcoord, poly_attr, begin; shininess

  // GXSTAT straight after the write that completes a command
  t3d_wait_idle();
  mtx_mode(2);
  box_test(0, 0, 0, 64, 64, 64);
  v[0] = GXSTAT;
  t3d_wait_idle();
  pos_test(0, 0, 0);
  v[1] = GXSTAT;
  t3d_wait_idle();
  vec_test(0, 0, 255);
  v[2] = GXSTAT;
  t3d_wait_idle();
  mtx_mode(1);
  t3d_wait_idle();
  mtx_push();
  v[3] = GXSTAT;
  t3d_wait_idle();
  mtx_pop(1);
  v[4] = GXSTAT;
  t3d_wait_idle();
  mtx_store(1);
  v[5] = GXSTAT;
  t3d_wait_idle();
  mtx_identity();
  v[6] = GXSTAT;
  t3d_wait_idle();
  tm_line("MID", v, 7, 8);

  // latency to the busy bit clearing
  mtx_mode(2);
  t3d_wait_idle();
  u32 t0 = clock_now();
  box_test(0, 0, 0, 64, 64, 64);
  while (GXSTAT & 1) {}
  v[0] = clock_now() - t0;
  t3d_wait_idle();
  t0 = clock_now();
  pos_test(0, 0, 0);
  while (GXSTAT & 1) {}
  v[1] = clock_now() - t0;
  t3d_wait_idle();
  t0 = clock_now();
  vec_test(0, 0, 255);
  while (GXSTAT & 1) {}
  v[2] = clock_now() - t0;
  t3d_wait_idle();
  mtx_mode(1);
  t3d_wait_idle();
  t0 = clock_now();
  mtx_push();
  while (GXSTAT & (1u << 14)) {}
  v[3] = clock_now() - t0;
  t3d_wait_idle();
  t0 = clock_now();
  mtx_pop(1);
  while (GXSTAT & (1u << 14)) {}
  v[4] = clock_now() - t0;
  t3d_wait_idle();
  t0 = clock_now();
  v[5] = clock_now() - t0;   // the clock read itself
  tm_line("LAT", v, 6, 4);

  // the scene: a quad, so frames compare
  while (1) {
    t3d_proj_px();
    t3d_reset_matrices();
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
    color(RGB(31, 20, 0));
    quad_px(96, 64, 160, 128, 0);
    t3d_frame(0);
  }
}
