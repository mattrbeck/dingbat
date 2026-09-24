// Probe: LZ77UnCompWram interrupted: a long stream (literals and
// back-references, source in EWRAM or the cartridge, destination EWRAM)
// decompressed while Timer 1 raises an IRQ every N cycles (the rt.s
// handler: acknowledge, count). The call's time and the IRQ count, HLE vs
// the real BIOS; RESULT[2] = source, RESULT[3] = period index.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
// Timers 2+3 cascaded: a 32-bit cycle count read in the probe itself
static inline void t_start(void) {
  REG16(0x0400010A) = 0; REG16(0x0400010E) = 0;
  REG16(0x04000108) = 0; REG16(0x0400010C) = 0;
  REG16(0x0400010E) = 0x0084; REG16(0x0400010A) = 0x0080;
}
static inline u32 t_read(void) {
  REG16(0x0400010A) = 0;
  return REG16(0x04000108) | ((u32)REG16(0x0400010C) << 16);
}

__attribute__((naked, target("arm"), section(".iwram"))) void t11(void) {
  __asm__ volatile("swi 0x110000\n bx lr");
}
__attribute__((naked, target("thumb"))) void tt11(void) {
  __asm__ volatile("swi 0x11\n bx lr");
}

#define SRC ((vu8 *)0x02020000)
#define DST 0x02038000

static void build(void) {
  u32 n = 4, out = 0;
  vu8 *s = SRC;
  for (u32 blk = 0; blk < 512; blk++) {
    u32 fpos = n++;
    u8 flags = 0;
    for (u32 b = 0; b < 8; b++) {
      u32 i = blk * 8 + b;
      if (out >= 64 && (i % 3) == 0) {
        u32 len = 3 + (i % 16), off = 1 + (i % 50);
        s[n++] = ((len - 3) << 4) | (off >> 8);
        s[n++] = off & 0xFF;
        flags |= 0x80 >> b;
        out += len;
      } else {
        s[n++] = (u8)(i * 7 + 1);
        out += 1;
      }
    }
    s[fpos] = flags;
  }
  s[0] = 0x10; s[1] = out; s[2] = out >> 8; s[3] = out >> 16;
}

int main(void) {
  static const u16 periods[4] = {0, 1000, 3000, 12000};
  u32 k = 0;
  build();
  REG16(0x04000204) = 0x4317;
  irq_setup(1 << 4);                 // Timer 1
  for (u32 p = 0; p < 4; p++)
    for (u32 th = 0; th < 2; th++) {
      REG16(0x04000106) = 0;
      if (periods[p]) {
        REG16(0x04000104) = (u16)(0x10000 - periods[p]);
        REG16(0x04000106) = 0x00C0;    // IRQ, start
      }
      u32 c0 = bd_irq_count;
      RESULT[2] = th; RESULT[3] = p;
      Q(); t_start(); bd_callfn_stk(th ? (u32)tt11 : (u32)t11, (u32)SRC, DST, 0);
      REG16(0x04000106) = 0;
      RESULT[4] = bd_irq_count - c0;
      RESULT[5] = t_read(); RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
    }
  MARK(0xFE);
  for (;;) {}
}
