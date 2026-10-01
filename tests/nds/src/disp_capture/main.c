// disp_capture: display capture (DISPCAPCNT 0x4000064) edge cases against
// GBATEK "DS Video Capture and Main Memory Display Mode". The top screen is
// engine A: 3D on BG0 with a red quad over the left half (x < 128) and a
// rear plane of blue at alpha 0, over a green backdrop, so the graphics
// composite is red | green and the 3D layer alone red | transparent blue.
// Capture lands in bank C (LCDC), source-B VRAM is bank D (LCDC). Results
// in hex on the bottom screen:
//   BUSY  DISPCAPCNT.31 for a 256x64 capture enabled in V-blank, read on
//         lines 10, 63, 64, 150, 191 and 192 ("cleared in line 192,
//         regardless of the capture size")
//   MID   enabled on line 100: .31 on line 150, on line 50 of the next
//         frame, on line 192 of that frame; then C at line 0 (captured from
//         the frame after the write) and at line 120 of the frame the write
//         was made in (untouched: marker 1234)
//   SZ0   128x128: C halfwords 0, 127, 128 (stride 128: line 1), 16383,
//         16384 (past the end: marker)
//   WRAP  256x192 at write offset 3 (18000h): C bytes 18000h, 1FFFEh,
//         00000h (line 64 wraps), 0FFFEh (line 191's end), 10000h (marker)
//   SRCB  source B = VRAM D (pattern: halfword i = i | 8000h) at read
//         offset 1 (8000h): C[0], C[1]; the same with display mode 2
//         (VRAM display of D: "read offset is ignored")
//   SRC3  source A = 3D only: C at x 0 (red), x 200 (transparent rear
//         plane: intensity and alpha bit)
//   BLND  A + B, EVA = EVB = 8: B = blue with alpha: C at x 0, x 200; B =
//         blue without alpha: C at x 0, x 200; EVA = 16, EVB = 16 (clamp):
//         C at x 0 with B = white + alpha
//   MODE  source A while the display is off (DISPCNT mode 0): C at x 0, 200
#include "t3d.h"
#include "tm.h"

#define DISPCNT_A R32(0x04000000)
#define DISPCAPCNT R32(0x04000064)
#define BANK_C ((vu16 *)0x06840000)
#define BANK_D ((vu16 *)0x06860000)
#define MARK 0x1234

static void wait_line(int l) {
  while (VCOUNT == l) {}
  while (VCOUNT != l) {}
}

static void fill(vu16 *b, u16 v) { for (int i = 0; i < 0x10000; i++) b[i] = v; }

static void scene(void) {
  t3d_proj_px();
  t3d_reset_matrices();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31) | PA_ID(1));
  color(RGB(31, 0, 0));
  quad_px(0, 0, 128, 192, 0);
  end_vtxs();
}

// one capture: set in V-blank, run to the next V-blank (capture done)
static void capture(u32 cnt) {
  wait_vblank();
  DISPCAPCNT = cnt | (1u << 31);
  scene();
  swap_buffers(0);
  wait_vblank();
  wait_line(193);
}

#define CAP(src, size, dst, wofs, rofs) \
  (((u32)(src) << 29) | ((u32)(size) << 20) | ((u32)(dst) << 16) | ((u32)(wofs) << 18) | ((u32)(rofs) << 26))

int main(void) {
  t3d_init("disp_capture");
  icache_on();
  u32 v[8];
  VRAMCNT(2) = 0x80;   // C: LCDC
  VRAMCNT(3) = 0x80;   // D: LCDC
  PAL_A_BG[0] = RGB(0, 20, 0);
  clear_color(RGB(0, 0, 31), 0, 0, 0);
  DISPCNT_A = 0x10108 | (3u << 18);   // mode 1, BG0 = 3D, VRAM block D for source B
  for (int f = 0; f < 3; f++) {
    scene();
    t3d_frame(0);
  }

  // BUSY
  wait_vblank();
  DISPCAPCNT = CAP(0, 1, 2, 0, 0) | (1u << 31);
  static const int lines[5] = {10, 63, 64, 150, 191};
  for (int i = 0; i < 5; i++) {
    scene();
    wait_line(lines[i]);
    v[i] = DISPCAPCNT >> 31;
    if (i == 0) swap_buffers(0);
  }
  wait_line(192);
  v[5] = DISPCAPCNT >> 31;
  tm_line("BUSY", v, 6, 1);

  // MID
  fill(BANK_C, MARK);
  wait_line(100);
  DISPCAPCNT = CAP(0, 3, 2, 0, 0) | (1u << 31);
  wait_line(150);
  v[0] = DISPCAPCNT >> 31;
  wait_line(50);
  v[1] = DISPCAPCNT >> 31;
  wait_line(192);
  v[2] = DISPCAPCNT >> 31;
  v[3] = BANK_C[0];
  v[4] = BANK_C[120 * 256];
  tm_line("MID", v, 5, 4);

  // SZ0
  fill(BANK_C, MARK);
  capture(CAP(0, 0, 2, 0, 0));
  v[0] = BANK_C[0];
  v[1] = BANK_C[127];
  v[2] = BANK_C[128];
  v[3] = BANK_C[16383];
  v[4] = BANK_C[16384];
  tm_line("SZ0", v, 5, 4);

  // WRAP
  fill(BANK_C, MARK);
  capture(CAP(0, 3, 2, 3, 0));
  v[0] = BANK_C[0x18000 / 2];
  v[1] = BANK_C[0x1FFFE / 2];
  v[2] = BANK_C[0];
  v[3] = BANK_C[0xFFFE / 2];
  v[4] = BANK_C[0x10000 / 2];
  tm_line("WRAP", v, 5, 4);

  // SRCB
  for (int i = 0; i < 0x10000; i++) BANK_D[i] = (u16)(i | 0x8000);
  fill(BANK_C, MARK);
  capture(CAP(1, 1, 2, 0, 1));
  v[0] = BANK_C[0];
  v[1] = BANK_C[1];
  fill(BANK_C, MARK);
  DISPCNT_A = 0x20000 | (3u << 18);   // VRAM display of D
  capture(CAP(1, 1, 2, 0, 1));
  DISPCNT_A = 0x10108 | (3u << 18);
  v[2] = BANK_C[0];
  v[3] = BANK_C[1];
  tm_line("SRCB", v, 4, 4);

  // SRC3
  fill(BANK_C, MARK);
  capture(CAP(0, 1, 2, 0, 0) | (1u << 24));
  v[0] = BANK_C[0];
  v[1] = BANK_C[200];
  tm_line("SRC3", v, 2, 4);

  // BLND
  fill(BANK_D, RGB(0, 0, 31) | 0x8000);
  fill(BANK_C, MARK);
  capture(CAP(2, 1, 2, 0, 0) | 8 | (8u << 8));
  v[0] = BANK_C[0];
  v[1] = BANK_C[200];
  fill(BANK_D, RGB(0, 0, 31));
  fill(BANK_C, MARK);
  capture(CAP(2, 1, 2, 0, 0) | 8 | (8u << 8));
  v[2] = BANK_C[0];
  v[3] = BANK_C[200];
  fill(BANK_D, 0xFFFF);
  fill(BANK_C, MARK);
  capture(CAP(2, 1, 2, 0, 0) | 16 | (16u << 8));
  v[4] = BANK_C[0];
  tm_line("BLND", v, 5, 4);

  // MODE
  fill(BANK_C, MARK);
  DISPCNT_A = 0x00108 | (3u << 18);   // display off, graphics still set up
  capture(CAP(0, 1, 2, 0, 0));
  DISPCNT_A = 0x10108 | (3u << 18);
  v[0] = BANK_C[0];
  v[1] = BANK_C[200];
  tm_line("MODE", v, 2, 4);

  while (1) {
    scene();
    t3d_frame(0);
  }
}
