// Probe: RegisterRamReset's time and stores per flag group: each flag alone,
// combinations (0xFD, 0xFC, 0x7D) and none, from a Thumb caller in the
// cartridge at WAITCNT 0 and 0x4317 (bd_callfn's F0/F1 markers bracket each
// call; BD_IOALL=1 and BD_MEMTRACE=1 give each I/O store's and each RAM
// clear's cycle). The groups' times add (hle_bios.nim RRR_GROUP_COST).
#include "drv.h"
__attribute__((naked, target("thumb"))) static void s01(void) {
  __asm__ volatile("swi 0x01\n bx lr");
}
int main(void) {
  static const u8 flags[] = {0x80, 0x20, 0x40, 0x01, 0x08, 0x10, 0x04, 0xFD, 0xFC, 0x7D, 0x00};
  for (u32 w = 0; w < 2; w++)
    for (u32 i = 0; i < sizeof flags; i++) {
      REG16(0x04000204) = w ? 0x4317 : 0;
      bd_callfn((u32)s01, flags[i], 0, 0);
      MARK(0x10 + i + w * 0x10);
    }
  MARK(0xFE);
  for (;;) {}
}
