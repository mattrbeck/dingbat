// Probe: SoundDriverMain's calls into the game (SoundInfo +0x20 with +0x24,
// then +0x28) for callees of every region and ISA: ARM/Thumb in IWRAM,
// EWRAM and ROM, and the BIOS's own 0x1709, under WAITCNT 0 and 0x4317.
// Each callee stamps itself with one store (BD_MEMTRACE=all shows when).
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
#define SI(o) REG32((u32)AREA + (o))

#define CB(name, sect, isa, slot) \
  __attribute__((section(sect), target(isa), noinline)) \
  void name(u32 arg) { RESULT[slot] = arg; }
CB(a_iw, ".iwram", "arm", 32)
CB(t_iw, ".iwram", "thumb", 33)
CB(a_ew, ".ewram", "arm", 34)
CB(t_ew, ".ewram", "thumb", 35)
CB(a_rom, ".text", "arm", 36)
CB(t_rom, ".text", "thumb", 37)

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

typedef void (*fnp)(u32);
static const fnp fns[] = {a_iw, t_iw, a_ew, t_ew, a_rom, t_rom, (fnp)0x1709};

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  Q(); bd_swi_28(0, 0, 0, 0);
  for (u32 w = 0; w < 2; w++) {
    REG16(0x04000204) = w ? 0x4317 : 0;
    for (u32 i = 0; i < 7; i++) {
      // as the +0x20 callback (with the default +0x28)
      SI(0x20) = (u32)fns[i]; SI(0x24) = 0x100 + i; SI(0x28) = 0x1709;
      Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
      // as the +0x28 callback alone
      SI(0x20) = 0; SI(0x28) = (u32)fns[i];
      Q(); bd_swi_1C(0, 0, 0, 0); mark_state(step++);
    }
  }
  MARK(0xFE);
  for (;;) {}
}
