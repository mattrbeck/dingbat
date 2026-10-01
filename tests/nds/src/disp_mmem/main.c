// disp_mmem: main-memory display (DISPCNT display mode 3) fed through
// DISP_MMEM_FIFO 0x4000068 (GBATEK "DS Video Capture and Main Memory
// Display Mode": DMA in main-memory mode, 32-bit, word count 4, destination
// DISP_MMEM_FIFO, "transfer starts at next frame"). The top screen is
// engine A in display mode 3; the bottom screen names the phase. Each
// phase runs 30 frames:
//   frames   0- 29  A  DMA1 mode 4, count 4, repeat, source bitmap 1,
//                      restarted at every V-blank
//   frames  30- 59  B  the same, started once and never restarted: the
//                      source runs on through bitmap 2 and beyond
//   frames  60- 89  C  count 128 (a line per block), repeat, restarted at
//                      every V-blank
//   frames  90-119  D  count 4, no repeat, restarted at every V-blank
//   frames 120-149  E  no DMA: the CPU writes 64 words (128 pixels of
//                      bitmap 1) at the start of each V-blank
//   frames 150-179  F  A again, enabled at line 100 (mid-frame) of each
//                      frame instead of in V-blank
//   frames 180-209  G  A, with DMA started on line 0 of a frame where the
//                      display is in mode 1, switching to mode 3 at line 96
// Bitmap 1: red = x / 8, green = y / 8, blue 31. Bitmap 2: red 31,
// green = x / 8, blue = y / 8. The words after bitmap 2 are white.
#include "t3d.h"
#include "tm.h"

#define DISPCNT_A R32(0x04000000)
#define MMEM R32(0x04000068)

static u16 bitmaps[3][256 * 192];

static void stop(void) __attribute__((unused));
static void stop(void) { DMA_CNT(1) = 0; }

static void start(u32 count, int repeat, const void *src) {
  DMA_CNT(1) = 0;
  DMA_SAD(1) = (u32)src;
  DMA_DAD(1) = 0x04000068;
  DMA_CNT(1) = count | (1u << 31) | (repeat ? 1u << 25 : 0) | (4u << 27) | (1u << 26) | (2u << 21);
}

static void wait_line(int l) {
  while (VCOUNT == l) {}
  while (VCOUNT != l) {}
}

int main(void) {
  t3d_init("disp_mmem");
  icache_on();
  for (int y = 0; y < 192; y++)
    for (int x = 0; x < 256; x += 2) {
      // two pixels per word (bits 0-15 = x even); both share x / 8
      u32 i = (y * 256 + x) >> 1;
      ((u32 *)bitmaps[0])[i] = RGB(x >> 3, y >> 3, 31) * 0x10001u;
      ((u32 *)bitmaps[1])[i] = RGB(31, x >> 3, y >> 3) * 0x10001u;
      ((u32 *)bitmaps[2])[i] = 0x7FFF7FFF;
    }
  DISPCNT_A = 0x30000;   // display mode 3
  wait_vblank();
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE A");
    start(4, 1, bitmaps[0]);
    wait_vblank();
  }
  t3d_print(0, 2, "PHASE B");
  start(4, 1, bitmaps[0]);
  for (int f = 0; f < 30; f++) wait_vblank();
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE C");
    start(128, 1, bitmaps[0]);
    wait_vblank();
  }
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE D");
    start(4, 0, bitmaps[0]);
    wait_vblank();
  }
  stop();
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE E");
    for (int i = 0; i < 64; i++) MMEM = ((const u32 *)bitmaps[0])[i];
    wait_vblank();
  }
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE F");
    stop();
    wait_line(100);
    start(4, 1, bitmaps[0]);
    wait_vblank();
  }
  stop();
  for (int f = 0; f < 30; f++) {
    t3d_print(0, 2, "PHASE G");
    DISPCNT_A = 0x10000;   // mode 1 (graphics: BG0 3D, nothing drawn)
    stop();
    wait_line(0);
    start(4, 1, bitmaps[0]);
    wait_line(96);
    DISPCNT_A = 0x30000;
    wait_vblank();
  }
  stop();
  t3d_print(0, 2, "DONE   ");
  while (1) wait_vblank();
}
