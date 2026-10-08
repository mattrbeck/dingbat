// Probe: how the EWRAM-stack cost of the data-driven SWIs scales (see
// swisp.c): each routine at several sizes and stream shapes, with the
// System-mode stack in IWRAM and then in EWRAM, and the validation-skip
// paths. Thumb callers in the
// cartridge (WAITCNT 0x4317), IRQs off. RESULT[2] = case, RESULT[3] = stack.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define S(n) \
  __attribute__((naked, target("thumb"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "\n bx lr"); }
S(0B) S(0C) S(0E) S(0F) S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18)
#undef S

__attribute__((naked, target("arm"), section(".iwram"))) static void
callfn_ewram(u32 fn, u32 a, u32 b, u32 c) {
  __asm__ volatile(
      "push {r4, lr}\n"
      "mov r4, sp\n"
      "ldr sp, =0x0203FF00\n"
      "ldr ip, =bd_callfn\n"
      "mov lr, pc\n"
      "bx ip\n"
      "mov sp, r4\n"
      "pop {r4, lr}\n"
      "bx lr\n"
      ".pool\n");
}

#define SRC 0x02020000
#define DST 0x02028000
#define VDST 0x06010000
#define ST 0x02024000   // streams, 0x400 apart
#define INFO 0x02023F00 // BitUnPack info blocks, 8 bytes apart

static vu8 *at(u32 a) { return (vu8 *)a; }

static void hdr(u32 a, u32 type, u32 len) {
  at(a)[0] = type; at(a)[1] = len; at(a)[2] = len >> 8; at(a)[3] = len >> 16;
}

// LZ77 stream: n literal blocks of 8, then r blocks of 8 back-references (len 3, dist 1)
static void lz(u32 a, u32 lit_blocks, u32 ref_blocks) {
  u32 n = 4, out = 0;
  for (u32 b = 0; b < lit_blocks; b++) {
    at(a)[n++] = 0;
    for (u32 i = 0; i < 8; i++) at(a)[n++] = (u8)(out++ * 5 + 1);
  }
  for (u32 b = 0; b < ref_blocks; b++) {
    at(a)[n++] = 0xFF;
    for (u32 i = 0; i < 8; i++) { at(a)[n++] = 0x00; at(a)[n++] = 0x01; out += 3; }
  }
  hdr(a, 0x10, out);
}

// RL stream: runs of `run` bytes (count) then literal groups of `lit` bytes (count)
static void rl(u32 a, u32 runs, u32 run, u32 lits, u32 lit) {
  u32 n = 4, out = 0;
  for (u32 i = 0; i < runs; i++) { at(a)[n++] = 0x80 | (run - 3); at(a)[n++] = 0x5A; out += run; }
  for (u32 i = 0; i < lits; i++) {
    at(a)[n++] = lit - 1;
    for (u32 j = 0; j < lit; j++) at(a)[n++] = (u8)(j + 1);
    out += lit;
  }
  hdr(a, 0x30, out);
}

static void diff(u32 a, u32 type, u32 len) {
  hdr(a, type, len);
  for (u32 i = 0; i < len; i++) at(a)[4 + i] = (u8)(i * 3 + 1);
}

// Huffman, 8-bit symbols, a two-leaf tree: len output bytes
static void huff8(u32 a, u32 len) {
  hdr(a, 0x28, len);
  u8 t[] = {0x01, 0xC0, 'A', 'B'};
  for (u32 i = 0; i < 4; i++) at(a)[4 + i] = t[i];
  for (u32 i = 0; i < (len + 31) / 32 * 4; i++) at(a)[8 + i] = (u8)(0x5A + i);
}
static void info(u32 k, u32 len, u32 sw, u32 dw, u32 off) {
  vu8 *p = at(INFO + k * 8);
  p[0] = len; p[1] = len >> 8; p[2] = sw; p[3] = dw;
  *(vu32 *)(INFO + k * 8 + 4) = off;
}

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  for (u32 i = 0; i < 0x400; i++) at(SRC)[i] = (u8)(i * 7 + 3);
  for (u32 i = 0; i < 0x100; i++) at(0x02023000)[i] = 0;
  lz(ST + 0x0000, 1, 0); lz(ST + 0x0400, 4, 0); lz(ST + 0x0800, 1, 1); lz(ST + 0x0C00, 1, 4);
  rl(ST + 0x1000, 1, 10, 0, 0); rl(ST + 0x1400, 4, 10, 0, 0); rl(ST + 0x1800, 1, 30, 0, 0);
  rl(ST + 0x1C00, 0, 0, 1, 10); rl(ST + 0x2000, 0, 0, 4, 10); rl(ST + 0x2400, 0, 0, 1, 30);
  diff(ST + 0x2800, 0x81, 16); diff(ST + 0x2C00, 0x81, 64);
  diff(ST + 0x3000, 0x82, 16); diff(ST + 0x3400, 0x82, 64);
  huff8(ST + 0x3800, 8); huff8(ST + 0x3C00, 32);
  info(0, 1, 1, 4, 1); info(1, 4, 1, 4, 1); info(2, 4, 8, 8, 0); info(3, 16, 8, 8, 0);
  info(4, 4, 4, 8, 1); info(5, 4, 1, 32, 0x80000000);
  static const Call calls[] = {
    {s0B, SRC, DST, 64}, {s0B, SRC, DST, 64 | (1 << 24)},          // 0-1
    {s0C, SRC, DST, 128}, {s0C, SRC, DST, 128 | (1 << 24)},        // 2-3
    {s0E, 0x02023000, DST, 2}, {s0E, 0x02023000, DST, 4},          // 4-5
    {s0F, 0x02023000, DST, 2}, {s0F, 0x02023000, DST, 4},          // 6-7
    {s10, SRC, DST, INFO + 0}, {s10, SRC, DST, INFO + 8},          // 8-9
    {s10, SRC, DST, INFO + 16}, {s10, SRC, DST, INFO + 24},        // 10-11
    {s10, SRC, DST, INFO + 32}, {s10, SRC, DST, INFO + 40},        // 12-13
    {s11, ST + 0x0000, DST, 0}, {s11, ST + 0x0400, DST, 0},        // 14-15
    {s11, ST + 0x0800, DST, 0}, {s11, ST + 0x0C00, DST, 0},        // 16-17
    {s12, ST + 0x0000, VDST, 0}, {s12, ST + 0x0400, VDST, 0},      // 18-19
    {s12, ST + 0x0800, VDST, 0}, {s12, ST + 0x0C00, VDST, 0},      // 20-21
    {s14, ST + 0x1000, DST, 0}, {s14, ST + 0x1400, DST, 0}, {s14, ST + 0x1800, DST, 0},   // 22-24
    {s14, ST + 0x1C00, DST, 0}, {s14, ST + 0x2000, DST, 0}, {s14, ST + 0x2400, DST, 0},   // 25-27
    {s15, ST + 0x1000, VDST, 0}, {s15, ST + 0x1400, VDST, 0}, {s15, ST + 0x1800, VDST, 0},  // 28-30
    {s15, ST + 0x1C00, VDST, 0}, {s15, ST + 0x2000, VDST, 0}, {s15, ST + 0x2400, VDST, 0},  // 31-33
    {s16, ST + 0x2800, DST, 0}, {s16, ST + 0x2C00, DST, 0},        // 34-35
    {s17, ST + 0x2800, VDST, 0}, {s17, ST + 0x2C00, VDST, 0},      // 36-37
    {s18, ST + 0x3000, DST, 0}, {s18, ST + 0x3400, DST, 0},        // 38-39
    {s13, ST + 0x3800, DST, 0}, {s13, ST + 0x3C00, DST, 0},        // 40-41
    // validation skips: zero length, or a source below 0x02000000
    {s0B, SRC, DST, 0}, {s0C, SRC, DST, 0}, {s10, 0x100, DST, INFO + 8},   // 42-44
    {s11, 0x100, DST, 0}, {s12, 0x100, VDST, 0}, {s13, 0x100, DST, 0},     // 45-47
    {s14, 0x100, DST, 0}, {s15, 0x100, VDST, 0}, {s16, 0x100, DST, 0},     // 48-50
    {s17, 0x100, VDST, 0}, {s18, 0x100, DST, 0},                           // 51-52
  };
  const u32 n = sizeof calls / sizeof calls[0];
  u32 k = 0;
  REG16(0x04000204) = 0x4317;
  for (u32 where = 0; where < 2; where++)
    for (u32 i = 0; i < n; i++) {
      RESULT[2] = i; RESULT[3] = where;
      Q();
      if (where) callfn_ewram((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
      else bd_callfn((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
      RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
    }
  MARK(0xFE);
  for (;;) {}
}
