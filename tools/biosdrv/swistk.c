// Probe: what the sound driver SWIs leave on the caller's stack below sp
// (they run in System mode on it): each SWI from an ARM thunk called
// through bd_callfn_stk (registers r3, r6-r11 known, the 16 words below sp
// captured and zeroed around the call), copied to RESULT[8..29] for the
// snapshot. RESULT[2] = SWI number, RESULT[3] = case.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
#define SI(o) REG32((u32)AREA + (o))

#define THUNK(n) \
  __attribute__((naked, target("arm"), section(".iwram"))) void t##n(void) { \
    __asm__ volatile("swi 0x" #n "0000\n bx lr"); }
THUNK(1A) THUNK(1B) THUNK(1C) THUNK(1D) THUNK(1E) THUNK(28) THUNK(29)
__attribute__((naked, target("thumb"))) void tt1C(void) {
  __asm__ volatile("swi 0x1C\n bx lr");
}

__attribute__((naked, target("arm"), section(".iwram"))) void cb_sp20(void) {
  __asm__ volatile("ldr r1, =0x02030080\n str sp, [r1]\n bx lr\n .pool");
}
__attribute__((naked, target("arm"), section(".iwram"))) void cb_sp28(void) {
  __asm__ volatile("ldr r1, =0x02030084\n str sp, [r1]\n bx lr\n .pool");
}

static void call(void (*t)(void), u32 swi, u32 k, u32 a, u32 b) {
  RESULT[2] = swi; RESULT[3] = k;
  Q(); bd_callfn_stk((u32)t, a, b, 0);
  for (u32 i = 0; i < 22; i++) RESULT[8 + i] = bd_stk[i];
  RESULT[1] = k;
  MARK(0x10 + (k & 0x3F));
}

static const u8 wave[16 + 64] __attribute__((aligned(4))) = {
  0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0,
  10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 127, 1, 2, 3};

int main(void) {
  call(t1A, 0x1A, 0, (u32)AREA, 0);
  call(t1B, 0x1B, 1, 0x0094F800, 0);
  call(t1B, 0x1B, 2, 0x00000000, 0);
  call(t28, 0x28, 3, 0, 0);
  call(t29, 0x29, 4, 0, 0);
  call(t1D, 0x1D, 5, 0, 0);
  // SoundDriverMain: no channel, then one channel sounding, callbacks the
  // BIOS's dummy
  SI(0x20) = 0x1709; SI(0x28) = 0x1709;
  call(t1C, 0x1C, 6, 0, 0);
  vu8 *ch = (vu8 *)((u32)AREA + 0x50);
  ch[0] = 0x80; ch[1] = 0x08; ch[2] = 100; ch[3] = 100; ch[4] = 255;
  ch[5] = 0; ch[6] = 255; ch[7] = 0;
  *(vu32 *)((u32)ch + 0x24) = (u32)wave;
  call(t1C, 0x1C, 7, 0, 0);
  call(t1C, 0x1C, 8, 0, 0);
  SI(0x20) = 0;
  call(t1C, 0x1C, 9, 0, 0);
  // the callbacks' sp (RESULT[32], RESULT[33])
  SI(0x20) = (u32)cb_sp20; SI(0x28) = (u32)cb_sp28;
  call(t1C, 0x1C, 11, 0, 0);
  SI(0x20) = 0; SI(0x28) = 0x1709;
  call(tt1C, 0x1C, 12, 0, 0);            // from Thumb code in the cartridge
  // Mode with other rates and fields, VSyncOff locked twice
  call(t1B, 0x1B, 13, 0x00910000, 0);
  call(t1B, 0x1B, 14, 0x009A0000, 0);
  call(t1B, 0x1B, 15, 0x00000A05, 0);
  call(t1E, 0x1E, 10, 0, 0);
  MARK(0xFE);
  for (;;) {}
}
