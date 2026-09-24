// Probe: the 36 sound-driver functions SoundGetJumpList (SWI 0x2A) hands out,
// each called directly (r0 = a MusicPlayerInfo, r1 = a MusicPlayerTrack, as
// a sequencer calls its score-command handlers) on freshly patterned
// structures, in several states. The snapshot (EWRAM 0x02010000, 0x600
// bytes, plus the SoundArea) shows what each wrote.
//
// Layout (EWRAM):
//   0x02010000 MusicPlayerInfo (0x40)   0x02010100 track (0x50)
//   0x02010200 command bytes            0x02010300 voice table (16 x 12)
//   0x02010400 a second track, 0x02010480 a pattern target
// Variants:
//   0 cmdPtr at a pointer, pattern level 1, repeat count 2
//   1 cmdPtr past the pointer (plain bytes)
//   2 pattern level 3, repeat count 0
//   3 pattern level 0
//   4 cmdPtr unaligned (the pointer at +1)
//   5 cmdPtr at zero bytes; repeat count 2 of 3 (the last pass)
//   6 channels chained to the track (SoundArea channels 0-2), key 0x3C
//   7 as 6 with other statuses/keys and a 0x80+ byte at cmdPtr
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
// CALLFN: bd_callfn, or (the _stk variants) bd_callfn_stk with its stack
// capture copied to RESULT[8..29]
#ifndef CALLFN
#define CALLFN(f, a, b, c) bd_callfn(f, a, b, c)
#endif

// JL_BASE moves the structures (jlist_iw.c: IWRAM)
#ifndef JL_BASE
#define JL_BASE 0x02010000
#endif
#define MP ((vu8 *)JL_BASE)
#define TR ((vu8 *)(JL_BASE + 0x100))
#define CMD ((vu8 *)(JL_BASE + 0x200))
#define VOICES ((vu8 *)(JL_BASE + 0x300))
#define W32(p, o) (*(vu32 *)((u32)(p) + (o)))
#define CH(n) ((vu8 *)((u32)AREA + 0x50 + (n) * 0x40))

static u32 jl[36];
static u32 variant;

static void put_ptr(u32 at, u32 v) {
  CMD[at] = v; CMD[at + 1] = v >> 8; CMD[at + 2] = v >> 16; CMD[at + 3] = v >> 24;
}

static void pattern(void) {
  for (u32 i = 0; i < 0x40; i++) MP[i] = (u8)(i * 7 + 0x11);
  for (u32 i = 0; i < 0x50; i++) TR[i] = (u8)(i * 5 + 0x23);
  for (u32 i = 0; i < 16 * 12; i++) VOICES[i] = (u8)(i * 3 + 0x40);
  for (u32 i = 0; i < 0x80; i++) ((vu8 *)(JL_BASE + 0x400))[i] = (u8)(i * 11 + 0x05);
  for (u32 i = 0; i < 0x40; i++) CMD[i] = 0;
  u32 tgt = JL_BASE + 0x480;
  static const u8 rest[] = {0x05, 0x7F, 0x40, 0x81, 0x00, 0x3C, 0xC0, 0x12};
  u32 cmd = 0;
  switch (variant) {
  case 0: case 2: case 3: case 6:
    put_ptr(0, tgt);
    for (u32 i = 0; i < 8; i++) CMD[4 + i] = rest[i];
    break;
  case 1:
    put_ptr(0, tgt);
    for (u32 i = 0; i < 8; i++) CMD[4 + i] = rest[i];
    cmd = 4;
    break;
  case 4:
    CMD[0] = 0x03; put_ptr(1, tgt);
    for (u32 i = 0; i < 8; i++) CMD[5 + i] = rest[i];
    cmd = 1;
    break;
  case 5:
    CMD[0] = 0x00; put_ptr(1, tgt); CMD[5] = 0x03; put_ptr(6, tgt + 8);
    cmd = 0;
    break;
  case 7:
    CMD[0] = 0x9C; put_ptr(1, tgt);
    cmd = 0;
    break;
  }
  W32(TR, 0x40) = (u32)CMD + cmd;                              // cmdPtr
  W32(TR, 0x44) = JL_BASE + 0x490; W32(TR, 0x48) = JL_BASE + 0x4A0; W32(TR, 0x4C) = JL_BASE + 0x4B0;
  TR[0x02] = variant == 2 ? 3 : (variant == 3 ? 0 : 1);       // patternLevel
  TR[0x03] = variant == 2 ? 0 : 2;                             // repN
  W32(TR, 0x20) = 0;                                           // chan
  W32(MP, 0x30) = (u32)VOICES;                                 // tone table
  W32(MP, 0x2C) = JL_BASE + 0x100;                                // tracks
  MP[0x08] = 2;                                                // trackCount
  for (u32 c = 0; c < 4; c++)
    for (u32 i = 0; i < 0x40; i++) CH(c)[i] = (u8)(i * 13 + c * 29 + 0x07);
  if (variant >= 6) {
    // three channels on the track: 0 <-> 1 <-> 2
    W32(TR, 0x20) = (u32)CH(0);
    TR[0x05] = 0x3C;                                           // key
    for (u32 c = 0; c < 3; c++) {
      W32(CH(c), 0x2C) = JL_BASE + 0x100;                         // track
      W32(CH(c), 0x30) = c ? (u32)CH(c - 1) : 0;               // prev
      W32(CH(c), 0x34) = c < 2 ? (u32)CH(c + 1) : 0;           // next
    }
    CH(0)[0x00] = 0x83; CH(1)[0x00] = variant == 6 ? 0x11 : 0x00; CH(2)[0x00] = 0x52;
    CH(0)[0x01] = 0x00; CH(1)[0x01] = 0x02; CH(2)[0x01] = 0x00;  // type
    CH(0)[0x11] = 0x3C; CH(1)[0x11] = variant == 6 ? 0x3C : 0x10; CH(2)[0x11] = 0x3C;
  }
}

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  Q(); bd_swi_2A((u32)jl, 0, 0, 0);
  for (variant = 0; variant < 8; variant++) {
    for (u32 e = 0; e < 36; e++) {
      if (e == 30 && variant > 0) continue;   // SampleFreqSet waits a frame
      pattern();
      RESULT[2] = e; RESULT[3] = variant;
      // RealClearChain takes a channel: the middle one of the chain
      u32 a0 = (e == 34 && variant >= 6) ? (u32)CH(1) : JL_BASE;
      Q(); CALLFN(jl[e], a0, JL_BASE + 0x100, 0x33333333);
      mark_state(step++);
    }
  }
  MARK(0xFE);
  for (;;) {}
}
