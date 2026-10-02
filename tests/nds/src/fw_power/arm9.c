/* fw_power ARM9: shows what the ARM7 (arm7.c) found. Top screen backdrop:
   grey while the ARM7 works, then green after the first boot's firmware
   write (count 1), blue after the second, white after later ones, red if
   the write did not read back. Bottom screen: yellow while running (black
   once the DS is off). No library. */
#include "fw_power.h"

#define DISPCNT_A REG32(0x04000000)
#define DISPCNT_B REG32(0x04001000)
#define POWCNT1   REG16(0x04000304)
#define PAL_A_BG  ((volatile u16 *)0x05000000)
#define PAL_B_BG  ((volatile u16 *)0x05000400)

int main(void) {
  POWCNT1 = 0x8203;                          /* LCDs, both engines, A on top */
  DISPCNT_A = 0x00010000;                    /* graphics mode, no layers */
  DISPCNT_B = 0x00010000;
  PAL_B_BG[0] = 0x03FF;                      /* yellow */
  PAL_A_BG[0] = 0x4210;                      /* grey */
  while (RES[0] != RES_MAGIC) {}
  u32 n = RES[1];
  PAL_A_BG[0] = !RES[2] ? 0x001F : n == 1 ? 0x03E0 : n == 2 ? 0x7C00 : 0x7FFF;
  for (;;) {}
}
