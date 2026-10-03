// Probe: the decompression routines' edge cases, output compared byte by byte
// (the destination, EWRAM 0x02030000 and VRAM 0x06008000, is cleared to 0xEE
// before each call and snapshotted after it): a header length that ends
// inside an LZ77 reference or a run (does the routine stop, or finish the
// token?), LZ77UnCompVram reading back a byte it has not stored yet
// (distance 1 at an odd position), HuffUnComp with its bitstream off a word
// boundary and 4-bit leaves above 15, BitUnPack offsets that overflow the
// destination width, odd lengths for the halfword forms, the Wram LZ77 into
// VRAM. ARM caller in IWRAM, IRQs off. RESULT[2] = case.
#include "drv.h"

#define S(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18)
#undef S

#define ST 0x02020000   // streams, 0x100 apart
#define DST 0x02030000
#define VDST 0x06008000
#define INFO 0x0201F000

static vu8 *at(u32 a) { return (vu8 *)a; }
static void put(u32 a, const u8 *b, u32 n) { for (u32 i = 0; i < n; i++) at(a)[i] = b[i]; }

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  // 0: LZ77, header 10 bytes: 4 literals, then a reference of 18 (cut at 6)
  static const u8 lz_cut[] = {0x10, 10, 0, 0, 0x08, 1, 2, 3, 4, 0xF0, 0x03, 9, 9, 9};
  put(ST + 0x000, lz_cut, sizeof lz_cut);
  // 1: LZ77 with a distance-1 reference starting at an odd position
  static const u8 lz_d1[] = {0x10, 16, 0, 0, 0x10, 0x11, 0x22, 0x33, 0x40, 0x00, 0x44,
                             0x55, 0x66, 0x77, 0x88, 0x99};
  put(ST + 0x100, lz_d1, sizeof lz_d1);
  // 2: LZ77 with a distance-1 reference at an even position
  static const u8 lz_d1e[] = {0x10, 16, 0, 0, 0x20, 0x11, 0x22, 0x40, 0x00, 0x44, 0x55,
                              0x66, 0x77, 0x88, 0x99, 0xAA};
  put(ST + 0x200, lz_d1e, sizeof lz_d1e);
  // 3: RL, header 7: a run of 10 (cut at 7); 4: literals 6, then cut at 3 of 6
  static const u8 rl_cut[] = {0x30, 7, 0, 0, 0x87, 0xAB, 0x05, 1, 2, 3, 4, 5, 6};
  put(ST + 0x300, rl_cut, sizeof rl_cut);
  static const u8 rl_cut2[] = {0x30, 3, 0, 0, 0x05, 1, 2, 3, 4, 5, 6, 0x83, 0x77};
  put(ST + 0x400, rl_cut2, sizeof rl_cut2);
  // 5: Huffman, 8-bit, tree size byte 2 (bitstream at +10: off a word)
  static const u8 hf_mis[] = {0x28, 8, 0, 0, 0x02, 0x40, 0xC0, 0x00, 0x05, 0x01,
                              0x5A, 0xA5, 0x3C, 0xC3, 0x96, 0x69, 0x0F, 0xF0, 0x12, 0x34};
  put(ST + 0x500, hf_mis, sizeof hf_mis);
  // 6: Huffman, 4-bit, leaves 0x1F, 0x23, 0x05
  static const u8 hf_4[] = {0x24, 8, 0, 0, 0x03, 0x40, 0xC0, 0x23, 0x1F, 0x05, 0x00, 0x00,
                            0x5A, 0xA5, 0x3C, 0xC3, 0x96, 0x69, 0x0F, 0xF0};
  put(ST + 0x600, hf_4, sizeof hf_4);
  // 7-10: BitUnPack, source bytes
  static const u8 bsrc[] = {0xFF, 0x81, 0x7E, 0x00, 0x13, 0x57, 0x9B, 0xDF};
  put(ST + 0x700, bsrc, sizeof bsrc);
  vu16 *h;
  h = (vu16 *)(INFO + 0x00); h[0] = 8; at(INFO + 0x02)[0] = 1; at(INFO + 0x03)[0] = 4;
  ((vu32 *)(INFO + 0x04))[0] = 0x0000000F;            // 1 -> 4, offset overflows
  h = (vu16 *)(INFO + 0x10); h[0] = 8; at(INFO + 0x12)[0] = 4; at(INFO + 0x13)[0] = 8;
  ((vu32 *)(INFO + 0x14))[0] = 0x800000F8;            // 4 -> 8, zero flag, overflows
  h = (vu16 *)(INFO + 0x20); h[0] = 8; at(INFO + 0x22)[0] = 8; at(INFO + 0x23)[0] = 32;
  ((vu32 *)(INFO + 0x24))[0] = 0x7FFFFFF0;            // 8 -> 32
  h = (vu16 *)(INFO + 0x30); h[0] = 3; at(INFO + 0x32)[0] = 2; at(INFO + 0x33)[0] = 8;
  ((vu32 *)(INFO + 0x34))[0] = 0x00000001;            // 2 -> 8, 3 bytes: a partial word
  // 11: Diff16, odd length 5; 12: Diff8 Vram, length 1
  static const u8 d16[] = {0x82, 5, 0, 0, 0x34, 0x12, 0x01, 0x01, 0xFF, 0xFF, 0x22, 0x22};
  put(ST + 0x800, d16, sizeof d16);
  static const u8 d8v1[] = {0x81, 1, 0, 0, 0x7C};
  put(ST + 0x900, d8v1, sizeof d8v1);
  // 13: RL Vram, a run that ends odd; 14: header length 0 (skip)
  static const u8 rlv[] = {0x30, 9, 0, 0, 0x86, 0x5E, 0x00, 0x99, 0x80, 0x11};
  put(ST + 0xA00, rlv, sizeof rlv);
  static const u8 zero[] = {0x10, 0, 0, 0, 0xFF, 0xFF};
  put(ST + 0xB00, zero, sizeof zero);

  static const Call calls[] = {
    {s11, ST + 0x000, DST, 0}, {s12, ST + 0x000, VDST, 0},   // 0-1 LZ77 cut
    {s12, ST + 0x100, VDST, 0}, {s12, ST + 0x200, VDST, 0},  // 2-3 LZ77 Vram distance 1
    {s11, ST + 0x100, VDST, 0},                              // 4 Wram form into VRAM
    {s14, ST + 0x300, DST, 0}, {s14, ST + 0x400, DST, 0},    // 5-6 RL cut
    {s15, ST + 0x300, VDST, 0}, {s15, ST + 0xA00, VDST, 0},  // 7-8 RL Vram
    {s13, ST + 0x500, DST, 0}, {s13, ST + 0x600, DST, 0},    // 9-10 Huffman
    {s10, ST + 0x700, DST, INFO + 0x00}, {s10, ST + 0x700, DST, INFO + 0x10},  // 11-12
    {s10, ST + 0x700, DST, INFO + 0x20}, {s10, ST + 0x700, DST, INFO + 0x30},  // 13-14
    {s18, ST + 0x800, DST, 0}, {s17, ST + 0x900, VDST, 0},   // 15-16
    {s17, ST + 0x800, VDST, 0}, {s16, ST + 0x800, DST, 0},   // 17-18
    {s11, ST + 0xB00, DST, 0}, {s15, ST + 0xB00, VDST, 0},   // 19-20 zero length
  };
  const u32 n = sizeof calls / sizeof calls[0];
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
