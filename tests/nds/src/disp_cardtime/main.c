// disp_cardtime: how long slot-1 ROM reads (command B7, KEY2 main mode
// after a direct boot) take, by the ARM9 polling ROMCTRL (GBATEK "DS
// Cartridge I/O Ports": bit 23 data ready, bit 31 busy; "DS Cartridge
// Protocol": 8 command bytes, gap1, data at 5 or 8 bus cycles a byte,
// gap2 per 200h with bit 28). A cascaded timer counts bus cycles (33.51 MHz).
// Each row: name, cycles to the first word, cycles to the end (hex);
// a ROMCTRL setting is the header's normal one (027FFE60h) with:
//   W4    4 bytes                   B200  200h bytes
//   B1K   1000h bytes               G1    gap1 = 657h (the commercial games')
//   CLK8  bit 27 (8 cycles a byte)  GAP2  bit 28, gap2 = 18h, 1000h bytes
// The rows repeat once (R2) to show the timing does not drift. Then the
// same reads by DMA (channel 0, start mode 5 "DS Cartridge Slot", one word
// per request, repeat, source fixed), first-word column = 0:
//   D200  200h bytes   DG1  200h with gap1 = 657h   D1K  1000h bytes
// The card's words go to 0x02200000. From frame 60, page 2 ("P2"): the
// G1 read with the CPU polling only after a delay (see card_read_late).
// Built with build_3d.sh (disp_* ROMs).
#include "t3d.h"
#include "tm.h"

#define EXMEMCNT R16(0x04000204)
#define AUXSPICNT R16(0x040001A0)
#define ROMCTRL R32(0x040001A4)
#define CARDCMD ((vu8 *)0x040001A8)
#define CARDDATA R32(0x04100010)

static u32 first_word, total;

static void card_dma(u32 addr, u32 ctrl) {
  CARDCMD[0] = 0xB7;
  CARDCMD[1] = addr >> 24;
  CARDCMD[2] = addr >> 16;
  CARDCMD[3] = addr >> 8;
  CARDCMD[4] = addr;
  CARDCMD[5] = 0;
  CARDCMD[6] = 0;
  CARDCMD[7] = 0;
  DMA_SAD(0) = 0x04100010;
  DMA_DAD(0) = 0x02200000;
  // enable, start mode 5 (card), 32-bit, repeat, source fixed, 1 word
  DMA_CNT(0) = (1u << 31) | (5u << 27) | (1u << 26) | (1u << 25) | (2u << 23) | 1;
  u32 t0 = clock_now();
  ROMCTRL = ctrl;
  while (ROMCTRL & (1u << 31)) {}
  total = clock_now() - t0;
  DMA_CNT(0) = 0;
  first_word = 0;
}

static void card_read(u32 addr, u32 ctrl, int words) {
  CARDCMD[0] = 0xB7;
  CARDCMD[1] = addr >> 24;
  CARDCMD[2] = addr >> 16;
  CARDCMD[3] = addr >> 8;
  CARDCMD[4] = addr;
  CARDCMD[5] = 0;
  CARDCMD[6] = 0;
  CARDCMD[7] = 0;
  vu32 *dst = (vu32 *)0x02200000;
  u32 t0 = clock_now();
  ROMCTRL = ctrl;
  int n = 0;
  first_word = 0;
  while (ROMCTRL & (1u << 31)) {
    if (ROMCTRL & (1u << 23)) {
      u32 w = CARDDATA;
      if (n == 0) first_word = clock_now() - t0;
      if (n < words) dst[n] = w;
      n++;
    }
  }
  total = clock_now() - t0;
}

// The same 200h-byte read, but the CPU starts polling only `delay` bus
// cycles after the ROMCTRL write: does the card wait at each word until it
// is read (one data latch), or run on into a buffer?
static void card_read_late(u32 addr, u32 ctrl, u32 delay) {
  CARDCMD[0] = 0xB7;
  CARDCMD[1] = addr >> 24;
  CARDCMD[2] = addr >> 16;
  CARDCMD[3] = addr >> 8;
  CARDCMD[4] = addr;
  CARDCMD[5] = 0;
  CARDCMD[6] = 0;
  CARDCMD[7] = 0;
  u32 t0 = clock_now();
  ROMCTRL = ctrl;
  while (clock_now() - t0 < delay) {}
  int n = 0;
  first_word = 0;
  while (ROMCTRL & (1u << 31)) {
    if (ROMCTRL & (1u << 23)) {
      (void)CARDDATA;
      if (n == 0) first_word = clock_now() - t0;
      n++;
    }
  }
  total = clock_now() - t0;
}

int main(void) {
  t3d_init("disp_cardtime: card read timing");
  icache_on();
  EXMEMCNT &= ~(1u << 11);                 // slot 1 to the ARM9
  AUXSPICNT = 0x8000;                      // slot enabled, ROM mode, no IRQ
  clock_start();
  u32 normal = R32(0x027FFE60);
  t3d_print(0, 2, "NORMAL");
  t3d_hex(8, 2, normal, 8);
  // keep the KEY2 bits (13, 14, 22) and gap2, replace gap1/CLK/bit 28;
  // start (31), release reset (29), block size in bits 24-26
  u32 base = (normal & 0x003F6000u) | (1u << 31) | (1u << 29);
  static const char *names[6] = {"W4", "B200", "B1K", "G1", "CLK8", "GAP2"};
  u32 ctrl[6] = {
    base | (7u << 24) | (normal & 0x1FFF),
    base | (1u << 24) | (normal & 0x1FFF),
    base | (4u << 24) | (normal & 0x1FFF),
    base | (1u << 24) | 0x657,
    base | (1u << 24) | (normal & 0x1FFF) | (1u << 27),
    (base & ~0x003F0000u) | (0x18u << 16) | (4u << 24) | (normal & 0x1FFF) | (1u << 28),
  };
  int words[6] = {1, 128, 1024, 128, 128, 1024};
  for (int pass = 0; pass < 2; pass++)
    for (int i = 0; i < 6; i++) {
      card_read(0x8000 + 0x200 * i, ctrl[i], words[i]);
      int row = 4 + pass * 7 + i;
      t3d_print(0, row, names[i]);
      if (pass) t3d_print(5, row, "R2");
      t3d_hex(8, row, first_word, 6);
      t3d_hex(16, row, total, 6);
    }
  static const char *dnames[3] = {"D200", "DG1", "D1K"};
  u32 dctrl[3] = {ctrl[1], ctrl[3], ctrl[2]};
  for (int i = 0; i < 3; i++) {
    card_dma(0x8000 + 0x200 * i, dctrl[i]);
    t3d_print(0, 18 + i, dnames[i]);
    t3d_hex(16, 18 + i, total, 6);
  }
  t3d_print(0, 22, "DONE");
  for (int f = 0; f < 60; f++) wait_vblank();
  // page 2 (frame 60 on): late polling, gap1 = 657h, 200h bytes; columns:
  // the delay, the first word's time, the end
  for (int r = 0; r < 24; r++) t3d_print(0, r, "                                ");
  t3d_print(0, 0, "P2 LATE POLL G1");
  static const u32 delays[6] = {0, 0x1000, 0x2000, 0x3000, 0x4000, 0x8000};
  for (int i = 0; i < 6; i++) {
    card_read_late(0x8000 + 0x200 * i, ctrl[3], delays[i]);
    t3d_hex(0, 2 + i, delays[i], 6);
    t3d_hex(8, 2 + i, first_word, 6);
    t3d_hex(16, 2 + i, total, 6);
  }
  t3d_print(0, 22, "DONE");
  while (1) wait_vblank();
}
