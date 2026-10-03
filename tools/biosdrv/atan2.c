// Probe: ArcTan2 down every path: the axes (y = 0 with x positive, negative
// and zero; x = 0 with y positive and negative), the eight octants, the
// ties |x| = |y| in each quadrant, -2^31 in either coordinate, coordinates
// past 2^17 (the shifted numerator wraps). Results (bd_regs) and time.
// Thumb caller in the cartridge, WAITCNT 0x4317, IRQs off. RESULT[2] = case.
#include "drv.h"
typedef signed int s32;

__attribute__((naked, target("thumb"))) static void s0A(void) {
  __asm__ volatile("swi 0x0A\n bx lr");
}

int main(void) {
  static const s32 xy[][2] = {
    {100, 0}, {-100, 0}, {0, 0}, {0, 100}, {0, -100},
    {100, 50}, {50, 100}, {-50, 100}, {-100, 50}, {-100, -50}, {-50, -100},
    {50, -100}, {100, -50},
    {70, 70}, {-70, 70}, {-70, -70}, {70, -70},
    {-0x7FFFFFFF - 1, 5}, {5, -0x7FFFFFFF - 1}, {0x30000, 0x20000}, {-0x20000, 0x30000},
    {1, 1}, {-1, -2}, {0x7FFF, -0x7FFF}, {12345, -678},
  };
  const u32 n = sizeof xy / sizeof xy[0];
  REG16(0x04000204) = 0x4317;
  for (u32 i = 0; i < n; i++) {
    RESULT[2] = i; RESULT[3] = 0;
    bd_callfn((u32)s0A, (u32)xy[i][0], (u32)xy[i][1], 0);
    RESULT[1] = i; MARK(0x10 + (i & 0x3F));
  }
  MARK(0xFE);
  for (;;) {}
}
