/* boot_cp15: the ARM9's CP15 state as the boot leaves it, printed in hex
   on the top screen before anything touches CP15 (common2d's crt0 doesn't).
   Old homebrew crt0s (the 4K intro sd4k) set only the protection regions
   they add and rely on the rest staying as the boot left them, so a direct
   boot has to leave the same state (docs/nds/compat.md).

   Rows: CTRL (c1), DC/IC cachable bits (c2,0 / c2,1), WB (c3), DAP/IAP
   extended permissions (c5,2 / c5,3), R0..R7 (c6 regions), DTCM / ITCM
   (c9,1,0 / c9,1,1). */
#include "../common2d/nds2d.h"

#define MRC(op1, cn, cm, op2) ({ u32 v_; \
  __asm__ volatile("mrc p15, " #op1 ", %0, c" #cn ", c" #cm ", " #op2 : "=r"(v_)); v_; })

static void hex(char *s, u32 v) {
  for (int i = 0; i < 8; i++) s[i] = "0123456789ABCDEF"[(v >> (28 - 4 * i)) & 15];
  s[8] = 0;
}

static void row(u32 map, int y, const char *label, u32 v) {
  char s[9];
  hex(s, v);
  print_at(map, 1, y, label, 0);
  print_at(map, 8, y, s, 0);
}

int main(void) {
  u32 v[16];
  v[0] = MRC(0, 1, 0, 0);
  v[1] = MRC(0, 2, 0, 0);
  v[2] = MRC(0, 2, 0, 1);
  v[3] = MRC(0, 3, 0, 0);
  v[4] = MRC(0, 5, 0, 2);
  v[5] = MRC(0, 5, 0, 3);
  v[6] = MRC(0, 6, 0, 0);
  v[7] = MRC(0, 6, 1, 0);
  v[8] = MRC(0, 6, 2, 0);
  v[9] = MRC(0, 6, 3, 0);
  v[10] = MRC(0, 6, 4, 0);
  v[11] = MRC(0, 6, 5, 0);
  v[12] = MRC(0, 6, 6, 0);
  v[13] = MRC(0, 6, 7, 0);
  v[14] = MRC(0, 9, 1, 0);
  v[15] = MRC(0, 9, 1, 1);
  POWCNT1 = 0x8203;
  VRAMCNT(0) = 0x81;
  DISPCNT_A = 0x00010100;               /* mode 0, BG0 */
  BGCNT(ENG_A, 0) = (1 << 2) | (16 << 8);  /* 4bpp tiles at 16K, map at 32K */
  load_font4(VRAM_A_BG + 0x4000, 1);
  u32 map = VRAM_A_BG + 16 * 0x800;
  clear16(map, 0x800, 0);
  PAL_A_BG[0] = RGB(0, 0, 8);
  PAL_A_BG[1] = RGB(31, 31, 31);
  static const char *const names[] = {
    "CTRL", "DC", "IC", "WB", "DAP", "IAP", "R0", "R1", "R2", "R3",
    "R4", "R5", "R6", "R7", "DTCM", "ITCM"};
  for (int i = 0; i < 16; i++) row(map, 1 + i, names[i], v[i]);
  for (;;) wait_vblank();
}
