// Probe: SoundDriverInit / SoundDriverMode / VSync / VSyncOff / VSyncOn /
// ChannelClear side effects. Every call is bracketed by harness markers
// (rt.s); after each call the probe stores the sound/DMA/timer registers it
// can read to RESULT[0..15] and marks 0x10+step so the snapshot has them.
#include "drv.h"

// Timer 0 off before every timed call: a FIFO DMA landing inside a call
// steals cycles (the driver's own DMA is what the probes test, not that)
#define Q() (REG16(0x04000102) = 0)

static void readback(u32 step) {
  RESULT[0] = SOUNDCNT_L | (SOUNDCNT_H << 16);
  RESULT[1] = SOUNDCNT_X | (SOUNDBIAS << 16);
  RESULT[2] = REG16(0x040000C6) | (REG16(0x040000D2) << 16);  // DMA1/2 CNT_H
  RESULT[3] = REG16(0x04000100) | (REG16(0x04000102) << 16);  // TM0
  RESULT[4] = REG16(0x04000104) | (REG16(0x04000106) << 16);  // TM1
  RESULT[5] = VCOUNT;
  RESULT[6] = step;
  for (int i = 0; i < 8; i++) RESULT[8 + i] = bd_regs[i];
  MARK(0x10 + step);
}

static const u32 modes[] = {
  0x00940000, 0x00910000, 0x00920000, 0x00930000, 0x00950000, 0x00960000,
  0x00970000, 0x00980000, 0x00990000, 0x009A0000, 0x009B0000, 0x009C0000,
  0x009D0000, 0x009F0000, 0x00900000,               // out-of-range rates
  0x00840000, 0x00A40000, 0x00B40000, 0x00740000, 0x00F40000, 0x00040000,  // DA bits
  0x0094F000, 0x00941000, 0x00940000 | (5 << 8), 0x00940000 | (12 << 8),
  0x00940000 | (15 << 8), 0x00940000 | (0 << 12),  // channels, volume
  0x009400C0, 0x00940080, 0x0094007F, 0x009400FF, 0x0094003F,  // reverb
  0x00000000, 0xFFFFFFFF, 0x0094A87F,
};

int main(void) {
  u32 step = 0;
  // Scenario A: IRQs off, SoundArea in IWRAM pre-filled with a pattern
  fill32(AREA, 0xA5A5A5A5, 0xFC0);
  REG32(0x03007FF0) = 0x12345678;
  while (VCOUNT != 100) {}
  Q(); bd_swi_1A((u32)AREA, 0x11, 0x22, 0x33);
  readback(step++);
  // Mode sweep
  for (u32 i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
    Q(); bd_swi_1B(modes[i], 0, 0, 0);
    readback(step++);
  }
  Q(); bd_swi_1B(0x00940000, 0, 0, 0);
  // VSyncOff / VSync / VSyncOn
  Q(); bd_swi_28(0, 0, 0, 0); readback(step++);
  Q(); bd_swi_1D(0, 0, 0, 0); readback(step++);
  Q(); bd_swi_29(0, 0, 0, 0); readback(step++);
  Q(); bd_swi_1D(0, 0, 0, 0); readback(step++);
  for (int i = 0; i < 9; i++) { bd_swi_1D(0, 0, 0, 0); readback(step++); }
  // ChannelClear with some channel bytes set
  fill32(AREA + 0x50, 0xC3C3C3C3, 0x300);
  Q(); bd_swi_1E(0, 0, 0, 0); readback(step++);
  // SoundDriverMain with nothing playing
  Q(); bd_swi_1C(0, 0, 0, 0); readback(step++);
  Q(); bd_swi_1C(0, 0, 0, 0); readback(step++);
  // Scenario B: Init again with the area in EWRAM, from another line
  fill32((void *)0x02020000, 0x5A5A5A5A, 0xFC0);
  while (VCOUNT != 20) {}
  Q(); bd_swi_1A(0x02020000, 0, 0, 0);
  readback(step++);
  // Scenario C: Init with V-blank IRQs live (the wait crosses nothing, but
  // the IRQ lands in the setup when started at line 157)
  irq_setup(1);
  fill32(AREA, 0xA5A5A5A5, 0xFC0);
  while (VCOUNT != 157) {}
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  readback(step++);
  RESULT[7] = bd_irq_count;
  MARK(0x7F);
  // Scenario D: Init from line 159 and 160 (the wait's edges)
  IME = 0;
  while (VCOUNT != 159) {}
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  readback(step++);
  while (VCOUNT != 160) {}
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  readback(step++);
  MARK(0xFE);
  for (;;) {}
}
