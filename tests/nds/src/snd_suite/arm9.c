/* snd_suite ARM9: shows the ARM7's result words (snd.h RES) on the top
   screen, one word per 8-pixel row, bit 31 leftmost, 8x8 cells: white = 1,
   dark = 0 (rows alternate grey / blue so they can be counted). The top-left
   cell of each row is bit 31. Bottom screen: green while the ARM7 runs, then
   RES[0] = 'SNDT' turns it white. */
#include "snd.h"

#define POWCNT1   REG16(0x04000304)
#define DISPCNT_A REG32(0x04000000)
#define DISPCNT_B REG32(0x04001000)
#define VRAMCNT_A REG8(0x04000240)
#define PAL_B     ((volatile u16 *)0x05000400)
#define LCDC      ((volatile u16 *)0x06800000)

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT_A = 0x80;              /* bank A at LCDC */
  DISPCNT_A = 0x00020000;        /* VRAM display, bank A */
  DISPCNT_B = 0x00010000;        /* graphics, backdrop only */
  for (u32 i = 0; i < RESULT_WORDS; i++) RES[i] = 0;
  for (;;) {
    while (VCOUNT != 192) {}
    for (int w = 0; w < RESULT_WORDS; w++) {
      u32 v = RES[w];
      u16 off = (w & 1) ? 0x2800 : 0x1084;
      for (int b = 0; b < 32; b++) {
        u16 c = (v >> (31 - b)) & 1 ? 0x7FFF : off;
        for (int y = 1; y < 7; y++)
          for (int x = 1; x < 7; x++) LCDC[(w * 8 + y) * 256 + b * 8 + x] = c;
      }
    }
    PAL_B[0] = RES[0] == RES_MAGIC ? 0x7FFF : 0x03E0;
    while (VCOUNT == 192) {}
  }
}
