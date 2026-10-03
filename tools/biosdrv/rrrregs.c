// Probe: the registers RegisterRamReset hands back (r0-r3, r12) for known
// inputs, flag by flag (RESULT[4..8] after each call).
#include "drv.h"
__attribute__((noinline)) static void call(u32 f) {
  __asm__ volatile(
      "mov r0, %0\n"
      "ldr r1, =0x11111111\n ldr r2, =0x22222222\n ldr r3, =0x33333333\n"
      "ldr r4, =0xCCCCCCCC\n mov r12, r4\n"
      "swi 0x01\n"
      "ldr r4, =0x02030010\n"
      "str r0, [r4]\n str r1, [r4, #4]\n str r2, [r4, #8]\n str r3, [r4, #12]\n"
      "mov r0, r12\n str r0, [r4, #16]\n"
      "b 1f\n .pool\n 1:\n"
      :: "r"(f) : "r0", "r1", "r2", "r3", "r4", "r12", "memory");
}
int main(void) {
  static const u8 flags[] = {0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0xFF, 0x7D};
  for (u32 i = 0; i < sizeof flags; i++) {
    REG16(0x04000204) = 0;
    call(flags[i]);
    MARK(0x10 + i);
  }
  MARK(0xFE);
  for (;;) {}
}
