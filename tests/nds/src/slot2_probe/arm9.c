/* slot2_probe ARM9: reads the GBA slot (slot 2) under each EXMEMCNT setting,
   from both CPUs, plus what each slot-2 device answers, and draws the 72
   result words as hex on the top screen (3 columns x 24 rows, read left to
   right, top to bottom). The bottom screen turns white when the run is
   complete; then the Rumble Pak latch flips once a frame for 30 frames. docs/nds/slot2.md lists every word; the same words are left at
   0x02200100 (slot2.h RES) for tests to read.

   GBATEK: "DS Memory Control - Cartridges and Main RAM" (EXMEMCNT, open
   bus), "DS Cart Rumble Pak" (detection loop), "DS Cart Expansion RAM"
   (lock register), "GBA Cart Backup Flash ROM" (ID command). */
#include "../common2d/nds2d.h"
#include "slot2.h"

#define EXMEMCNT REG16(0x04000204)
#define LCDC ((volatile u16 *)0x06800000)

static int nres;
static void put(u32 v) { RES[nres++] = v; }

static u32 h(u32 a) { return *(volatile u16 *)a; }
static u32 b(u32 a) { return *(volatile u8 *)a; }
static u32 w(u32 a) { return *(volatile u32 *)a; }

static u32 seq = 0x100;
static void arm7(u32 cmd, u32 arg) {
  ARG = (cmd << 16) | arg;
  CMD = ++seq;
  while (DONE != seq) {}
}

static void draw_hex(int col, int row, u32 v) {
  for (int d = 0; d < 8; d++) {
    int digit = (v >> (28 - 4 * d)) & 15;
    int t = font_index("0123456789ABCDEF"[digit]);
    for (int y = 0; y < 8; y++) {
      int bits = glyph_bits(t, y);
      for (int x = 0; x < 8; x++)
        LCDC[(row * 8 + y) * 256 + col * 64 + d * 8 + x] =
            (bits >> x) & 1 ? 0x7FFF : (((row + col) & 1) ? 0x0C63 : 0x2108);
    }
  }
}

int main(void) {
  POWCNT1 = 0x8203;
  VRAMCNT(0) = 0x80;             /* bank A at LCDC */
  DISPCNT_A = 0x00020000;        /* VRAM display, bank A */
  DISPCNT_B = 0x00010000;        /* backdrop only */
  PAL_B_BG[0] = 0x0010;
  for (int i = 0; i < 256 * 192; i++) LCDC[i] = 0;
  for (int i = 0; i <= RES_N; i++) RES[i] = 0;
  DONE = 0;

  /* 0-19: ROM region, ARM9 owner, first access 10/8/6/18 (bits 2-3), then
     10 with the 4-cycle second access (bit 4) */
  for (u32 s = 0; s < 5; s++) {
    EXMEMCNT = 0x6000 | (s < 4 ? s << 2 : 0x10);
    put(h(0x08000000));
    put(h(0x0800ABCE));
    put(h(0x09FFFFFE));
    put(w(0x08000100));
  }
  /* 20-23: SRAM region (8-bit bus) */
  EXMEMCNT = 0x6000;
  put(b(0x0A000000));
  put(h(0x0A000002));
  put(w(0x0A000004));
  put(b(0x0A012345));
  /* 24-26: the ARM9 after giving the slot to the ARM7 */
  EXMEMCNT = 0x6080;
  put(h(0x08000000));
  put(w(0x08001000));
  put(b(0x0A000000));
  /* 27-34: the ARM7 owning it, its EXMEMSTAT first access 10/8/6/18:
     halfwords at 0x08000000 and 0x0800ABCE */
  for (u32 s = 0; s < 4; s++) {
    arm7(C7_READ, s << 2);
    put(A7RES[0]);
    put(A7RES[1]);
  }
  /* 35: its SRAM byte; 36: its EXMEMSTAT readback (ARM9 bits 7-15 + its
     own 0-6); 37: the ARM9's EXMEMCNT after writing 0080h (bit 14 too) */
  arm7(C7_READ, 0x0C);
  put(A7RES[2]);
  put(A7RES[3]);
  EXMEMCNT = 0x0080;
  put(EXMEMCNT);
  /* 38: the ARM7 not owning it */
  EXMEMCNT = 0x6000;
  arm7(C7_READ, 0);
  put(A7RES[0]);
  /* 39-44: ARM9 cycles for 16 LDRH of 0x08000000, settings as 0-19 plus
     6 cycles first + 4 second */
  for (u32 s = 0; s < 4; s++) {
    EXMEMCNT = 0x6000 | (s << 2);
    put(time16_ldrh(0x08000000));
  }
  EXMEMCNT = 0x6010;
  put(time16_ldrh(0x08000000));
  EXMEMCNT = 0x6018;
  put(time16_ldrh(0x08000000));
  /* 45-48: ARM9 cycles for 16 LDRB of 0x0A000000, SRAM 10/8/6/18 */
  for (u32 s = 0; s < 4; s++) {
    EXMEMCNT = 0x6000 | s;
    put(time16_ldrb(0x0A000000));
  }
  /* 49-52: ARM7 cycles for 16 LDRH, its first access 10/8/6/18 */
  EXMEMCNT = 0x6080;
  for (u32 s = 0; s < 4; s++) {
    arm7(C7_READ, s << 2);
    put(A7RES[4]);
  }
  /* 53: Rumble Pak detection (GBATEK): halfwords i of 0..FFFh reading
     (i AND FFFDh), at the 6-cycle first access */
  EXMEMCNT = 0x6008;
  u32 match = 0;
  for (u32 i = 0; i < 0x1000; i++)
    if (h(0x08000000 + i * 2) == (i & 0xFFFD)) match++;
  put(match);
  /* 54-57: the header area words B0h-BCh (a GBA cart's maker code, 96h,
     unit/device, version/checksum) */
  for (u32 i = 0; i < 4; i++) put(w(0x080000B0 + 4 * i));
  /* 58-62: Expansion Pak RAM at 0x09000000: as found, after a locked
     write, after unlocking (STRH 1 to 0x08240000) and writing, after a byte
     store to the odd byte, after locking and writing again */
  put(h(0x09000000));
  *(volatile u16 *)0x09000000 = 0x1234;
  put(h(0x09000000));
  *(volatile u16 *)0x08240000 = 1;
  *(volatile u16 *)0x09000000 = 0x5678;
  put(h(0x09000000));
  *(volatile u8 *)0x09000001 = 0xAB;
  put(h(0x09000000));
  *(volatile u16 *)0x08240000 = 0;
  *(volatile u16 *)0x09000000 = 0x9999;
  put(h(0x09000000));
  /* 63: the GBA game code; 64: the FLASH chip ID (AAh/55h/90h, then the
     two ID bytes, then F0h to leave ID mode) as maker | device << 8 */
  EXMEMCNT = 0x6000;
  put(w(0x080000AC));
  *(volatile u8 *)0x0A005555 = 0xAA;
  *(volatile u8 *)0x0A002AAA = 0x55;
  *(volatile u8 *)0x0A005555 = 0x90;
  put(b(0x0A000000) | (b(0x0A000001) << 8));
  *(volatile u8 *)0x0A005555 = 0xAA;
  *(volatile u8 *)0x0A002AAA = 0x55;
  *(volatile u8 *)0x0A005555 = 0xF0;
  /* 65-67: what the boot left at 0x027FFC30 about the GBA slot */
  for (u32 i = 0; i < 3; i++) put(w(0x027FFC30 + 4 * i));
  /* 68: EXMEMCNT after writing FFFFh; 69: the ARM7's EXMEMSTAT after it
     writes FFFFh (ARM9 bits then 0x6880: slot 2 and card to the ARM9) */
  EXMEMCNT = 0xFFFF;
  put(EXMEMCNT);
  EXMEMCNT = 0x6000;
  arm7(C7_EXMEM_ALL, 0);
  put(A7RES[0]);
  /* 70: SRAM byte after the FLASH ID sequence (data again);
     71: the halfword past a 16 MB GBA ROM, at 10 cycles */
  put(b(0x0A000000));
  put(h(0x09000002));
  /* 72-76: Expansion Pak lock: unlock and read back the halfword written
     while locked (item 62); lock and read a halfword never written; the
     halfword past the 8 MB of RAM; the lock register's address; a word
     store while unlocked, read back as a word */
  *(volatile u16 *)0x08240000 = 1;
  put(h(0x09000000));
  *(volatile u16 *)0x08240000 = 0;
  put(h(0x09000002));
  put(h(0x09800000));
  put(h(0x08240000));
  *(volatile u16 *)0x08240000 = 1;
  *(volatile u32 *)0x09000010 = 0x89ABCDEF;
  put(w(0x09000010));
  /* 77-79: a GBA cart's GPIO port (GBATEK "GBA Cart I/O Port"): C4h-C8h
     with the port write-only, then readable (C8h = 1), then direction 0Fh
     and data 05h read back */
  put(w(0x080000C4) & 0xFFFF);
  *(volatile u16 *)0x080000C8 = 1;
  put(w(0x080000C4));
  *(volatile u16 *)0x080000C6 = 0x0F;
  *(volatile u16 *)0x080000C4 = 0x05;
  put(w(0x080000C4));
  *(volatile u16 *)0x080000C6 = 0;
  *(volatile u16 *)0x080000C8 = 0;

  /* 80-81: control for 39-52: 16 LDRH of main RAM, ARM9 then ARM7 (the
     loop's own fetch cost, so the slot's share can be read off) */
  put(time16_ldrh(0x02100000));
  EXMEMCNT = 0x6000;
  arm7(C7_READ, 0);
  put(A7RES[5]);

  RES[RES_N] = RES_MAGIC;
  for (int i = 0; i < RES_N; i++) draw_hex(i % 4, i / 4, RES[i]);
  PAL_B_BG[0] = 0x7FFF;
  /* then the Rumble Pak's actuator (libnds rumbleSet: AD1 of a halfword
     store to 0x08001000) flips once a frame for 30 frames, then rests */
  for (u32 f = 0; f < 30; f++) {
    wait_vblank();
    *(volatile u16 *)0x08001000 = (u16)((f & 1) << 1);
  }
  *(volatile u16 *)0x08001000 = 0;
  for (;;) {}
}
