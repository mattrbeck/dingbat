/* slot2_probe ARM7: waits for commands from the ARM9 (slot2.h) and reads
   the GBA slot from this side. */
#include "slot2.h"

static void cmd_read(u32 setting) {
  /* the slot as the ARM7 sees it with EXMEMSTAT bits 0-6 = setting */
  EXMEM = (u16)setting;
  A7RES[0] = *(volatile u16 *)0x08000000;
  A7RES[1] = *(volatile u16 *)0x0800ABCE;
  A7RES[2] = *(volatile u8 *)0x0A000000;
  A7RES[3] = EXMEM;
  A7RES[4] = time16_ldrh(0x08000000);
  A7RES[5] = time16_ldrh(0x02100000);
}

int main(void) {
  u32 last = 0;
  for (;;) {
    u32 c = CMD;
    if (c == last) continue;
    last = c;
    switch (ARG >> 16) {
    case C7_READ: cmd_read(ARG & 0xFFFF); break;
    case C7_EXMEM_ALL:
      EXMEM = 0xFFFF;              /* only bits 0-6 are the ARM7's */
      A7RES[0] = EXMEM;
      EXMEM = 0;
      break;
    }
    DONE = c;
  }
}
