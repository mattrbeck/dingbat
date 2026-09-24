// Probe: SoundDriverMode field combinations (reverb / channels / volume /
// D/A bits, with and without a rate change) and costs; VSyncOff and Mode with
// the SoundArea in EWRAM; rate index 14. IRQs off.
#include "drv.h"

// Timer 0 off before every timed call: a FIFO DMA landing inside a call
// steals cycles (the driver's own DMA is what the probes test, not that)
#define Q() (REG16(0x04000102) = 0)

static void mark_state(u32 step) {
  RESULT[0] = SOUNDBIAS;
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  for (u32 c = 0; c < 16; c++) {
    u32 m = 0;
    if (c & 1) m |= 0x85;        // reverb
    if (c & 2) m |= 0x600;       // channels
    if (c & 4) m |= 0xC000;      // volume
    if (c & 8) m |= 0x900000;    // D/A bits
    Q(); bd_swi_1B(m, 0, 0, 0); mark_state(step++);
  }
  Q(); bd_swi_1B(0x0085, 0, 0, 0); mark_state(step++);   // reverb, bit 7 set
  Q(); bd_swi_1B(0x0005, 0, 0, 0); mark_state(step++);   // reverb, bit 7 clear
  Q(); bd_swi_1B(0x0080, 0, 0, 0); mark_state(step++);   // reverb 0x80
  Q(); bd_swi_1B(0x009E0000, 0, 0, 0); mark_state(step++);  // rate 14
  Q(); bd_swi_1B(0x0094C685, 0, 0, 0); mark_state(step++);  // everything + rate 4
  Q(); bd_swi_1B(0x00040000, 0, 0, 0); mark_state(step++);  // rate only
  // SoundArea in EWRAM
  Q(); bd_swi_1A(0x02020000, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_28(0, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1D(0, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1D(0, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1E(0, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x0094C685, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x0000C685, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00910000, 0, 0, 0); mark_state(step++);
  MARK(0xFE);
  for (;;) {}
}
