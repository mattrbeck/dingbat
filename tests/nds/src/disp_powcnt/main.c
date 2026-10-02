// disp_powcnt: what POWCNT1's engine bits gate (GBATEK "DS Power Control":
// "When disabled, corresponding Ports become Read-only, corresponding
// (palette-) memory becomes read-only-zero-filled"). Each row writes a
// word with the unit on, switches the unit off, reads, writes a second
// word, reads, switches it back on and reads again; printed in hex on the
// bottom screen once at start-up:
//   PALA  0x05000010 (engine A palette): on, off, off after write, on again
//   OAMA  0x07000010 (engine A OAM)
//   IOA   BG1CNT A 0x0400000A (16-bit), DISPCNT A read while off
//   XB    engine B palette word 0x05000400 read while engine A is off
//   PALB  0x05000410, OAMB 0x07000410, IOB BG1CNT B 0x0400100A, DISPCNT B
//   GEO   geometry engine off: CLIPMTX_RESULT[0] with it on (identity),
//         while off, after MTX_SCALE 2.0 while off, after switching it on
//   RDR   rendering engine off: RDLINES_COUNT, DISP3DCNT
//   PWR   POWCNT1 as the boot left it (direct boot, or the firmware's)
// Top screen: engine A backdrop blue, BG0 = 3D with a red rear plane and a
// white quad -- then the 3D rendering engine is switched off for good, so
// the top shows what the display does without it: until frame 60 with no
// further SWAP_BUFFERS, after it with a smaller quad swapped in every frame,
// and from frame 120 with the geometry engine off as well.
#include "t3d.h"

#define CLIPMTX0 R32(0x04000640)
#define RDLINES R16(0x04000320)

static u32 v[64];
static int nv;

static void probe32(u32 addr, u16 bit) {
  R32(addr) = 0x11112222u;
  v[nv++] = R32(addr);
  POWCNT1 &= ~bit;
  v[nv++] = R32(addr);
  R32(addr) = 0x33334444u;
  v[nv++] = R32(addr);
  POWCNT1 |= bit;
  v[nv++] = R32(addr);
}

static void probe16(u32 addr, u16 bit) {
  R16(addr) = 0x1234;
  v[nv++] = R16(addr);
  POWCNT1 &= ~bit;
  v[nv++] = R16(addr);
  R16(addr) = 0x0567;
  v[nv++] = R16(addr);
  POWCNT1 |= bit;
  v[nv++] = R16(addr);
}

static int row = 1;
static void line(const char *label, int first, int n) {
  t3d_print(0, row, label);
  int col = 5;
  for (int i = first; i < first + n; i++) {
    t3d_hex(col, row, v[i], 8);
    col += 9;
    if (col + 8 > 32) {
      row++;
      col = 5;
    }
  }
  row++;
}

int main(void) {
  u32 powcnt_at_entry = POWCNT1;
  t3d_init("DISP POWCNT");
  PAL_A_BG[0] = RGB(0, 0, 31);
  clear_color(RGB(31, 0, 0), 31, 0, 0);

  // engine A (POWCNT1 bit 1)
  nv = 0;
  probe32(0x05000010, 2);
  probe32(0x07000010, 2);
  probe16(0x0400000A, 2);
  POWCNT1 &= ~2;
  v[nv++] = R32(0x04000000);
  v[nv++] = R16(0x05000402);
  POWCNT1 |= 2;
  // engine B (bit 9): its palette holds the text colours, restored after
  probe32(0x05000410, 0x200);
  probe32(0x07000410, 0x200);
  probe16(0x0400100A, 0x200);
  POWCNT1 &= ~0x200;
  v[nv++] = R32(0x04001000);
  POWCNT1 |= 0x200;
  // geometry engine (bit 3)
  t3d_wait_idle();
  mtx_mode(0);
  mtx_identity();
  mtx_mode(1);
  mtx_identity();
  t3d_wait_idle();
  v[nv++] = CLIPMTX0;
  POWCNT1 &= ~8;
  v[nv++] = CLIPMTX0;
  mtx_scale(FX(2.0), FX(2.0), FX(2.0));
  v[nv++] = CLIPMTX0;
  POWCNT1 |= 8;
  t3d_wait_idle();
  v[nv++] = CLIPMTX0;
  mtx_identity();

  // the scene, then the rendering engine (bit 2) off
  t3d_proj_px();
  color(0x7FFF);
  quad_px(64, 48, 192, 144, FX(0));
  end_vtxs();
  t3d_frame(0);
  wait_vblank();
  POWCNT1 &= ~4;
  wait_vblank();
  v[nv++] = RDLINES;
  v[nv++] = DISP3DCNT;

  line("PALA", 0, 4);
  line("OAMA", 4, 4);
  line("IOA", 8, 5);
  line("XB", 13, 1);
  line("PALB", 14, 4);
  line("OAMB", 18, 4);
  line("IOB", 22, 5);
  line("GEO", 27, 4);
  line("RDR", 31, 2);
  v[nv] = powcnt_at_entry;
  line("PWR", nv, 1);
  t3d_print(0, 23, "DONE");
  // phase 1 (to frame 60): no more swaps; phase 2: a new list (a smaller
  // quad) and SWAP_BUFFERS every frame with the rendering engine still off
  for (int f = 0; f < 50; f++) wait_vblank();
  for (int f = 0;; f++) {
    if (f == 60) POWCNT1 &= ~8;      // phase 3 (frame 120 on): geometry off too
    quad_px(96, 72, 160, 120, FX(0));
    end_vtxs();
    t3d_frame(0);
  }
}
