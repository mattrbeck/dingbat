// Probe: HuffUnComp with 4-bit symbols as well as 8-bit, two- and
// four-leaf trees, at several lengths, with the System-mode stack in IWRAM
// and then in EWRAM (swisp2.c measured only 8-bit streams there): does the
// per-leaf stack reload happen for 4-bit symbols too? Thumb caller in the
// cartridge (WAITCNT 0x4317), IRQs off. RESULT[2] = case, RESULT[3] = stack.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

__attribute__((naked, target("thumb"))) static void s13(void) {
  __asm__ volatile("swi 0x13\n bx lr");
}

__attribute__((naked, target("arm"), section(".iwram"))) static void
callfn_ewram(u32 fn, u32 a, u32 b, u32 c) {
  __asm__ volatile(
      "push {r4, lr}\n"
      "mov r4, sp\n"
      "ldr sp, =0x0203FF00\n"
      "ldr ip, =bd_callfn\n"
      "mov lr, pc\n"
      "bx ip\n"
      "mov sp, r4\n"
      "pop {r4, lr}\n"
      "bx lr\n"
      ".pool\n");
}

#define DST 0x02028000
#define ST 0x02024000   // streams, 0x400 apart

static vu8 *at(u32 a) { return (vu8 *)a; }

// bits: symbol width (4 or 8); leaves: 2 or 4; len: output bytes
static void huff(u32 a, u32 bits, u32 leaves, u32 len) {
  at(a)[0] = 0x20 | bits; at(a)[1] = len; at(a)[2] = len >> 8; at(a)[3] = len >> 16;
  u32 n;
  if (leaves == 2) {
    static const u8 t[] = {0x01, 0xC0, 0x1, 0x2};
    for (n = 0; n < 4; n++) at(a)[4 + n] = t[n];
  } else {
    // root -> two nodes -> four leaves
    static const u8 t[] = {0x03, 0x00, 0xC0, 0xC1, 0x1, 0x2, 0x3, 0x4};
    for (n = 0; n < 8; n++) at(a)[4 + n] = t[n];
  }
  for (u32 i = 0; i < 64; i++) at(a)[4 + n + i] = (u8)(0x5A + i * 37);
}

int main(void) {
  static const u8 shapes[][3] = {
    {4, 2, 4}, {4, 2, 16}, {4, 4, 4}, {4, 4, 16},
    {8, 2, 4}, {8, 2, 16}, {8, 4, 4}, {8, 4, 16},
  };
  const u32 n = sizeof shapes / sizeof shapes[0];
  for (u32 i = 0; i < n; i++) huff(ST + i * 0x400, shapes[i][0], shapes[i][1], shapes[i][2]);
  u32 k = 0;
  REG16(0x04000204) = 0x4317;
  for (u32 where = 0; where < 2; where++)
    for (u32 i = 0; i < n; i++) {
      RESULT[2] = i; RESULT[3] = where;
      Q();
      if (where) callfn_ewram((u32)s13, ST + i * 0x400, DST, 0);
      else bd_callfn((u32)s13, ST + i * 0x400, DST, 0);
      RESULT[1] = k; MARK(0x10 + (k++ & 0x3F));
    }
  MARK(0xFE);
  for (;;) {}
}
