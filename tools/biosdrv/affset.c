// Probe: BgAffineSet and ObjAffineSet step by step -- which operand each of
// their multiplies takes as the multiplier (its internal cycles follow that
// operand's magnitude): entries whose scales and display offsets fall in
// different magnitude classes, one call per entry and one with all of them,
// from EWRAM and from the cartridge. ARM caller in IWRAM, IRQs off.
// RESULT[2] = case.
#include "drv.h"
typedef signed int s32;
typedef signed short s16;

__attribute__((naked, target("arm"), section(".iwram"))) static void s0E(void) {
  __asm__ volatile("swi 0x0E0000\n bx lr");
}
// ObjAffineSet's r3 (the destination stride) from RESULT[6]
__attribute__((naked, target("arm"), section(".iwram"))) static void s0F(void) {
  __asm__ volatile("ldr r3, =0x02030018\n ldr r3, [r3]\n swi 0x0F0000\n bx lr\n .pool");
}

#define SRC 0x02024000
#define DST 0x02028000

typedef struct { s32 ox, oy; s16 cx, cy, sx, sy; u16 ang, pad; } Bg;
typedef struct { s16 sx, sy; u16 ang, pad; } Obj;

static const Bg bgs[] = {
  {0x8000, 0x4000, 5, 300, 0x10, 0x1234, 0x1000, 0},
  {0x8000, 0x4000, 300, 5, 0x1234, 0x10, 0x2345, 0},
  {-0x100, 0x7FFF, -3, -500, -5, -0x400, 0x8000, 0},
  {0x12345, -0x54321, 0x7FFF, -1, 0x7FFF, -0x8000, 0xC567, 0},
  {0, 0, -0x8000, 0x7FFF, 0x100, -0x100, 0x4000, 0},
  {7, 9, 255, 256, -256, -257, 0x0123, 0},
  {7, 9, 256, -256, 5, 5, 0x0123, 0},
  {7, 9, -256, 1, 5, 5, 0x0123, 0},
};
static const Obj objs[] = {
  {0x10, 0x1234, 0x1000, 0}, {0x1234, 0x10, 0x2345, 0}, {-5, -0x400, 0x8000, 0},
  {0x7FFF, -0x8000, 0xC567, 0}, {0x100, -0x100, 0x4000, 0}, {-256, -257, 0x0123, 0},
};

typedef struct { void (*fn)(void); u32 a, b, c, d; } Call;

int main(void) {
  Bg *bw = (Bg *)SRC;
  Obj *ow = (Obj *)(SRC + 0x200);
  for (u32 i = 0; i < 6; i++) ow[i] = objs[i];
  for (u32 i = 0; i < 8; i++) bw[i] = bgs[i];
  static Call calls[40];
  u32 n = 0;
  for (u32 i = 0; i < 8; i++) calls[n++] = (Call){s0E, SRC + 20 * i, DST, 1, 0};
  calls[n++] = (Call){s0E, SRC, DST, 6, 0};
  calls[n++] = (Call){s0E, (u32)bgs, DST, 6, 0};
  for (u32 i = 0; i < 6; i++) calls[n++] = (Call){s0F, SRC + 0x200 + 8 * i, DST, 1, 2};
  calls[n++] = (Call){s0F, SRC + 0x200, DST, 6, 8};
  calls[n++] = (Call){s0F, (u32)objs, DST, 6, 2};
  REG16(0x04000204) = 0x4317;
  for (u32 i = 0; i < n; i++) {
    RESULT[2] = i; RESULT[3] = 0;
    RESULT[6] = calls[i].d;
    bd_callfn((u32)calls[i].fn, calls[i].a, calls[i].b, calls[i].c);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
