// Probe: the decompression routines with the sound FIFO's DMA running (timer
// 0 at a sample every 1254 and every 777 cycles, DMA1 refilling FIFO A) and,
// in a second pass, a Timer 1 interrupt every 3000 cycles on top: long LZ77
// streams from EWRAM and from the cartridge into EWRAM and VRAM, RLUnComp,
// HuffUnComp, a Diff filter. Thumb caller in the cartridge, WAITCNT 0x4317.
// Each call's time (timers 2+3) and the interrupts taken; the FIFO bytes
// (compare.py --fifo) show each burst's reads. RESULT[2] = case, RESULT[3] =
// pass (0: DMA at 1254, 1: DMA at 777, 2: 1254 + IRQ, 3: 777 + IRQ).
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
static inline void t_start(void) {
  REG16(0x0400010A) = 0; REG16(0x0400010E) = 0;
  REG16(0x04000108) = 0; REG16(0x0400010C) = 0;
  REG16(0x0400010E) = 0x0084; REG16(0x0400010A) = 0x0080;
}
static inline u32 t_read(void) {
  REG16(0x0400010A) = 0;
  return REG16(0x04000108) | ((u32)REG16(0x0400010C) << 16);
}

#define S(n) \
  __attribute__((naked, target("thumb"))) static void s##n(void) { \
    __asm__ volatile("swi 0x" #n "\n bx lr"); }
S(11) S(12) S(13) S(14) S(16)
#undef S

#define LZ ((vu8 *)0x02020000)
#define RL ((vu8 *)0x02024000)
#define HF ((vu8 *)0x02026000)
#define DF ((vu8 *)0x02027000)
#define PCM ((vu32 *)0x02010000)
#define DST 0x02030000
#define VDST 0x06008000

// a stream in the cartridge: literals and references
static const u8 rom_lz[] __attribute__((aligned(4))) = {
  0x10, 0x00, 0x02, 0x00,
#define B8(a, b, c, d, e, f, g, h) a, b, c, d, e, f, g, h
  0x00, B8(1, 2, 3, 4, 5, 6, 7, 8),
  0x55, 9, 0x50, 0x03, 10, 0x60, 0x05, 11, 0x70, 0x07, 12, 0xF0, 0x0B,
  0xFF, 0xF0, 0x00, 0xF0, 0x01, 0xF0, 0x02, 0xF0, 0x03, 0xF0, 0x04, 0xF0, 0x05,
        0xF0, 0x06, 0xF0, 0x07,
  0xFF, 0xF0, 0x08, 0xF0, 0x09, 0xF0, 0x0A, 0xF0, 0x0B, 0xF0, 0x0C, 0xF0, 0x0D,
        0xF0, 0x0E, 0xF0, 0x0F,
  0xFF, 0xF0, 0x10, 0xF0, 0x11, 0xF0, 0x12, 0xF0, 0x13, 0xF0, 0x14, 0xF0, 0x15,
        0xF0, 0x16, 0xF0, 0x17,
  0xAA, 0x30, 0x01, 13, 0x30, 0x02, 14, 0x30, 0x03, 15, 0x30, 0x04, 16,
  0x00, B8(17, 18, 19, 20, 21, 22, 23, 24),
  0xFF, 0xF0, 0x20, 0xF0, 0x21, 0xF0, 0x22, 0xF0, 0x23, 0xF0, 0x24, 0xF0, 0x25,
        0xF0, 0x26, 0xF0, 0x27,
};

static void build_lz(void) {
  u32 n = 4, out = 0;
  for (u32 blk = 0; out < 0x1800; blk++) {
    u32 fpos = n++;
    u8 flags = 0;
    for (u32 b = 0; b < 8; b++) {
      u32 i = blk * 8 + b;
      if (out >= 64 && (i % 3) == 0) {
        u32 len = 3 + (i % 16), off = 1 + (i % 50);
        LZ[n++] = ((len - 3) << 4) | (off >> 8);
        LZ[n++] = off & 0xFF;
        flags |= 0x80 >> b;
        out += len;
      } else {
        LZ[n++] = (u8)(i * 7 + 1);
        out += 1;
      }
    }
    LZ[fpos] = flags;
  }
  LZ[0] = 0x10; LZ[1] = out; LZ[2] = out >> 8; LZ[3] = out >> 16;
}

static void build_rl(void) {
  u32 n = 4, out = 0;
  for (u32 i = 0; out < 0x1000; i++) {
    if (i & 1) { u32 len = 3 + (i * 37) % 100; RL[n++] = 0x80 | (len - 3); RL[n++] = (u8)i; out += len; }
    else { u32 len = 1 + (i * 11) % 20; RL[n++] = len - 1; for (u32 k = 0; k < len; k++) RL[n++] = (u8)(i + k); out += len; }
  }
  RL[0] = 0x30; RL[1] = out; RL[2] = out >> 8; RL[3] = 0;
}

static void build_hf(void) {
  HF[0] = 0x28; HF[1] = 0x00; HF[2] = 0x08; HF[3] = 0;   // 0x800 bytes
  static const u8 t[] = {0x03, 0x40, 0xC0, 0x00, 0x05, 0x01, 0x02, 0x00};
  for (u32 i = 0; i < 8; i++) HF[4 + i] = t[i];
  for (u32 i = 0; i < 0x1000; i++) HF[12 + i] = (u8)(0x5A + i * 37);
}

static void build_df(void) {
  DF[0] = 0x81; DF[1] = 0x00; DF[2] = 0x08; DF[3] = 0;
  for (u32 i = 0; i < 0x800; i++) DF[4 + i] = (u8)(i * 29 + 3);
}

static void sound_on(u32 period) {
  REG16(0x04000084) = 0x0080;               // master on
  REG16(0x04000082) = 0x0B0E;               // FIFO A both, timer 0, reset
  REG32(0x040000BC) = (u32)PCM;             // DMA1: PCM -> FIFO A
  REG32(0x040000C0) = 0x040000A0;
  REG16(0x040000C6) = 0xB640;               // enable, special, 32-bit, repeat, fixed dst
  REG16(0x04000100) = (u16)(0x10000 - period);
  REG16(0x04000102) = 0x0080;
}
static void sound_off(void) {
  REG16(0x04000102) = 0;
  REG16(0x040000C6) = 0;
  REG16(0x04000084) = 0;
}

typedef struct { void (*fn)(void); u32 a, b; } Call;

int main(void) {
  for (u32 i = 0; i < 0x1000; i++) PCM[i] = i * 0x01010101;
  build_lz(); build_rl(); build_hf(); build_df();
  static const Call calls[] = {
    {s11, (u32)LZ, DST}, {s11, (u32)rom_lz, DST}, {s12, (u32)LZ, VDST},
    {s12, (u32)rom_lz, VDST}, {s14, (u32)RL, DST}, {s13, (u32)HF, DST},
    {s16, (u32)DF, DST},
  };
  const u32 n = sizeof calls / sizeof calls[0];
  static const u16 periods[2] = {1254, 777};
  u32 k = 0;
  REG16(0x04000204) = 0x4317;
  irq_setup(1 << 4);                        // Timer 1
  for (u32 pass = 0; pass < 4; pass++) {
    for (u32 i = 0; i < n; i++) {
      sound_on(periods[pass & 1]);
      REG16(0x04000106) = 0;
      if (pass >= 2) {
        REG16(0x04000104) = (u16)(0x10000 - 3000);
        REG16(0x04000106) = 0x00C0;
      }
      u32 c0 = bd_irq_count;
      RESULT[2] = i; RESULT[3] = pass;
      t_start(); bd_callfn((u32)calls[i].fn, calls[i].a, calls[i].b, 0);
      RESULT[5] = t_read();
      REG16(0x04000106) = 0;
      RESULT[4] = bd_irq_count - c0;
      sound_off();
      RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
    }
  }
  MARK(0xFE);
  for (;;) {}
}
