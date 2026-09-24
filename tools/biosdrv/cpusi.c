// Probe: CpuSet interrupted: long copies and fills (halfword and word,
// EWRAM to EWRAM) while Timer 1 raises an IRQ every N cycles, called from
// ARM in IWRAM and Thumb in the cartridge (WAITCNT 0x4317). Timers 2+3
// cascaded measure each call in the probe itself (RESULT[5]); RESULT[2] =
// kind * 2 + caller, RESULT[3] = period index.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
static inline void t_start(void) {
  REG16(0x0400010A) = 0; REG16(0x0400010E) = 0;
  REG16(0x04000108) = 0; REG16(0x0400010C) = 0;
  REG16(0x0400010E) = 0x0084; REG16(0x0400010A) = 0x0080;
}
static inline u32 t_read(void) {
  REG16(0x0400010A) = 0;
  return REG16(0x04000108) | ((u32)REG16(0x0400010C) << 16);
}

__attribute__((naked, target("arm"), section(".iwram"))) void t0b(void) {
  __asm__ volatile("swi 0x0B0000\n bx lr");
}
__attribute__((naked, target("thumb"))) void tt0b(void) {
  __asm__ volatile("swi 0x0B\n bx lr");
}

int main(void) {
  static const u16 periods[4] = {0, 1000, 3000, 12000};
  static const u32 ctrl[4] = {8000, 8000 | (1 << 26), 8000 | (1 << 24),
                              8000 | (1 << 24) | (1 << 26)};
  u32 k = 0;
  REG16(0x04000204) = 0x4317;
  irq_setup(1 << 4);
  for (u32 p = 0; p < 4; p++)
    for (u32 kind = 0; kind < 4; kind++)
      for (u32 th = 0; th < 2; th++) {
        REG16(0x04000106) = 0;
        if (periods[p]) {
          REG16(0x04000104) = (u16)(0x10000 - periods[p]);
          REG16(0x04000106) = 0x00C0;
        }
        RESULT[2] = kind * 2 + th; RESULT[3] = p;
        Q(); t_start();
        bd_callfn_stk(th ? (u32)tt0b : (u32)t0b, 0x02020000, 0x02028000, ctrl[kind]);
        REG16(0x04000106) = 0;
        RESULT[5] = t_read(); RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
      }
  MARK(0xFE);
  for (;;) {}
}
