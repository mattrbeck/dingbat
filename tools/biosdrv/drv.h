// BIOS sound-driver probe ROMs: shared declarations (see rt.s, build.py).
#ifndef DRV_H
#define DRV_H
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed char s8;
typedef volatile u8 vu8;
typedef volatile u16 vu16;
typedef volatile u32 vu32;

#define REG16(a) (*(vu16 *)(a))
#define REG32(a) (*(vu32 *)(a))
#define REG8(a) (*(vu8 *)(a))

#define DISPCNT REG16(0x04000000)
#define DISPSTAT REG16(0x04000004)
#define VCOUNT REG16(0x04000006)
#define SOUNDCNT_L REG16(0x04000080)
#define SOUNDCNT_H REG16(0x04000082)
#define SOUNDCNT_X REG16(0x04000084)
#define SOUNDBIAS REG16(0x04000088)
#define IE REG16(0x04000200)
#define IF REG16(0x04000202)
#define IME REG16(0x04000208)
#define IRQ_VECTOR REG32(0x03007FFC)

// Harness marker: a byte store here snapshots BD_SNAP regions (biosdrv_probe)
#define MARK(n) (REG8(0x04000FF0) = (u8)(n))

// Fixed work areas (clear of the crt0's .bss at the bottom of IWRAM)
#define AREA ((u8 *)0x03004000)       // SoundArea, 0xFB0 bytes
#define RESULT ((vu32 *)0x02030000)   // probe-written results

extern u32 bd_regs[8];
extern volatile u32 bd_irq_count;
extern volatile u32 bd_irq_vsync;
extern void bd_irq_handler(void);
extern void bd_callfn(u32 fn, u32 a, u32 b, u32 c);
#define W(n) extern u32 bd_swi_##n(u32 a, u32 b, u32 c, u32 d);
W(1A) W(1B) W(1C) W(1D) W(1E) W(1F) W(20) W(21) W(22) W(23) W(24) W(28) W(29) W(2A)
#undef W
#define T(n) extern u32 bd_tswi_##n(u32 a, u32 b, u32 c, u32 d);
T(1A) T(1B) T(1C) T(1D) T(1E) T(28) T(29)
#undef T
#define X(p, n) extern u32 p##_##n(u32 a, u32 b, u32 c, u32 d);
X(bd_aswi, 1A) X(bd_aswi, 1B) X(bd_aswi, 1D) X(bd_aswi, 28)
X(bd_eswi, 1A) X(bd_eswi, 1B) X(bd_eswi, 1D) X(bd_eswi, 28)
X(bd_etswi, 1A) X(bd_etswi, 1B) X(bd_etswi, 1D) X(bd_etswi, 28)
#undef X

static inline void irq_setup(u16 ie) {
  IME = 0;
  IRQ_VECTOR = (u32)bd_irq_handler;
  DISPSTAT = 1 << 3;  // V-blank IRQ
  IE = ie;
  IF = 0xFFFF;
  IME = 1;
}

static inline void vblank_wait(void) {
  u32 n = bd_irq_count;
  while (bd_irq_count == n) {}
}

static inline void fill32(void *p, u32 v, u32 bytes) {
  vu32 *w = (vu32 *)p;
  for (u32 i = 0; i < bytes / 4; i++) w[i] = v;
}
#endif
