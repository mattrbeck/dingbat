/* fw_power ARM7: writes the firmware's user settings once a boot, then
   powers the DS off when START is pressed. No library. For the web app's
   end-to-end tests (web/e2e/nds.e2e.mjs: the firmware a game wrote survives
   a reload; the app shows a console the game switched off, and Restart).

   Firmware flash (GBATEK "DS Firmware Serial Flash Memory", "DS Firmware
   User Settings"): SPICNT device 1 at 4 MHz, chip select held (bit 11) for
   every byte but a command's last. READ 03h + 3 address bytes; WREN 06h;
   page write 0Ah + address + 256 bytes (erase and program); RDSR 05h, bit 0
   = write in progress. The user settings are two 100h copies at
   [header 020h] * 8 (3FE00h on a DS); the current one is the CRC-valid copy
   whose update counter (070h) is one more than the other's. Each boot reads
   the current copy and writes it over the other one with the nickname
   "FWTEST<n>" (n = the boot count: one more than the digit an earlier boot
   left there, else 1), the counter one more, and the CRC16 (initial FFFFh)
   of 000h..06Fh at 072h.

   Power-off (GBATEK "DS Power Management Device"): register 0 bit 6, "DS
   System Power (0=Normal, 1=Shut Down)"; SPICNT device 0 at 1 MHz, the
   index byte held, then the value. */
#include "fw_power.h"

#define KEYINPUT REG16(0x04000130)
#define SPICNT REG16(0x040001C0)
#define SPIDATA REG16(0x040001C2)

#define FW_HOLD 0x8900
#define FW_LAST 0x8100
#define PM_HOLD 0x8802
#define PM_LAST 0x8002

static u8 spi_xfer(u16 cnt, u8 v) {
  SPICNT = cnt;
  SPIDATA = v;
  while (SPICNT & 0x80) {}
  return SPIDATA & 0xFF;
}

static void fw_cmd_addr(u8 cmd, u32 a) {
  spi_xfer(FW_HOLD, cmd);
  spi_xfer(FW_HOLD, (a >> 16) & 0xFF);
  spi_xfer(FW_HOLD, (a >> 8) & 0xFF);
  spi_xfer(FW_HOLD, a & 0xFF);
}

static void fw_read(u32 a, u8 *buf, int n) {
  fw_cmd_addr(0x03, a);
  for (int i = 0; i < n; i++) buf[i] = spi_xfer(i < n - 1 ? FW_HOLD : FW_LAST, 0);
}

static void fw_page_write(u32 a, const u8 *buf) {
  spi_xfer(FW_LAST, 0x06);                   /* WREN */
  fw_cmd_addr(0x0A, a);
  for (int i = 0; i < 256; i++) spi_xfer(i < 255 ? FW_HOLD : FW_LAST, buf[i]);
  spi_xfer(FW_HOLD, 0x05);                   /* RDSR until the write is done */
  while (spi_xfer(FW_HOLD, 0) & 1) {}
  spi_xfer(FW_LAST, 0);
}

static u16 crc16(const u8 *p, int n) {
  u16 crc = 0xFFFF;
  for (int i = 0; i < n; i++) {
    crc ^= p[i];
    for (int b = 0; b < 8; b++) crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
  }
  return crc;
}

static int crc_ok(const u8 *s) {
  return crc16(s, 0x70) == (u16)(s[0x72] | (s[0x73] << 8));
}

/* 1 if copy 1 is current, else 0 (GBATEK's rule; neither valid: copy 0) */
static int current(const u8 *s0, const u8 *s1) {
  int ok0 = crc_ok(s0), ok1 = crc_ok(s1);
  if (ok0 != ok1) return ok1;
  return ((s0[0x70] + 1) & 0x7F) == (s1[0x70] & 0x7F);
}

static u8 copies[2][256];
static u8 next[256];

static u32 settings_offset(void) {
  u8 h[2];
  fw_read(0x20, h, 2);
  u32 us = (u32)(h[0] | (h[1] << 8)) * 8;
  return (us == 0 || us + 0x200 > 0x40000) ? 0x3FE00 : us;
}

static void read_copies(u32 us) {
  fw_read(us, copies[0], 256);
  fw_read(us + 0x100, copies[1], 256);
}

int main(void) {
  for (int i = 0; i < 4; i++) RES[i] = 0;
  SPICNT = 0;
  u32 us = settings_offset();
  read_copies(us);
  int cur = current(copies[0], copies[1]);
  const u8 *s = copies[cur];
  static const char tag[] = "FWTEST";
  int count = 1;
  if ((s[0x1A] | (s[0x1B] << 8)) == 7) {
    int match = 1;
    for (int i = 0; i < 6; i++)
      if (s[0x06 + 2 * i] != (u8)tag[i] || s[0x07 + 2 * i] != 0) match = 0;
    u8 d = s[0x06 + 12];
    if (match && d >= '1' && d <= '9' && s[0x07 + 12] == 0) count = d - '0' + 1;
    if (count > 9) count = 9;
  }
  for (int i = 0; i < 256; i++) next[i] = s[i];
  for (int i = 0; i < 20; i++) next[0x06 + i] = 0;
  for (int i = 0; i < 6; i++) next[0x06 + 2 * i] = (u8)tag[i];
  next[0x06 + 12] = (u8)('0' + count);
  next[0x1A] = 7; next[0x1B] = 0;
  next[0x70] = (u8)((s[0x70] + 1) & 0x7F); next[0x71] = 0;
  u16 c = crc16(next, 0x70);
  next[0x72] = c & 0xFF; next[0x73] = c >> 8;
  fw_page_write(us + (cur ? 0 : 0x100), next);
  read_copies(us);
  int ok = current(copies[0], copies[1]) == !cur;
  for (int i = 0; i < 256; i++) if (copies[!cur][i] != next[i]) ok = 0;
  RES[1] = (u32)count;
  RES[2] = (u32)ok;
  RES[0] = RES_MAGIC;
  while (KEYINPUT & 0x0008) {}               /* START (bit 3, 0 = pressed) */
  spi_xfer(PM_HOLD, 0x80);                   /* read register 0 */
  u8 r0 = spi_xfer(PM_LAST, 0);
  spi_xfer(PM_HOLD, 0x00);                   /* write it back with bit 6 */
  spi_xfer(PM_LAST, r0 | 0x40);
  for (;;) {}
}
