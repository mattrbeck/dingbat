/* Headless SameBoy oracle (links libsameboy) that dumps an arbitrary memory
 * range, for ROMs that leave raw measurements in WRAM (wilbertpol mooneye
 * `acceptance/gpu` stores single-register reads at `$C014...`).
 *
 * Usage:
 *   sameboy_wram <bootromdir> <rom.gb> <addr_hex> <len> [frames] [model]
 *   sameboy_wram <bootromdir> --list <list.txt> <addr_hex> <len> [frames] [model]
 *
 * model is one of dmg mgb sgb sgb2 cgb0 cgba cgbb cgbc cgbd cgbe agb, or
 * `cart` (the default) to follow the ROM header the way dingbat's `cart`
 * Device column does.  Reads go through GB_safe_read_memory, so the dump is
 * the CPU's view (bank switches included) with no side effects.
 *
 * Output is one line per ROM:  WRAM <hexbytes> <rom>
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

static const struct { const char* name; GB_model_t model; int cgb; } MODELS[] = {
  {"dmg",  GB_MODEL_DMG_B, 0}, {"mgb",  GB_MODEL_MGB,   0},
  {"sgb",  GB_MODEL_SGB,   0}, {"sgb2", GB_MODEL_SGB2,  0},
  {"cgb0", GB_MODEL_CGB_0, 1}, {"cgba", GB_MODEL_CGB_A, 1},
  {"cgbb", GB_MODEL_CGB_B, 1}, {"cgbc", GB_MODEL_CGB_C, 1},
  {"cgbd", GB_MODEL_CGB_D, 1}, {"cgbe", GB_MODEL_CGB_E, 1},
  {"agb",  GB_MODEL_AGB_A, 1},
};

static int run_one(const char* bootdir, const char* rom, unsigned addr, unsigned len,
                   int frames, const char* modelname) {
  GB_random_set_enabled(false);
  GB_random_seed(0);

  FILE* rf = fopen(rom, "rb");
  if (!rf) { fprintf(stderr, "WRAM OPENFAIL %s\n", rom); return 0; }
  unsigned char hdr[0x150];
  size_t got = fread(hdr, 1, sizeof hdr, rf);
  fclose(rf);
  if (got < sizeof hdr) { fprintf(stderr, "WRAM TOOSMALL %s\n", rom); return 0; }

  GB_model_t model = (hdr[0x143] & 0x80) ? GB_MODEL_CGB_C : GB_MODEL_DMG_B;
  int is_cgb = (hdr[0x143] & 0x80) != 0;
  if (modelname && strcmp(modelname, "cart") != 0) {
    size_t i;
    for (i = 0; i < sizeof MODELS / sizeof *MODELS; ++i) {
      if (!strcmp(modelname, MODELS[i].name)) {
        model = MODELS[i].model;
        is_cgb = MODELS[i].cgb;
        break;
      }
    }
    if (i == sizeof MODELS / sizeof *MODELS) {
      fprintf(stderr, "WRAM BADMODEL %s\n", modelname);
      return 0;
    }
  }

  GB_gameboy_t gb;
  GB_init(&gb, model);
  GB_set_log_callback(&gb, log_cb);

  char bootpath[1024];
  snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
           is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
  if (GB_load_boot_rom(&gb, bootpath)) {
    fprintf(stderr, "WRAM NOBOOT %s\n", rom);
    GB_free(&gb);
    return 0;
  }
  if (GB_load_rom(&gb, rom)) {
    fprintf(stderr, "WRAM LOADFAIL %s\n", rom);
    GB_free(&gb);
    return 0;
  }

  static uint32_t vbuf[160 * 144];
  GB_set_pixels_output(&gb, vbuf);
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  GB_set_rendering_disabled(&gb, false);

  for (int i = 0; i < 1000 && !gb.boot_rom_finished; ++i) GB_run_frame(&gb);
  if (!gb.boot_rom_finished) {
    fprintf(stderr, "WRAM BOOTHUNG %s\n", rom);
    GB_free(&gb);
    return 0;
  }
  for (int f = 0; f < frames; ++f) GB_run_frame(&gb);

  printf("WRAM ");
  for (unsigned i = 0; i < len; ++i)
    printf("%02X", GB_safe_read_memory(&gb, (uint16_t) (addr + i)));
  printf(" %s\n", rom);
  GB_free(&gb);
  return 1;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr,
            "Usage: %s <bootromdir> <rom.gb> <addr_hex> <len> [frames] [model]\n"
            "       %s <bootromdir> --list <list.txt> <addr_hex> <len> [frames] [model]\n",
            argv[0], argv[0]);
    return 2;
  }
  const char* bootdir = argv[1];
  int listmode = !strcmp(argv[2], "--list");
  const char* target = argv[listmode ? 3 : 2];
  int ai = listmode ? 4 : 3;
  if (argc < ai + 2) { fprintf(stderr, "need <addr_hex> <len>\n"); return 2; }
  unsigned addr = (unsigned) strtoul(argv[ai], NULL, 16);
  unsigned len = (unsigned) strtoul(argv[ai + 1], NULL, 0);
  int frames = argc > ai + 2 ? atoi(argv[ai + 2]) : 60;
  const char* modelname = argc > ai + 3 ? argv[ai + 3] : "cart";

  if (!listmode) { run_one(bootdir, target, addr, len, frames, modelname); return 0; }

  FILE* lf = fopen(target, "r");
  if (!lf) { perror(target); return 3; }
  char line[4096];
  while (fgets(line, sizeof line, lf)) {
    char* nl = strpbrk(line, "\r\n");
    if (nl) *nl = 0;
    if (!line[0] || line[0] == '#') continue;
    run_one(bootdir, line, addr, len, frames, modelname);
    fflush(stdout);
  }
  fclose(lf);
  return 0;
}
