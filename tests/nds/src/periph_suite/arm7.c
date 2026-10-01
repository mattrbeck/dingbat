/* periph_suite ARM7: the system peripherals measured from the ARM7 side and
   posted to RES (periph.h) for the ARM9 to draw. Times are in bus cycles
   (33.51 MHz) from timers 0+1 cascaded; every measurement includes the
   same polling code on every runner, so runs compare one to one.

   Timeline (frames of 560190 bus cycles from the timers' start, so long
   sections don't lose count); the presses are the
   ones tests/nds_periph_test.nim and the reference runs give:
     start   SPI busy times and IRQ, SPIDATA during a transfer, 16-bit
             mode, RCNT, power manager registers, TSC channels (released),
             firmware flash ID/status/page-program busy
     60      TSC with the pen down      (--press TOUCH:128:96@50-80)
     90      microphone, 256 AUX samples at 16 kHz (ndsrun --mic)
     100     RTC: 1 Hz and 16 Hz interrupt periods, 2+8 Hz falls in a
             second, alarm 1, the adjust register
     after   sleep until A               (--press A@600+4)
     then    sleep until the lid opens   (--press LID@660-700)

   RES words (ndsrun --peek9 0x02200000.. or the drawn rows):
     0  'PERI'            1-4  PM busy at baud 0-3
     5  write -> IF.23    6    SPICNT at that IF (busy bit) | IF.23 after ack
     7  SPIDATA right after the write | after the wait << 8
     8  16-bit busy (TSC, baud 2)     9  8-bit busy (TSC, baud 2)
     10 RCNT after 8000h | after 8100h << 16
     11 RCNT after 80F0h | after 80FFh << 16
     12 PM regs 0-3 (bytes)  13 PM regs 4-7  14 PM regs 8-11
     15 PM: reg2, reg3 after FFh; reg0 after 8Dh, after 0Fh (bytes)
     16 TSC TEMP0 | TEMP1 << 16      17 battery | AUX (amp on, gain 160)
     18 differential TEMP0 | AUX     19 Y | X released
     20 Z1 | Z2 released             21 8-bit TEMP0 | 8-bit AUX
     22 EXTKEYIN released after a PD0 | after a PD1 command << 16
     23 Y | X pressed                24 Z1 | Z2 pressed
     25 EXTKEYIN pressed after PD0 | after PD1 << 16
     26 1 Hz period    27 16 Hz period    28 2+8 Hz falls in one second
     29 time write 23:59:58 -> alarm 1 (00:00) IF.7
     30 status 1 after the alarm | status 1 read again << 8
     31 RCNT with the alarm pending | after INT1AE cleared << 16
     32 adjust register after writing 3Fh
     33 flash RDID (3 bytes)    34 RDSR after WREN | after WRDI << 8
     35 page program (FFh to 3FD00h, changes nothing) busy
     36 first RDSR after it
     37 timer during sleep    38 ARM9 frames during sleep   39 IF after
     40 ARM9 frames during the lid sleep    41 IF after
     42 mic min | max << 8 | mid-crossings << 16
     47 'LIDS' */
#include "periph.h"

#define TM0D REG16(0x04000100)
#define TM0C REG16(0x04000102)
#define TM1D REG16(0x04000104)
#define TM1C REG16(0x04000106)
#define KEYCNT REG16(0x04000132)
#define RCNT REG16(0x04000134)
#define EXTKEYIN REG16(0x04000136)
#define RTCIO REG16(0x04000138)
#define SPICNT REG16(0x040001C0)
#define SPIDATA REG16(0x040001C2)
#define IME REG32(0x04000208)
#define IE REG32(0x04000210)
#define IF REG32(0x04000214)
#define HALTCNT REG8(0x04000301)

#define SEC 33513982u
#define IRQ_SIO (1u << 7)
#define IRQ_KEY (1u << 12)
#define IRQ_LID (1u << 22)
#define IRQ_SPI (1u << 23)

static u32 now(void) {
  u16 h, l, h2;
  do { h = TM1D; l = TM0D; h2 = TM1D; } while (h != h2);
  return ((u32)h << 16) | l;
}

#define FRAME_CYCLES 560190u     /* 355 dots x 263 lines x 6 */
static void until(u32 f) { while (now() / FRAME_CYCLES < f) {} }

static void delay(int n) { for (volatile int i = 0; i < n; i++) {} }

/* --- SPI ------------------------------------------------------------------ */

static void spi_wait(void) { while (SPICNT & 0x80) {} }
static u8 spi_xfer(u16 cnt, u8 v) {
  SPICNT = cnt;
  SPIDATA = v;
  spi_wait();
  return SPIDATA & 0xFF;
}
static u32 spi_time(u16 cnt, u8 v) {
  SPICNT = cnt;
  u32 t0 = now();
  SPIDATA = v;
  spi_wait();
  return now() - t0;
}

static u8 pm_read(int reg) {
  spi_xfer(0x8802, 0x80 | reg);
  return spi_xfer(0x8002, 0);
}
static void pm_write(int reg, u8 v) {
  spi_xfer(0x8802, reg);
  spi_xfer(0x8002, v);
}

static u32 tsc(u8 ctl) {
  spi_xfer(0x8A01, ctl);
  u32 hi = spi_xfer(0x8A01, 0);
  u32 lo = spi_xfer(0x8201, 0);
  return (ctl & 8) ? (((hi << 1) | (lo >> 7)) & 0xFF) : (((hi << 5) | (lo >> 3)) & 0xFFF);
}

/* --- RTC (GBATEK "DS Real-Time Clock": LSB first, CS high, /SCK) ----------- */

static void rtc_out(u8 b) {
  for (int i = 0; i < 8; i++) {
    u16 bit = (b >> i) & 1;
    RTCIO = 0x74 | bit;          /* CS, /SCK low, data */
    delay(8);
    RTCIO = 0x76 | bit;          /* /SCK high */
    delay(8);
  }
}
static u8 rtc_in(void) {
  u8 v = 0;
  for (int i = 0; i < 8; i++) {
    RTCIO = 0x64;
    delay(8);
    RTCIO = 0x66;
    delay(8);
    v |= (RTCIO & 1) << i;
  }
  return v;
}
static void rtc_begin(u8 cmd) {
  RTCIO = 0x72;                  /* CS low, /SCK high */
  delay(8);
  RTCIO = 0x76;                  /* CS high */
  delay(8);
  rtc_out(cmd);
}
static void rtc_end(void) { RTCIO = 0x72; delay(8); }
static void rtc_write(int reg, const u8 *p, int n) {
  rtc_begin(0x06 | (reg << 4));
  for (int i = 0; i < n; i++) rtc_out(p[i]);
  rtc_end();
}
static void rtc_write1(int reg, u8 v) { rtc_write(reg, &v, 1); }
static u8 rtc_read1(int reg) {
  rtc_begin(0x86 | (reg << 4));
  u8 v = rtc_in();
  rtc_end();
  return v;
}

/* wait for IF.7 (acknowledging it), at most `limit` cycles; the time it took */
static u32 wait_sio(u32 limit) {
  u32 t0 = now();
  for (;;) {
    u32 t = now() - t0;
    if (IF & IRQ_SIO) { IF = IRQ_SIO; return t; }
    if (t > limit) return 0xFFFFFFFFu;
  }
}

/* --- sections --------------------------------------------------------------- */

static void spi_section(void) {
  for (int b = 0; b < 4; b++) {
    RES[1 + b] = spi_time(0x8800 | b, 0x80);   /* PM index byte, held */
    spi_xfer(0x8000 | b, 0);
  }
  /* IF.23: write -> flag */
  IF = IRQ_SPI;
  SPICNT = 0xC802;
  u32 t0 = now();
  SPIDATA = 0x80;
  while (!(IF & IRQ_SPI)) {}
  u32 t1 = now();
  u16 c = SPICNT;
  IF = IRQ_SPI;
  RES[5] = t1 - t0;
  spi_xfer(0x8002, 0);
  RES[6] = c | ((IF & IRQ_SPI) ? 0x10000u : 0);
  /* SPIDATA during a transfer: the last reply was register 0 (0Dh); this
     transfer's reply is 0 */
  pm_read(0);
  SPICNT = 0x8802;
  SPIDATA = 0x80;
  u32 during = SPIDATA & 0xFF;
  spi_wait();
  RES[7] = during | ((SPIDATA & 0xFF) << 8);
  spi_xfer(0x8002, 0);
  RES[8] = spi_time(0x8602, 0);              /* TSC, 16-bit, baud 2 */
  RES[9] = spi_time(0x8202, 0);
}

static void rcnt_section(void) {
  RCNT = 0x8000; u32 a = RCNT;
  RCNT = 0x8100; u32 b = RCNT;
  RES[10] = a | (b << 16);
  RCNT = 0x80F0; a = RCNT;
  RCNT = 0x80FF; b = RCNT;
  RES[11] = a | (b << 16);
  RCNT = 0x8000;
}

static void pm_section(void) {
  for (int k = 0; k < 3; k++) {
    u32 w = 0;
    for (int i = 0; i < 4; i++) w |= (u32)pm_read(k * 4 + i) << (8 * i);
    RES[12 + k] = w;
  }
  pm_write(2, 0xFF);
  pm_write(3, 0xFF);
  u32 r2 = pm_read(2), r3 = pm_read(3);
  u8 r0 = pm_read(0);
  pm_write(0, 0x8D);
  u32 a = pm_read(0);
  pm_write(0, 0x0F);
  u32 b = pm_read(0);
  pm_write(0, r0);
  RES[15] = r2 | (r3 << 8) | (a << 16) | (b << 24);
  pm_write(2, 1);                            /* mic amp on, gain 160 */
  pm_write(3, 3);
}

static void tsc_section(int pressed) {
  if (!pressed) {
    RES[16] = tsc(0x84) | (tsc(0xF4) << 16);
    RES[17] = tsc(0xA4) | (tsc(0xE4) << 16);
    RES[18] = tsc(0x80) | (tsc(0xE0) << 16);
    RES[19] = tsc(0x90) | (tsc(0xD0) << 16);
    RES[20] = tsc(0xB0) | (tsc(0xC0) << 16);
    RES[21] = tsc(0x8C) | (tsc(0xEC) << 16);
  } else {
    RES[23] = tsc(0x90) | (tsc(0xD0) << 16);
    RES[24] = tsc(0xB0) | (tsc(0xC0) << 16);
  }
  tsc(0x84);
  u32 a = EXTKEYIN;
  tsc(0x85);
  u32 b = EXTKEYIN;
  tsc(0x84);
  RES[pressed ? 25 : 22] = a | (b << 16);
}

static void flash_section(void) {
  spi_xfer(0x8900, 0x9F);
  u32 id = spi_xfer(0x8900, 0);
  id |= (u32)spi_xfer(0x8900, 0) << 8;
  id |= (u32)spi_xfer(0x8100, 0) << 16;
  RES[33] = id;
  spi_xfer(0x8100, 0x06);                    /* WREN */
  spi_xfer(0x8900, 0x05);
  u32 s1 = spi_xfer(0x8100, 0);
  spi_xfer(0x8100, 0x04);                    /* WRDI */
  spi_xfer(0x8900, 0x05);
  u32 s2 = spi_xfer(0x8100, 0);
  RES[34] = s1 | (s2 << 8);
  /* page program FFh at 3FD00h: programming can only clear bits, so this
     leaves the firmware as it was */
  spi_xfer(0x8100, 0x06);
  spi_xfer(0x8900, 0x02);
  spi_xfer(0x8900, 0x03);
  spi_xfer(0x8900, 0xFD);
  spi_xfer(0x8900, 0x00);
  spi_xfer(0x8100, 0xFF);
  u32 t0 = now();
  spi_xfer(0x8900, 0x05);
  u32 first = spi_xfer(0x8900, 0);
  u32 st = first;
  while ((st & 1) && now() - t0 < SEC) st = spi_xfer(0x8900, 0);
  RES[35] = now() - t0;
  spi_xfer(0x8100, 0);
  RES[36] = first;
}

static void mic_section(void) {
  u32 t = now();
  for (int i = 0; i < MIC_SAMPLES; i++) {
    while (now() - t < SEC / 16000) {}
    t += SEC / 16000;
    MICBUF[i] = (u8)tsc(0xEC);
  }
  u32 lo = 255, hi = 0, cross = 0;
  for (int i = 0; i < MIC_SAMPLES; i++) {
    u32 v = MICBUF[i];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
    if (i > 0 && MICBUF[i - 1] < 0x80 && v >= 0x80) cross++;
  }
  RES[42] = lo | (hi << 8) | (cross << 16);
}

static void rtc_section(void) {
  rtc_write1(0, 0x02);                       /* status 1: 24-hour */
  RCNT = 0x8100;                             /* GP mode, SI IRQ */
  rtc_write1(4, 0x01);                       /* INT1: selected frequency */
  rtc_write1(1, 0x01);                       /* 1 Hz */
  IF = IRQ_SIO;
  wait_sio(3 * SEC);
  RES[26] = wait_sio(3 * SEC);
  rtc_write1(1, 0x10);                       /* 16 Hz */
  wait_sio(SEC);
  RES[27] = wait_sio(SEC);
  rtc_write1(1, 0x0A);                       /* 2 Hz AND 8 Hz */
  IF = IRQ_SIO;
  u32 t0 = now(), n = 0;
  while (now() - t0 < SEC)
    if (IF & IRQ_SIO) { IF = IRQ_SIO; n++; }
  RES[28] = n;
  rtc_write1(4, 0x00);
  /* alarm 1 at 00:00 (hour and minute compared), time set to 23:59:58 */
  rtc_write1(4, 0x04);
  static const u8 alarm[3] = {0x00, 0x80 | 0x00, 0x80 | 0x00};
  rtc_write(1, alarm, 3);
  rtc_read1(0);                              /* clear old flags */
  IF = IRQ_SIO;
  static const u8 tm[3] = {0x23, 0x59, 0x58};
  rtc_write(6, tm, 3);
  RES[29] = wait_sio(4 * SEC);
  u32 s1 = rtc_read1(0);
  u32 s2 = rtc_read1(0);
  RES[30] = s1 | (s2 << 8);
  u32 r1 = RCNT;
  rtc_write1(4, 0x00);
  RES[31] = r1 | ((u32)RCNT << 16);
  rtc_write1(3, 0x3F);
  RES[32] = rtc_read1(3);
  rtc_write1(3, 0x00);
  RCNT = 0x8000;
}

static void sleep_section(u32 wake_irq) {
  IME = 0;
  IE = wake_irq;
  IF = 0xFFFFFFFFu;
  if (wake_irq & IRQ_KEY) KEYCNT = 0x4001;   /* A, IRQ */
  u32 f0 = FRAME9;
  u32 t0 = now();
  HALTCNT = 0xC0;
  u32 t1 = now();
  u32 f1 = FRAME9;
  u32 flags = IF;
  KEYCNT = 0;
  if (wake_irq & IRQ_KEY) {
    RES[37] = t1 - t0;
    RES[38] = f1 - f0;
    RES[39] = flags;
  } else {
    RES[40] = f1 - f0;
    RES[41] = flags;
  }
  IE = 0;
}

int main(void) {
  TM0C = 0; TM1C = 0;
  TM0D = 0; TM1D = 0;
  TM1C = 0x84;                               /* count-up, on */
  TM0C = 0x80;                               /* F/1, on */
  for (int i = 0; i < RESULT_WORDS; i++) RES[i] = 0;
  SPICNT = 0;
  spi_section();
  rcnt_section();
  pm_section();
  tsc_section(0);
  flash_section();
  until(60);
  tsc_section(1);
  until(90);
  mic_section();
  until(100);
  rtc_section();
  RES[0] = RES_MAGIC;
  until(560);
  sleep_section(IRQ_KEY);
  until(640);
  sleep_section(IRQ_LID);
  RES[RESULT_WORDS - 1] = LID_MAGIC;
  for (;;) {}
}
