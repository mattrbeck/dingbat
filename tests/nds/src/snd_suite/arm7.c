/* snd_suite ARM7: a fixed timeline of SPU tests (GBATEK "DS Sound"), made
   to be measured from a WAV dump of the output (tools: snd_analyze.py), plus
   register/capture readbacks posted to RES (snd.h) for the ARM9 to draw.

   Timeline: frames are counted on the ARM7 from VCOUNT reaching 192. After
   LEAD frames of silence, sections follow back to back; a section is
   `steps` steps of STEP frames, then one STEP of silence (every channel and
   capture stopped, SOUNDCNT = 807Fh, SOUNDBIAS = 200h). The section table in
   snd_analyze.py must list the same sections with the same step counts.

   Rates: TMR = 10000h - 524 gives 16756991 / 524 = 31979 Hz, and the
   32-sample sine tables then play at 999.3 Hz. */
#include "snd.h"

#define SCNT(n) REG32(0x04000400 + 16 * (n))
#define SSAD(n) REG32(0x04000404 + 16 * (n))
#define STMR(n) REG16(0x04000408 + 16 * (n))
#define SPNT(n) REG16(0x0400040A + 16 * (n))
#define SLEN(n) REG32(0x0400040C + 16 * (n))
#define SOUNDCNT REG16(0x04000500)
#define SOUNDBIAS REG16(0x04000504)
#define CAPCNT(x) REG8(0x04000508 + (x))
#define CAPDAD(x) REG32(0x04000510 + 8 * (x))
#define CAPLEN(x) REG16(0x04000514 + 8 * (x))
#define POWCNT2 REG16(0x04000304)
#define TM0D REG16(0x04000100)
#define TM0C REG16(0x04000102)
#define TM1D REG16(0x04000104)
#define TM1C REG16(0x04000106)

enum { PCM8 = 0, PCM16 = 1, ADPCM = 2, PSG = 3 };
enum { MANUAL = 0, LOOP = 1, ONESHOT = 2, PROHIBITED = 3 };
#define CNT(vol, div, hold, pan, duty, rep, fmt)                              \
  ((u32)(vol) | ((u32)(div) << 8) | ((u32)(hold) << 15) | ((u32)(pan) << 16) | \
   ((u32)(duty) << 24) | ((u32)(rep) << 27) | ((u32)(fmt) << 29) | 0x80000000u)

#define LEAD 30
#define STEP 8
#define T32K (0x10000 - 524)

/* Sample memory in main RAM (the SPU reads it through the ARM7 bus). */
#define SINE16 0x02100000u   /* 32 x PCM16, amplitude 6000h */
#define SINE8 0x02100040u    /* 32 x PCM8, amplitude 60h */
#define ADPCMD 0x02100100u   /* header + 640 nibbles */
#define TWOPART 0x02100400u  /* 512 x sine 6000h, 512 x sine 3000h, PCM16 */
#define HOLD16 0x02101000u   /* 32 x sine, 32 x 4000h, PCM16 */
#define DC 0x02101100u       /* DC(k): 16 x PCM16 constant, 32 bytes apart */
#define CAPBUF 0x02110000u   /* 2048 words loop-back buffer */
#define CAPSMALL 0x02120000u /* 4 words per readback capture */

static const s16 sine[32] = {
  0, 4795, 9405, 13654, 17378, 20434, 22705, 24104, 24576, 24104, 22705,
  20434, 17378, 13654, 9405, 4795, 0, -4795, -9405, -13654, -17378, -20434,
  -22705, -24104, -24576, -24104, -22705, -20434, -17378, -13654, -9405, -4795};

static const s16 adpcm_table[89] = {
  0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x0010,
  0x0011, 0x0013, 0x0015, 0x0017, 0x0019, 0x001C, 0x001F, 0x0022, 0x0025,
  0x0029, 0x002D, 0x0032, 0x0037, 0x003C, 0x0042, 0x0049, 0x0050, 0x0058,
  0x0061, 0x006B, 0x0076, 0x0082, 0x008F, 0x009D, 0x00AD, 0x00BE, 0x00D1,
  0x00E6, 0x00FD, 0x0117, 0x0133, 0x0151, 0x0173, 0x0198, 0x01C1, 0x01EE,
  0x0220, 0x0256, 0x0292, 0x02D4, 0x031C, 0x036C, 0x03C3, 0x0424, 0x048E,
  0x0502, 0x0583, 0x0610, 0x06AB, 0x0756, 0x0812, 0x08E0, 0x09C3, 0x0ABD,
  0x0BD0, 0x0CFF, 0x0E4C, 0x0FBA, 0x114C, 0x1307, 0x14EE, 0x1706, 0x1954,
  0x1BDC, 0x1EA5, 0x21B6, 0x2515, 0x28CA, 0x2CDF, 0x315B, 0x364B, 0x3BB9,
  0x41B2, 0x4844, 0x4F7E, 0x5771, 0x602F, 0x69CE, 0x7462, 0x7FFF};
static const s8 adpcm_index[8] = {-1, -1, -1, -1, 2, 4, 6, 8};

static u32 frame, t0;

static void wait_frame(void) {
  while (VCOUNT != 192) {}
  while (VCOUNT == 192) {}
  frame++;
}
static void until(u32 f) { while (frame < f) wait_frame(); }
static void step(int k) { until(t0 + (u32)k * STEP); }

static void all_off(void) {
  for (int i = 0; i < 16; i++) SCNT(i) = 0;
  CAPCNT(0) = 0;
  CAPCNT(1) = 0;
  SOUNDCNT = 0x807F;
  SOUNDBIAS = 0x200;
}

static void section_end(int steps) {
  step(steps);
  all_off();
  step(steps + 1);
  t0 = frame;
}

static void set(int n, u32 sad, u16 tmr, u16 pnt, u32 len) {
  SCNT(n) = 0;
  SSAD(n) = sad;
  STMR(n) = tmr;
  SPNT(n) = pnt;
  SLEN(n) = len;
}

static void play(int n, u32 sad, u16 tmr, u16 pnt, u32 len, u32 cnt) {
  set(n, sad, tmr, pnt, len);
  SCNT(n) = cnt;
}

static void w16(u32 a, s32 v) { *(volatile u16 *)a = (u16)v; }
static void w8(u32 a, s32 v) { *(volatile u8 *)a = (u8)v; }

/* ---------------------------------------------------------------------- */
/* IMA-ADPCM encoder that tracks GBATEK's decoder exactly (its rounding and
   clipping), so the decoded waveform is known. */
static int enc_pcm, enc_idx;
static int adpcm_enc(int target) {
  int t = adpcm_table[enc_idx], diff = target - enc_pcm, nib = 0;
  if (diff < 0) { nib = 8; diff = -diff; }
  if (diff >= t) { nib |= 4; diff -= t; }
  if (diff >= (t >> 1)) { nib |= 2; diff -= t >> 1; }
  if (diff >= (t >> 2)) nib |= 1;
  int d = t >> 3;
  if (nib & 1) d += t >> 2;
  if (nib & 2) d += t >> 1;
  if (nib & 4) d += t;
  if (nib & 8) { enc_pcm -= d; if (enc_pcm < -0x7FFF) enc_pcm = -0x7FFF; }
  else { enc_pcm += d; if (enc_pcm > 0x7FFF) enc_pcm = 0x7FFF; }
  enc_idx += adpcm_index[nib & 7];
  if (enc_idx < 0) enc_idx = 0;
  if (enc_idx > 88) enc_idx = 88;
  return nib;
}

static void make_tables(void) {
  for (int i = 0; i < 32; i++) {
    w16(SINE16 + 2 * i, sine[i]);
    w8(SINE8 + i, sine[i] >> 8);
    w16(HOLD16 + 2 * i, sine[i]);
    w16(HOLD16 + 64 + 2 * i, 0x4000);
  }
  for (int i = 0; i < 1024; i++)
    w16(TWOPART + 2 * i, i < 512 ? sine[i & 31] : sine[i & 31] / 2);
  static const s32 dc[] = {0x6000, -0x2000, -0x1000, 0x1000, 0x4000, -0x4080, 0};
  for (int k = 0; k < 7; k++)
    for (int i = 0; i < 16; i++) w16(DC + 32 * k + 2 * i, dc[k]);
  /* ADPCM: 128 samples easing from 0 to -3000h, then a 512-sample loop
     body ramping -3000h -> +3000h (a 62.5 Hz sawtooth at 32 kHz). Header
     PCM 0, index 0. Loop start PNT = 1 + 16 words. */
  enc_pcm = 0;
  enc_idx = 0;
  *(volatile u32 *)ADPCMD = 0;
  for (int i = 0; i < 640; i += 2) {
    int v0, v1;
    v0 = i < 128 ? -0x3000 * i / 128 : -0x3000 + 0x6000 * (i - 128) / 512;
    v1 = i + 1 < 128 ? -0x3000 * (i + 1) / 128 : -0x3000 + 0x6000 * (i + 1 - 128) / 512;
    int lo = adpcm_enc(v0), hi = adpcm_enc(v1);
    w8(ADPCMD + 4 + i / 2, lo | (hi << 4));
  }
}

/* ---------------------------------------------------------------------- */
/* Audible sections */

static u16 tmr_rate(u32 hz) { return (u16)(0x10000 - 16756991u / hz); }

static void s_levels(void) {
  /* 1: PCM16 left only, PCM16 right only, PCM8 centre */
  play(0, SINE16, T32K, 0, 16, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  step(1);
  play(0, SINE16, T32K, 0, 16, CNT(127, 0, 0, 127, 0, LOOP, PCM16));
  step(2);
  play(0, SINE8, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM8));
  section_end(3);
}

static void s_adpcm(void) {
  /* 2: ADPCM loop with state restore, 4 steps */
  play(0, ADPCMD, T32K, 17, 64, CNT(127, 0, 0, 64, 0, LOOP, ADPCM));
  section_end(4);
}

static void s_duty(void) {
  /* 3: PSG ch8 duty 0..7 at 999.8 Hz (rate 7998.6 Hz) */
  for (int d = 0; d < 8; d++) {
    play(8, 0, 0x10000 - 2095, 0, 0, CNT(127, 0, 0, 64, d, 0, PSG));
    step(d + 1);
  }
  section_end(8);
}

static void s_psg_chans(void) {
  /* 4: PSG duty 3 on ch9..13, tone 500 * (k + 2) Hz */
  for (int k = 0; k < 5; k++) {
    play(9 + k, 0, tmr_rate(8 * 500 * (k + 2)), 0, 0, CNT(127, 0, 0, 64, 3, 0, PSG));
    step(k + 1);
    SCNT(9 + k) = 0;
  }
  section_end(5);
}

static void s_noise(void) {
  /* 5: noise ch14 at 32728.5 Hz (TMR FE00h), then ch15 at a quarter */
  play(14, 0, 0xFE00, 0, 0, CNT(127, 0, 0, 64, 0, 0, PSG));
  step(2);
  SCNT(14) = 0;
  play(15, 0, 0xF800, 0, 0, CNT(127, 0, 0, 64, 0, 0, PSG));
  section_end(4);
}

static void s_repeat(void) {
  /* 6: repeat modes 0..3, PNT 256 words (512 samples at 6000h), LEN 256
     words (512 samples at 3000h), restarted at each step */
  for (int m = 0; m < 4; m++) {
    play(0, TWOPART, T32K, 256, 256, CNT(127, 0, 0, 64, 0, m, PCM16));
    step(m + 1);
  }
  section_end(4);
}

static void s_hold(void) {
  /* 7: one-shot ending on 4000h at 1022.8 Hz (62.6 ms): hold set, hold
     clear, hold set then cleared by a CNT write at frame 5 */
  play(0, HOLD16, 0x10000 - 16384, 0, 32, CNT(127, 0, 1, 64, 0, ONESHOT, PCM16));
  step(1);
  play(0, HOLD16, 0x10000 - 16384, 0, 32, CNT(127, 0, 0, 64, 0, ONESHOT, PCM16));
  step(2);
  play(0, HOLD16, 0x10000 - 16384, 0, 32, CNT(127, 0, 1, 64, 0, ONESHOT, PCM16));
  until(t0 + 2 * STEP + 5);
  SCNT(0) = CNT(127, 0, 0, 64, 0, ONESHOT, PCM16) & 0x7FFFFFFF;
  section_end(3);
}

static void s_div(void) {
  /* 8: volume divider 0..3 (/1 /2 /4 /16) */
  for (int d = 0; d < 4; d++) {
    play(0, SINE16, T32K, 0, 16, CNT(127, d, 0, 64, 0, LOOP, PCM16));
    step(d + 1);
  }
  section_end(4);
}

static void s_vol(void) {
  /* 9: volume 127, 96, 64, 32, 1 */
  static const u8 v[5] = {127, 96, 64, 32, 1};
  for (int k = 0; k < 5; k++) {
    play(0, SINE16, T32K, 0, 16, CNT(v[k], 0, 0, 64, 0, LOOP, PCM16));
    step(k + 1);
  }
  section_end(5);
}

static void s_pan(void) {
  /* 10: pan 0, 32, 64, 96, 127 */
  static const u8 p[5] = {0, 32, 64, 96, 127};
  for (int k = 0; k < 5; k++) {
    play(0, SINE16, T32K, 0, 16, CNT(127, 0, 0, p[k], 0, LOOP, PCM16));
    step(k + 1);
  }
  section_end(5);
}

static void s_master(void) {
  /* 11: master volume 127, 96, 64, 32, 0 (channel at pan 64) */
  static const u8 m[5] = {127, 96, 64, 32, 0};
  play(0, SINE16, T32K, 0, 16, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  for (int k = 0; k < 5; k++) {
    SOUNDCNT = 0x8000 | m[k];
    step(k + 1);
  }
  section_end(5);
}

static void s_select(void) {
  /* 12: output selectors. ch0 = 499.6 Hz centre, ch1 = 999.3 Hz left,
     ch3 = 1499 Hz right. SOUNDCNT bits 8-13 per step. */
  static const u16 sel[8] = {
    0x0000, 0x0900 /* L=ch1 R=ch3 */, 0x0600 /* L=ch3 R=ch1 */, 0x0F00 /* both ch1+ch3 */,
    0x1000 /* ch1 not to mixer */, 0x2000 /* ch3 not to mixer */, 0x3000, 0x3300 /* L=ch1+ch3, ch1/3 not to mixer */};
  play(0, SINE16, (u16)(0x10000 - 1048), 0, 16, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  play(1, SINE16, T32K, 0, 16, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  play(3, SINE16, (u16)(0x10000 - 349), 0, 16, CNT(127, 0, 0, 127, 0, LOOP, PCM16));
  for (int k = 0; k < 8; k++) {
    SOUNDCNT = 0x807F | sel[k];
    step(k + 1);
  }
  section_end(8);
}

static void s_capture_echo(void) {
  /* 13: capture loop-back. ch0 plays one 16 ms burst (512 samples of
     TWOPART) at centre; capture 0 records the left mixer into a 2048-word
     PCM16 loop (4096 samples = 128 ms at ch1's 31979 Hz); ch1 replays the
     buffer at volume 64, panned left, so each echo is half the last. */
  for (u32 i = 0; i < 2048; i++) *(volatile u32 *)(CAPBUF + 4 * i) = 0;
  set(1, CAPBUF, T32K, 0, 2048);
  CAPDAD(0) = CAPBUF;
  CAPLEN(0) = 2048;
  CAPCNT(0) = 0x80;                         /* left mixer, loop, PCM16 */
  SCNT(1) = CNT(64, 0, 0, 0, 0, LOOP, PCM16);
  play(0, TWOPART, T32K, 0, 256, CNT(127, 0, 0, 64, 0, ONESHOT, PCM16));
  section_end(6);
}

static void s_timer(void) {
  /* 14: timer extremes. PSG duty 3 at TMR 0 (31.96 Hz) and FC00h (2045.5
     Hz); PCM16 sine at TMR FFC0h (8182 Hz) and FFF5h (47.6 kHz tone, above
     the output rate) */
  play(8, 0, 0x0000, 0, 0, CNT(127, 0, 0, 64, 3, 0, PSG));
  step(1);
  play(8, 0, 0xFC00, 0, 0, CNT(127, 0, 0, 64, 3, 0, PSG));
  step(2);
  SCNT(8) = 0;
  play(0, SINE16, 0xFFC0, 0, 16, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  step(3);
  play(0, SINE16, 0xFFF5, 0, 16, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  section_end(4);
}

static void s_bias(void) {
  /* 15: SOUNDBIAS 200h -> 0 over 2 steps, back over 2; then a step with a
     channel playing and SOUNDCNT master enable off */
  for (int k = 0; k < 4 * STEP; k++) {
    int b = k < 2 * STEP ? 0x200 - k * 0x200 / (2 * STEP)
                         : (k - 2 * STEP) * 0x200 / (2 * STEP);
    SOUNDBIAS = (u16)b;
    until(t0 + (u32)k + 1);
  }
  SOUNDBIAS = 0x200;
  play(0, SINE16, T32K, 0, 16, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  SOUNDCNT = 0x007F;
  section_end(5);
}

static void s_sixteen(void) {
  /* 16: all sixteen channels, PCM16 sines at 250 * (i + 1) Hz, volume 8,
     alternating pans */
  for (int i = 0; i < 16; i++)
    play(i, SINE16, tmr_rate(32 * 250 * (i + 1)), 0, 16,
         CNT(8, 0, 0, (i & 1) ? 96 : 32, 0, LOOP, PCM16));
  section_end(4);
}

/* ---------------------------------------------------------------------- */
/* Readbacks (master volume 0: nothing audible) */

static u32 cycles(void) {
  u16 hi, lo;
  do { hi = TM1D; lo = TM0D; } while (hi != TM1D);
  return ((u32)hi << 16) | lo;
}

static void timer_start(void) {
  TM0C = 0;
  TM1C = 0;
  TM0D = 0;
  TM1D = 0;
  TM1C = 0x84;   /* cascade */
  TM0C = 0x80;   /* F/1 */
}

static u32 busy_time(int n, u32 sad, u16 tmr, u16 pnt, u32 len, u32 cnt) {
  set(n, sad, tmr, pnt, len);
  timer_start();
  SCNT(n) = cnt;
  u32 t = 0;
  while (SCNT(n) & 0x80000000u) {
    t = cycles();
    if (t > 33513982u) break;
  }
  return t;
}

static u32 capture_word(int x, u32 capcnt, int word) {
  /* one-shot capture of 4 words (after the channels have settled) */
  for (int i = 0; i < 4; i++) *(volatile u32 *)(CAPSMALL + 4 * i) = 0xDEADBEEF;
  STMR(1 + 2 * x) = T32K;
  CAPDAD(x) = CAPSMALL;
  CAPLEN(x) = 4;
  until(frame + 2);
  CAPCNT(x) = (u8)(0x84 | capcnt);
  until(frame + 2);
  return *(volatile u32 *)(CAPSMALL + 4 * word);
}

static void readbacks(void) {
  SOUNDCNT = 0x8000;   /* enabled, master 0 */
  play(0, SINE8, 0x10000 - 0x4000, 0, 16, CNT(127, 0, 0, 64, 0, ONESHOT, PCM8));
  RES[1] = SCNT(0);
  SCNT(0) = 0x7FFFFFFF;
  RES[2] = SCNT(0);
  SCNT(0) = 0;
  RES[3] = busy_time(0, SINE8, 0x10000 - 0x4000, 0, 16, CNT(127, 0, 0, 64, 0, ONESHOT, PCM8));
  RES[21] = SCNT(0);
  RES[4] = busy_time(0, ADPCMD, 0x10000 - 0x4000, 0, 5, CNT(127, 0, 0, 64, 0, ONESHOT, ADPCM));
  RES[19] = busy_time(0, SINE16, 0x10000 - 0x4000, 0, 4, CNT(127, 0, 0, 64, 0, ONESHOT, PCM16));
  play(8, 0, 0xFE00, 0, 0, CNT(127, 0, 0, 64, 3, ONESHOT, PSG));
  play(2, SINE16, T32K, 1, 2, CNT(127, 0, 0, 64, 0, ONESHOT, PCM16));
  until(frame + 10);
  RES[5] = SCNT(8);
  RES[6] = SCNT(2);
  SCNT(8) = 0;
  SCNT(2) = 0;
  SOUNDCNT = 0xFFFF;
  RES[7] = SOUNDCNT;
  SOUNDCNT = 0x8000;
  SOUNDBIAS = 0xFFFF;
  RES[8] = SOUNDBIAS;
  SOUNDBIAS = 0x200;
  REG16(0x04000508) = 0x7F7F;
  RES[9] = REG16(0x04000508);
  REG16(0x04000508) = 0;
  CAPDAD(0) = 0xFFFFFFFF;
  RES[10] = CAPDAD(0);
  SSAD(5) = 0x02100000;
  RES[11] = SSAD(5);

  /* capture: left mixer, PCM16 */
  play(0, DC + 32 * 4, T32K, 0, 8, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  RES[12] = capture_word(0, 0, 3);
  RES[18] = CAPCNT(0);
  CAPCNT(0) = 0;
  play(2, DC + 32 * 0, T32K, 0, 8, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  play(0, DC + 32 * 0, T32K, 0, 8, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  RES[13] = capture_word(0, 0, 3);
  CAPCNT(0) = 0;
  SCNT(2) = 0;
  play(0, DC + 32 * 5, T32K, 0, 8, CNT(127, 0, 0, 0, 0, LOOP, PCM16));
  RES[14] = capture_word(0, 8, 1);                 /* PCM8 */
  CAPCNT(0) = 0;
  /* capture: channel 0 source, both-negative bug, plain, addition overflow */
  play(0, DC + 32 * 1, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  play(1, DC + 32 * 2, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  RES[15] = capture_word(0, 2, 3);
  CAPCNT(0) = 0;
  play(1, DC + 32 * 3, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  RES[16] = capture_word(0, 2, 3);
  CAPCNT(0) = 0;
  play(0, DC + 32 * 0, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  play(1, DC + 32 * 0, T32K, 0, 8, CNT(127, 0, 0, 64, 0, LOOP, PCM16));
  RES[17] = capture_word(0, 3, 3);
  CAPCNT(0) = 0;
  SCNT(0) = 0;
  SCNT(1) = 0;
  RES[20] = capture_word(0, 0, 3);                 /* nothing playing */
  CAPCNT(0) = 0;
  all_off();
}

int main(void) {
  POWCNT2 = 1;                 /* speakers on */
  make_tables();
  all_off();
  wait_frame();
  frame = 0;
  t0 = LEAD;
  until(t0);
  s_levels();
  s_adpcm();
  s_duty();
  s_psg_chans();
  s_noise();
  s_repeat();
  s_hold();
  s_div();
  s_vol();
  s_pan();
  s_master();
  s_select();
  s_capture_echo();
  s_timer();
  s_bias();
  s_sixteen();
  readbacks();
  RES[0] = RES_MAGIC;
  for (;;) wait_frame();
}
