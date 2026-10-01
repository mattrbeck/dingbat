// tm.h: timing helpers for the 3d_timing_* / disp_* test ROMs (header-only,
// included after t3d.h). A 32-bit bus-cycle clock from timers 0+1
// (33.51 MHz, cascaded), the ARM9 instruction cache switched on so the
// CPU writes commands faster than the geometry engine runs them, and a
// row printer for hex readouts.
#ifndef TM_H
#define TM_H

#define TM0CNT_L R16(0x04000100)
#define TM0CNT_H R16(0x04000102)
#define TM1CNT_L R16(0x04000104)
#define TM1CNT_H R16(0x04000106)
#define DISPSTAT R16(0x04000004)
#define DMA_SAD(n) R32(0x040000B0 + 12 * (n))
#define DMA_DAD(n) R32(0x040000B4 + 12 * (n))
#define DMA_CNT(n) R32(0x040000B8 + 12 * (n))
#define RDLINES R16(0x04000320)

static inline void clock_start(void) {
  TM0CNT_H = 0;
  TM1CNT_H = 0;
  TM0CNT_L = 0;
  TM1CNT_L = 0;
  TM1CNT_H = 0x84;   // count-up
  TM0CNT_H = 0x80;   // F/1
}

static inline u32 clock_now(void) {
  // timer 1 can carry between the two reads: re-read until stable
  u32 hi, lo, hi2;
  do {
    hi = TM1CNT_L;
    lo = TM0CNT_L;
    hi2 = TM1CNT_L;
  } while (hi != hi2);
  return (hi << 16) | lo;
}

static inline void icache_on(void) {
  // protection unit: region 0 = the whole 4 GB, instruction-cachable,
  // full access; regions 1-7 off; data cache and write buffer off so I/O
  // timing stays plain (ARM946E-S CP15, GBATEK "ARM CP15")
  u32 r = 0;
  __asm__ volatile(
      "mov %0, #0\n\t"
      "mcr p15, 0, %0, c7, c5, 0\n\t"   // invalidate the I-cache
      "mcr p15, 0, %0, c6, c1, 0\n\t"
      "mcr p15, 0, %0, c6, c2, 0\n\t"
      "mcr p15, 0, %0, c6, c3, 0\n\t"
      "mcr p15, 0, %0, c6, c4, 0\n\t"
      "mcr p15, 0, %0, c6, c5, 0\n\t"
      "mcr p15, 0, %0, c6, c6, 0\n\t"
      "mcr p15, 0, %0, c6, c7, 0\n\t"
      "mcr p15, 0, %0, c2, c0, 0\n\t"   // no data-cachable regions
      "mcr p15, 0, %0, c3, c0, 0\n\t"   // no write buffer
      "mov %0, #0x3F\n\t"
      "mcr p15, 0, %0, c6, c0, 0\n\t"   // region 0: base 0, 4 GB, on
      "mov %0, #1\n\t"
      "mcr p15, 0, %0, c2, c0, 1\n\t"   // region 0 instruction-cachable
      "mov %0, #3\n\t"
      "mcr p15, 0, %0, c5, c0, 2\n\t"   // data access: region 0 R/W
      "mcr p15, 0, %0, c5, c0, 3\n\t"   // instruction access: region 0 R/W
      "mrc p15, 0, %0, c1, c0, 0\n\t"
      "orr %0, %0, #0x1000\n\t"         // I-cache
      "orr %0, %0, #1\n\t"              // protection unit
      "bic %0, %0, #4\n\t"              // no D-cache
      "mcr p15, 0, %0, c1, c0, 0\n\t"
      : "+r"(r));
}

static int tm_row __attribute__((unused)) = 1;

static __attribute__((unused)) void tm_line(const char *label, const u32 *v, int n, int digits) {
  t3d_print(0, tm_row, label);
  int col = 5;
  for (int i = 0; i < n; i++) {
    if (col + digits > 32) {
      tm_row++;
      col = 5;
    }
    t3d_hex(col, tm_row, v[i], digits);
    col += digits + 1;
  }
  tm_row++;
}

#endif
