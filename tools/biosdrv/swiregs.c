// Probe: what the math, affine, filter and sound SWIs hand back in r0-r3
// beyond their documented results (bd_regs after each call), over inputs
// that move the scratch values: BgAffineSet at several angles and scales,
// ArcTan at several inputs, MidiKey2Freq at several keys and pitches,
// Diff16bitUnFilter and the odd-length Vram decompressors. Thumb callers in
// the cartridge (WAITCNT 0x4317), IRQs off. RESULT[2] = case.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define S(n) \
  __attribute__((naked, target("thumb"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "\n bx lr"); }
S(08) S(09) S(0A) S(0D) S(0E) S(0F) S(15) S(17) S(18) S(19) S(1F)
#undef S

#define DST 0x02028000
#define VDST 0x06010000
#define ST 0x02024000

static vu8 *at(u32 a) { return (vu8 *)a; }
static void bg(u32 a, u32 sx, u32 sy, u32 ang) {
  vu32 *w = (vu32 *)a;
  w[0] = 0x8000; w[1] = 0x4000;
  ((vu16 *)a)[4] = 10; ((vu16 *)a)[5] = 20;
  ((vu16 *)a)[6] = sx; ((vu16 *)a)[7] = sy; ((vu16 *)a)[8] = ang;
}

typedef struct { void (*fn)(void); u32 a, b, c; } Call;

int main(void) {
  bg(ST + 0x000, 0x100, 0x100, 0x0000);
  bg(ST + 0x020, 0x100, 0x100, 0x1000);
  bg(ST + 0x040, 0x100, 0x180, 0x2000);
  bg(ST + 0x060, 0x200, 0x100, 0x4000);
  bg(ST + 0x080, 0x0C0, 0x100, 0xC000);
  bg(ST + 0x0A0, 0x100, 0x100, 0x2345);
  // ObjAffineSet source
  vu16 *ob = (vu16 *)(ST + 0x100);
  ob[0] = 0x100; ob[1] = 0x200; ob[2] = 0x3000; ob[3] = 0;
  // Diff16: 16 and 6 bytes
  at(ST + 0x200)[0] = 0x82; at(ST + 0x200)[1] = 16; at(ST + 0x200)[2] = 0; at(ST + 0x200)[3] = 0;
  for (u32 i = 0; i < 16; i++) at(ST + 0x204)[i] = (u8)(i * 11 + 5);
  at(ST + 0x240)[0] = 0x82; at(ST + 0x240)[1] = 6; at(ST + 0x240)[2] = 0; at(ST + 0x240)[3] = 0;
  for (u32 i = 0; i < 6; i++) at(ST + 0x244)[i] = (u8)(i * 29 + 1);
  // Diff8 Vram, odd length 7
  at(ST + 0x280)[0] = 0x81; at(ST + 0x280)[1] = 7; at(ST + 0x280)[2] = 0; at(ST + 0x280)[3] = 0;
  for (u32 i = 0; i < 7; i++) at(ST + 0x284)[i] = (u8)(i * 3 + 1);
  // Diff8 Vram, odd lengths 3, 5, 9, 1 and even 8
  static const u8 dl[] = {3, 5, 9, 1, 8};
  for (u32 k = 0; k < 5; k++) {
    vu8 *d = at(ST + 0x400 + k * 0x20);
    d[0] = 0x81; d[1] = dl[k]; d[2] = 0; d[3] = 0;
    for (u32 i = 0; i < dl[k]; i++) d[4 + i] = (u8)(i * 5 + 2);
  }
  bg(ST + 0x0C0, 0x100, 0x100, 0x8000);
  // RL Vram, odd length 11: a run of 5, then 6 literals
  u8 rl[] = {0x30, 11, 0, 0, 0x82, 0x77, 0x05, 1, 2, 3, 4, 5, 6};
  for (u32 i = 0; i < sizeof rl; i++) at(ST + 0x2C0)[i] = rl[i];
  // MidiKey2Freq WaveData: frequency at +4
  vu32 *wd = (vu32 *)(ST + 0x300);
  wd[0] = 0; wd[1] = 0x00D56000;
  static const Call calls[] = {
    {s0E, ST + 0x000, DST, 1}, {s0E, ST + 0x020, DST, 1}, {s0E, ST + 0x040, DST, 1},  // 0-2
    {s0E, ST + 0x060, DST, 1}, {s0E, ST + 0x080, DST, 1}, {s0E, ST + 0x0A0, DST, 1},  // 3-5
    {s0E, ST + 0x000, DST, 6},                                                         // 6
    {s0F, ST + 0x100, DST, 1},                                                         // 7
    {s09, 0x0000, 0, 0}, {s09, 0x2000, 0, 0}, {s09, 0x4000, 0, 0}, {s09, 0xC000, 0, 0},  // 8-11
    {s0A, 100, 50, 0}, {s0A, -70, 30, 0},                                              // 12-13
    {s08, 0, 0, 0}, {s08, 1000, 0, 0},                                                 // 14-15
    {s0D, 0, 0, 0},                                                                    // 16
    {s18, ST + 0x200, DST, 0}, {s18, ST + 0x240, DST, 0},                              // 17-18
    {s17, ST + 0x280, VDST, 0}, {s15, ST + 0x2C0, VDST, 0},                            // 19-20
    {s1F, ST + 0x300, 60, 0}, {s1F, ST + 0x300, 69, 0x80}, {s1F, ST + 0x300, 30, 0x40},  // 21-23
    {s19, 1, 0, 0}, {s19, 0, 0, 0},                                                    // 24-25
    {s17, ST + 0x400, VDST, 0}, {s17, ST + 0x420, VDST, 0}, {s17, ST + 0x440, VDST, 0}, // 26-28
    {s17, ST + 0x460, VDST, 0}, {s17, ST + 0x480, VDST, 0},                             // 29-30
    {s0E, ST + 0x0C0, DST, 1},                                                         // 31
  };
  const u32 n = sizeof calls / sizeof calls[0];
  REG16(0x04000204) = 0x4317;
  for (u32 i = 0; i < n; i++) {
    RESULT[2] = i; RESULT[3] = 0;
    Q();
    bd_callfn((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
