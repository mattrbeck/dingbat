/* save_write: a boot counter in the card's save chip, for the web app's
   end-to-end save test (web/e2e/nds.e2e.mjs). No library.

   Each boot reads 8 bytes at address 0 of a 0.5K EEPROM, counts up the
   boot count it finds there ("DGB" + count, else 0), and writes it back
   ("DGB", count, then 4 bytes of count ^ 0xA5 + i). The top screen's
   backdrop says what it saw: green after the first boot, blue after the
   second, white after later ones, red if the write did not read back.

   Card SPI (GBATEK "DS Cartridge Backup"): AUXSPICNT 0x040001A0 bit 15
   slot enable, bit 13 backup SPI mode, bit 7 busy, bit 6 hold chip select
   (clear for a command's last byte); AUXSPIDATA 0x040001A2. EEPROM 0.5K
   commands: WREN 06h, RDSR 05h (bit 0 write in progress), RDLO 03h and
   WRLO 02h with one address byte (16-byte pages). EXMEMCNT 0x04000204
   bit 11 = 0 gives the ARM9 the slot. The chip's type is never asked: the
   test starts it with a 512-byte save, whose size names it. */

#include "../common2d/nds2d.h"

#define EXMEMCNT   REG16(0x04000204)
#define AUXSPICNT  REG16(0x040001A0)
#define AUXSPIDATA REG16(0x040001A2)

static u8 xfer(u8 v, int hold)
{
	AUXSPICNT = 0xA000 | (hold ? 0x40 : 0);
	AUXSPIDATA = v;
	while (AUXSPICNT & 0x80) {}
	return (u8)AUXSPIDATA;
}

static void read8(u8 *buf)
{
	xfer(0x03, 1);
	xfer(0x00, 1);
	for (int i = 0; i < 8; i++) buf[i] = xfer(0x00, i < 7);
}

int main(void)
{
	u8 buf[8], data[8];
	EXMEMCNT &= ~0x0800;

	read8(buf);
	int count = (buf[0] == 'D' && buf[1] == 'G' && buf[2] == 'B') ? buf[3] : 0;
	count = (count + 1) & 0xFF;
	data[0] = 'D'; data[1] = 'G'; data[2] = 'B'; data[3] = (u8)count;
	for (int i = 4; i < 8; i++) data[i] = (u8)((count ^ 0xA5) + i);

	xfer(0x06, 0);                           /* WREN */
	xfer(0x02, 1);                           /* WRLO at 0 */
	xfer(0x00, 1);
	for (int i = 0; i < 8; i++) xfer(data[i], i < 7);
	for (int n = 0; n < 100000; n++) {       /* until the write is done */
		xfer(0x05, 1);
		if (!(xfer(0x00, 0) & 1)) break;
	}

	read8(buf);
	int ok = 1;
	for (int i = 0; i < 8; i++) if (buf[i] != data[i]) ok = 0;

	POWCNT1 = 0x8003;                        /* LCDs, engine A on top */
	DISPCNT_A = 0x00010000;                  /* graphics mode, no layers */
	PAL_A_BG[0] = !ok ? 0x001F : count == 1 ? 0x03E0 : count == 2 ? 0x7C00 : 0x7FFF;
	for (;;) {}
}
