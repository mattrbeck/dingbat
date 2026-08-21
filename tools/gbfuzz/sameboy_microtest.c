/* Headless SameBoy oracle for GBMicrotest.
 *
 * GBMicrotest ROMs answer in HRAM -- $FF80 actual, $FF81 expected, $FF82
 * verdict ($01 pass / $FF fail) -- and there is no completion signal at all:
 * they write their result and keep running, so the frame count is the exit
 * condition. Every SameBoy runner in this tree reads the SCREEN, so until now
 * "does a correct emulator agree with this GBMicrotest row?" could not be asked
 * directly; the workaround was to rebuild the question as a gambatte-format ROM
 * (tools/gbppu/gam_patchrun.py). This asks it directly.
 *
 * Usage:
 *   sameboy_microtest <bootromdir> <rom.gb> [frames] [dmg|cgb]
 *   sameboy_microtest <bootromdir> --list <list.txt> [frames] [dmg|cgb]
 *
 * A list is one ROM path per line (blank lines and `#` comments skipped).
 * Output is one line per ROM:
 *
 *   MT <ff80> <ff81> <ff82> <PASS|FAIL> <rom>
 *
 * scored the way dingbat's --mode=microtest scores it: on $FF82 alone, per the
 * suite's own howto, because some of its tests leave $FF80 == $FF81 on a
 * failure. $FF80/$FF81 are printed too because when the verdict is FAIL those
 * two are the actual-vs-expected pair the row's residual is measured from.
 *
 * The device follows the cart header (GBMicrotest ships DMG carts), which is
 * what dingbat's `cart` Device column means; the optional last argument forces
 * one. Model defaults to DMG-B / CGB-C -- CGB-C because that is the revision
 * this tree scores and the one gambatte's `cgb04c` names.
 *
 * Build: see build.sh.
 */
#define GB_INTERNAL
#include <Core/gb.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void vblank(GB_gameboy_t* gb, GB_vblank_type_t t) { (void) gb; (void) t; }
static void log_cb(GB_gameboy_t* gb, const char* s, GB_log_attributes_t a) {
  (void) gb; (void) s; (void) a;
}
static uint32_t rgb_encode(GB_gameboy_t* gb, uint8_t r, uint8_t g, uint8_t b) {
  (void) gb;
  return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}

static int run_one(const char* bootdir, const char* rom, int frames, int force) {
  /* Determinism: GB_init seeds RAM/OAM through GB_random(), whose generator is
   * seeded from the wall clock by a library constructor. A GBMicrotest ROM that
   * reads a byte before writing it would otherwise answer differently per run. */
  GB_random_set_enabled(false);
  GB_random_seed(0);

  FILE* rf = fopen(rom, "rb");
  if (!rf) { fprintf(stderr, "MT ?? ?? ?? OPENFAIL %s\n", rom); return 0; }
  unsigned char hdr[0x150];
  size_t got = fread(hdr, 1, sizeof hdr, rf);
  fclose(rf);
  if (got < sizeof hdr) { fprintf(stderr, "MT ?? ?? ?? TOOSMALL %s\n", rom); return 0; }
  int is_cgb = (hdr[0x143] & 0x80) != 0;
  if (force == 1) is_cgb = 0;
  else if (force == 2) is_cgb = 1;

  GB_gameboy_t gb;
  GB_init(&gb, is_cgb ? GB_MODEL_CGB_C : GB_MODEL_DMG_B);
  GB_set_log_callback(&gb, log_cb);

  char bootpath[1024];
  snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
           is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
  if (GB_load_boot_rom(&gb, bootpath)) {
    fprintf(stderr, "MT ?? ?? ?? NOBOOT %s\n", rom);
    GB_free(&gb);
    return 0;
  }
  if (GB_load_rom(&gb, rom)) {
    fprintf(stderr, "MT ?? ?? ?? LOADFAIL %s\n", rom);
    GB_free(&gb);
    return 0;
  }

  static uint32_t vbuf[160 * 144];
  GB_set_pixels_output(&gb, vbuf);
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  GB_set_rendering_disabled(&gb, false);

  /* Play the real boot ROM, then count from its end -- the same timeline the
   * other runners here use. These ROMs settle long before the frame budget. */
  for (int i = 0; i < 1000 && !gb.boot_rom_finished; ++i) GB_run_frame(&gb);
  if (!gb.boot_rom_finished) {
    fprintf(stderr, "MT ?? ?? ?? BOOTHUNG %s\n", rom);
    GB_free(&gb);
    return 0;
  }
  for (int f = 0; f < frames; ++f) GB_run_frame(&gb);

  /* gb.hram is indexed from $FF80. */
  unsigned a = gb.hram[0x00], e = gb.hram[0x01], v = gb.hram[0x02];
  printf("MT %02X %02X %02X %s %s\n", a, e, v, v == 0x01 ? "PASS" : "FAIL", rom);
  GB_free(&gb);
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr,
            "Usage: %s <bootromdir> <rom.gb> [frames] [dmg|cgb]\n"
            "       %s <bootromdir> --list <list.txt> [frames] [dmg|cgb]\n",
            argv[0], argv[0]);
    return 2;
  }
  const char* bootdir = argv[1];
  int listmode = !strcmp(argv[2], "--list");
  const char* target = listmode ? (argc > 3 ? argv[3] : NULL) : argv[2];
  if (!target) { fprintf(stderr, "--list needs a file\n"); return 2; }
  int fi = listmode ? 4 : 3;
  int frames = argc > fi ? atoi(argv[fi]) : 60;
  int force = 0;
  if (argc > fi + 1) {
    if (!strcmp(argv[fi + 1], "dmg")) force = 1;
    else if (!strcmp(argv[fi + 1], "cgb")) force = 2;
  }

  if (!listmode) { run_one(bootdir, target, frames, force); return 0; }

  FILE* lf = fopen(target, "r");
  if (!lf) { perror(target); return 3; }
  char line[4096];
  while (fgets(line, sizeof line, lf)) {
    char* nl = strpbrk(line, "\r\n");
    if (nl) *nl = 0;
    if (!line[0] || line[0] == '#') continue;
    run_one(bootdir, line, frames, force);
    fflush(stdout);
  }
  fclose(lf);
  return 0;
}
