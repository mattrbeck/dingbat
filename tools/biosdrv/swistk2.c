// Probe: what the other SWIs a sound-driver game uses leave on the caller's
// stack below sp (every BIOS routine runs in System mode on it): Div,
// DivArm, Sqrt, ArcTan2, CpuSet, CpuFastSet, LZ77 (WRAM and VRAM),
// MidiKey2Freq, VBlankIntrWait. As swistk.c: an ARM thunk per SWI called
// through bd_callfn_stk, RESULT[2] = SWI, RESULT[3] = case.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define THUNK(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) void t##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
THUNK(05) THUNK(06) THUNK(07) THUNK(08) THUNK(0A) THUNK(0B) THUNK(0C) THUNK(11)
THUNK(12) THUNK(1F)

static void call(void (*t)(void), u32 swi, u32 k, u32 a, u32 b, u32 c) {
  RESULT[2] = swi; RESULT[3] = k;
  Q(); bd_callfn_stk((u32)t, a, b, c);
  for (u32 i = 0; i < 22; i++) RESULT[8 + i] = bd_stk[i];
  RESULT[1] = k;
  MARK(0x10 + (k & 0x3F));
}

// LZ77 stream: header (type 0x10, 32 bytes), literals and a back-reference
static const u8 lz[] __attribute__((aligned(4))) = {
  0x10, 32, 0, 0, 0x08, 1, 2, 3, 4, 0xF0, 0x03, 5, 6, 7, 0x00,
  8, 9, 10, 11, 12, 13, 14, 15, 0x00, 16, 17, 18, 19, 20, 21, 22, 23};
static u32 src[32], dst[64];
static u32 wave[4] = {0, 0x3443 << 10, 0, 0};

int main(void) {
  for (u32 i = 0; i < 32; i++) src[i] = i * 0x01010101;
  call(t06, 0x06, 0, 1000, 7, 0);
  call(t07, 0x07, 1, 7, 1000, 0);
  call(t08, 0x08, 2, 12345, 0, 0);
  call(t0A, 0x0A, 3, 0x1000, 0x2000, 0);
  call(t0B, 0x0B, 4, (u32)src, (u32)dst, 16);             // 16 halfwords
  call(t0B, 0x0B, 5, (u32)src, (u32)dst, 16 | (1 << 26)); // 16 words
  call(t0B, 0x0B, 6, (u32)src, (u32)dst, 16 | (5 << 24)); // word fill
  call(t0C, 0x0C, 7, (u32)src, (u32)dst, 32);
  call(t0C, 0x0C, 8, (u32)src, (u32)dst, 32 | (1 << 24));
  call(t11, 0x11, 9, (u32)lz, (u32)dst, 0);
  call(t12, 0x12, 10, (u32)lz, 0x06010000, 0);
  call(t1F, 0x1F, 11, (u32)wave, 60, 0);
  call(t1F, 0x1F, 12, (u32)wave, 180, 7);
  // VBlankIntrWait with V-blank IRQs on
  irq_setup(1);
  call(t05, 0x05, 13, 0, 0, 0);
  MARK(0xFE);
  for (;;) {}
}
