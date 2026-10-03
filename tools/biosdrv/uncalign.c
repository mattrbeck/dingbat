// Probe: the copy, decompression and unpack routines handed addresses off a
// word (or halfword) boundary -- which of their loads rotate the word they
// read (ldr, ldrh) and which take it whole (ldmia), and where their stores
// land. Mortal Kombat - Deadly Alliance keeps its RLUnCompWram streams at
// odd halfwords: the header comes out of the word below. Every routine is
// called on the same bytes at offsets 0-3 (BitUnPack with its info block
// off too, the Vram forms with an odd destination); the destination
// (EWRAM 0x02030000 and VRAM 0x06008000, cleared before each call) and
// r0-r3 after it are compared. ARM caller in IWRAM, IRQs off.
// RESULT[2] = case.
#include "drv.h"

#define S(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
S(0B) S(0C) S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18)
#undef S

#define ST 0x02020000
#define DST 0x02030000
#define VDST 0x06008000
#define INFO 0x0201F000

static vu8 *at(u32 a) { return (vu8 *)a; }

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  // The byte pattern every stream reads. The header of a stream at a word
  // plus k is read from the word below, rotated by 8k (ldr) or not (ldmia):
  // the word's bytes are picked so that either reading gives a short length
  // (k = 0: 0x18; k = 1: 0x120 or 0x01; k = 2: 0x100 or 0x200; k = 3: 0x01
  // or 0x140)
  for (u32 i = 0; i < 0x1000; i++) at(ST + i)[0] = (u8)(i * 0x1D + 0x07);
  static const u8 hw[4][4] = {
    {0x10, 0x18, 0x00, 0x00}, {0x00, 0x20, 0x01, 0x00},
    {0x02, 0x00, 0x01, 0x00}, {0x40, 0x01, 0x00, 0x00}};
  for (u32 m = 1; m <= 5; m++)
    for (u32 k = 0; k < 4; k++)
      for (u32 i = 0; i < 4; i++) at(ST + 0x200 * m + 0x80 * k + i)[0] = hw[k][i];
  // RL: a run, then literals, after the header (k = 0)
  { vu8 *h = at(ST + 0x400 + 4); h[0] = 0x84; h[1] = 0x5A; h[2] = 0x03; }
  // Huffman: tree size 3, a three-leaf tree, after the header
  for (u32 k = 0; k < 4; k++) {
    vu8 *h = at(ST + 0xA00 + 0x80 * k + k + 4);
    static const u8 t[] = {0x03, 0x40, 0xC0, 0x00, 0x05, 0x01, 0x02, 0x00};
    for (u32 i = 0; i < sizeof t; i++) h[i] = t[i];
  }
  // BitUnPack info blocks: the length halfword reads 4 or 0x400, 4 -> 8,
  // offset 1
  for (u32 i = 0; i < 0x40; i++) at(INFO + i)[0] = 0;
  for (u32 k = 0; k < 4; k++) {
    vu8 *h = at(INFO + 0x10 * k + k);
    h[0] = 4; h[1] = 0; h[2] = 4; h[3] = 8; h[4] = 1;
  }
  static Call calls[64];
  u32 n = 0;
  for (u32 k = 0; k < 4; k++) {
    calls[n++] = (Call){s11, ST + 0x200 + 0x80 * k + k, DST, 0};
    calls[n++] = (Call){s12, ST + 0x200 + 0x80 * k + k, VDST + (k & 1), 0};
    calls[n++] = (Call){s14, ST + 0x400 + 0x80 * k + k, DST + k, 0};
    calls[n++] = (Call){s15, ST + 0x400 + 0x80 * k + k, VDST + (k & 1), 0};
    calls[n++] = (Call){s16, ST + 0x600 + 0x80 * k + k, DST + k, 0};
    calls[n++] = (Call){s17, ST + 0x600 + 0x80 * k + k, VDST + (k & 1), 0};
    calls[n++] = (Call){s18, ST + 0x800 + 0x80 * k + k, DST + k, 0};
    calls[n++] = (Call){s13, ST + 0xA00 + 0x80 * k + k, DST + k, 0};
    calls[n++] = (Call){s10, ST + k, DST + k, INFO + 0x10 * k + k};
    calls[n++] = (Call){s0B, ST + k, DST + k, 8};                  // halfword copy
    calls[n++] = (Call){s0B, ST + k, DST + k, 8 | (1 << 26)};      // word copy
    calls[n++] = (Call){s0B, ST + k, DST + k, 8 | (1 << 24)};      // halfword fill
    calls[n++] = (Call){s0B, ST + k, DST + k, 8 | (5 << 24)};      // word fill
    calls[n++] = (Call){s0C, ST + k, DST + k, 8};
    calls[n++] = (Call){s0C, ST + k, DST + k, 8 | (1 << 24)};
  }
  for (u32 i = 0; i < n; i++) {
    fill32((void *)DST, 0xEEEEEEEE, 0x100);
    fill32((void *)VDST, 0xEEEEEEEE, 0x100);
    RESULT[2] = i; RESULT[3] = 0;
    bd_callfn_stk((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
