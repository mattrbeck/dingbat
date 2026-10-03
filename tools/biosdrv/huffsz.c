// Probe: HuffUnComp with every value of the header's symbol-size nibble
// (0-15; the format defines 4 and 8), the same tree and bitstream each time:
// what the routine spills below sp, the words it writes and r0-r3 after it.
// ARM caller in IWRAM, IRQs off. RESULT[2] = the size nibble.
#include "drv.h"

__attribute__((naked, target("arm"), section(".iwram"))) static void s13(void) {
  __asm__ volatile("swi 0x130000\n bx lr");
}

#define ST 0x02020000
#define DST 0x02030000

static vu8 *at(u32 a) { return (vu8 *)a; }

int main(void) {
  for (u32 n = 0; n < 16; n++) {
    vu8 *h = at(ST + 0x100 * n);
    // length 16; root -> (node -> leaves 0x35, 0xCA), leaf 0x5F
    static const u8 t[] = {0x00, 16, 0, 0, 0x03, 0x40, 0xC0, 0x5F, 0x35, 0xCA, 0x00, 0x00};
    for (u32 i = 0; i < sizeof t; i++) h[i] = t[i];
    h[0] = 0x20 | n;
    for (u32 i = 0; i < 64; i++) h[12 + i] = (u8)(0x5A + i * 37);
  }
  for (u32 n = 0; n < 16; n++) {
    fill32((void *)DST, 0xEEEEEEEE, 0x100);
    RESULT[2] = n; RESULT[3] = 0;
    bd_callfn_stk((u32)s13, ST + 0x100 * n, DST, 0);
    RESULT[1] = n; MARK(0x10 + n);
  }
  MARK(0xFE);
  for (;;) {}
}
