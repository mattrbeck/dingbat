// Probe: which registers each driver SWI path sets and which it leaves.
// Every call enters with r1-r3 and r12 holding patterns (r0 the argument
// where the routine takes one); bd_regs catches them after (rt.s).
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
#define IDENT REG32((u32)AREA)
#define CNT REG8((u32)AREA + 4)

extern u32 bd_pswi(u32 n, u32 r0);   // below: swi n with patterned r1-r3/r12

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  Q(); bd_pswi(0x1A, (u32)AREA); mark_state(step++);
  Q(); bd_pswi(0x1B, 0x00000000); mark_state(step++);          // Mode, nothing
  Q(); bd_pswi(0x1B, 0x0000A87F); mark_state(step++);          // Mode, fields
  Q(); bd_pswi(0x1B, 0x00940000); mark_state(step++);          // Mode, rate
  CNT = 3; Q(); bd_pswi(0x1D, 0x55555555); mark_state(step++); // VSync dec
  CNT = 1; Q(); bd_pswi(0x1D, 0x55555555); mark_state(step++); // VSync reset
  Q(); bd_pswi(0x1E, 0x55555555); mark_state(step++);          // ChannelClear
  Q(); bd_pswi(0x28, 0x55555555); mark_state(step++);          // VSyncOff
  Q(); bd_pswi(0x29, 0x55555555); mark_state(step++);          // VSyncOn
  Q(); bd_pswi(0x1C, 0x55555555); mark_state(step++);          // Main
  // refusals: locked
  IDENT = 0x68736D55;
  Q(); bd_pswi(0x1D, 0x55555555); mark_state(step++);
  Q(); bd_pswi(0x1E, 0x55555555); mark_state(step++);
  Q(); bd_pswi(0x28, 0x55555555); mark_state(step++);
  Q(); bd_pswi(0x1B, 0x0000A87F); mark_state(step++);
  Q(); bd_pswi(0x1C, 0x55555555); mark_state(step++);
  IDENT = 0x68736D53;
  MARK(0xFE);
  for (;;) {}
}
