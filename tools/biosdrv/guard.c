// Probe: which SoundArea ident values (and a null SoundArea pointer) each
// driver SWI accepts, the VSync counter law at its edges, and the costs of
// every path. IRQs stay off; Init runs once at the top.
#include "drv.h"

// Timer 0 off before every timed call: a FIFO DMA landing inside a call
// steals cycles (the driver's own DMA is what the probes test, not that)
#define Q() (REG16(0x04000102) = 0)

#define IDENT REG32(0x03004000)
#define CNT REG8(0x03004004)
#define PERIOD REG8(0x0300400B)
static const u32 idents[] = {
  0x68736D53, 0x68736D54, 0x68736D55, 0x68736D5D, 0x68736D52, 0, 0x12345678,
};

static void mark_state(u32 step) {
  RESULT[0] = REG16(0x040000C6) | (REG16(0x040000D2) << 16);
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  for (u32 k = 0; k < sizeof(idents) / sizeof(idents[0]); k++) {
    for (u32 nullp = 0; nullp < 2; nullp++) {
      REG32(0x03007FF0) = nullp ? 0 : (u32)AREA;
      IDENT = idents[k]; CNT = 3;
      Q(); bd_swi_1D(0, 0, 0, 0); mark_state(step++);
      IDENT = idents[k]; CNT = 3;
      Q(); bd_swi_28(0, 0, 0, 0); mark_state(step++);
      IDENT = idents[k]; CNT = 3;
      Q(); bd_swi_29(0, 0, 0, 0); mark_state(step++);
      IDENT = idents[k];
      fill32(AREA + 0x50, 0xC3C3C3C3, 0x300);
      Q(); bd_swi_1E(0, 0, 0, 0); mark_state(step++);
      IDENT = idents[k];
      Q(); bd_swi_1B(0x0000A87F, 0, 0, 0); mark_state(step++);   // no rate change
      IDENT = idents[k];
      Q(); bd_swi_1B(0x00000000, 0, 0, 0); mark_state(step++);
      IDENT = idents[k];
      Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
    }
  }
  REG32(0x03007FF0) = (u32)AREA;
  IDENT = 0x68736D53;
  // VSync counter law: every starting counter value with period 7 and 0
  static const u8 cnts[] = {0, 1, 2, 7, 8, 0x7F, 0x80, 0x81, 0xFE, 0xFF};
  for (u32 p = 0; p < 2; p++) {
    PERIOD = p ? 0 : 7;
    for (u32 i = 0; i < sizeof(cnts); i++) {
      CNT = cnts[i];
      Q(); bd_swi_1D(0, 0, 0, 0); mark_state(step++);
    }
  }
  PERIOD = 7;
  // Mode with rate change while locked (does the lock refuse it?)
  IDENT = 0x68736D54;
  Q(); bd_swi_1B(0x00910000, 0, 0, 0); mark_state(step++);
  IDENT = 0x68736D53;
  // Mode DA-bit values 12..14 and 7
  Q(); bd_swi_1B(0x00C00000, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00D00000, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00E00000, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00B00000, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00700000, 0, 0, 0); mark_state(step++);
  // SOUNDBIAS bits kept? set the low bias field and see the DA write
  SOUNDBIAS = 0x3FFE;
  Q(); bd_swi_1B(0x00900000, 0, 0, 0); mark_state(step++);
  SOUNDBIAS = 0x0000;
  Q(); bd_swi_1B(0x00800000, 0, 0, 0); mark_state(step++);
  SOUNDBIAS = 0x0200;
  // Mode channel count 0 (keep?) and reverb byte 0
  Q(); bd_swi_1B(0x00000100, 0, 0, 0); mark_state(step++);
  Q(); bd_swi_1B(0x00000000, 0, 0, 0); mark_state(step++);
  MARK(0xFE);
  for (;;) {}
}
