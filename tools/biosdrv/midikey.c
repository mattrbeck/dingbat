// Probe: MidiKey2Freq (SWI 0x1F) over its inputs, results to EWRAM for the
// harness's final dump (biosdrv_probe writes ewram.bin):
//   0x02000000: keys 0-255 at fine pitch 0, for eight WaveData frequencies
//   0x02002000: fine pitch 0-255 at keys 60, 61, 100, 179 for those
//   0x0200A000: out-of-range pitches (keys 60, 177) and keys (pitch 7)
#include "drv.h"

static u32 wave[4];

static u32 m2f(u32 w, u32 key, u32 fp) {
  register u32 r0 __asm__("r0") = w;
  register u32 r1 __asm__("r1") = key;
  register u32 r2 __asm__("r2") = fp;
  __asm__ volatile("swi 0x1F" : "+r"(r0), "+r"(r1), "+r"(r2) : : "r3", "memory");
  return r0;
}

static const u32 freqs[8] = {0x00200000, 0x01000000, 0xFFFFFFFF, 0x80000000,
                             0x0001E0A5, 0x3443 << 10, 0x12345678, 0x00000400};

int main(void) {
  vu32 *out = (vu32 *)0x02000000;
  for (u32 f = 0; f < 8; f++) {
    wave[1] = freqs[f];
    for (u32 k = 0; k < 256; k++) out[f * 256 + k] = m2f((u32)wave, k, 0);
  }
  out = (vu32 *)0x02002000;
  static const u8 keys[4] = {60, 61, 100, 179};
  for (u32 f = 0; f < 8; f++) {
    wave[1] = freqs[f];
    for (u32 k = 0; k < 4; k++)
      for (u32 p = 0; p < 256; p++) out[(f * 4 + k) * 256 + p] = m2f((u32)wave, keys[k], p);
  }
  // out-of-range fine pitch and key arguments
  out = (vu32 *)0x0200A000;
  static const u32 odd[] = {256, 300, 511, 1000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x12345};
  for (u32 f = 0; f < 8; f++) {
    wave[1] = freqs[f];
    for (u32 i = 0; i < 8; i++) {
      out[(f * 8 + i) * 3 + 0] = m2f((u32)wave, 60, odd[i]);
      out[(f * 8 + i) * 3 + 1] = m2f((u32)wave, 177, odd[i]);
      out[(f * 8 + i) * 3 + 2] = m2f((u32)wave, odd[i], 7);
    }
  }
  MARK(0xFE);
  for (;;) {}
}
