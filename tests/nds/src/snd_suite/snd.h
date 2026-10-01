/* snd_suite: shared layout between the ARM7 test sequencer (arm7.c) and the
   ARM9 result display (arm9.c). */
#ifndef SND_H
#define SND_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed char s8;
typedef signed short s16;
typedef signed int s32;

#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#define REG8(a) (*(volatile u8 *)(a))

#define VCOUNT REG16(0x04000006)

/* Results: the ARM7 writes RESULT_WORDS words here (main RAM, outside both
   binaries), the ARM9 draws them as bit rows. RES[0] = 'SNDT' when the run
   is complete. */
#define RES ((volatile u32 *)0x02200000)
#define RESULT_WORDS 24
#define RES_MAGIC 0x54444E53u

#endif
