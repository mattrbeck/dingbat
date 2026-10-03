// Probe: RegisterRamReset with the IWRAM flag (0x02, 0x82, 0xFF, 0x03, 0x42,
// none, sound): the probe keeps no state in IWRAM below 0x03007E00 across a
// call and brackets it itself from cartridge code (bd_callfn lives in IWRAM).
#include "drv.h"
__attribute__((noinline)) static void call(u32 f) {
  MARK(0xF0);
  __asm__ volatile("mov r0, %0\n swi 0x01" :: "r"(f) : "r0", "r1", "r2", "r3", "memory");
  MARK(0xF1);
}
int main(void) {
  static const u8 flags[] = {0x02, 0x82, 0xFF, 0x03, 0x42, 0x00, 0x40};
  for (u32 i = 0; i < sizeof flags; i++) {
    REG16(0x04000204) = 0;
    call(flags[i]);
    MARK(0x10 + i);
  }
  MARK(0xFE);
  for (;;) {}
}
