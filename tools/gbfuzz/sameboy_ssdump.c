/* The SameBoy half of tools/gbapu — dump a SameSuite APU ROM's result buffer
 * ($C000 onwards) after N frames, on a chosen CGB revision or on an AGB.
 *
 *   sameboy_ssdump <rom.gb> <0|A|B|C|D|E|agb> <bootromdir> [frames] [count]
 *
 * Why a fifth runner rather than a flag on sameboy_runner: this one has to
 * select the CGB REVISION (SameBoy models six of them and the SameSuite APU
 * sub-suite splits on four), which sameboy_runner deliberately does not — it
 * pins CGB-E so that its screenshots are comparable.
 *
 * The buffer is the whole point. `sameboy_gambatte` reads a decoded hex string
 * off the SCREEN, which for these ROMs is a rendering of $C000 and no more
 * informative; reading WRAM skips the font table and works before the ROM has
 * finished drawing. $CFFE (offset $0FFE) is the ROM's own verdict byte: $50
 * pass, $46 fail.
 *
 * THE CAVEAT, and it is not the same one sameboy_gambatte carries. SameBoy has
 * no skip-boot API, so this plays the boot ROM while dingbat skips it, and for
 * these ROMs that is not a constant offset in TIME but a different APU tick
 * phase at the moment the test starts. On `channel_1_duty` it moves SameBoy's
 * whole staircase two cells relative to dingbat's. So compare the VERDICT byte
 * across revisions, or compare a ladder DIFFERENTIALLY (sweep a delay and ask
 * whether the answer moves the way the model predicts) — do not read a buffer
 * mismatch as a disagreement about behaviour.
 *
 * Build: see build.sh. Boot ROMs: SameBoy's own `make bootroms` output has the
 * cgb0/agb pair this needs, which the two-file bootdir the other runners use
 * does not.
 */
#define GB_INTERNAL
#include <Core/gb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b) {
  (void) gb;
  return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}
static void vblank(GB_gameboy_t *gb, GB_vblank_type_t t) { (void) gb; (void) t; }
static void logcb(GB_gameboy_t *gb, const char *s, GB_log_attributes_t a) {
  (void) gb; (void) s; (void) a;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <rom> <0|A|B|C|D|E|agb> <bootromdir> [frames] [count]\n", argv[0]);
    return 2;
  }
  const char *rom = argv[1], *m = argv[2], *bootdir = argv[3];
  int frames = argc > 4 ? atoi(argv[4]) : 400;
  int count  = argc > 5 ? atoi(argv[5]) : 16;

  GB_model_t model;
  const char *bootname = "cgb_boot.bin";
  if      (!strcmp(m, "0"))   { model = GB_MODEL_CGB_0; bootname = "cgb0_boot.bin"; }
  else if (!strcmp(m, "A"))     model = GB_MODEL_CGB_A;
  else if (!strcmp(m, "B"))     model = GB_MODEL_CGB_B;
  else if (!strcmp(m, "C"))     model = GB_MODEL_CGB_C;
  else if (!strcmp(m, "D"))     model = GB_MODEL_CGB_D;
  else if (!strcmp(m, "E"))     model = GB_MODEL_CGB_E;
  else if (!strcmp(m, "agb")) { model = GB_MODEL_AGB_A; bootname = "agb_boot.bin"; }
  else { fprintf(stderr, "model must be 0, A, B, C, D, E or agb\n"); return 2; }

  /* Same reason as sameboy_runner: GB_init seeds RAM through a clock-seeded
   * generator, and these ROMs read $C000 back. */
  GB_random_set_enabled(false);
  GB_random_seed(0);

  GB_gameboy_t gb;
  GB_init(&gb, model);
  GB_set_log_callback(&gb, logcb);
  char bp[1024];
  snprintf(bp, sizeof bp, "%s/%s", bootdir, bootname);
  if (GB_load_boot_rom(&gb, bp)) { fprintf(stderr, "boot rom load failed: %s\n", bp); return 3; }
  if (GB_load_rom(&gb, rom))     { fprintf(stderr, "rom load failed: %s\n", rom); return 3; }
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  static uint32_t fb[160 * 144];
  GB_set_pixels_output(&gb, fb);

  for (int i = 0; i < frames; ++i) GB_run_frame(&gb);
  if (count > (int) gb.ram_size) count = gb.ram_size;
  for (int i = 0; i < count; ++i) printf("%02x", gb.ram[i]);
  printf("\n");
  return 0;
}
