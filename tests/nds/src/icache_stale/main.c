// icache_stale: the ARM9 instruction cache holds instructions. Code is
// written into an instruction-cached line behind the cache's back, run,
// and run again after invalidating (GBATEK "ARM CP15 Cache Control": C7,C5,0
// invalidate the whole instruction cache, C7,C5,1 one line, C7,C13,1
// prefetch a line; "DS Memory Control - Cache and TCM": 8 KB, 4-way,
// 32-byte lines). Each test line holds `mov r0, #K; bx lr` (Thumb:
// `movs r0, #K; bx lr`); a call returns K, so a row shows which version
// ran. A console runs the version the line was filled with until the line
// is invalidated or evicted.
//
// Protection unit: region 0 I/O + VRAM (uncached), region 1 main RAM
// 0x02000000 4 MB (instruction-cached only), region 2 its mirror 0x02400000
// (uncached), region 3 0x02200000 4 KB (instruction- and data-cached,
// write-back); round-robin replacement (control bit 14).
//
// Rows (bottom screen, one digit per call), with what a console runs:
//   STR   1 1 2    v1 filled; v2 stored to the same address (the data
//                  cache does not hold region 1); after C7,C5,1
//   MIR   1 1 2    v2 stored through the uncached mirror; after C7,C5,0
//   DMA   1 1 2    v2 copied in by DMA3; after C7,C5,1
//   THM   1 1 2    Thumb, halfword store; after C7,C5,1
//   OFF   1 2 1 2  v1 filled; v2 stored, run with the instruction cache
//                  off (memory); on again without invalidating (the line
//                  still holds v1: Assumed, GBATEK is silent); after C7,C5,1
//   PRE   1 2      C7,C13,1 prefetched v1, v2 stored, run (prefetched
//                  line); after C7,C5,1
//   WB    1 1 2    region 3: v2 stored through the write-back data cache;
//                  after C7,C5,1 alone (memory still has v1); after
//                  C7,C10,1 clean + C7,C5,1
//   EVI   1 2      v1 filled, v2 stored, 8 other lines of the same set
//                  run (4 ways: the line is gone whatever the policy); run
//   DONE           all rows written
#include "t3d.h"

typedef u32 (*fn)(void);

#define MCR(cn, cm, op2, v) \
  __asm__ volatile("mcr p15, 0, %0, c" #cn ", c" #cm ", " #op2 ::"r"(v) : "memory")
#define MRC(cn, cm, op2) ({ u32 v_; \
  __asm__ volatile("mrc p15, 0, %0, c" #cn ", c" #cm ", " #op2 : "=r"(v_)); v_; })

#define IC_INV_ALL() MCR(7, 5, 0, 0)
#define IC_INV_LINE(a) MCR(7, 5, 1, (a))
#define IC_PREFETCH(a) MCR(7, 13, 1, (a))
#define DC_INV_ALL() MCR(7, 6, 0, 0)
#define DC_CLEAN_LINE(a) MCR(7, 10, 1, (a))

#define MIRROR 0x00400000u
#define ARM_MOV(k) (0xE3A00000u | (k))   // mov r0, #k
#define ARM_BX_LR 0xE12FFF1Eu
#define THUMB_MOV_BX(k) (0x47702000u | (k))   // movs r0, #k ; bx lr

static u32 put_arm(u32 a, u32 k) {
  R32(a) = ARM_MOV(k);
  R32(a + 4) = ARM_BX_LR;
  return a;
}

static u32 call(u32 a) { return ((fn)a)(); }

static u32 src[2];

static void dma3_copy(u32 dst, const u32 *s, int words) {
  R32(0x040000D4) = (u32)s;
  R32(0x040000D8) = dst;
  R32(0x040000DC) = (u32)words | (1u << 26) | (1u << 31);   // 32-bit, now
  while (R32(0x040000DC) & (1u << 31)) {}
}

static u32 r[9][4];

static void run_tests(void) {
  // STR: same address, line invalidate
  u32 a = put_arm(0x02100000, 1);
  IC_INV_LINE(a);
  r[0][0] = call(a);
  R32(a) = ARM_MOV(2);
  r[0][1] = call(a);
  IC_INV_LINE(a);
  r[0][2] = call(a);

  // MIR: uncached mirror, whole invalidate
  a = put_arm(0x02100040, 1);
  IC_INV_LINE(a);
  r[1][0] = call(a);
  R32(a + MIRROR) = ARM_MOV(2);
  r[1][1] = call(a);
  IC_INV_ALL();
  r[1][2] = call(a);

  // DMA
  a = put_arm(0x02100080, 1);
  IC_INV_LINE(a);
  r[2][0] = call(a);
  src[0] = ARM_MOV(2);
  src[1] = ARM_BX_LR;
  dma3_copy(a, src, 2);
  r[2][1] = call(a);
  IC_INV_LINE(a);
  r[2][2] = call(a);

  // THM: Thumb
  a = 0x021000C0;
  R32(a) = THUMB_MOV_BX(1);
  IC_INV_LINE(a);
  r[3][0] = call(a | 1);
  R16(a) = 0x2002;
  r[3][1] = call(a | 1);
  IC_INV_LINE(a);
  r[3][2] = call(a | 1);

  // OFF: instruction cache off and on again
  u32 ctl = MRC(1, 0, 0);
  a = put_arm(0x02100100, 1);
  IC_INV_LINE(a);
  r[4][0] = call(a);
  R32(a) = ARM_MOV(2);
  MCR(1, 0, 0, ctl & ~(1u << 12));
  r[4][1] = call(a);
  MCR(1, 0, 0, ctl);
  r[4][2] = call(a);
  IC_INV_LINE(a);
  r[4][3] = call(a);

  // PRE: prefetch
  a = put_arm(0x02100140, 1);
  IC_INV_LINE(a);
  IC_PREFETCH(a);
  R32(a) = ARM_MOV(2);
  r[5][0] = call(a);
  IC_INV_LINE(a);
  r[5][1] = call(a);

  // WB: through the write-back data cache (region 3)
  a = 0x02200000;
  R32(a + MIRROR) = ARM_MOV(1);
  R32(a + MIRROR + 4) = ARM_BX_LR;
  IC_INV_LINE(a);
  r[6][0] = call(a);
  (void)R32(a);                      // the data cache allocates on a read
  R32(a) = ARM_MOV(2);               // dirty: memory keeps v1
  IC_INV_LINE(a);
  r[6][1] = call(a);
  DC_CLEAN_LINE(a);
  IC_INV_LINE(a);
  r[6][2] = call(a);

  // EVI: eviction by 8 other lines of the same set (2 KB apart)
  a = put_arm(0x021001C0, 1);
  for (u32 k = 1; k <= 8; k++) put_arm(a + k * 0x800, 0);
  IC_INV_LINE(a);
  r[7][0] = call(a);
  R32(a) = ARM_MOV(2);
  for (u32 k = 1; k <= 8; k++) call(a + k * 0x800);
  r[7][1] = call(a);
}

int main(void) {
  t3d_init("ICACHE STALE");
  // protection unit
  MCR(6, 0, 0, 0x04000033);          // 0: 0x04000000 64 MB
  MCR(6, 1, 0, 0x0200002B);          // 1: 0x02000000 4 MB
  MCR(6, 2, 0, 0x0240002B);          // 2: 0x02400000 4 MB
  MCR(6, 3, 0, 0x02200017);          // 3: 0x02200000 4 KB
  MCR(6, 4, 0, 0);
  MCR(6, 5, 0, 0);
  MCR(6, 6, 0, 0);
  MCR(6, 7, 0, 0);
  MCR(2, 0, 1, 0x0A);                // instruction-cachable: 1, 3
  MCR(2, 0, 0, 0x08);                // data-cachable: 3
  MCR(3, 0, 0, 0x08);                // write-buffered (write-back): 3
  MCR(5, 0, 2, 0x3333);              // data AP 3, regions 0-3
  MCR(5, 0, 3, 0x3333);              // code AP 3
  IC_INV_ALL();
  DC_INV_ALL();
  MCR(1, 0, 0, MRC(1, 0, 0) | 1 | 4 | (1u << 12) | (1u << 14));

  run_tests();

  static const char *const names[] = {"STR", "MIR", "DMA", "THM", "OFF", "PRE", "WB", "EVI"};
  static const int count[] = {3, 3, 3, 3, 4, 2, 3, 2};
  for (int i = 0; i < 8; i++) {
    t3d_print(0, 2 + i, names[i]);
    for (int j = 0; j < count[i]; j++) t3d_hex(6 + 2 * j, 2 + i, r[i][j], 1);
  }
  t3d_print(0, 11, "DONE");
  for (;;) wait_vblank();
}
