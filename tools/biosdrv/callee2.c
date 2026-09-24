// Probe: does the real SoundDriverMain reach an IWRAM callback later by its
// address? The same ARM leaf copied to 16 IWRAM addresses and called as
// +0x28 (BD_MEMTRACE=all stamps its store).
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
#define SI(o) REG32((u32)AREA + (o))

// str r0, [r1] ; bx lr  (r1 = SoundInfo? no: r0 is the SoundInfo) --
// the leaf: ldr r3, =RESULT+0x80 ; str r0, [r3] ; bx lr
static const u32 leaf[] = {0xE59F3004, 0xE5830000, 0xE12FFF1E, 0x02030080};

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  Q(); bd_swi_28(0, 0, 0, 0);
  for (u32 k = 0; k < 16; k++) {
    u32 *dst = (u32 *)(0x03002000 + k * 0x24);
    for (u32 i = 0; i < 4; i++) dst[i] = leaf[i];
    SI(0x20) = 0; SI(0x28) = (u32)dst;
    Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
    SI(0x20) = (u32)dst; SI(0x24) = k; SI(0x28) = 0x1709;
    Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  }
  MARK(0xFE);
  for (;;) {}
}
