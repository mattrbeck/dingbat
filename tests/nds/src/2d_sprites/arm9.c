/* 2d_sprites: OBJs, windows and blending.

   Top (engine A; tile OBJs 1D with a 64-byte boundary, bitmap OBJs 2D
   128 pixels wide; BG0 = dark-blue/grey stripes, 2nd blend target):
     row 1 (y 16): four 16x16 4bpp balls, palettes 0..3 (red, green, blue,
       yellow), the last one H-flipped (its highlight on the right).
     (20,48): the red ball rotating 22.5 degrees a frame (affine, double-size).
     (120,48): a 16x16 semi-transparent ball: BG0 stripes show through it.
     (160,48): a 32x16 bitmap OBJ, colour bars, alpha 8 (half blended).
     (200,48)-(231,79): a 32x32 OBJ-window ball: inside it BG0 is hidden
       (backdrop black shows).
     BLDCNT brightens BG0 (BLDY 8) wherever effects are on, so the stripes
       read light grey-blue.
     WIN0 (16..240 x 120..176) shows BG0 only: the orange 8bpp 32x32 OBJ
       at (100,100) is cut off at y=120.
     a green 16x16 ball at y=248 wraps: its lower half shows at the top
       (lines 0..7) at x=240.
   Bottom (engine B; tile OBJs 2D, OBJ ext palettes via VRAM I):
     a 4x4 grid of 16x16 8bpp balls using OBJ ext palettes 0..15 (hues),
     priority test: two overlapping balls at (180,100)/(188,108), the
     second (higher OAM index) with better priority on top.
*/
#include "../common2d/nds2d.h"

static void ball4(u32 base, int tile_bytes) {
  /* 16x16 4bpp ball in 1D order (4 tiles): colour 1 body, 2 highlight */
  for (int ty = 0; ty < 2; ty++)
    for (int tx = 0; tx < 2; tx++)
      for (int r = 0; r < 8; r++) {
        u32 word = 0;
        for (int c = 0; c < 8; c++) {
          int x = tx * 8 + c, y = ty * 8 + r;
          int dx = 2 * x - 15, dy = 2 * y - 15;
          int d = dx * dx + dy * dy;
          int col = d < 196 ? ((x - 5) * (x - 5) + (y - 5) * (y - 5) < 8 ? 2 : 1) : 0;
          word |= (u32)col << (c * 4);
        }
        w32(base + (ty * 2 + tx) * tile_bytes + r * 4, word);
      }
}

static void ball8_2d(u32 base, int r_px, int ink) {
  /* 2D-mapped 8bpp ball, (2*r_px) square: tile row stride 1K */
  int n = 2 * r_px;
  for (int y = 0; y < n; y++)
    for (int x = 0; x < n; x += 2) {
      int v[2];
      for (int k = 0; k < 2; k++) {
        int dx = 2 * (x + k) - (n - 1), dy = 2 * y - (n - 1);
        v[k] = dx * dx + dy * dy < n * n ? ink + ((x + k + y) & 1) : 0;
      }
      u32 a = base + (y >> 3) * 0x400 + (x >> 3) * 64 + (y & 7) * 8 + (x & 7);
      w16(a, (u16)(v[0] | (v[1] << 8)));
    }
}

static const s16 SINT[16] = {0, 98, 181, 236, 256, 236, 181, 98, 0, -98, -181, -236, -256, -236, -181, -98};

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT(0) = 0x81;              /* A: A BG */
  VRAMCNT(1) = 0x82;              /* B: A OBJ */
  VRAMCNT(2) = 0x84;              /* C: B BG */
  VRAMCNT(3) = 0x84;              /* D: B OBJ */
  VRAMCNT(9) = 0x80;              /* I: LCDC while its palette is written */

  for (int i = 0; i < 128; i++) { OAM_A[i * 4] = 0x200; OAM_B[i * 4] = 0x200; }

  /* --- engine A ------------------------------------------------------ */
  /* tile OBJ 1D 64-byte boundary (bits 4, 20), bitmap 2D 128 wide,
     OBJ, BG0, WIN0, OBJWIN */
  DISPCNT_A = 0x00010000 | 0x00100000 | 0x10 | 0x0100 | 0x1000 | 0x2000 | 0x8000;
  BGCNT(ENG_A, 0) = (1 << 2) | (0 << 8) | 1;
  for (int r = 0; r < 8; r++) w32(VRAM_A_BG + 0x4000 + 32 + r * 4, r < 4 ? 0x11111111 : 0x22222222);
  clear16(VRAM_A_BG, 0x800, 1);
  PAL_A_BG[0] = RGB(0, 0, 0);
  PAL_A_BG[1] = RGB(4, 4, 16);
  PAL_A_BG[2] = RGB(12, 12, 12);

  ball4(VRAM_A_OBJ + 64 * 1, 32);         /* tile 1 = byte 64 */
  static const u16 BODY[4] = { RGB(28, 4, 4), RGB(4, 28, 4), RGB(6, 10, 31), RGB(31, 28, 0) };
  for (int p = 0; p < 4; p++) {
    PAL_A_OBJ[p * 16 + 1] = BODY[p];
    PAL_A_OBJ[p * 16 + 2] = RGB(31, 31, 31);
  }
  for (int i = 0; i < 4; i++) {
    OAM_A[i * 4 + 0] = 16;
    OAM_A[i * 4 + 1] = (u16)((16 + 24 * i) | (1 << 14) | (i == 3 ? 0x1000 : 0));
    OAM_A[i * 4 + 2] = (u16)(1 | (i << 12));
  }
  /* 4: the 16x16 ball rotating in a 32x32 double-size box (group 0) */
  OAM_A[4 * 4 + 0] = 48 | 0x300;
  OAM_A[4 * 4 + 1] = 20 | (1 << 14) | (0 << 9);
  OAM_A[4 * 4 + 2] = 1 | (0 << 12);
  /* 5: semi-transparent ball */
  OAM_A[5 * 4 + 0] = 48 | (1 << 10);
  OAM_A[5 * 4 + 1] = 120 | (1 << 14);
  OAM_A[5 * 4 + 2] = 1 | (3 << 12);
  /* 6: bitmap OBJ 32x16, 2D 128-wide: tile 0x40 -> (0x40&15)*16 + (0x40&~15)*128 = 8K */
  for (int y = 0; y < 16; y++)
    for (int x = 0; x < 32; x++)
      w16(VRAM_A_OBJ + 0x2000 + (y * 128 + x) * 2, 0x8000 | RGB((x >> 3) * 10, 31 - y, (x & 7) * 4));
  OAM_A[6 * 4 + 0] = 48 | (3 << 10) | (1 << 14);
  OAM_A[6 * 4 + 1] = 160 | (2 << 14);
  OAM_A[6 * 4 + 2] = 0x40 | (8 << 12);
  /* 7: OBJ-window ball, double the 16x16 via affine scale 0.5 */
  OAM_A[7 * 4 + 0] = 48 | (2 << 10) | 0x300;
  OAM_A[7 * 4 + 1] = 200 | (1 << 14) | (1 << 9);
  OAM_A[7 * 4 + 2] = 1;
  OAM_A[4 * 4 + 3] = 128;  OAM_A[5 * 4 + 3] = 0;   /* group 1: scale 2x */
  OAM_A[6 * 4 + 3] = 0;    OAM_A[7 * 4 + 3] = 128;
  /* 8: 8bpp 32x32 ball inside WIN0's area (hidden there) */
  for (int y = 0; y < 32; y++)
    for (int x = 0; x < 32; x += 2) {
      int v[2];
      for (int k = 0; k < 2; k++) {
        int dx = 2 * (x + k) - 31, dy = 2 * y - 31;
        v[k] = dx * dx + dy * dy < 1024 ? 16 : 0;
      }
      u32 a = VRAM_A_OBJ + 0x1000 + ((y >> 3) * 4 + (x >> 3)) * 64 + (y & 7) * 8 + (x & 7);
      w16(a, (u16)(v[0] | (v[1] << 8)));
    }
  PAL_A_OBJ[16] = RGB(31, 16, 0);
  OAM_A[8 * 4 + 0] = 100 | 0x2000;
  OAM_A[8 * 4 + 1] = 100 | (2 << 14);
  OAM_A[8 * 4 + 2] = 0x1000 / 64;
  /* 9: wrap ball at y=248 */
  OAM_A[9 * 4 + 0] = 248;
  OAM_A[9 * 4 + 1] = 240 | (1 << 14);
  OAM_A[9 * 4 + 2] = 1 | (1 << 12);

  WIN0H(ENG_A) = (16 << 8) | 240;
  WIN0V(ENG_A) = (120 << 8) | 176;
  WININ(ENG_A) = 0x21;                  /* WIN0: BG0 + effects */
  WINOUT(ENG_A) = 0x31 | (0x30 << 8);   /* outside all; OBJ window: OBJ + effects */
  BLDCNT(ENG_A) = (1 << 0) | (2 << 6) | (1 << 8);   /* brighten BG0; BG0 2nd target */
  BLDALPHA(ENG_A) = 8 | (8 << 8);
  BLDY(ENG_A) = 8;

  /* --- engine B ------------------------------------------------------ */
  DISPCNT_B = 0x80010000 | 0x1000;      /* OBJ, 2D tiles, OBJ ext palettes */
  PAL_B_BG[0] = RGB(2, 2, 6);
  ball8_2d(VRAM_B_OBJ + 0x20 * 2, 8, 1);  /* tile 2 */
  for (int p = 0; p < 16; p++) {
    int h = p * 6;                      /* crude hue wheel */
    int r = h < 32 ? 31 - h : (h < 64 ? 0 : h - 64);
    int g = h < 32 ? h : (h < 64 ? 63 - h : 0);
    int b = h < 32 ? 0 : (h < 64 ? h - 32 : 95 - h);
    w16(0x068A0000 + (p * 256 + 1) * 2, RGB(r & 31, g & 31, b & 31));
    w16(0x068A0000 + (p * 256 + 2) * 2, RGB((r + 8) > 31 ? 31 : r + 8, (g + 8) > 31 ? 31 : g + 8, (b + 8) > 31 ? 31 : b + 8));
  }
  VRAMCNT(9) = 0x83;                    /* I: engine B OBJ ext palette */
  for (int i = 0; i < 16; i++) {
    OAM_B[i * 4 + 0] = (u16)((16 + (i >> 2) * 24) | 0x2000);
    OAM_B[i * 4 + 1] = (u16)((16 + (i & 3) * 24) | (1 << 14));
    OAM_B[i * 4 + 2] = (u16)(2 | (i << 12) | (1 << 10));
  }
  OAM_B[16 * 4 + 0] = 100 | 0x2000;
  OAM_B[16 * 4 + 1] = 180 | (1 << 14);
  OAM_B[16 * 4 + 2] = 2 | (0 << 12) | (1 << 10);
  OAM_B[17 * 4 + 0] = 108 | 0x2000;
  OAM_B[17 * 4 + 1] = 188 | (1 << 14);
  OAM_B[17 * 4 + 2] = 2 | (8 << 12) | (0 << 10);

  for (int f = 0;; f++) {
    wait_vblank();
    int s = SINT[f & 15], c = SINT[(f + 4) & 15];
    /* group 0: rotation; the 16x16 ball drawn in a 32x32 double box */
    OAM_A[0 * 4 + 3] = (u16)c;
    OAM_A[1 * 4 + 3] = (u16)-s;
    OAM_A[2 * 4 + 3] = (u16)s;
    OAM_A[3 * 4 + 3] = (u16)c;
  }
}
