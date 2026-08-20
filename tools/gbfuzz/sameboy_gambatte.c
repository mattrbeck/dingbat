/* Headless SameBoy oracle for the gambatte suite.
 *
 * The gambatte ROMs draw their answer as hex glyphs along the top-left row of
 * the screen, and the expected value is in the filename. Scoring dingbat tells
 * you a row is wrong; it does not tell you what a *correct* emulator does with
 * a ROM you have just modified. This runner closes that loop: it runs a ROM
 * under SameBoy and prints the same hex string dingbat's `--mode=gambatte`
 * decodes, so a tweaked ROM can be put to an oracle that passes the row.
 *
 * Usage:
 *   sameboy_gambatte <bootromdir> <list.tsv> [frames]
 *   sameboy_gambatte <bootromdir> --rom <dmg|cgb> <rom.gb> [frames]
 *
 * list.tsv lines are either `<dmg|cgb>\t<rompath>` or the 4-column form
 * dingbat_test's --list= takes (`<dmg|cgb>\t<hex|png>\t<expected>\t<rompath>`);
 * columns 2 and 3 are ignored here. Blank lines and `#` comments are skipped.
 * One `GAM <index> <hexstring> <rompath>` line comes back per input line, in
 * order. `?` in the hex string is a tile that matched no glyph.
 *
 * The device comes from the list, never from the cart header: nearly every
 * gambatte ROM ships a CGB header even for its DMG half (gambatte picks the
 * device from its loader flag), so scoring by header answers the wrong
 * machine's question on ~1,700 rows.
 *
 * Frame count: gambatte's own runner reads the frame after exactly 15 LCD
 * frames from the post-boot state. SameBoy has no skip-boot API, so this runs
 * the real boot ROM to completion first and counts from there. That is the
 * more faithful timeline, not a compromise — and the suite is insensitive to
 * the count anyway (its ROMs have settled and hold their result).
 *
 * Build: see build.sh.
 */
#define GB_INTERNAL
#include <Core/gb.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 160
#define H 144

/* Same four-shade DMG ramp the other runners use, darkest first. Only the two
 * ends matter here: the glyphs are pure black on pure white. */
static const GB_palette_t GREY4 = {{
    {0x00, 0x00, 0x00}, {0x52, 0x52, 0x52}, {0xAD, 0xAD, 0xAD},
    {0xFF, 0xFF, 0xFF}, {0xFF, 0xFF, 0xFF},
}};

/* Hex-digit glyph bitmaps, 8 rows of 8 pixels, bit 7 = leftmost, 1 = black.
 * Same provenance as tests/dingbat_test.nim's GambatteGlyphs: harvested from
 * the ROMs' own rendered output, not copied from GPL-2.0 gambatte-core. */
static const uint8_t GLYPHS[16][8] = {
  {0x00,0x7F,0x41,0x41,0x41,0x41,0x41,0x7F}, {0x00,0x08,0x08,0x08,0x08,0x08,0x08,0x08},
  {0x00,0x7F,0x01,0x01,0x7F,0x40,0x40,0x7F}, {0x00,0x7F,0x01,0x01,0x3F,0x01,0x01,0x7F},
  {0x00,0x41,0x41,0x41,0x7F,0x01,0x01,0x01}, {0x00,0x7F,0x40,0x40,0x7E,0x01,0x01,0x7E},
  {0x00,0x7F,0x40,0x40,0x7F,0x41,0x41,0x7F}, {0x00,0x7F,0x01,0x02,0x04,0x08,0x10,0x10},
  {0x00,0x3E,0x41,0x41,0x3E,0x41,0x41,0x3E}, {0x00,0x7F,0x41,0x41,0x7F,0x01,0x01,0x7F},
  {0x00,0x08,0x22,0x41,0x7F,0x41,0x41,0x41}, {0x00,0x7E,0x41,0x41,0x7E,0x41,0x41,0x7E},
  {0x00,0x3E,0x41,0x40,0x40,0x40,0x41,0x3E}, {0x00,0x7E,0x41,0x41,0x41,0x41,0x41,0x7E},
  {0x00,0x7F,0x40,0x40,0x7F,0x40,0x40,0x7F}, {0x00,0x7F,0x40,0x40,0x7F,0x40,0x40,0x40},
};

/* gambatte's device tags name a silicon revision: `cgb04c` is a CGB rev C and
 * `dmg08` a DMG-B. Getting the CGB revision wrong is not cosmetic — the CGB-E
 * PPU differs from the CGB-C one on exactly the mid-mode-3 and OAM-DMA rows
 * this oracle exists to arbitrate. SAMEBOY_CGB_MODEL / SAMEBOY_DMG_MODEL
 * override for a deliberate cross-revision comparison. */
static GB_model_t g_cgb_model = GB_MODEL_CGB_C;
static GB_model_t g_dmg_model = GB_MODEL_DMG_B;

static void pick_models(void) {
  const char* c = getenv("SAMEBOY_CGB_MODEL");
  if (c) {
    if (!strcasecmp(c, "0")) g_cgb_model = GB_MODEL_CGB_0;
    else if (!strcasecmp(c, "a")) g_cgb_model = GB_MODEL_CGB_A;
    else if (!strcasecmp(c, "b")) g_cgb_model = GB_MODEL_CGB_B;
    else if (!strcasecmp(c, "c")) g_cgb_model = GB_MODEL_CGB_C;
    else if (!strcasecmp(c, "d")) g_cgb_model = GB_MODEL_CGB_D;
    else if (!strcasecmp(c, "e")) g_cgb_model = GB_MODEL_CGB_E;
    else { fprintf(stderr, "SAMEBOY_CGB_MODEL must be 0/A/B/C/D/E\n"); exit(2); }
  }
  const char* d = getenv("SAMEBOY_DMG_MODEL");
  if (d) {
    if (!strcasecmp(d, "b")) g_dmg_model = GB_MODEL_DMG_B;
    else { fprintf(stderr, "SAMEBOY_DMG_MODEL must be B\n"); exit(2); }
  }
}

static uint32_t rgb_encode(GB_gameboy_t* gb, uint8_t r, uint8_t g, uint8_t b) {
  (void) gb;
  return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}
static void vblank(GB_gameboy_t* gb, GB_vblank_type_t t) { (void) gb; (void) t; }
static void log_cb(GB_gameboy_t* gb, const char* s, GB_log_attributes_t a) {
  (void) gb; (void) s; (void) a;
}

/* One glyph column of the top row, as a bit-per-pixel mask. A tile holding
 * anything but pure black and pure white comes back all-ones, which no glyph
 * can equal — the same rule dingbat's gambatte_tile uses, so "?" means the
 * same thing on both sides. */
static int decode_tile(const uint32_t* fb, int col, char* out) {
  uint8_t bits[8];
  for (int y = 0; y < 8; ++y) {
    uint8_t b = 0;
    for (int x = 0; x < 8; ++x) {
      uint32_t p = fb[y * W + col * 8 + x] & 0xF8F8F8u;
      if (p == 0u) b |= (uint8_t) (0x80u >> x);
      else if (p != 0xF8F8F8u) return 0;      /* not a glyph tile */
    }
    bits[y] = b;
  }
  int blank = 1;
  for (int y = 0; y < 8; ++y) if (bits[y]) blank = 0;
  if (blank) return 0;
  for (int i = 0; i < 16; ++i)
    if (!memcmp(GLYPHS[i], bits, 8)) { *out = "0123456789ABCDEF"[i]; return 1; }
  *out = '?';
  return 1;
}

static int run_one(const char* bootdir, int is_cgb, const char* rom, int frames,
                   char* out, size_t outsz) {
  GB_random_set_enabled(false);
  GB_random_seed(0);
  GB_gameboy_t gb;
  GB_init(&gb, is_cgb ? g_cgb_model : g_dmg_model);
  GB_set_log_callback(&gb, log_cb);

  char bootpath[1024];
  snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
           is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
  if (GB_load_boot_rom(&gb, bootpath)) {
    snprintf(out, outsz, "!bootrom");
    GB_free(&gb);
    return 0;
  }
  if (GB_load_rom(&gb, rom)) {
    snprintf(out, outsz, "!loadfail");
    GB_free(&gb);
    return 0;
  }

  static uint32_t vbuf[W * H];
  GB_set_pixels_output(&gb, vbuf);
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  GB_set_color_correction_mode(&gb, GB_COLOR_CORRECTION_DISABLED);
  GB_set_palette(&gb, &GREY4);
  GB_set_rendering_disabled(&gb, false);

  /* These ROMs are read-only fixtures in a shared cache: never write a battery
   * file beside one, or the next run (or the next agent) powers on from it. */
  for (int i = 0; i < 1000 && !gb.boot_rom_finished; ++i) GB_run_frame(&gb);
  if (!gb.boot_rom_finished) { snprintf(out, outsz, "!noboot"); GB_free(&gb); return 0; }
  for (int f = 0; f < frames; ++f) GB_run_frame(&gb);

  size_t n = 0;
  for (int col = 0; col < 20 && n + 1 < outsz; ++col) {
    char c;
    if (!decode_tile(vbuf, col, &c)) break;
    out[n++] = c;
  }
  out[n] = 0;
  if (!n) snprintf(out, outsz, "-");
  GB_free(&gb);
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr,
            "Usage: %s <bootromdir> <list.tsv> [frames]\n"
            "       %s <bootromdir> --rom <dmg|cgb> <rom.gb> [frames]\n",
            argv[0], argv[0]);
    return 2;
  }
  pick_models();
  const char* bootdir = argv[1];
  char out[64];

  if (!strcmp(argv[2], "--rom")) {
    if (argc < 5) { fprintf(stderr, "--rom needs <dmg|cgb> <rom>\n"); return 2; }
    int is_cgb = !strcmp(argv[3], "cgb");
    int frames = argc > 5 ? atoi(argv[5]) : 15;
    run_one(bootdir, is_cgb, argv[4], frames, out, sizeof out);
    printf("GAM 0 %s %s\n", out, argv[4]);
    return 0;
  }

  int frames = argc > 3 ? atoi(argv[3]) : 15;
  FILE* lf = fopen(argv[2], "r");
  if (!lf) { perror(argv[2]); return 3; }
  char line[4096];
  int idx = 0;
  while (fgets(line, sizeof line, lf)) {
    char* nl = strpbrk(line, "\r\n");
    if (nl) *nl = 0;
    if (!line[0] || line[0] == '#') continue;
    /* Split on tabs; the device is column 1 and the ROM is the last column. */
    char* cols[8];
    int nc = 0;
    for (char* p = line; nc < 8; ) {
      cols[nc++] = p;
      char* t = strchr(p, '\t');
      if (!t) break;
      *t = 0;
      p = t + 1;
    }
    if (nc < 2) continue;
    int is_cgb = !strcmp(cols[0], "cgb");
    const char* rom = cols[nc - 1];
    run_one(bootdir, is_cgb, rom, frames, out, sizeof out);
    printf("GAM %d %s %s\n", idx++, out, rom);
    fflush(stdout);
  }
  fclose(lf);
  return 0;
}
