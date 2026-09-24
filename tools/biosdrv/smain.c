// Probe: SoundDriverMain with no channel sounding -- its calling structure
// and costs: the two callbacks (SoundInfo +0x20 with +0x24, +0x28 with the
// SoundInfo), BIOS-address defaults, the reverb pass at three rates.
// IRQs off; the sound DMA is stopped so no FIFO DMA lands in a timed call.
#include "drv.h"

#define Q() (REG16(0x04000102) = 0)
#define SI(o) REG32((u32)AREA + (o))

// Callbacks in IWRAM: log their argument and the mode/lr they see
__attribute__((section(".iwram"), target("arm"), noinline))
void cb_func(u32 arg) {
  u32 lr, cpsr;
  __asm__ volatile("mov %0, lr\n mrs %1, cpsr" : "=r"(lr), "=r"(cpsr));
  RESULT[16] = arg; RESULT[17] = lr; RESULT[18] = cpsr; RESULT[19]++;
}
__attribute__((section(".iwram"), target("arm"), noinline))
void cb_cgb(u32 arg) {
  u32 lr, cpsr;
  __asm__ volatile("mov %0, lr\n mrs %1, cpsr" : "=r"(lr), "=r"(cpsr));
  RESULT[20] = arg; RESULT[21] = lr; RESULT[22] = cpsr; RESULT[23]++;
}
__attribute__((target("thumb"), noinline))
void cb_thumb(u32 arg) { RESULT[24] = arg; RESULT[25]++; }

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  static const u32 rates[] = {0x00910000, 0x00940000, 0x009C0000};
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  for (u32 r = 0; r < 3; r++) {
    Q(); bd_swi_1B(rates[r], 0, 0, 0);
    Q(); bd_swi_28(0, 0, 0, 0);          // DMA off, counter 0
    for (u32 rv = 0; rv < 2; rv++) {
      REG8((u32)AREA + 5) = rv ? 0x40 : 0;
      // every slot position the period allows (a counter above period + 1
      // puts the slot below the ring, over the SoundArea's own header)
      u32 lim = REG8((u32)AREA + 0xB) + 2;
      for (u32 c = 0; c < 8 && c < lim; c++) {
        REG8((u32)AREA + 4) = c;         // every slot position
        Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
      }
    }
  }
  REG8((u32)AREA + 4) = 3;
  // Callback variants (+0x28 = 0 is called too: the BIOS jumps to 0 and
  // reboots, so it is not probed here)
  SI(0x28) = (u32)cb_cgb;
  Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  SI(0x20) = (u32)cb_func; SI(0x24) = 0x12345678;
  Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  SI(0x20) = (u32)cb_thumb; SI(0x28) = (u32)cb_thumb;
  Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  SI(0x20) = 0x1709; SI(0x28) = 0x1709;
  Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  SI(0x20) = 0; SI(0x28) = 0x1709;
  Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
  // From Thumb in ROM, and from EWRAM
  SI(0x28) = 0x1709;
  Q(); bd_tswi_1C(0, 0, 0, 0); mark_state(step++);
  MARK(0xFE);
  for (;;) {}
}
