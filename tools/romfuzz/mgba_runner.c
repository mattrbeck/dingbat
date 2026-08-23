/* Headless mGBA runner (links libmgba as a black-box reference) for
 * cross-emulator screenshot comparison.
 *
 * Usage: mgba_runner <rom.gba> <bios.bin> <outprefix> <script> <shots>
 *   script: comma-separated FRAME:KEY[:HOLD] (empty string for none),
 *           KEY in A,B,SELECT,START,RIGHT,LEFT,UP,DOWN,R,L; HOLD defaults 10
 *   shots:  comma-separated frame numbers; writes <outprefix>.f<frame>.ppm
 *
 * Build: see build.sh (links ~/code/mgba-ref-src/build-headless/libmgba.a)
 */
#include <mgba/core/core.h>
#include <mgba/gba/core.h>
#include <mgba/core/config.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>
#include <mgba/internal/arm/arm.h>
#include <mgba/internal/gba/gba.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W 240
#define H 160
#define MAX_EV 256
#define MAX_SHOT 64

struct Ev { int frame; uint32_t bit; int press; };
static struct Ev g_ev[MAX_EV];
static int g_nev;
static int g_shots[MAX_SHOT];
static int g_nshots;

static uint32_t key_bit(const char* name) {
  static const char* names[] = {"A","B","SELECT","START","RIGHT","LEFT","UP","DOWN","R","L"};
  for (int i = 0; i < 10; ++i)
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
    fprintf(stderr, "Usage: %s <rom> <bios> <outprefix> <script> <shots>\n", argv[0]);
    return 2;
  }
  const char* rom = argv[1];
  const char* bios = argv[2];
  const char* prefix = argv[3];
  char* script = strdup(argv[4]);
  char* shots = strdup(argv[5]);
  if (script[0]) parse_script(script);
  for (char* tok = strtok(shots, ","); tok; tok = strtok(NULL, ","))
    g_shots[g_nshots++] = atoi(tok);

  mLogSetDefaultLogger(&g_logger);

  struct mCore* core = GBACoreCreate();
  core->init(core);
  mCoreInitConfig(core, NULL);
  mCoreConfigSetValue(&core->config, "idleOptimization", "ignore");
  /* Skip the boot logo so frame 0 is the first game frame in every runner,
   * unless ROMFUZZ_RUN_BIOS is set. core->loadConfig does not map config
   * values into core->opts (only mCoreLoadConfig does), so set the opt
   * directly — reset() reads core->opts.skipBios. */
  core->opts.skipBios = getenv("ROMFUZZ_RUN_BIOS") == NULL;
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
  struct VFile* bvf = VFileOpen(bios, O_RDONLY);
  if (!bvf) { fprintf(stderr, "no bios %s\n", bios); return 3; }
  core->loadBIOS(core, bvf, 0);
  core->reset(core);

  int max_frame = 0;
  for (int i = 0; i < g_nshots; ++i)
    if (g_shots[i] > max_frame) max_frame = g_shots[i];

  /* ROMFUZZ_TRACE=<path>:<ninstr>: instead of running frames, single-step
   * <ninstr> instructions logging "pc r0 r1" per line, then exit. */
  const char* tr = getenv("ROMFUZZ_TRACE");
  if (tr) {
    char trpath[1024];
    long n = 1000000;
    const char* colon = strrchr(tr, ':');
    if (colon) {
      size_t len = (size_t)(colon - tr);
      memcpy(trpath, tr, len); trpath[len] = 0;
      n = atol(colon + 1);
    } else {
      snprintf(trpath, sizeof trpath, "%s", tr);
    }
    FILE* tf = fopen(trpath, "w");
    if (!tf) { perror(trpath); return 3; }
    struct ARMCore* cpu = core->cpu;
    for (long i = 0; i < n; ++i) {
      uint32_t pc = cpu->gprs[15] - (cpu->executionMode == MODE_THUMB ? 4 : 8);
      fprintf(tf, "%08X %08X %08X\n", pc, cpu->gprs[0], cpu->gprs[1]);
      core->step(core);
    }
    fclose(tf);
    /* ROMFUZZ_DUMP=<hexaddr>:<hexlen>:<path>: dump memory after the trace */
    const char* du = getenv("ROMFUZZ_DUMP");
    if (du) {
      uint32_t a0, len;
      char dpath[1024];
      if (sscanf(du, "%x:%x:%1023s", &a0, &len, dpath) == 3) {
        FILE* df = fopen(dpath, "wb");
        for (uint32_t a = a0; a < a0 + len; ++a) {
          uint8_t b = core->busRead8(core, a);
          fwrite(&b, 1, 1, df);
        }
        fclose(df);
      }
    }
    core->deinit(core);
    return 0;
  }

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
