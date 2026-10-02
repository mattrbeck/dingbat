// Probe: every timed SWI called with the System-mode stack in IWRAM and
// then in EWRAM. The BIOS dispatcher pushes {r2, lr} on that stack and most
// routines push their own frame there, so a stack in work RAM pays its wait
// states on every word (Mario Party Advance runs its tasks on EWRAM
// stacks). Thumb callers in the cartridge (WAITCNT 0x4317), IRQs off except
// for the V-blank wait. RESULT[2] = case, RESULT[3] = 0 IWRAM / 1 EWRAM.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define S(n) \
  __attribute__((naked, target("thumb"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "\n bx lr"); }
S(02) S(05) S(06) S(07) S(08) S(09) S(0A) S(0B) S(0C) S(0D) S(0E) S(0F)
S(10) S(11) S(12) S(13) S(14) S(15) S(16) S(17) S(18) S(19) S(1F)
#undef S

// bd_callfn on a stack at 0x0203FF00 (EWRAM)
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
#define STRUCTS 0x02024000

static void setup_data(void) {
  vu8 *s = (vu8 *)SRC;
  for (u32 i = 0; i < 0x200; i++) s[i] = (u8)(i * 7 + 3);
  vu32 *w = (vu32 *)STRUCTS;
  // LZ77: 16 bytes, one literal block then a back-reference block
  vu8 *lz = (vu8 *)(STRUCTS + 0x000);
  u8 lzs[] = {0x10, 16, 0, 0, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 0x80, 0x50, 0x07};
  for (u32 i = 0; i < sizeof lzs; i++) lz[i] = lzs[i];
  // RL: 20 bytes, a run of 10 then 10 literals
  vu8 *rl = (vu8 *)(STRUCTS + 0x040);
  u8 rls[] = {0x30, 20, 0, 0, 0x87, 0x5A, 0x09, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
  for (u32 i = 0; i < sizeof rls; i++) rl[i] = rls[i];
  // Diff8 (0x81) and Diff16 (0x82): 16 bytes each
  vu8 *d8 = (vu8 *)(STRUCTS + 0x080);
  d8[0] = 0x81; d8[1] = 16; d8[2] = 0; d8[3] = 0;
  for (u32 i = 0; i < 16; i++) d8[4 + i] = (u8)i;
  vu8 *d16 = (vu8 *)(STRUCTS + 0x0C0);
  d16[0] = 0x82; d16[1] = 16; d16[2] = 0; d16[3] = 0;
  for (u32 i = 0; i < 16; i++) d16[4 + i] = (u8)(i * 3);
  // Huffman (0x28, 8-bit data): tree of two leaves 'A'/'B', 8 bytes out
  vu8 *hf = (vu8 *)(STRUCTS + 0x100);
  u8 hfs[] = {0x28, 8, 0, 0, 0x01, 0xC0, 'A', 'B', 0x55, 0xAA, 0x55, 0xAA};
  for (u32 i = 0; i < sizeof hfs; i++) hf[i] = hfs[i];
  // BitUnPack info: 8 bytes 1 bpp -> 4 bpp, offset 1
  vu16 *bu = (vu16 *)(STRUCTS + 0x140);
  bu[0] = 8; ((vu8 *)bu)[2] = 1; ((vu8 *)bu)[3] = 4; w[(0x144) / 4] = 1;
  // BgAffineSet / ObjAffineSet sources
  vu32 *bg = (vu32 *)(STRUCTS + 0x180);
  bg[0] = 0x8000; bg[1] = 0x4000; ((vu16 *)bg)[4] = 10; ((vu16 *)bg)[5] = 20;
  ((vu16 *)bg)[6] = 0x100; ((vu16 *)bg)[7] = 0x180; ((vu16 *)bg)[8] = 0x2000;
  vu16 *ob = (vu16 *)(STRUCTS + 0x1C0);
  ob[0] = 0x100; ob[1] = 0x200; ob[2] = 0x3000; ob[3] = 0;
  // MidiKey2Freq WaveData: frequency at +4
  w[(0x200) / 4] = 0; w[(0x204) / 4] = 0x00D56000;
}

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  static const Call calls[] = {
    {s06, 1000000, 7, 0}, {s07, 7, 1000000, 0}, {s08, 0x12345678, 0, 0},
    {s09, 0x2000, 0, 0}, {s0A, 100, 50, 0},
    {s0B, SRC, DST, 16}, {s0B, SRC, DST, 16 | (1 << 24)},
    {s0B, SRC, DST, 16 | (1 << 26)}, {s0B, SRC, DST, 16 | (1 << 24) | (1 << 26)},
    {s0C, SRC, DST, 32}, {s0C, SRC, DST, 32 | (1 << 24)},
    {s0D, 0, 0, 0},
    {s0E, STRUCTS + 0x180, DST, 1}, {s0F, STRUCTS + 0x1C0, DST, 2},
    {s10, SRC, DST, STRUCTS + 0x140},
    {s11, STRUCTS + 0x000, DST, 0}, {s12, STRUCTS + 0x000, VDST, 0},
    {s13, STRUCTS + 0x100, DST, 0},
    {s14, STRUCTS + 0x040, DST, 0}, {s15, STRUCTS + 0x040, VDST, 0},
    {s16, STRUCTS + 0x080, DST, 0}, {s17, STRUCTS + 0x080, VDST, 0},
    {s18, STRUCTS + 0x0C0, DST, 0},
    {s19, 0, 0, 0},
    {s1F, STRUCTS + 0x200, 60, 0},
    {s05, 0, 0, 0}, {s02, 0, 0, 0},
  };
  const u32 n = sizeof calls / sizeof calls[0];
  u32 k = 0;
  REG16(0x04000204) = 0x4317;
  setup_data();
  irq_setup(1);
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
