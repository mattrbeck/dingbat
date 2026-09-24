// Probe: the jump list's TrackStop (31), FadeOutBody (32) and TrkVolPitSet
// (33) over many randomised MusicPlayerInfo/track states, and TrackStop,
// fine and endtie over channel chains in varied states. One call per
// snapshot pair (rt.s markers); layout as jlist.c.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)
// CALLFN: bd_callfn, or (the _stk variants) bd_callfn_stk with its stack
// capture copied to RESULT[8..29]
#ifndef CALLFN
#define CALLFN(f, a, b, c) bd_callfn(f, a, b, c)
#endif

// JL_BASE moves the structures (jlist2_iw.c: IWRAM)
#ifndef JL_BASE
#define JL_BASE 0x02010000
#endif
#define MP ((vu8 *)JL_BASE)
#define TR ((vu8 *)(JL_BASE + 0x100))
#define TR2 ((vu8 *)(JL_BASE + 0x150))
#define W32(p, o) (*(vu32 *)((u32)(p) + (o)))
#define W16(p, o) (*(vu16 *)((u32)(p) + (o)))
#define CH(n) ((vu8 *)((u32)AREA + 0x50 + (n) * 0x40))

static u32 jl[36];
static u32 seed = 12345;
static u32 rnd(void) { seed = seed * 1103515245 + 12345; return seed >> 8; }

static void mark_state(u32 step) {
  RESULT[1] = step;
  MARK(0x10 + (step & 0x3F));
}

static void fill(vu8 *p, u32 n) { for (u32 i = 0; i < n; i++) p[i] = rnd(); }

// A game CgbOscOff for SoundInfo +0x2C: logs its argument and every
// channel's status at the call (+0x500: count, then 9 bytes a call)
#define LOG ((vu8 *)(JL_BASE + 0x500))
static void cgboff(u32 t) {
  u32 n = LOG[0];
  LOG[1 + n * 9] = t;
  for (u32 c = 0; c < 8; c++) LOG[2 + n * 9 + c] = CH(c)[0];
  LOG[0] = n + 1;
}

// A chain of n channels from CH(first) on track tr, random statuses (a
// quarter zero) and types
static void chain(vu8 *tr, u32 first, u32 n) {
  W32(tr, 0x20) = n ? (u32)CH(first) : 0;
  for (u32 i = 0; i < n; i++) {
    vu8 *c = CH(first + i);
    fill(c, 0x40);
    if ((rnd() & 3) == 0) c[0] = 0;
    W32(c, 0x2C) = (u32)tr;
    W32(c, 0x30) = i ? (u32)CH(first + i - 1) : 0;
    W32(c, 0x34) = i + 1 < n ? (u32)CH(first + i + 1) : 0;
  }
}

int main(void) {
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  Q(); bd_swi_2A((u32)jl, 0, 0, 0);
  // TrkVolPitSet: random tracks, 240 calls (the last 120 with modT 0-2)
  for (u32 k = 0; k < 240; k++) {
    fill(MP, 0x40); fill(TR, 0x50);
    W32(TR, 0x20) = 0;
    if (k >= 120) TR[0x18] = k % 3;     // the three modulation targets
    RESULT[2] = 33; RESULT[3] = k;
    Q(); CALLFN(jl[33], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // FadeOutBody: random players with two tracks, 60 calls
  for (u32 k = 0; k < 60; k++) {
    fill(MP, 0x40); fill(TR, 0x100);
    W32(MP, 0x2C) = JL_BASE + 0x100; MP[0x08] = 2;
    W32(TR, 0x20) = 0; W32(TR2, 0x20) = 0;
    if (k & 1) W16(MP, 0x26) = 1;          // the counter about to expire
    if (k & 2) W16(MP, 0x28) = rnd() & 0x3FF;
    RESULT[2] = 32; RESULT[3] = k;
    Q(); CALLFN(jl[32], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // TrackStop / fine / endtie over chains: 3 channels, random statuses/keys
  static const u8 fns[3] = {31, 0, 29};
  for (u32 k = 0; k < 90; k++) {
    u32 e = fns[k % 3];
    fill(MP, 0x40); fill(TR, 0x50);
    for (u32 c = 0; c < 4; c++) fill(CH(c), 0x40);
    W32(TR, 0x20) = (u32)CH(0);
    W32(TR, 0x40) = JL_BASE + 0x200;
    ((vu8 *)(JL_BASE + 0x200))[0] = (k & 4) ? 0x90 : (rnd() & 0x7F);
    for (u32 c = 0; c < 3; c++) {
      W32(CH(c), 0x2C) = JL_BASE + 0x100;
      W32(CH(c), 0x30) = c ? (u32)CH(c - 1) : 0;
      W32(CH(c), 0x34) = c < 2 ? (u32)CH(c + 1) : 0;
      CH(c)[0x11] = (rnd() & 1) ? TR[0x05] : ((vu8 *)(JL_BASE + 0x200))[0];
    }
    RESULT[2] = e; RESULT[3] = k;
    Q(); CALLFN(jl[e], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // TrackStop over chains of 0-4 channels, the BIOS's CgbOscOff (k < 30)
  // and a game's (k >= 30), 60 calls
  for (u32 k = 0; k < 60; k++) {
    if (k == 30) W32(AREA, 0x2C) = (u32)cgboff;
    fill(MP, 0x40); fill(TR, 0x50);
    for (u32 i = 0; i < 0x80; i++) LOG[i] = 0;
    TR[0] |= 0x80;
    chain(TR, 0, k % 5);
    RESULT[2] = 31; RESULT[3] = 100 + k;
    Q(); CALLFN(jl[31], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // FadeOutBody edges with the game's CgbOscOff: 0-3 tracks with chains,
  // fadeOI 0, fadeOV around the stop, 48 calls
  static const u16 ovs[6] = {0x10, 0x11, 0x0F, 0x20, 0x8010, 0x0};
  for (u32 k = 0; k < 48; k++) {
    fill(MP, 0x40); fill(TR, 0x100);
    for (u32 i = 0; i < 0x80; i++) LOG[i] = 0;
    W32(MP, 0x2C) = JL_BASE + 0x100; MP[0x08] = k & 3;
    for (u32 t = 0; t < 3; t++) chain(TR + t * 0x50, t * 3, (k >> 2) % 3);
    W16(MP, 0x26) = 1;
    W16(MP, 0x28) = ovs[(k >> 2) % 6];
    if (k >= 40) W16(MP, 0x24) = 0;
    RESULT[2] = 32; RESULT[3] = 100 + k;
    Q(); CALLFN(jl[32], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // fine and endtie over chains of 0-4 channels (the game's CgbOscOff still
  // set: neither calls it), 120 calls
  for (u32 k = 0; k < 120; k++) {
    u32 e = k & 1 ? 29 : 0;
    fill(MP, 0x40); fill(TR, 0x50);
    TR[0] |= 0x80;
    chain(TR, 0, (k >> 1) % 5);
    W32(TR, 0x40) = JL_BASE + 0x200;
    ((vu8 *)(JL_BASE + 0x200))[0] = (k & 2) ? 0x90 : (rnd() & 0x7F);
    u32 key = (k & 2) ? TR[0x05] : ((vu8 *)(JL_BASE + 0x200))[0];
    for (u32 c = 0; c < 4; c++) if (rnd() & 1) CH(c)[0x11] = key;
    RESULT[2] = e; RESULT[3] = 200 + k;
    Q(); CALLFN(jl[e], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // modt with the value the track has and with another, 20 calls
  for (u32 k = 0; k < 20; k++) {
    fill(MP, 0x40); fill(TR, 0x50);
    W32(TR, 0x40) = JL_BASE + 0x200;
    ((vu8 *)(JL_BASE + 0x200))[0] = (k & 1) ? TR[0x18] : (u8)(TR[0x18] + 1 + (k & 2));
    RESULT[2] = 20; RESULT[3] = 400 + k;
    Q(); CALLFN(jl[20], JL_BASE, JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  // RealClearChain on the first, a middle and the last channel of chains
  // of 1-3 and on a channel with no track, 16 calls
  for (u32 k = 0; k < 16; k++) {
    fill(MP, 0x40); fill(TR, 0x50);
    u32 n = 1 + (k % 3);
    chain(TR, 0, n);
    u32 at = (k / 3) % n;
    if (k >= 12) W32(CH(at), 0x2C) = 0;
    RESULT[2] = 34; RESULT[3] = 500 + k;
    Q(); CALLFN(jl[34], (u32)CH(at), JL_BASE + 0x100, 0);
    mark_state(step++);
  }
  MARK(0xFE);
  for (;;) {}
}
