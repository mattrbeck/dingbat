// Probe: the registers each routine keeps its work in, as an interrupt
// finds them -- Timer 1 every 257 cycles while the copy, decompression,
// unpack and wait routines run (steptrace.nim BD_IRQREGS=1 logs r0-r12 and
// the System sp and lr at each interrupt, for the HLE and the BIOS image
// alike). A game's handler that does not keep a register the console's
// routine leaves alone breaks the HLE's routine if the HLE keeps state
// there (Dragon Ball Z - The Legacy of Goku's handler and r8). ARM caller in
// IWRAM (bd_callfn_stk: r3, r6-r11 hold known values). RESULT[2] = case.
#include "drv.h"

#define S(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
S(04) S(05) S(06) S(07) S(0B) S(0C) S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18)
#undef S

#define ST 0x02020000   // streams, 0x400 apart
#define DST 0x02030000
#define VDST 0x06004000
#define INFO 0x0201F000

static vu8 *at(u32 a) { return (vu8 *)a; }

static void lz(u32 a, u32 n) {
  u32 p = 4, out = 0;
  for (u32 blk = 0; blk * 8 < n; blk++) {
    u32 fpos = p++;
    u8 flags = 0;
    for (u32 b = 0; b < 8 && blk * 8 + b < n; b++) {
      u32 i = blk * 8 + b;
      if (out >= 4 && i % 3 == 0) {
        u32 len = 3 + (i * 5) % 16, off = (i * 7) % 20;
        at(a)[p++] = ((len - 3) << 4) | (off >> 8);
        at(a)[p++] = off & 0xFF;
        flags |= 0x80 >> b;
        out += len;
      } else {
        at(a)[p++] = (u8)(i * 13 + 7);
        out += 1;
      }
    }
    at(a)[fpos] = flags;
  }
  at(a)[0] = 0x10; at(a)[1] = out; at(a)[2] = out >> 8; at(a)[3] = 0;
}

static void rl(u32 a) {
  u32 n = 4, out = 0;
  for (u32 i = 0; out < 0x180; i++) {
    if (i & 1) { u32 len = 3 + (i * 37) % 30; at(a)[n++] = 0x80 | (len - 3); at(a)[n++] = (u8)i; out += len; }
    else { u32 len = 1 + (i * 11) % 12; at(a)[n++] = len - 1; for (u32 k = 0; k < len; k++) at(a)[n++] = (u8)(i + k); out += len; }
  }
  at(a)[0] = 0x30; at(a)[1] = out; at(a)[2] = out >> 8; at(a)[3] = 0;
}

static void huff(u32 a, u32 bits) {
  at(a)[0] = 0x20 | bits; at(a)[1] = 0x80; at(a)[2] = 0; at(a)[3] = 0;
  static const u8 t[] = {0x03, 0x40, 0xC0, 0x00, 0x05, 0x01, 0x02, 0x00};
  for (u32 n = 0; n < 8; n++) at(a)[4 + n] = t[n];
  for (u32 i = 0; i < 0x100; i++) at(a)[12 + i] = (u8)(0x5A + i * 37);
}

static void diff(u32 a, u32 type) {
  at(a)[0] = 0x80 | type; at(a)[1] = 0x80; at(a)[2] = 0; at(a)[3] = 0;
  for (u32 i = 0; i < 0x80; i++) at(a)[4 + i] = (u8)(i * 29 + 3);
}

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  lz(ST + 0x000, 120);
  rl(ST + 0x400);
  huff(ST + 0x800, 8);
  huff(ST + 0xC00, 4);
  diff(ST + 0x1000, 1);
  diff(ST + 0x1400, 2);
  for (u32 i = 0; i < 0x80; i++) at(ST + 0x1800)[i] = (u8)(i * 0x35 + 0x10);
  vu16 *h = (vu16 *)INFO;
  h[0] = 0x40; at(INFO + 2)[0] = 2; at(INFO + 3)[0] = 8; ((vu32 *)(INFO + 4))[0] = 0x80000003;
  static const Call calls[] = {
    {s11, ST + 0x000, DST, 0}, {s12, ST + 0x000, VDST, 0},
    {s14, ST + 0x400, DST, 0}, {s15, ST + 0x400, VDST, 0},
    {s13, ST + 0x800, DST, 0}, {s13, ST + 0xC00, DST, 0},
    {s16, ST + 0x1000, DST, 0}, {s17, ST + 0x1000, VDST, 0}, {s18, ST + 0x1400, DST, 0},
    {s10, ST + 0x1800, DST, INFO},
    {s0B, ST, DST, 0x60}, {s0B, ST, DST, 0x60 | (1 << 24)},
    {s0B, ST, DST, 0x60 | (1 << 26)}, {s0B, ST, DST, 0x60 | (5 << 24)},
    {s0C, ST, DST, 0x80}, {s0C, ST, DST, 0x80 | (1 << 24)},
    {s06, 1000000, 7, 0}, {s07, 7, 1000000, 0}, {s06, -123456789, 77, 0},
    {s05, 0, 0, 0}, {s04, 1, 1, 0},
  };
  const u32 n = sizeof calls / sizeof calls[0];
  irq_setup((1 << 4) | 1);                 // Timer 1, V-blank
  for (u32 i = 0; i < n; i++) {
    REG16(0x04000106) = 0;
    REG16(0x04000104) = (u16)(0x10000 - 257);
    REG16(0x04000106) = 0x00C0;
    RESULT[2] = i; RESULT[3] = 0;
    bd_callfn_stk((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
    REG16(0x04000106) = 0;
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
