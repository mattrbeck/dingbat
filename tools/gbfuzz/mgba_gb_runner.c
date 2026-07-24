/* Headless mGBA runner for GB/GBC cross-emulator screenshot comparison.
 *
 * Usage: mgba_gb_runner <rom.gb> <bootromdir|none> <outprefix> <script> <shots>
 *   script: comma-separated FRAME:KEY[:HOLD] (empty string for none),
 *           KEY in A,B,SELECT,START,RIGHT,LEFT,UP,DOWN; HOLD defaults 10
 *   shots:  comma-separated frame numbers; writes <outprefix>.f<frame>.ppm
 *
 * All three runners play the boot ROM out of <bootromdir> by default and
 * count frame 0 from power-on. GBFUZZ_SKIP_BIOS=1 skips it instead.
 *
 * mGBA only accepts boot ROMs whose CRC matches a known Nintendo dump, which
 * rejects SameBoy's freely redistributable reimplementation and silently falls
 * back to skip-boot. The reference tree is patched to honour GBFUZZ_ANY_BIOS
 * (see build.sh); this runner sets it so the three stay frame-aligned.
 *
 * Model follows the cartridge CGB flag, never SGB: an SGB-bordered frame is
 * 256x224 and would not be comparable. mGBA's per-game DMG colorisation
 * database is disabled so DMG carts stay four-shade.
 *
 * Build: see build.sh (links ~/code/mgba-ref-src/build-headless/libmgba.a)
 */
#include <mgba/core/core.h>
#include <mgba/gb/core.h>
#include <mgba/core/config.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W 160
#define H 144
#define MAX_EV 512
#define MAX_SHOT 512

/* Shared four-shade DMG ramp. Every value survives the 8->5->8 bit round trip
 * mGBA applies to its DMG palette, so all three runners emit identical bytes. */
static const uint32_t GREY4[4] = {0xFFFFFF, 0xADADAD, 0x525252, 0x000000};

struct Ev { int frame; uint32_t bit; int press; };
static struct Ev g_ev[MAX_EV];
static int g_nev;
static int g_shots[MAX_SHOT];
static int g_nshots;

static uint32_t key_bit(const char* name) {
  static const char* names[] = {"A","B","SELECT","START","RIGHT","LEFT","UP","DOWN"};
  for (int i = 0; i < 8; ++i)
    if (!strcasecmp(name, names[i])) return 1u << i;
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
    uint32_t bit = key_bit(key);
    g_ev[g_nev++] = (struct Ev){frame, bit, 1};
    g_ev[g_nev++] = (struct Ev){frame + hold, bit, 0};
  }
}

static void write_ppm(const char* path, const uint32_t* buf) {
  FILE* f = fopen(path, "wb");
  if (!f) { perror(path); exit(3); }
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; ++i) {
    /* mColor 32-bit: R low byte, G mid, B high (M_COLOR_RED 0x000000FF) */
    uint8_t rgb[3] = {buf[i] & 0xFF, (buf[i] >> 8) & 0xFF, (buf[i] >> 16) & 0xFF};
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
}

static void null_log(struct mLogger* log, int cat, enum mLogLevel level,
                     const char* format, va_list args) {
  (void) log; (void) cat; (void) level; (void) format; (void) args;
}
static struct mLogger g_logger = { .log = null_log };

int main(int argc, char** argv) {
  if (argc != 6) {
    fprintf(stderr, "Usage: %s <rom> <bootromdir|none> <outprefix> <script> <shots>\n", argv[0]);
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

  FILE* rf = fopen(rom, "rb");
  if (!rf) { perror(rom); return 3; }
  uint8_t hdr[0x150];
  size_t got = fread(hdr, 1, sizeof hdr, rf);
  fclose(rf);
  if (got < sizeof hdr) { fprintf(stderr, "rom too small: %s\n", rom); return 3; }
  int is_cgb = (hdr[0x143] & 0x80) != 0;

  mLogSetDefaultLogger(&g_logger);

  struct mCore* core = GBCoreCreate();
  core->init(core);
  mCoreInitConfig(core, NULL);
  mCoreConfigSetValue(&core->config, "idleOptimization", "ignore");
  /* Force one model per cartridge class across every mGBA model bucket, so an
   * SGB-enhanced or hybrid cart cannot silently pick a different renderer. */
  const char* model = is_cgb ? "CGB" : "DMG";
  mCoreConfigSetValue(&core->config, "gb.model", model);
  mCoreConfigSetValue(&core->config, "sgb.model", model);
  mCoreConfigSetValue(&core->config, "cgb.model", model);
  mCoreConfigSetValue(&core->config, "cgb.hybridModel", model);
  mCoreConfigSetValue(&core->config, "cgb.sgbModel", model);
  mCoreConfigSetIntValue(&core->config, "gb.colors", 0);
  mCoreConfigSetIntValue(&core->config, "useCgbColors", 0);
  for (int i = 0; i < 4; ++i) {
    char key[16];
    snprintf(key, sizeof key, "gb.pal[%d]", i);
    mCoreConfigSetIntValue(&core->config, key, (int) GREY4[i]);
  }
  setenv("GBFUZZ_ANY_BIOS", "1", 1);
  core->opts.skipBios = getenv("GBFUZZ_SKIP_BIOS") != NULL;
  /* keep .sav files next to the outprefix, not the shared ROM dir */
  char savedir[1024];
  snprintf(savedir, sizeof savedir, "%s", prefix);
  char* slash = strrchr(savedir, '/');
  if (slash) *slash = 0;
  mCoreConfigSetValue(&core->config, "savegamePath", savedir);
  core->loadConfig(core, &core->config);

  static uint32_t vbuf[W * H];
  core->setVideoBuffer(core, (color_t*) vbuf, W);

  if (!mCoreLoadFile(core, rom)) {
    fprintf(stderr, "failed to load %s\n", rom);
    return 3;
  }
  mCoreAutoloadSave(core);
  if (!core->opts.skipBios && strcmp(bootdir, "none") != 0) {
    char bootpath[1024];
    snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
             is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
    struct VFile* bvf = VFileOpen(bootpath, O_RDONLY);
    if (!bvf) { fprintf(stderr, "no boot rom %s\n", bootpath); return 3; }
    core->loadBIOS(core, bvf, 0);
  }
  core->reset(core);

  int max_frame = 0;
  for (int i = 0; i < g_nshots; ++i)
    if (g_shots[i] > max_frame) max_frame = g_shots[i];

  uint32_t keys = 0;
  for (int f = 0; f <= max_frame; ++f) {
    for (int i = 0; i < g_nev; ++i)
      if (g_ev[i].frame == f) {
        if (g_ev[i].press) keys |= g_ev[i].bit; else keys &= ~g_ev[i].bit;
      }
    core->setKeys(core, keys);
    core->runFrame(core);
    for (int i = 0; i < g_nshots; ++i)
      if (g_shots[i] == f) {
        char path[1024];
        snprintf(path, sizeof path, "%s.f%04d.ppm", prefix, f);
        write_ppm(path, vbuf);
      }
  }
  core->deinit(core);
  return 0;
}
