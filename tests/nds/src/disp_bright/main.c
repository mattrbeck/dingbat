// disp_bright: the colour depth of engine A's output stage. GBATEK "DS Video
// ... MASTER_BRIGHT": the factor applies to 6-bit R,G,B intensities; "DS 3D
// 2D Display Engine A ... Special Effects": a 3D pixel blends over a 2nd
// target with its own alpha. Column c (8 dots wide) uses the 2D colour
// col2d(c) = RGB(c, 31-c, 7c mod 32). Each setting is held for 4 frames;
// the bottom screen (engine B, never brightened or blended) prints the
// page and setting the top screen (engine A) shows this frame:
// "PG p" and "MB ss vvvv" (setting, register value).
//
// Page 1, MASTER_BRIGHT through 35 settings: off, up 1..16, down 1..16,
// up 31, down 20 (both clamp to 16):
//   rows 0-47    2D only (BG1, 8bpp tiles; the 3D layer is transparent)
//   rows 48-95   opaque 3D quads, vertex colour col2d(c)
//   rows 96-191  12 bands of 8 rows: a translucent 3D quad of alpha
//                1 + (c mod 30) and band colour C3[k] over BG1 colour C2[k]
//                (BLDCNT: BG0 1st target, BG1 2nd target, alpha mode)
// Page 2, the colour effects (BLDCNT 1st BG0+BG1, 2nd BG0+BG2+backdrop,
// MASTER_BRIGHT off) through 20 settings: alpha with the EVA/EVB pairs in
// EV[], then brighten and darken with EVY 1, 4, 8, 13, 16 ("MB" prints
// BLDCNT's mode in the high byte, EVA/EVY in the low byte, EVB in the
// middle):
//   rows 0-47    BG1 col2d(c) over BG2 col2d(31-c)
//   rows 48-95   BG1 col2d(c) over opaque 3D col2d(c ^ 31) (3D as 2nd target)
//   rows 96-143  opaque 3D col2d(c) (BG1 transparent) over BG2 col2d(31-c)
//   rows 144-191 BG1 col2d(c) over BG2 col2d(31-c) again
#include "t3d.h"

#define DISPCNT_A R32(0x04000000)
#define BG0CNT_A R16(0x04000008)
#define BG1CNT_A R16(0x0400000A)
#define BG2CNT_A R16(0x0400000C)
#define BLDY_A R16(0x04000054)
#define MASTER_BRIGHT_A R16(0x0400006C)
#define BG_VRAM_A ((vu16 *)0x06000000)

static const u16 C3[12] = {
  RGB(31, 31, 31), RGB(17, 9, 3), RGB(1, 2, 3), RGB(16, 16, 16), RGB(31, 0, 15), RGB(5, 25, 30),
  RGB(31, 31, 31), RGB(0, 0, 0), RGB(17, 9, 3), RGB(10, 20, 30), RGB(29, 3, 11), RGB(2, 31, 8),
};
static const u16 C2[12] = {
  RGB(0, 0, 0), RGB(0, 0, 0), RGB(31, 31, 31), RGB(1, 1, 1), RGB(15, 31, 0), RGB(9, 3, 27),
  RGB(31, 31, 31), RGB(31, 31, 31), RGB(30, 1, 16), RGB(20, 10, 0), RGB(3, 3, 3), RGB(16, 16, 16),
};
static const u8 EV[10][2] = {{16, 0}, {0, 16}, {8, 8}, {4, 12}, {12, 4}, {3, 7}, {15, 15}, {9, 10}, {16, 16}, {1, 1}};
static const u8 EVY[5] = {1, 4, 8, 13, 16};

static u16 col2d(int c) { return RGB(c, 31 - c, (c * 7) & 31); }

static u16 setting1(int s) {
  if (s == 0) return 0;
  if (s <= 16) return 0x4000 | s;
  if (s <= 32) return 0x8000 | (s - 16);
  return s == 33 ? 0x4000 | 31 : 0x8000 | 20;
}

// page 2: BLDCNT mode (1-3) << 12 | EVB << 6 | EVA/EVY, the value printed
static u16 setting2(int s) {
  if (s < 10) return 0x1000 | (EV[s][1] << 6) | EV[s][0];
  if (s < 15) return 0x2000 | EVY[s - 10];
  return 0x3000 | EVY[s - 15];
}

static void quad_col(int x, int y0, int y1, u16 c, int alpha, int id) {
  poly_attr(PA_FRONT | PA_ALPHA(alpha) | PA_ID(id));
  color(c);
  quad_px(x, y0, x + 8, y1, 0);
}

static void scene1(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  tex_param(0);
  for (int c = 0; c < 32; c++) quad_col(c * 8, 48, 96, col2d(c), 31, 1);
  // a different ID per quad: no translucent-ID rule between neighbours
  for (int k = 0; k < 12; k++)
    for (int c = 0; c < 32; c++) quad_col(c * 8, 96 + k * 8, 104 + k * 8, C3[k], 1 + (c % 30), 2 + c);
  end_vtxs();
}

static void scene2(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  tex_param(0);
  for (int c = 0; c < 32; c++) {
    quad_col(c * 8, 48, 96, col2d(c ^ 31), 31, 1);
    quad_col(c * 8, 96, 144, col2d(c), 31, 1);
  }
  end_vtxs();
}

static void maps(int page) {
  vu16 *m1 = BG_VRAM_A + 0x7800 / 2;       // BG1: screen base 15
  vu16 *m2 = BG_VRAM_A + 0x7000 / 2;       // BG2: screen base 14
  for (int r = 0; r < 32; r++)
    for (int c = 0; c < 32; c++) {
      int t1 = 0, t2 = 0;
      if (page == 1) {
        if (r < 12) t1 = 1 + c;            // rows 0-95: column colours
        else if (r < 24) t1 = 33 + (r - 12);   // bands: C2[k]
      } else {
        t1 = (r >= 12 && r < 18) ? 0 : 1 + c;
        t2 = 1 + (31 - c);
      }
      m1[r * 32 + c] = t1;
      m2[r * 32 + c] = t2;
    }
}

int main(void) {
  t3d_init("disp_bright: MASTER_BRIGHT + 3D/2D");
  // BG tiles: 8bpp in bank A, tile t solid colour index t (tile 0: clear)
  VRAMCNT(0) = 0x81;                       // A: engine A BG
  for (int t = 0; t < 48; t++)
    for (int i = 0; i < 32; i++) BG_VRAM_A[t * 32 + i] = t | (t << 8);
  for (int c = 0; c < 32; c++) PAL_A_BG[1 + c] = col2d(c);
  for (int k = 0; k < 12; k++) PAL_A_BG[33 + k] = C2[k];
  PAL_A_BG[0] = 0;
  DISP3DCNT = D3_BLEND;
  clear_color(0, 0, 63, 0);
  u32 frame = 0;
  int shown = 0;
  while (1) {
    int s = (frame / 4) % 55;
    int page = s < 35 ? 1 : 2;
    if (page != shown) {
      // switch pages in V-blank; the 3D drawn for this frame matches
      maps(page);
      if (page == 1) {
        BG0CNT_A = 0;                      // 3D priority 0
        BG1CNT_A = (1 << 7) | (15 << 8) | 1;
        DISPCNT_A = 0x10308;               // mode 0, BG0 = 3D, BG0 + BG1
        BLDCNT_A = 0x0241;                 // BG0 1st, BG1 2nd target, alpha
        BLDALPHA_A = 16;
      } else {
        MASTER_BRIGHT_A = 0;
        BG0CNT_A = 1;                      // 3D priority 1
        BG1CNT_A = (1 << 7) | (15 << 8) | 0;
        BG2CNT_A = (1 << 7) | (14 << 8) | 2;
        DISPCNT_A = 0x10708;               // BG0 = 3D, BG0 + BG1 + BG2
      }
      shown = page;
    }
    u16 v;
    if (page == 1) {
      v = setting1(s);
      MASTER_BRIGHT_A = v;                 // set in V-blank: shown next frame
    } else {
      v = setting2(s - 35);
      BLDCNT_A = 0x2503 | ((v >> 12) << 6);
      BLDALPHA_A = (v & 0x1F) | (((v >> 6) & 0x1F) << 8);
      BLDY_A = v & 0x1F;
    }
    t3d_print(0, 2, "PG");
    t3d_hex(3, 2, page, 1);
    t3d_print(0, 3, "MB");
    t3d_hex(3, 3, page == 1 ? s : s - 35, 2);
    t3d_hex(6, 3, v, 4);
    if (page == 1) scene1(); else scene2();
    t3d_frame(0);
    frame++;
  }
}
