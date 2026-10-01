/* Register map and helpers for the no-library 2D test ROMs (GBATEK "DS
   Video"). ARM9 byte writes to VRAM, palette and OAM are dropped, so every
   store here is 16- or 32-bit. */
#ifndef NDS2D_H
#define NDS2D_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed short s16;
typedef signed int s32;

#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#define REG8(a) (*(volatile u8 *)(a))

#define DISPCNT_A   REG32(0x04000000)
#define DISPCNT_B   REG32(0x04001000)
#define VCOUNT      REG16(0x04000006)
#define POWCNT1     REG16(0x04000304)
#define VRAMCNT(n)  REG8(0x04000240 + (n))   /* A..G = 0..6, H = 8, I = 9 */
#define ENG_A       0x04000000
#define ENG_B       0x04001000
#define BGCNT(e, n)   REG16((e) + 0x08 + 2 * (n))
#define BGHOFS(e, n)  REG16((e) + 0x10 + 4 * (n))
#define BGVOFS(e, n)  REG16((e) + 0x12 + 4 * (n))
#define BGPA(e, n)    REG16((e) + 0x20 + 0x10 * ((n) - 2))
#define BGPB(e, n)    REG16((e) + 0x22 + 0x10 * ((n) - 2))
#define BGPC(e, n)    REG16((e) + 0x24 + 0x10 * ((n) - 2))
#define BGPD(e, n)    REG16((e) + 0x26 + 0x10 * ((n) - 2))
#define BGX(e, n)     REG32((e) + 0x28 + 0x10 * ((n) - 2))
#define BGY(e, n)     REG32((e) + 0x2C + 0x10 * ((n) - 2))
#define WIN0H(e)      REG16((e) + 0x40)
#define WIN1H(e)      REG16((e) + 0x42)
#define WIN0V(e)      REG16((e) + 0x44)
#define WIN1V(e)      REG16((e) + 0x46)
#define WININ(e)      REG16((e) + 0x48)
#define WINOUT(e)     REG16((e) + 0x4A)
#define MOSAIC(e)     REG16((e) + 0x4C)
#define BLDCNT(e)     REG16((e) + 0x50)
#define BLDALPHA(e)   REG16((e) + 0x52)
#define BLDY(e)       REG16((e) + 0x54)
#define MASTER_BRIGHT(e) REG16((e) + 0x6C)

#define PAL_A_BG   ((volatile u16 *)0x05000000)
#define PAL_A_OBJ  ((volatile u16 *)0x05000200)
#define PAL_B_BG   ((volatile u16 *)0x05000400)
#define PAL_B_OBJ  ((volatile u16 *)0x05000600)
#define OAM_A      ((volatile u16 *)0x07000000)
#define OAM_B      ((volatile u16 *)0x07000400)
#define VRAM_A_BG  0x06000000
#define VRAM_B_BG  0x06200000
#define VRAM_A_OBJ 0x06400000
#define VRAM_B_OBJ 0x06600000
#define VRAM_LCDC  0x06800000

#define RGB(r, g, b) ((u16)((r) | ((g) << 5) | ((b) << 10)))

static inline void wait_vblank(void) {
  while (VCOUNT != 192) {}
  while (VCOUNT == 192) {}
}

static inline void w16(u32 a, u16 v) { *(volatile u16 *)a = v; }
static inline void w32(u32 a, u32 v) { *(volatile u32 *)a = v; }

/* 3x5 font, each glyph drawn 2x wide into rows 1-5 of an 8x8 tile;
   tile n is FONT_CHARS[n] */
static const char FONT_CHARS[] = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:-!";
static const char *const FONT[] = {
  "... ... ... ... ...",
  "### #.# #.# #.# ###", ".#. ##. .#. .#. ###", "### ..# ### #.. ###", "### ..# ### ..# ###",
  "#.# #.# ### ..# ..#", "### #.. ### ..# ###", "### #.. ### #.# ###", "### ..# ..# ..# ..#",
  "### #.# ### #.# ###", "### #.# ### ..# ###",
  "### #.# ### #.# #.#", "##. #.# ##. #.# ##.", "### #.. #.. #.. ###", "##. #.# #.# #.# ##.",
  "### #.. ### #.. ###", "### #.. ### #.. #..", "### #.. #.# #.# ###", "#.# #.# ### #.# #.#",
  "### .#. .#. .#. ###", "..# ..# ..# #.# ###", "#.# #.# ##. #.# #.#", "#.. #.. #.. #.. ###",
  "#.# ### ### #.# #.#", "##. #.# #.# #.# #.#", "### #.# #.# #.# ###", "### #.# ### #.. #..",
  "### #.# #.# ### ..#", "### #.# ##. #.# #.#", "### #.. ### ..# ###", "### .#. .#. .#. .#.",
  "#.# #.# #.# #.# ###", "#.# #.# #.# #.# .#.", "#.# #.# ### ### #.#", "#.# #.# .#. #.# #.#",
  "#.# #.# .#. .#. .#.", "### ..# .#. #.. ###",
  "... ... ... ... .#.", "... .#. ... .#. ...", "... ... ### ... ...", ".#. .#. .#. ... .#.",
};
#define FONT_N ((int)(sizeof(FONT) / sizeof(FONT[0])))

__attribute__((unused)) static int glyph_bits(int t, int row) {
  /* row bits of tile t, bit 0 = leftmost pixel */
  if (row < 1 || row > 5) return 0;
  const char *s = FONT[t];
  int bits = 0;
  for (int c = 0; c < 3; c++)
    if (s[(row - 1) * 4 + c] == '#') bits |= 3 << (c * 2 + 1);
  return bits;
}

__attribute__((unused)) static int font_index(char ch) {
  for (int i = 0; FONT_CHARS[i]; i++)
    if (FONT_CHARS[i] == ch) return i;
  return 0;
}

/* 4bpp glyph tiles at `base`, colour index `ink` */
__attribute__((unused)) static void load_font4(u32 base, int ink) {
  for (int t = 0; t < FONT_N; t++)
    for (int row = 0; row < 8; row++) {
      int bits = glyph_bits(t, row);
      u32 word = 0;
      for (int x = 0; x < 8; x++)
        if (bits & (1 << x)) word |= (u32)ink << (x * 4);
      w32(base + t * 32 + row * 4, word);
    }
}

/* 8bpp glyph tiles at `base`, colour index `ink` */
__attribute__((unused)) static void load_font8(u32 base, int ink) {
  for (int t = 0; t < FONT_N; t++)
    for (int row = 0; row < 8; row++) {
      int bits = glyph_bits(t, row);
      for (int x = 0; x < 8; x += 2) {
        u16 v = ((bits >> x) & 1 ? ink : 0) | ((bits >> (x + 1)) & 1 ? ink << 8 : 0);
        w16(base + t * 64 + row * 8 + x, v);
      }
    }
}

/* text into a 32-wide map of 16-bit entries */
__attribute__((unused)) static void print_at(u32 map, int tx, int ty, const char *s, u16 attr) {
  for (int i = 0; s[i]; i++)
    w16(map + (ty * 32 + tx + i) * 2, (u16)font_index(s[i]) | attr);
}

__attribute__((unused)) static void clear16(u32 a, u32 bytes, u16 v) {
  for (u32 i = 0; i < bytes; i += 2) w16(a + i, v);
}

#endif
