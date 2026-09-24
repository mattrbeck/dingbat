// Probe: the BIOS SoundDriverMain mixer driven directly. Init + Mode, then
// every frame: the V-blank IRQ runs SoundDriverVSync, the main loop runs
// SoundDriverMain and marks (the snapshot carries the whole SoundArea:
// channels and pcmBuffer). A script in ROM pokes SoundChannel / SoundInfo
// fields before given frames' passes, the way a sequencer would.
//
// Script entries: {frame, offset from the SoundArea, width 1/2/4 or 0x81
// (OR into a byte), value}.
// Wave pointers use WAVE(n) = address of wave n (resolved at run time).
#include "drv.h"

typedef struct { u16 frame; u16 off; u8 width; u8 pad; u16 pad2; u32 value; } Op;

// WaveData: u16 type, u16 flags (0x4000 = loop), u32 freq, u32 loop start,
// u32 size, s8 data[] (loveemu's MP2K summary / Bregalad-ipatix notes)
#define WAVE_HDR(flags, freq, loop, size) \
  0, 0, (flags) & 0xFF, (flags) >> 8, \
  (freq) & 0xFF, ((freq) >> 8) & 0xFF, ((freq) >> 16) & 0xFF, ((freq) >> 24) & 0xFF, \
  (loop) & 0xFF, ((loop) >> 8) & 0xFF, ((loop) >> 16) & 0xFF, ((loop) >> 24) & 0xFF, \
  (size) & 0xFF, ((size) >> 8) & 0xFF, ((size) >> 16) & 0xFF, ((size) >> 24) & 0xFF

#include "mix_script.h"

extern const u8 *const waves[];

// MIX_WAVE_RAM: the waves are copied to EWRAM first (the mixer's source
// reads then cost EWRAM waits instead of the cartridge's)
#ifdef MIX_WAVE_RAM
extern const u32 wave_sizes[];
static u8 *ram_waves[16];
#endif
static u32 resolve(u32 v) {
  if ((v & 0xFFFF0000) == 0xEE000000) {
#ifdef MIX_WAVE_RAM
    return (u32)ram_waves[v & 0xFFFF];
#else
    return (u32)waves[v & 0xFFFF];
#endif
  }
  return v;
}

int main(void) {
#ifdef MIX_WAITCNT
  REG16(0x04000204) = MIX_WAITCNT;
#endif
#ifdef MIX_WAVE_RAM
  u8 *dst = (u8 *)0x02010000;
  for (u32 w = 0; w < MIX_NWAVES; w++) {
    ram_waves[w] = dst;
    for (u32 i = 0; i < wave_sizes[w]; i++) dst[i] = waves[w][i];
    dst += (wave_sizes[w] + 3) & ~3u;
  }
#endif
  bd_swi_1A((u32)AREA, 0, 0, 0);
  bd_swi_1B(MIX_MODE, 0, 0, 0);
  bd_irq_vsync = 1;
  irq_setup(1);
  u32 op = 0;
  for (u32 f = 0; f < MIX_FRAMES; f++) {
    vblank_wait();
    while (op < sizeof(script) / sizeof(script[0]) && script[op].frame == f) {
      const Op *o = &script[op++];
      u32 v = resolve(o->value);
      if (o->width == 0x81) REG8((u32)AREA + o->off) |= v;       // OR a byte
      else if (o->width == 1) REG8((u32)AREA + o->off) = v;
      else if (o->width == 2) REG16((u32)AREA + o->off) = v;
      else REG32((u32)AREA + o->off) = v;
    }
#ifdef MIX_QUIET
    REG16(0x04000102) = 0;   // Timer 0 off: no FIFO DMA inside the timed pass
#endif
    bd_swi_1C(0, 0, 0, 0);
#ifdef MIX_QUIET
    REG16(0x04000102) = 0x80;
#endif
    RESULT[0] = f;
    MARK(0x20);
  }
  MARK(0xFE);
  for (;;) {}
}
