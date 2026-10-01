/* 2d_text: text BGs on both engines.

   Top (engine A, mode 0; DISPCNT char base +64K, screen base +64K):
     BG0 4bpp white console text (rows 1-9), BG1 4bpp: palette banks 1-3
     (white, orange, cyan) and per-tile H/V flips, scrolling left one pixel
     a frame on row 12, BG2 8bpp through extended palette slot 2: row 15
     "EXT PAL 0" green, row 16 "EXT PAL 5" magenta (the standard palette
     entry would be red).
   Bottom (engine B, mode 0): BG0 8bpp through VRAM H extended palettes
     (slot 0, palettes 0..2: yellow, light blue, pink), BG1 512x256 4bpp map
     scrolled so its second screen block shows on the right half.
*/
#include "../common2d/nds2d.h"

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT(0) = 0x81;              /* A: engine A BG 0x06000000 */
  VRAMCNT(2) = 0x84;              /* C: engine B BG 0x06200000 */
  VRAMCNT(4) = 0x80;              /* E: LCDC while its palettes are written */
  VRAMCNT(8) = 0x80;              /* H: LCDC */

  /* engine A: tiles at 64K + 16K, maps at 64K + n*2K */
  DISPCNT_A = 0x09010000 | 0x40000000 | 0x0700;   /* BG0-2, ext palettes */
  BGCNT(ENG_A, 0) = (1 << 2) | (2 << 8) | 1;
  BGCNT(ENG_A, 1) = (1 << 2) | (3 << 8) | 1;
  BGCNT(ENG_A, 2) = 0x80 | (2 << 2) | (4 << 8) | 0;   /* 8bpp tiles at 64K+32K */
  u32 a_tiles = VRAM_A_BG + 0x10000 + 0x4000;
  load_font4(a_tiles, 1);
  load_font8(VRAM_A_BG + 0x10000 + 0x8000, 9);
  u32 m0 = VRAM_A_BG + 0x10000 + 2 * 0x800;
  u32 m1 = VRAM_A_BG + 0x10000 + 3 * 0x800;
  u32 m2 = VRAM_A_BG + 0x10000 + 4 * 0x800;
  clear16(m0, 0x800, 0);
  clear16(m1, 0x800, 0);
  clear16(m2, 0x800, 0);
  print_at(m0, 1, 1, "DINGBAT DS 2D TEXT TEST", 0);
  print_at(m0, 1, 3, "BG0 4BPP CONSOLE", 0);
  print_at(m0, 1, 4, "CHAR BASE 64K+16K", 0);
  print_at(m0, 1, 5, "SCREEN BASE 64K+4K", 0);
  print_at(m0, 1, 7, "0123456789 .:-!", 0);
  print_at(m0, 1, 9, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0);
  print_at(m1, 1, 11, "BANK1", 0x1000);
  print_at(m1, 8, 11, "BANK2", 0x2000);
  print_at(m1, 15, 11, "BANK3", 0x3000);
  print_at(m1, 1, 12, "SCROLLING ROW HFLIP:", 0x1000);
  print_at(m1, 21, 12, "FLIP", 0x1400);
  print_at(m1, 1, 13, "VFLIP:", 0x1000);
  print_at(m1, 8, 13, "FLIP", 0x1800);
  print_at(m2, 1, 15, "EXT PAL 0", 0x0000);
  print_at(m2, 1, 16, "EXT PAL 5", 0x5000);
  PAL_A_BG[0] = RGB(0, 0, 10);
  PAL_A_BG[1] = RGB(31, 31, 31);
  PAL_A_BG[0x11] = RGB(31, 31, 31);
  PAL_A_BG[0x21] = RGB(31, 18, 0);
  PAL_A_BG[0x31] = RGB(0, 28, 31);
  PAL_A_BG[9] = RGB(31, 0, 0);                 /* standard palette: must not show */
  /* BG2 ext palette slot 2 (VRAM E + 2*8K), palettes 0 and 5, entry 9 */
  w16(0x06880000 + 2 * 0x2000 + (0 * 256 + 9) * 2, RGB(0, 31, 0));
  w16(0x06880000 + 2 * 0x2000 + (5 * 256 + 9) * 2, RGB(31, 0, 31));
  VRAMCNT(4) = 0x84;              /* E: engine A BG ext palettes */

  /* engine B: BG0 8bpp ext palettes, BG1 4bpp 512x256 */
  DISPCNT_B = 0x40010000 | 0x0300;
  BGCNT(ENG_B, 0) = 0x80 | (1 << 2) | (16 << 8);
  BGCNT(ENG_B, 1) = (3 << 2) | (20 << 8) | (1 << 14);
  load_font8(VRAM_B_BG + 0x4000, 3);
  load_font4(VRAM_B_BG + 0xC000, 2);
  u32 b0 = VRAM_B_BG + 16 * 0x800;
  u32 b1 = VRAM_B_BG + 20 * 0x800;
  clear16(b0, 0x800, 0);
  clear16(b1, 0x1000, 0);
  print_at(b0, 1, 1, "ENGINE B", 0);
  print_at(b0, 1, 2, "8BPP EXT PAL 0", 0x0000);
  print_at(b0, 1, 3, "8BPP EXT PAL 1", 0x1000);
  print_at(b0, 1, 4, "8BPP EXT PAL 2", 0x2000);
  print_at(b1, 1, 8, "LEFT BLOCK", 0);
  print_at(b1 + 0x800, 1, 9, "RIGHT BLOCK", 0);
  BGHOFS(ENG_B, 1) = 128;        /* map x 128..383: left block's right half, right block's left */
  PAL_B_BG[0] = RGB(6, 0, 6);
  PAL_B_BG[2] = RGB(31, 31, 31);
  PAL_B_BG[3] = RGB(31, 0, 0);    /* standard palette: must not show */
  w16(0x06898000 + (0 * 256 + 3) * 2, RGB(31, 31, 0));
  w16(0x06898000 + (1 * 256 + 3) * 2, RGB(16, 24, 31));
  w16(0x06898000 + (2 * 256 + 3) * 2, RGB(31, 16, 24));
  VRAMCNT(8) = 0x82;              /* H: engine B BG ext palettes */

  for (int f = 0;; f++) {
    wait_vblank();
    BGHOFS(ENG_A, 1) = f & 0x1FF;
  }
}
