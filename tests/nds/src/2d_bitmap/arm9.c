/* 2d_bitmap: extended BGs.

   Top (engine A, mode 5):
     BG3 direct-colour 256x256 bitmap (VRAM A): a red/green gradient with a
       blue 32-pixel checker, alpha bit clear on every 4th checker column so
       the backdrop (dark grey) shows there; rotated 15 degrees, wrap on.
     BG2 256-colour 256x256 bitmap (VRAM B, base 128K), priority 0: a white
       frame 8 pixels wide round the screen, index 0 elsewhere; 2x mosaic off.
   Bottom (engine B, mode 3):
     BG3 16-bit-entry affine tiled 128x128 (VRAM C): 4 tiles in a 2x2
       repeat with H/V flip bits, zoomed 2x, ext palettes off (standard
       palette), wrap on: a pattern of arrows pointing right/left/down/up.
     BG0 4bpp text label.
*/
#include "../common2d/nds2d.h"

static const s16 SIN[] = { 0, 66 };   /* sin 0, sin 15 deg (x256) */
static const s16 COS[] = { 256, 247 };

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT(0) = 0x81;              /* A: A BG 0x00000 */
  VRAMCNT(1) = 0x89;              /* B: A BG 0x20000 */
  VRAMCNT(2) = 0x84;              /* C: B BG */

  DISPCNT_A = 0x00010000 | 0x0C00 | 5;
  BGCNT(ENG_A, 3) = 0x84 | (0 << 8) | (1 << 14) | 0x2000 | 1;
  BGCNT(ENG_A, 2) = 0x80 | (8 << 8) | (1 << 14) | 0;
  for (int y = 0; y < 256; y++)
    for (int x = 0; x < 256; x++) {
      int cx = x >> 5, cy = y >> 5;
      u16 c = RGB(x >> 3, y >> 3, ((cx ^ cy) & 1) ? 31 : 0);
      if ((cx & 3) != 3) c |= 0x8000;
      w16(VRAM_A_BG + (y * 256 + x) * 2, c);
    }
  for (int y = 0; y < 256; y++)
    for (int x = 0; x < 256; x += 2) {
      int edge = (y < 8 || (y >= 184 && y < 192) || x < 8 || x >= 248);
      w16(VRAM_A_BG + 0x20000 + y * 256 + x, edge ? 0x0101 : 0);
    }
  PAL_A_BG[0] = RGB(6, 6, 6);
  PAL_A_BG[1] = RGB(31, 31, 31);
  BGPA(ENG_A, 3) = COS[1];
  BGPB(ENG_A, 3) = (u16)-SIN[1];
  BGPC(ENG_A, 3) = SIN[1];
  BGPD(ENG_A, 3) = COS[1];
  BGX(ENG_A, 3) = 0;
  BGY(ENG_A, 3) = 0;
  BGPA(ENG_A, 2) = 256;
  BGPD(ENG_A, 2) = 256;
  BGX(ENG_A, 2) = 0;
  BGY(ENG_A, 2) = 0;

  /* engine B: mode 3, BG3 16-bit affine tiled, BG0 text */
  DISPCNT_B = 0x00010000 | 0x0900 | 3;
  BGCNT(ENG_B, 3) = (1 << 2) | (2 << 8) | (0 << 14) | 0x2000 | 1;
  BGCNT(ENG_B, 0) = (3 << 2) | (3 << 8) | 0;
  /* tile 1 (8bpp at 16K + 64): an arrow pointing right, colour 1 on 2 */
  static const char *ARROW[8] = {
    "........", "...#....", "...##...", "#######.", "########", "#######.", "...##...", "...#...."};
  for (int r = 0; r < 8; r++)
    for (int x = 0; x < 8; x += 2) {
      int a = ARROW[r][x] == '#' ? 1 : 2, b = ARROW[r][x + 1] == '#' ? 1 : 2;
      w16(VRAM_B_BG + 0x4000 + 64 + r * 8 + x, (u16)(a | (b << 8)));
    }
  /* map: 16x16 entries; (even,even) plain, (odd,even) H flip, (even,odd)
     V flip... the arrow is horizontal, so V flip shows as no change */
  for (int ty = 0; ty < 16; ty++)
    for (int tx = 0; tx < 16; tx++) {
      u16 e = 1;
      if (tx & 1) e |= 0x400;
      if (ty & 1) e |= 0x800;
      w16(VRAM_B_BG + 2 * 0x800 + (ty * 16 + tx) * 2, e);
    }
  BGPA(ENG_B, 3) = 128;
  BGPD(ENG_B, 3) = 128;
  BGX(ENG_B, 3) = 0;
  BGY(ENG_B, 3) = 0;
  load_font4(VRAM_B_BG + 0xC000, 3);
  clear16(VRAM_B_BG + 3 * 0x800, 0x800, 0);
  print_at(VRAM_B_BG + 3 * 0x800, 1, 22, "EXT AFFINE 16BIT MAP 2X", 0);
  PAL_B_BG[0] = RGB(0, 0, 0);
  PAL_B_BG[1] = RGB(31, 24, 0);
  PAL_B_BG[2] = RGB(0, 6, 16);
  PAL_B_BG[3] = RGB(31, 31, 31);

  for (;;) wait_vblank();
}
