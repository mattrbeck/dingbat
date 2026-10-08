// Probe: the decompression and unpack family on short synthetic streams,
// one call each, IRQs off, no DMA -- the shapes that walk every path of each
// routine (literals and back-references, runs and literal runs, 4- and
// 8-bit Huffman trees, every BitUnPack width pair, the three Diff filters),
// into EWRAM and VRAM. ARM caller in IWRAM (bd_callfn_stk: the stack the
// routine leaves). For tools/biosdrv/steptrace.nim and compare.py.
// RESULT[2] = case.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define S(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18)
#undef S

#define ST 0x02020000   // streams, 0x200 apart
#define DST 0x02030000
#define VDST 0x06004000
#define INFO 0x0201F000

static vu8 *at(u32 a) { return (vu8 *)a; }

// LZ77: n tokens; every third a back-reference (lengths 3..18, distances
// 1..20), the output ending inside a reference when cut is set
static void lz(u32 a, u32 n, u32 cut) {
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
  if (cut) out -= 2;
  at(a)[0] = 0x10; at(a)[1] = out; at(a)[2] = out >> 8; at(a)[3] = 0;
}

static void rl(u32 a) {
  static const u8 t[] = {0x30, 23, 0, 0, 0x82, 0x55, 0x02, 1, 2, 3, 0x80, 0x66,
                         0x00, 9, 0x83, 0x77};
  for (u32 i = 0; i < sizeof t; i++) at(a)[i] = t[i];
}

static void huff(u32 a, u32 bits, u32 len) {
  at(a)[0] = 0x20 | bits; at(a)[1] = len; at(a)[2] = 0; at(a)[3] = 0;
  // root -> (node -> two leaves), leaf; offsets per the format
  static const u8 t[] = {0x03, 0x40, 0xC0, 0x00, 0x05, 0x01, 0x02, 0x00};
  for (u32 n = 0; n < 8; n++) at(a)[4 + n] = t[n];
  for (u32 i = 0; i < 32; i++) at(a)[12 + i] = (u8)(0x5A + i * 37);
}

static void diff(u32 a, u32 type, u32 len) {
  at(a)[0] = 0x80 | type; at(a)[1] = len; at(a)[2] = 0; at(a)[3] = 0;
  for (u32 i = 0; i < len; i++) at(a)[4 + i] = (u8)(i * 29 + 3);
}

static void bup(u32 a, u32 len, u32 sw, u32 dw, u32 off) {
  vu16 *h = (vu16 *)a;
  h[0] = len; at(a)[2] = sw; at(a)[3] = dw;
  ((vu32 *)a)[1] = off;
}

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  lz(ST + 0x000, 24, 0);
  lz(ST + 0x200, 24, 1);
  rl(ST + 0x400);
  huff(ST + 0x600, 8, 8);
  huff(ST + 0x800, 4, 8);
  diff(ST + 0xA00, 1, 9);
  diff(ST + 0xC00, 2, 10);
  for (u32 i = 0; i < 16; i++) at(ST + 0xE00)[i] = (u8)(i * 0x35 + 0x10);
  bup(INFO + 0x00, 4, 1, 4, 0x00000001);
  bup(INFO + 0x10, 4, 4, 8, 0x80000010);
  bup(INFO + 0x20, 4, 8, 16, 0x00000000);
  bup(INFO + 0x30, 2, 2, 32, 0x00000003);
  static const Call calls[] = {
    {s11, ST + 0x000, DST, 0}, {s11, ST + 0x200, DST, 0},     // 0-1 LZ77 Wram
    {s12, ST + 0x000, VDST, 0}, {s12, ST + 0x200, VDST, 0},   // 2-3 LZ77 Vram
    {s14, ST + 0x400, DST, 0}, {s15, ST + 0x400, VDST, 0},    // 4-5 RL
    {s13, ST + 0x600, DST, 0}, {s13, ST + 0x800, DST, 0},     // 6-7 Huff 8, 4
    {s16, ST + 0xA00, DST, 0}, {s17, ST + 0xA00, VDST, 0},    // 8-9 Diff8
    {s18, ST + 0xC00, DST, 0},                                // 10 Diff16
    {s10, ST + 0xE00, DST, INFO + 0x00}, {s10, ST + 0xE00, DST, INFO + 0x10},  // 11-12
    {s10, ST + 0xE00, DST, INFO + 0x20}, {s10, ST + 0xE00, VDST, INFO + 0x30}, // 13-14
  };
  const u32 n = sizeof calls / sizeof calls[0];
  for (u32 i = 0; i < n; i++) {
    RESULT[2] = i; RESULT[3] = 0;
    Q();
    bd_callfn_stk((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
