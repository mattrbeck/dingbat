/* periph_suite: shared layout between the ARM7 measurements (arm7.c) and
   the ARM9 display (arm9.c). */
#ifndef PERIPH_H
#define PERIPH_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed short s16;
typedef signed int s32;

#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#define REG8(a) (*(volatile u8 *)(a))

#define VCOUNT REG16(0x04000006)

/* Results: the ARM7 writes RESULT_WORDS words here (main RAM, outside both
   binaries); the ARM9 draws them as bit rows, 4 pixels high, bit 31
   leftmost, 8 pixels per bit (white = 1). RES[0] = 'PERI' once the main
   sections are done, RES[RESULT_WORDS - 1] = 'LIDS' after the lid one. */
#define RES ((volatile u32 *)0x02200000)
#define RESULT_WORDS 48
#define RES_MAGIC 0x49524550u   /* "PERI" */
#define LID_MAGIC 0x5344494Cu   /* "LIDS" */

/* ARM9 V-blank count (the ARM7 reads it around its sleeps) and the
   microphone capture (256 8-bit AUX samples) the ARM9 plots. */
#define FRAME9 (*(volatile u32 *)0x02200100)
#define MICBUF ((volatile u8 *)0x02201000)
#define MIC_SAMPLES 256

#endif
