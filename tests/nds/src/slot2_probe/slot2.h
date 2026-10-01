/* slot2_probe: the mailbox between the ARM9 (arm9.c, runs the probe and
   draws the results) and the ARM7 (arm7.c, reads the slot when the ARM9
   hands it over). Both live in main RAM outside the two binaries. */
#ifndef SLOT2_H
#define SLOT2_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#define REG8(a) (*(volatile u8 *)(a))

#define EXMEM REG16(0x04000204)   /* EXMEMCNT on the ARM9, EXMEMSTAT on the ARM7 */
#define TM0D REG16(0x04000100)
#define TM0C REG16(0x04000102)

/* ARM9 -> ARM7 command: CMD is bumped, ARG goes with it; the ARM7 fills
   A7RES and copies CMD to DONE. */
#define CMD REG32(0x02200000)
#define ARG REG32(0x02200004)
#define DONE REG32(0x02200008)
#define A7RES ((volatile u32 *)0x02200010)

enum { C7_READ = 1, C7_EXMEM_ALL = 2 };

/* The results, in the order docs/nds/slot2.md lists them; RES[RES_N] =
   RES_MAGIC once the run is complete. */
#define RES ((volatile u32 *)0x02200100)
#define RES_N 82
#define RES_MAGIC 0x32544F53u   /* 'SOT2' */

/* Cycle count of 16 back-to-back loads from `a` (timer 0 at the 33 MHz bus
   clock): the probe compares the access-time settings. */
static inline u32 time16_ldrh(u32 a) {
  u32 t0, t1, x;
  TM0C = 0;
  TM0D = 0;
  TM0C = 0x80;
  __asm__ volatile(
      "ldrh %0, [%3]\n"
      ".rept 16\n ldrh %2, [%4]\n .endr\n"
      "ldrh %1, [%3]\n"
      : "=&r"(t0), "=&r"(t1), "=&r"(x)
      : "r"(0x04000100), "r"(a)
      : "memory");
  return (t1 - t0) & 0xFFFF;
}

static inline u32 time16_ldrb(u32 a) {
  u32 t0, t1, x;
  TM0C = 0;
  TM0D = 0;
  TM0C = 0x80;
  __asm__ volatile(
      "ldrh %0, [%3]\n"
      ".rept 16\n ldrb %2, [%4]\n .endr\n"
      "ldrh %1, [%3]\n"
      : "=&r"(t0), "=&r"(t1), "=&r"(x)
      : "r"(0x04000100), "r"(a)
      : "memory");
  return (t1 - t0) & 0xFFFF;
}

#endif
