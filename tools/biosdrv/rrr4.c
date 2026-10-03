// Probe: RegisterRamReset from ARM callers in IWRAM and in the cartridge, at
// two WAITCNTs: long calls (EWRAM, VRAM) that cross frame ends, where the
// HLE stops and resumes them.
#include "drv.h"
__attribute__((naked, target("arm"), section(".iwram"))) static void a01(void) {
  __asm__ volatile("swi 0x010000\n bx lr");
}
__attribute__((naked, target("arm"))) static void r01(void) {
  __asm__ volatile("swi 0x010000\n bx lr");
}
int main(void) {
  static const u8 flags[] = {0x01, 0x08, 0x48, 0x00};
  for (u32 w = 0; w < 2; w++)
    for (u32 f = 0; f < 2; f++)
      for (u32 i = 0; i < sizeof flags; i++) {
        REG16(0x04000204) = w ? 0x4317 : 0;
        bd_callfn(f ? (u32)r01 : (u32)a01, flags[i], 0, 0);
        MARK(0x10 + i);
      }
  MARK(0xFE);
  for (;;) {}
}
