// Probe: Div, DivArm, Sqrt and ArcTan over inputs that walk their loops'
// counts and their multiplies' operand widths (powers of two and their
// neighbours, both signs, the extremes, a zero divisor where the console
// returns), each call's results (bd_regs) and time. Thumb caller in the
// cartridge, WAITCNT 0x4317, IRQs off. RESULT[2] = case.
#include "drv.h"
typedef signed int s32;

#define S(n) \
  __attribute__((naked, target("thumb"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "\n bx lr"); }
S(06) S(07) S(08) S(09)
#undef S

typedef struct { void (*fn)(void); u32 a, b; } Call;

int main(void) {
  static const u32 sq[] = {0, 1, 2, 3, 4, 5, 15, 16, 17, 0xFF, 0x100, 0xFFFF, 0x10000,
                           0x12345678, 0x40000000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
                           0x0001E240, 0x00BC614E};
  static const u32 at[] = {0, 1, 0x2000, 0x4000, 0xC000, 0xFFFF, 0x10000, 0x7FFF0000,
                           0xFFFFC000, 0x80000000, 0xFEDCBA98, 0x00012345};
  static const s32 dv[][2] = {{1000000, 7}, {-1000000, 7}, {1000000, -7}, {-7, -1000000},
                              {2, 1}, {1, 0}, {-1, 0}, {0, 0}, {0x7FFFFFFF, 1},
                              {-0x7FFFFFFF - 1, -1}, {0x40000000, 0x40000000},
                              {0x7FFFFFFF, 0x10000}, {12345, 12345}, {12345, 12346}};
  static Call calls[64];
  u32 n = 0;
  for (u32 i = 0; i < sizeof sq / 4; i++) calls[n++] = (Call){s08, sq[i], 0};
  for (u32 i = 0; i < sizeof at / 4; i++) calls[n++] = (Call){s09, at[i], 0};
  for (u32 i = 0; i < sizeof dv / 8; i++) calls[n++] = (Call){s06, (u32)dv[i][0], (u32)dv[i][1]};
  for (u32 i = 0; i < 4; i++) calls[n++] = (Call){s07, (u32)dv[i][1], (u32)dv[i][0]};
  REG16(0x04000204) = 0x4317;
  for (u32 i = 0; i < n; i++) {
    RESULT[2] = i; RESULT[3] = 0;
    bd_callfn((u32)calls[i].fn, calls[i].a, calls[i].b, 0);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
