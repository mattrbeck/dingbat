// Probe: RegisterRamReset(VRAM) from ARM and Thumb callers in IWRAM, EWRAM
// and the cartridge, six calls each: frame-end stops and resumes from every
// caller region.
#include "drv.h"
__attribute__((naked, target("arm"), section(".iwram"))) static void ai(void) {
  __asm__ volatile("swi 0x010000\n bx lr");
}
__attribute__((naked, target("thumb"), section(".iwram"))) static void ti(void) {
  __asm__ volatile("swi 0x01\n bx lr");
}
__attribute__((naked, target("arm"), section(".ewram"))) static void ae(void) {
  __asm__ volatile("swi 0x010000\n bx lr");
}
__attribute__((naked, target("thumb"), section(".ewram"))) static void te(void) {
  __asm__ volatile("swi 0x01\n bx lr");
}
__attribute__((naked, target("arm"))) static void ar(void) {
  __asm__ volatile("swi 0x010000\n bx lr");
}
__attribute__((naked, target("thumb"))) static void tr(void) {
  __asm__ volatile("swi 0x01\n bx lr");
}
int main(void) {
  static void (*const fns[])(void) = {ai, ti, ae, te, ar, tr};
  for (u32 f = 0; f < 6; f++)
    for (u32 k = 0; k < 6; k++) {
      REG16(0x04000204) = 0;
      bd_callfn((u32)fns[f], 0x08, 0, 0);   // VRAM: 64.8k cycles
      MARK(0x10 + f);
    }
  MARK(0xFE);
  for (;;) {}
}
