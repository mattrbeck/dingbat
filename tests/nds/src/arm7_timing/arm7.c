/* arm7_timing ARM7: ARM7 instruction timing, measured with timers 0+1
   cascaded (33.51 MHz bus cycles). Each loop (loops.s) runs 256 and 512
   passes; RES[k] = T(512) - T(256), i.e. 256 x the cycles of one pass,
   so the call and timer overheads cancel. The ARM9 side is periph_suite's
   (it draws RES as bit rows; tools/periph_rows.py reads them back).

   RES words:
     1  Thumb SUB/BGT        (GBATEK WaitByLoop: 20BAh passes per ms = 4.0)
     2  ARM SUBS/BGT
     3  ARM 8 x MOV + SUBS/BGT (8 sequential opcodes on top of word 2)
     4  8 x LDRH from ARM7 WRAM    5  8 x LDRH from main RAM
     6  8 x LDR from main RAM      7  8 x STR to main RAM
     8  LDMIA 8 regs, main RAM     9  8 x MUL
     10 Thumb BL + BX LR + SUB/BGT  11 Thumb CMP/BEQ untaken + SUB/BGT
     12 Thumb SUB/BGT run from main RAM
     13 BIOS WaitByLoop (SWI 03h) with r0 = 256 / 512: T(512) - T(256)
     14 BIOS GetCRC16 (SWI 0Eh) over 512 more bytes of ARM7 WRAM
     15 the same over main RAM
   RES[0] = 'PERI' when done. */
#include "../periph_suite/periph.h"

#define TM0D REG16(0x04000100)
#define TM0C REG16(0x04000102)
#define TM1D REG16(0x04000104)
#define TM1C REG16(0x04000106)

typedef void (*loop_fn)(u32 passes, volatile void *data);
void loop_thumb(u32, volatile void *);
void loop_arm(u32, volatile void *);
void loop_arm_nop8(u32, volatile void *);
void loop_ldrh8(u32, volatile void *);
void loop_ldr8(u32, volatile void *);
void loop_str8(u32, volatile void *);
void loop_ldm8(u32, volatile void *);
void loop_mul8(u32, volatile void *);
void loop_thumb_call(u32, volatile void *);
void loop_thumb_untaken(u32, volatile void *);

static u32 wram_buf[16];
static u32 crc_buf[256];
#define MAIN_BUF ((volatile u32 *)0x02300000)
#define MAIN_CODE ((volatile u16 *)0x02301000)

static inline u32 now(void) {
  u32 hi, lo, hi2;
  do {
    hi = TM1D;
    lo = TM0D;
    hi2 = TM1D;
  } while (hi != hi2);
  return (hi << 16) | lo;
}

static u32 timed(loop_fn f, u32 passes, volatile void *data) {
  u32 t0 = now();
  f(passes, data);
  return now() - t0;
}

static u32 slope(loop_fn f, volatile void *data) {
  return timed(f, 512, data) - timed(f, 256, data);
}

static void wait_by_loop(u32 n) {
  register u32 r0 __asm__("r0") = n;
  __asm__ volatile("swi 0x30000" : "+r"(r0) : : "r1", "r2", "r3", "lr", "memory");
}

static u32 crc16(u32 crc, volatile void *p, u32 len) {
  register u32 r0 __asm__("r0") = crc;
  register volatile void *r1 __asm__("r1") = p;
  register u32 r2 __asm__("r2") = len;
  __asm__ volatile("swi 0xE0000" : "+r"(r0), "+r"(r1), "+r"(r2) : : "r3", "lr", "memory");
  return r0;
}

static u32 timed_crc(volatile void *p, u32 len) {
  u32 t0 = now();
  crc16(0xFFFF, p, len);
  return now() - t0;
}

static u32 timed_wbl(u32 n) {
  u32 t0 = now();
  wait_by_loop(n);
  return now() - t0;
}

int main(void) {
  for (int i = 0; i < RESULT_WORDS; i++) RES[i] = 0;
  TM0C = 0;
  TM1C = 0;
  TM0D = 0;
  TM1D = 0;
  TM1C = 0x84;   /* count-up */
  TM0C = 0x80;   /* F/1 */
  /* Thumb SUB/BGT/BX LR copied to main RAM */
  MAIN_CODE[0] = 0x3801;   /* subs r0, #1 */
  MAIN_CODE[1] = 0xDCFD;   /* bgt .-2 */
  MAIN_CODE[2] = 0x4770;   /* bx lr */
  RES[1] = slope(loop_thumb, 0);
  RES[2] = slope(loop_arm, 0);
  RES[3] = slope(loop_arm_nop8, 0);
  RES[4] = slope(loop_ldrh8, wram_buf);
  RES[5] = slope(loop_ldrh8, MAIN_BUF);
  RES[6] = slope(loop_ldr8, MAIN_BUF);
  RES[7] = slope(loop_str8, MAIN_BUF);
  RES[8] = slope(loop_ldm8, MAIN_BUF);
  RES[9] = slope(loop_mul8, 0);
  RES[10] = slope(loop_thumb_call, 0);
  RES[11] = slope(loop_thumb_untaken, 0);
  RES[12] = slope((loop_fn)((u32)MAIN_CODE | 1), 0);
  RES[13] = timed_wbl(512) - timed_wbl(256);
  RES[14] = timed_crc(crc_buf, 1024) - timed_crc(crc_buf, 512);
  RES[15] = timed_crc(MAIN_BUF, 1024) - timed_crc(MAIN_BUF, 512);
  RES[0] = RES_MAGIC;
  while (1) {}
}
