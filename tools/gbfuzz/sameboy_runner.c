/* Headless SameBoy runner for cross-emulator screenshot comparison (GB/GBC).
 *
 * Usage: sameboy_runner <rom.gb> <bootromdir> <outprefix> <script> <shots>
 *   script: comma-separated FRAME:KEY[:HOLD] (empty string for none),
 *           KEY in A,B,SELECT,START,RIGHT,LEFT,UP,DOWN; HOLD defaults 10
 *   shots:  comma-separated frame numbers; writes <outprefix>.f<frame>.ppm
 *
 * All three runners play the boot ROM by default and count frame 0 from
 * power-on, so a difference in where an emulator's skip-boot shortcut lands
 * cannot show up as animation-phase drift. GBFUZZ_SKIP_BIOS=1 selects the
 * skip-boot timeline instead (dingbat's shipping default); SameBoy has no
 * skip-boot API, so it reaches the same point by burning the boot animation.
 *
 * Model follows the cartridge CGB flag: DMG-only carts run on a DMG-B, CGB
 * carts on a CGB-E. SGB is never selected — its 256x224 bordered output is
 * not comparable with the other runners' 160x144.
 *
 * Build: see build.sh (links ~/code/SameBoy/build/lib/libsameboy.a)
 */
#define GB_INTERNAL
#include <Core/gb.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 160
#define H 144
#define MAX_EV 512
#define MAX_SHOT 512

struct Ev { int frame; GB_key_t key; int press; };
static struct Ev g_ev[MAX_EV];
static int g_nev;
static int g_shots[MAX_SHOT];
static int g_nshots;

/* Shared four-shade DMG ramp, darkest first (SameBoy indexes colors[3] as
 * shade 0). Every value survives the 8->5->8 bit round trip that mGBA applies
 * to its DMG palette, so all three runners emit identical bytes. */
static const GB_palette_t GREY4 = {{
    {0x00, 0x00, 0x00}, {0x52, 0x52, 0x52}, {0xAD, 0xAD, 0xAD},
    {0xFF, 0xFF, 0xFF}, {0xFF, 0xFF, 0xFF},
}};

static GB_key_t key_id(const char* name) {
  static const char* names[] = {"RIGHT","LEFT","UP","DOWN","A","B","SELECT","START"};
  for (int i = 0; i < GB_KEY_MAX; ++i)
    if (!strcasecmp(name, names[i])) return (GB_key_t) i;
  fprintf(stderr, "unknown key %s\n", name);
  exit(2);
}

static void parse_script(char* s) {
  for (char* tok = strtok(s, ","); tok; tok = strtok(NULL, ",")) {
    int frame, hold = 10;
    char key[16];
    if (sscanf(tok, "%d:%15[^:]:%d", &frame, key, &hold) < 2) {
      fprintf(stderr, "bad script entry %s\n", tok);
      exit(2);
    }
    if (g_nev + 2 > MAX_EV) { fprintf(stderr, "too many script events\n"); exit(2); }
    GB_key_t k = key_id(key);
    g_ev[g_nev++] = (struct Ev){frame, k, 1};
    g_ev[g_nev++] = (struct Ev){frame + hold, k, 0};
  }
}

static void write_ppm(const char* path, const uint32_t* buf) {
  FILE* f = fopen(path, "wb");
  if (!f) { perror(path); exit(3); }
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; ++i) {
    /* rgb_encode packs 0x00RRGGBB (see rgb_encode below) */
    uint8_t rgb[3] = {(buf[i] >> 16) & 0xFF, (buf[i] >> 8) & 0xFF, buf[i] & 0xFF};
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
}

static uint32_t rgb_encode(GB_gameboy_t* gb, uint8_t r, uint8_t g, uint8_t b) {
  (void) gb;
  return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}

static void vblank(GB_gameboy_t* gb, GB_vblank_type_t type) { (void) gb; (void) type; }

static void log_cb(GB_gameboy_t* gb, const char* string, GB_log_attributes_t attributes) {
  (void) gb; (void) string; (void) attributes;
}

int main(int argc, char** argv) {
  if (argc != 6) {
    fprintf(stderr, "Usage: %s <rom> <bootromdir> <outprefix> <script> <shots>\n", argv[0]);
    return 2;
  }
  const char* rom = argv[1];
  const char* bootdir = argv[2];
  const char* prefix = argv[3];
  char* script = strdup(argv[4]);
  char* shots = strdup(argv[5]);
  if (script[0]) parse_script(script);
  for (char* tok = strtok(shots, ","); tok; tok = strtok(NULL, ",")) {
    if (g_nshots >= MAX_SHOT) { fprintf(stderr, "too many shots\n"); return 2; }
    g_shots[g_nshots++] = atoi(tok);
  }

  /* Peek at the cartridge CGB flag (0x143) to pick the model before init. */
  FILE* rf = fopen(rom, "rb");
  if (!rf) { perror(rom); return 3; }
  uint8_t hdr[0x150];
  size_t got = fread(hdr, 1, sizeof hdr, rf);
  fclose(rf);
  if (got < sizeof hdr) { fprintf(stderr, "rom too small: %s\n", rom); return 3; }
  int is_cgb = (hdr[0x143] & 0x80) != 0;

  GB_gameboy_t gb;
  GB_init(&gb, is_cgb ? GB_MODEL_CGB_E : GB_MODEL_DMG_B);
  GB_set_log_callback(&gb, log_cb);
  /* Determinism: no host entropy in uninitialised memory, no host clock. */
  GB_random_set_enabled(false);
  GB_random_seed(0);

  char bootpath[1024];
  snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
           is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
  if (GB_load_boot_rom(&gb, bootpath)) {
    fprintf(stderr, "failed to load boot rom %s\n", bootpath);
    return 3;
  }
  if (GB_load_rom(&gb, rom)) {
    fprintf(stderr, "failed to load %s\n", rom);
    return 3;
  }

  static uint32_t vbuf[W * H];
  GB_set_pixels_output(&gb, vbuf);
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  GB_set_color_correction_mode(&gb, GB_COLOR_CORRECTION_DISABLED);
  GB_set_palette(&gb, &GREY4);
  GB_set_rendering_disabled(&gb, false);

  int max_frame = 0;
  for (int i = 0; i < g_nshots; ++i)
    if (g_shots[i] > max_frame) max_frame = g_shots[i];

  if (getenv("GBFUZZ_BOOT_FRAMES")) {
    int n = 0;
    while (n < 1000 && !gb.boot_rom_finished) { GB_run_frame(&gb); ++n; }
    printf("boot_frames %d\n", n);
    return 0;
  }
  if (getenv("GBFUZZ_SKIP_BIOS")) {
    /* Burn the boot animation. Bounded: a stuck boot must not hang the sweep. */
    for (int i = 0; i < 1000 && !gb.boot_rom_finished; ++i) GB_run_frame(&gb);
    if (!gb.boot_rom_finished) {
      fprintf(stderr, "boot rom never finished\n");
      return 4;
    }
  }

  for (int f = 0; f <= max_frame; ++f) {
    for (int i = 0; i < g_nev; ++i)
      if (g_ev[i].frame == f) GB_set_key_state(&gb, g_ev[i].key, g_ev[i].press);
    GB_run_frame(&gb);
    for (int i = 0; i < g_nshots; ++i)
      if (g_shots[i] == f) {
        char path[1024];
        snprintf(path, sizeof path, "%s.f%04d.ppm", prefix, f);
        write_ppm(path, vbuf);
      }
  }
  GB_free(&gb);
  return 0;
}
