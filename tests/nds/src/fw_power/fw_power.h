/* fw_power: shared layout between the ARM7 (firmware flash, power manager:
   arm7.c) and the ARM9 (the screens: arm9.c). */
#ifndef FW_POWER_H
#define FW_POWER_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#define REG8(a) (*(volatile u8 *)(a))

/* Main RAM outside both binaries: RES[0] = 'FWPW' once the ARM7 is done,
   RES[1] = the boot count it wrote into the nickname (1..9), RES[2] = 1 if
   the firmware read back as written (the new copy current, CRC valid). */
#define RES ((volatile u32 *)0x02200000)
#define RES_MAGIC 0x57505746u   /* "FWPW" */

#endif
