/* periph_suite ARM9: counts V-blanks into FRAME9 and draws the ARM7's
   result words (periph.h RES) on the top screen, one word per 4-pixel row,
   bit 31 leftmost, 8x4 cells: white = 1, dark = 0 (rows alternate grey /
   blue). Bottom screen: the microphone capture as a trace (engine B
   direct-colour bitmap), green background while the ARM7 runs, white when
   RES[0] = 'PERI'. */
#include "periph.h"

#define POWCNT1   REG16(0x04000304)
#define DISPCNT_A REG32(0x04000000)
#define DISPCNT_B REG32(0x04001000)
#define BG3CNT_B  REG16(0x0400100E)
#define BG3PA_B   REG16(0x04001030)
#define BG3PB_B   REG16(0x04001032)
#define BG3PC_B   REG16(0x04001034)
#define BG3PD_B   REG16(0x04001036)
#define BG3X_B    REG32(0x04001038)
#define BG3Y_B    REG32(0x0400103C)
#define VRAMCNT_A REG8(0x04000240)
#define VRAMCNT_C REG8(0x04000242)
#define LCDC      ((volatile u16 *)0x06800000)
#define BMP_B     ((volatile u16 *)0x06200000)

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT_A = 0x80;              /* bank A at LCDC */
  VRAMCNT_C = 0x84;              /* bank C: engine B BG */
  DISPCNT_A = 0x00020000;        /* VRAM display, bank A */
  DISPCNT_B = 0x00010805;        /* mode 5, BG3 */
  BG3CNT_B = 0x4084;             /* 256x256 direct colour bitmap */
  BG3PA_B = 0x100; BG3PB_B = 0; BG3PC_B = 0; BG3PD_B = 0x100;
  BG3X_B = 0; BG3Y_B = 0;
  for (int i = 0; i < MIC_SAMPLES; i++) MICBUF[i] = 0x80;
  FRAME9 = 0;
  /* a little drawing per frame (one result row, 16 plot columns), so no
     V-blank goes uncounted */
  for (u32 f = 0;; f++) {
    while (VCOUNT != 192) {}
    FRAME9++;
    int w = f % RESULT_WORDS;
    u32 v = RES[w];
    u16 off = (w & 1) ? 0x2800 : 0x1084;
    for (int b = 0; b < 32; b++) {
      u16 c = (v >> (31 - b)) & 1 ? 0x7FFF : off;
      for (int y = 1; y < 3; y++)
        for (int x = 1; x < 7; x++) LCDC[(w * 4 + y) * 256 + b * 8 + x] = c;
    }
    u16 bg = RES[0] == RES_MAGIC ? 0xFFFF : 0x83E0;
    int x0 = (f % 16) * 16;
    for (int x = x0; x < x0 + 16; x++) {
      int y = 191 - (MICBUF[x] * 3) / 4;
      for (int r = 0; r < 192; r++) BMP_B[r * 256 + x] = (r == y) ? 0x801F : bg;
    }
    while (VCOUNT == 192) {}
  }
}
