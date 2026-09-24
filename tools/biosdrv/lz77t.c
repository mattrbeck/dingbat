// Probe: LZ77UnCompWram (SWI 0x11) time over stream shapes and regions,
// IRQs off, no DMA: literal runs, back-references of lengths 3-18 at small
// and large offsets, from EWRAM and the cartridge into EWRAM and IWRAM, at
// WAITCNT 0 and 0x4317. RESULT[2] = case, RESULT[3] = WAITCNT index.
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

// the cartridge copy of one mixed stream
static const u8 rom_stream[] __attribute__((aligned(4))) = {
  0x10, 0x40, 0, 0,
  0x55, 1, 2, 0xF0, 0x01, 3, 0x30, 0x02, 4, 0xF0, 0x05,
  0xAA, 0xF0, 0x03, 5, 0x10, 0x00, 6, 0x70, 0x08, 7,
  0x00, 8, 9, 10, 11, 12, 13, 14, 15};

#define SRC ((vu8 *)0x02020000)
#define DST_E 0x02030400
#define DST_I 0x03005000

static u32 build(u32 kind) {
  // header then tokens; returns the stream length
  u32 n = 4, out = 0;
  vu8 *s = SRC;
  for (u32 blk = 0; blk < 16; blk++) {
    u32 fpos = n++;
    u8 flags = 0;
    for (u32 b = 0; b < 8; b++) {
      u32 ref = kind == 0 ? 0 : kind == 1 ? 1 : ((blk * 8 + b) % 3 == 0);
      if (ref && out >= 32) {
        u32 len = kind == 1 ? 18 : 3 + ((blk * 8 + b) % 16);
        u32 off = kind == 3 ? 31 : 0;     // offset field (distance - 1)
        s[n++] = ((len - 3) << 4) | (off >> 8);
        s[n++] = off & 0xFF;
        flags |= 0x80 >> b;
        out += len;
      } else {
        s[n++] = (u8)(blk * 8 + b + 1);
        out += 1;
      }
    }
    s[fpos] = flags;
  }
  s[0] = 0x10; s[1] = out; s[2] = out >> 8; s[3] = 0;
  return out;
}

int main(void) {
  static const u16 wc[2] = {0x0000, 0x4317};
  u32 k = 0;
  for (u32 w = 0; w < 2; w++) {
    REG16(0x04000204) = wc[w];
    for (u32 kind = 0; kind < 4; kind++) {
      build(kind);
      for (u32 d = 0; d < 2; d++) {
        RESULT[2] = kind * 2 + d; RESULT[3] = w;
        Q(); t_start(); bd_callfn_stk((u32)t11, (u32)SRC, d ? DST_I : DST_E, 0);
        RESULT[5] = t_read(); RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
      }
    }
    for (u32 d = 0; d < 2; d++) {
      RESULT[2] = 8 + d; RESULT[3] = w;
      Q(); t_start(); bd_callfn_stk((u32)t11, (u32)rom_stream, d ? DST_I : DST_E, 0);
      RESULT[5] = t_read(); RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
    }
  }
  MARK(0xFE);
  for (;;) {}
}
