// Probe: IntrWait and VBlankIntrWait, the whole wait as BIOS code: called
// from ARM in IWRAM and Thumb in the cartridge, discarding old flags or
// not, with the wanted flag already set, with other interrupts (Timer 1,
// H-blank) arriving before the wanted one, with IME clear at the call. The
// rt.s handler acknowledges and sets the BIOS flags. Each call's time and
// what it leaves (bd_regs, the flags word). RESULT[2] = case.
#include "drv.h"

__attribute__((naked, target("arm"), section(".iwram"))) static void a05(void) {
  __asm__ volatile("swi 0x050000\n bx lr");
}
__attribute__((naked, target("arm"), section(".iwram"))) static void a04(void) {
  __asm__ volatile("swi 0x040000\n bx lr");
}
__attribute__((naked, target("thumb"))) static void t05(void) {
  __asm__ volatile("swi 0x05\n bx lr");
}
__attribute__((naked, target("thumb"))) static void t04(void) {
  __asm__ volatile("swi 0x04\n bx lr");
}

#define FLAGS REG16(0x03007FF8)

typedef struct { void (*fn)(void); u32 a, b; u16 ie; u16 dispstat; u16 tm; u8 ime; u8 preset; } Call;

int main(void) {
  static const Call calls[] = {
    {a05, 0, 0, 0x0001, 0x0008, 0, 1, 0},          // 0 VBlankIntrWait, ARM IWRAM
    {t05, 0, 0, 0x0001, 0x0008, 0, 1, 0},          // 1 ... Thumb cartridge
    {a04, 1, 1, 0x0001, 0x0008, 0, 1, 0},          // 2 IntrWait(1, vblank)
    {t04, 1, 1, 0x0001, 0x0008, 0, 1, 0},          // 3
    {a04, 0, 1, 0x0001, 0x0008, 0, 1, 1},          // 4 IntrWait(0, vblank), flag set
    {t04, 0, 1, 0x0001, 0x0008, 0, 1, 1},          // 5
    {a04, 1, 1, 0x0011, 0x0008, 3000, 1, 0},       // 6 Timer 1 IRQs before the vblank
    {t04, 1, 1, 0x0011, 0x0008, 3000, 1, 0},       // 7
    {a04, 1, 1, 0x0003, 0x0018, 0, 1, 0},          // 8 H-blank IRQs before it
    {t05, 0, 0, 0x0003, 0x0018, 0, 1, 0},          // 9
    {a04, 1, 0x10, 0x0011, 0x0008, 5000, 1, 0},    // 10 IntrWait(1, timer 1)
    {t04, 1, 0x10, 0x0011, 0x0008, 5000, 0, 0},    // 11 ... IME clear at the call
    {a05, 0, 0, 0x0001, 0x0008, 0, 0, 0},          // 12 VBlankIntrWait, IME clear
    {t04, 0, 3, 0x0003, 0x0018, 0, 1, 2},          // 13 IntrWait(0, vbl|hbl), H-blank set
  };
  const u32 n = sizeof calls / sizeof calls[0];
  REG16(0x04000204) = 0x4317;
  IRQ_VECTOR = (u32)bd_irq_handler;
  for (u32 r = 0; r < 2; r++)
    for (u32 i = 0; i < n; i++) {
      const Call *c = &calls[i];
      IME = 0;
      REG16(0x04000106) = 0;
      DISPSTAT = c->dispstat;
      IE = c->ie;
      IF = 0xFFFF;
      FLAGS = c->preset;
      if (c->tm) {
        REG16(0x04000104) = (u16)(0x10000 - c->tm);
        REG16(0x04000106) = 0x00C0;
      }
      // start each call at another point of the frame
      while (VCOUNT != (20 + 37 * i + 11 * r) % 160) {}
      IME = c->ime;
      RESULT[2] = i; RESULT[3] = r;
      bd_callfn_stk((u32)c->fn, c->a, c->b, 0);
      RESULT[4] = FLAGS;
      REG16(0x04000106) = 0;
      RESULT[1] = i; MARK(0x10 + (i & 0x3F));
    }
  IME = 0;
  MARK(0xFE);
  for (;;) {}
}
