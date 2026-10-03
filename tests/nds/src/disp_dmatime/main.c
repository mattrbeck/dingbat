// disp_dmatime: how long an ARM9 DMA (channel 0, start immediately)
// holds the CPU, per source/destination region and unit size (GBATEK
// "DS DMA Transfers"; "DS Memory Timings" says only that main memory reads
// are slow and that DMA main memory reads may overlap writes elsewhere).
// A cascaded timer counts bus cycles (33.51 MHz) from just before the
// DMA_CNT write to the first instruction after it; the ARM9 runs from its
// instruction cache, data cache off. Each row: name, then the cycles for
// 1, 16 and 256 units (hex); the per-unit cost is (256 - 16) / 240.
//   MM  main RAM -> main RAM       MV  main RAM -> VRAM (bank A, LCDC)
//   VM  VRAM -> main RAM           MP  main RAM -> palette
//   MW  main RAM -> shared WRAM    WV  shared WRAM -> VRAM
//   MI  main RAM -> I/O (BG2PA..)  FV  fill (src fixed: an I/O word) -> VRAM
// first with 32-bit units (W), then 16-bit (H). From frame 60 the screen
// shows page 2 ("P2" in the top-left cell): for n = 1..20 units (row
// n+1, n in hex at column 0) the cycles of MM, MV, MW, MI, VM with 32-bit
// units and MV with 16-bit ones, at columns 3, 8, 13, 18, 23, 28, to see
// the per-unit cost step by step. Built with build_3d.sh.
#include "t3d.h"
#include "tm.h"

#define WRAMCNT R8(0x04000247)

static u32 run(u32 src, u32 dst, u32 units, int word, int src_fixed, int dst_fixed) {
  DMA_SAD(0) = src;
  DMA_DAD(0) = dst;
  u32 cnt = (1u << 31) | (word ? (1u << 26) : 0) | (src_fixed ? (2u << 23) : 0) |
            (dst_fixed ? (2u << 21) : 0) | units;
  u32 t0 = clock_now();
  DMA_CNT(0) = cnt;
  u32 t1 = clock_now();
  return t1 - t0;
}

int main(void) {
  t3d_init("disp_dmatime: ARM9 DMA cycles");
  icache_on();
  clock_start();
  VRAMCNT(0) = 0x80;                       // A: LCDC (0x06800000)
  WRAMCNT = 0;                             // shared WRAM: all 32K to the ARM9
  static const char *names[8] = {"MM", "MV", "VM", "MP", "MW", "WV", "MI", "FV"};
  static const u32 src[8] = {0x02100000, 0x02100000, 0x06800000, 0x02100000,
                             0x02100000, 0x03000000, 0x02100000, 0x040000E0};
  static const u32 dst[8] = {0x02180000, 0x06810000, 0x02180000, 0x05000000,
                             0x03004000, 0x06810000, 0x04000020, 0x06810000};
  static const u32 counts[3] = {1, 16, 256};
  R32(0x040000E0) = 0x12345678;            // DMA0 fill word
  for (int w = 0; w < 2; w++)
    for (int i = 0; i < 8; i++) {
      int row = 2 + w * 9 + i;
      t3d_print(0, row, names[i]);
      t3d_print(3, row, w ? "H" : "W");
      for (int k = 0; k < 3; k++) {
        u32 n = counts[k];
        // I/O destination: 4 bytes (BG2PA/PB) then fixed, so nothing past them
        int dfix = (i == 6) ? 1 : 0;
        int sfix = (i == 7) ? 1 : 0;
        u32 t = run(src[i], dst[i], n, !w, sfix, dfix);
        t3d_hex(5 + k * 9, row, t, 6);
      }
    }
  // the overhead of the two timer reads alone
  u32 t0 = clock_now();
  u32 t1 = clock_now();
  t3d_print(0, 20, "CLK");
  t3d_hex(5, 20, t1 - t0, 6);
  t3d_print(0, 22, "DONE");
  for (int f = 0; f < 60; f++) wait_vblank();
  for (int r = 0; r < 24; r++) t3d_print(0, r, "                                ");
  t3d_print(0, 0, "P2 MM   MV   MW   MI   VM   MVH");
  static const int pick[6] = {0, 1, 4, 6, 2, 1};
  for (u32 n = 1; n <= 20; n++) {
    t3d_hex(0, n + 1, n, 2);
    for (int k = 0; k < 6; k++) {
      int i = pick[k];
      u32 t = run(src[i], dst[i], n, k < 5, 0, i == 6);
      t3d_hex(3 + k * 5, n + 1, t, 4);
    }
  }
  while (1) wait_vblank();
}
