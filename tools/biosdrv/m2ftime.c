// Probe: MidiKey2Freq (SWI 0x1F) timing, bracketed by the rt.s markers:
// WaveData in IWRAM and in the cartridge, WAITCNT 0 and 0x4317, keys in
// the low and top octaves and clamped, fine pitch 0 and not. RESULT[2..3]
// tag each call (wave place | waitcnt, key, pitch).
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

static u32 wave_iw[4];
static const u32 wave_rom[4] = {0, 0x3443 << 10, 0, 0};

int main(void) {
  static const u8 keys[5] = {12, 60, 83, 84, 179};
  static const u8 pitches[2] = {0, 0x80};
  static const u16 wc[2] = {0x0000, 0x4317};
  wave_iw[1] = 0x3443 << 10;
  for (u32 w = 0; w < 2; w++) {
    REG16(0x04000204) = wc[w];
    for (u32 place = 0; place < 2; place++) {
      u32 wave = place ? (u32)wave_rom : (u32)wave_iw;
      for (u32 k = 0; k < 5; k++)
        for (u32 p = 0; p < 2; p++) {
          RESULT[2] = (place << 4) | w;
          RESULT[3] = (keys[k] << 8) | pitches[p];
          Q(); bd_swi_1F(wave, keys[k], pitches[p], 0);
        }
    }
  }
  MARK(0xFE);
  for (;;) {}
}
