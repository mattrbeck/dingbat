// Probe: the stub-continued driver SWIs (Init, Mode with a rate, VSyncOff)
// and VSync called from every caller region/ISA the wrappers cover: Thumb
// and ARM in ROM (WAITCNT reset value, 3/1 + prefetch, 8/2, 2/1), ARM and Thumb
// in EWRAM. The return refill runs in the caller's region.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

typedef u32 (*fn)(u32, u32, u32, u32);
static const fn sets[][4] = {
  {bd_tswi_1A, bd_tswi_1B, bd_tswi_1D, bd_tswi_28},
  {bd_aswi_1A, bd_aswi_1B, bd_aswi_1D, bd_aswi_28},
  {bd_eswi_1A, bd_eswi_1B, bd_eswi_1D, bd_eswi_28},
  {bd_etswi_1A, bd_etswi_1B, bd_etswi_1D, bd_etswi_28},
};

int main(void) {
  u32 step = 0;
  static const u16 waits[] = {0x0000, 0x4317, 0x000C, 0x0018};
  for (u32 w = 0; w < 4; w++) {
    REG16(0x04000204) = waits[w];
    for (u32 k = 0; k < 4; k++) {
      Q(); sets[k][0]((u32)AREA, 0, 0, 0); mark_state(step++);
      Q(); sets[k][1](0x00910000, 0, 0, 0); mark_state(step++);
      Q(); sets[k][2](0, 0, 0, 0); mark_state(step++);
      Q(); sets[k][2](0, 0, 0, 0); mark_state(step++);
      Q(); sets[k][3](0, 0, 0, 0); mark_state(step++);
    }
  }
  MARK(0xFE);
  for (;;) {}
}
