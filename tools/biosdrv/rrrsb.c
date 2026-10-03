// Probe: what RegisterRamReset's sound group writes to SOUNDBIAS (it reads
// the register first): with the amplitude-resolution and level bits set
// beforehand, and clear. Thumb caller in the cartridge. RESULT[2] = case,
// RESULT[4] = SOUNDBIAS after the call.
#include "drv.h"
__attribute__((naked, target("thumb"))) static void s01(void) {
  __asm__ volatile("swi 0x01\n bx lr");
}
int main(void) {
  static const u16 before[] = {0xC1F8, 0x0000, 0x4002, 0x83FE};
  for (u32 i = 0; i < 4; i++) {
    SOUNDBIAS = before[i];
    RESULT[2] = i;
    bd_callfn((u32)s01, 0x40, 0, 0);
    RESULT[4] = SOUNDBIAS;
    RESULT[1] = i; MARK(0x10 + i);
  }
  MARK(0xFE);
  for (;;) {}
}
