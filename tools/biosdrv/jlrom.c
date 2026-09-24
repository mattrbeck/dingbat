// Probe: the jump list's score-reading functions with the score and the
// tone table in the cartridge (as games keep them), MusicPlayerInfo and
// track in IWRAM, at WAITCNT 0x4014 (prefetch on), 0x4317 and 0x0000.
// One call per snapshot pair; RESULT[2] = entry, RESULT[3] = waitcnt index
// << 8 | offset into the score.
#include "drv.h"
#define Q() (REG16(0x04000102) = 0)

#define MP ((vu8 *)0x03005000)
#define TR ((vu8 *)0x03005100)
#define W32(p, o) (*(vu32 *)((u32)(p) + (o)))

static u32 jl[36];
// score bytes: a pointer (to the score itself), then plain bytes
static const u8 score[32] __attribute__((aligned(4))) = {
  0x00, 0x00, 0x00, 0x00, 0x05, 0x7F, 0x40, 0x81, 0x00, 0x3C, 0xC0, 0x12,
  0x03, 0x00, 0x00, 0x00, 0x00, 0x02, 0x55, 0x10, 0x20, 0x30, 0x40, 0x50};
static const u32 voices[16 * 3] = {0x11111111, 0x22222222, 0x33333333,
                                   0x44444444, 0x55555555, 0x66666666};

int main(void) {
  static const u8 entries[] = {1, 2, 4, 9, 10, 11, 12, 13, 14, 17, 20, 23, 27, 29};
  static const u16 wc[3] = {0x4014, 0x4317, 0x0000};
  u32 step = 0;
  Q(); bd_swi_1A((u32)AREA, 0, 0, 0);
  Q(); bd_swi_2A((u32)jl, 0, 0, 0);
  for (u32 w = 0; w < 3; w++) {
    REG16(0x04000204) = wc[w];
    for (u32 i = 0; i < sizeof entries; i++)
      for (u32 off = 0; off < 2; off++) {
        u32 e = entries[i];
        for (u32 j = 0; j < 0x50; j++) TR[j] = 0;
        for (u32 j = 0; j < 0x40; j++) MP[j] = 0;
        W32(MP, 0x30) = (u32)voices;
        W32(MP, 0x2C) = (u32)TR;
        TR[0x02] = 1; TR[0x03] = 1; TR[0x00] = 0x80;
        // goto/patt/rept read a pointer at +0 (or +12 for rept's count 3);
        // the byte commands read from +4 or +5
        u32 at = (e == 1 || e == 2) ? 0 : (e == 4 ? 12 : 4 + off);
        if (e == 1 || e == 2) at += 0;
        W32(TR, 0x40) = (u32)score + at;
        RESULT[2] = e; RESULT[3] = (w << 8) | off;
        Q(); bd_callfn(jl[e], (u32)MP, (u32)TR, 0);
        RESULT[1] = step;
        MARK(0x10 + (step++ & 0x3F));
      }
  }
  MARK(0xFE);
  for (;;) {}
}
