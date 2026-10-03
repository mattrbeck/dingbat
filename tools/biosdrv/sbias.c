// Probe: SoundBias step by step: rising to 0x200 from 0x000, 0x1FC and
// 0x200, falling to 0 from 0x006, 0x000 and 0x3FE, rising with the level
// above 0x200 (it stays), the other SOUNDBIAS bits set. ARM caller in IWRAM,
// IRQs off. RESULT[2] = case, RESULT[4] = SOUNDBIAS after it.
#include "drv.h"

__attribute__((naked, target("arm"), section(".iwram"))) static void s19(void) {
  __asm__ volatile("swi 0x190000\n bx lr");
}

int main(void) {
  static const u16 from[] = {0x000, 0x1FC, 0x200, 0x006, 0x000, 0x3FE, 0x3FE, 0xC1F8};
  static const u8 up[] = {1, 1, 1, 0, 0, 0, 1, 1};
  for (u32 i = 0; i < sizeof from / sizeof from[0]; i++) {
    SOUNDBIAS = from[i];
    RESULT[2] = i; RESULT[3] = 0;
    bd_callfn((u32)s19, up[i], 0, 0);
    RESULT[4] = SOUNDBIAS;
    RESULT[1] = i; MARK(0x10 + i);
  }
  MARK(0xFE);
  for (;;) {}
}
