// 3d_timing_fifo: what the geometry FIFO does around SWAP_BUFFERS, a full
// FIFO and GXFIFO DMA (GBATEK "DS 3D Geometry Commands": FIFO / PIPE, the
// CPU stall on a full FIFO, DMA mode 7; "SWAP_BUFFERS": halted until
// V-blank, then 392 cycles). Clock: timers 0+1 in bus cycles (tm.h).
// Printed on the bottom screen in hex once at start-up.
//   SWAP  SWAP_BUFFERS written on line 100: cycles from the first poll that
//         sees VCOUNT = 192 to GXSTAT.27 clearing, and VCOUNT then; the same
//         with 10 MTX_IDENTITY (19 each) queued behind the swap
//   STAL  SWAP_BUFFERS on line 100, then 300 MTX_IDENTITY: cycles the 300
//         writes took (the CPU stalls while the FIFO is full), VCOUNT and
//         GXSTAT right after the last write
//   DMA   400 BOX_TESTs (1600 words, unpacked) by DMA mode 7: lowest and
//         highest FIFO count GXSTAT showed while the DMA ran, polls taken,
//         cycles to the DMA's end, cycles to GXSTAT.27 clearing
//   DIRQ  IF.21 with GXSTAT IRQ mode 1 (less than half full) sampled while
//         that DMA runs: polls with the flag set, polls with it clear (the
//         ROM acknowledges it each poll)
//   SLOW  2000 BOX_TESTs from the CPU right after V-blank (206000 cycles of
//         engine time, plus the CPU's), then SWAP_BUFFERS: V-blanks the CPU
//         saw while writing, then V-blanks until GXSTAT.27 cleared, and
//         VCOUNT then; the same for 6000 (the swap misses a frame: 3D at
//         30 fps or less)
//   RAMC  RAM_COUNT read on line 191 after a swap was queued behind a
//         triangle, then on line 192 (+ a few polls), and after the swap
#include "t3d.h"
#include "tm.h"

static u32 list[1600];

static void wait_line(int l) {
  while (VCOUNT == l) {}
  while (VCOUNT != l) {}
}

static void box(void) { box_test(0, 0, 0, 64, 64, 64); }

int main(void) {
  t3d_init("3d_timing_fifo");
  icache_on();
  clock_start();
  u32 v[8];

  // --- SWAP_BUFFERS: the engine stays busy until V-blank + 392
  for (int q = 0; q < 2; q++) {
    t3d_wait_idle();
    wait_line(100);
    swap_buffers(0);
    for (int i = 0; i < q * 10; i++) mtx_identity();
    u32 t192 = 0;
    int seen = 0;
    u32 t;
    while (1) {
      int vc = VCOUNT;
      u32 st = GXSTAT;
      t = clock_now();
      if (!seen && vc == 192) {
        seen = 1;
        t192 = t;
      }
      if (!(st & (1u << 27))) break;
    }
    v[q * 2] = t - t192;
    v[q * 2 + 1] = VCOUNT;
  }
  tm_line("SWAP", v, 4, 4);

  // --- a full FIFO behind a pending swap stalls the CPU
  t3d_wait_idle();
  wait_line(100);
  swap_buffers(0);
  u32 t0 = clock_now();
  for (int i = 0; i < 300; i++) mtx_identity();
  v[0] = clock_now() - t0;
  v[1] = VCOUNT;
  v[2] = GXSTAT;
  tm_line("STAL", v, 3, 8);

  // --- DMA mode 7 keeps the FIFO between half and full
  for (int i = 0; i < 400; i++) {
    list[i * 4] = 0x70;
    list[i * 4 + 1] = 0;
    list[i * 4 + 2] = 64u << 16;
    list[i * 4 + 3] = 64 | (64u << 16);
  }
  mtx_mode(2);
  t3d_wait_idle();
  wait_vblank();
  u32 lo = 0x1FF, hi = 0, polls = 0, irq_on = 0, irq_off = 0;
  IME = 0;
  GXSTAT = 1u << 30;   // IRQ when less than half full (flag only, IME off)
  t0 = clock_now();
  DMA_SAD(0) = (u32)list;
  DMA_DAD(0) = 0x04000400;
  DMA_CNT(0) = 1600 | (1u << 31) | (7u << 27) | (1u << 26) | (2u << 21);
  u32 tdma = 0;
  while (1) {
    u32 st = GXSTAT;
    u32 cnt = DMA_CNT(0);
    u32 lvl = (st >> 16) & 0x1FF;
    if (lvl < lo) lo = lvl;
    if (lvl > hi) hi = lvl;
    polls++;
    if (IF9 & (1u << 21)) irq_on++;
    else irq_off++;
    IF9 = 1u << 21;
    if (!(cnt & (1u << 31))) {
      tdma = clock_now() - t0;
      break;
    }
  }
  t3d_wait_idle();
  u32 tend = clock_now() - t0;
  GXSTAT = 0;
  IF9 = 1u << 21;
  v[0] = lo;
  v[1] = hi;
  v[2] = polls;
  v[3] = tdma;
  v[4] = tend;
  tm_line("DMA", v, 5, 5);
  v[0] = irq_on;
  v[1] = irq_off;
  tm_line("DIRQ", v, 2, 4);

  // --- a frame the engine cannot finish in time
  for (int q = 0; q < 2; q++) {
    int n = q ? 6000 : 2000;
    t3d_wait_idle();
    wait_vblank();
    int vbl_during = 0, was = 1;
    for (int i = 0; i < n; i++) {
      box();
      int in = (DISPSTAT & 1) != 0;
      if (in && !was) vbl_during++;
      was = in;
    }
    swap_buffers(0);
    int vbl_after = 0;
    while (GXSTAT & (1u << 27)) {
      int in = (DISPSTAT & 1) != 0;
      if (in && !was) vbl_after++;
      was = in;
    }
    v[q * 3] = vbl_during;
    v[q * 3 + 1] = vbl_after;
    v[q * 3 + 2] = VCOUNT;
  }
  mtx_mode(1);
  tm_line("SLOW", v, 6, 4);

  // --- RAM_COUNT around the swap
  t3d_proj_px();
  t3d_reset_matrices();
  t3d_wait_idle();
  wait_vblank();
  t3d_wait_idle();
  poly_attr(PA_FRONT | PA_BACK | PA_ALPHA(31));
  tri_px(10, 10, 10, 20, 20, 15, 0);
  swap_buffers(0);
  wait_line(191);
  v[0] = RAM_COUNT;
  while (VCOUNT != 192) {}
  v[1] = RAM_COUNT;
  v[2] = RAM_COUNT;
  t3d_wait_idle();
  v[3] = RAM_COUNT;
  tm_line("RAMC", v, 4, 8);

  while (1) {
    t3d_proj_px();
    t3d_reset_matrices();
    poly_attr(PA_FRONT | PA_ALPHA(31) | PA_ID(1));
    color(RGB(0, 20, 31));
    quad_px(96, 64, 160, 128, 0);
    t3d_frame(0);
  }
}
