/* Persistent headless mGBA driver for tools/playtest (links libmgba as a
 * black-box reference). Speaks the line protocol in tools/playtest/README.md.
 *
 * Usage: mgba_driver <rom.gba> <bios.bin> [--run-bios] [--rtc EPOCH]
 *   The battery save is <rom minus extension>.sav, where mGBA's own frontend
 *   puts it by default. Run with TZ=UTC so a fixed RTC epoch reads the same
 *   wall-clock fields as the other drivers.
 *
 * Build: tools/playtest/build.sh
 */
#include <mgba/core/core.h>
#include <mgba/gba/core.h>
#include <mgba/core/config.h>
#include <mgba/core/log.h>
#include <mgba/core/serialize.h>
#include <mgba-util/vfs.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W 240
#define H 160

static uint32_t vbuf[W * H];

static uint16_t px555(uint32_t c) {
  /* color_t is XBGR8888 (red in the low byte) */
  uint16_t r = (c & 0xFF) >> 3, g = ((c >> 8) & 0xFF) >> 3, b = ((c >> 16) & 0xFF) >> 3;
  return r | (g << 5) | (b << 10);
}

static uint64_t fb_hash(void) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (int i = 0; i < W * H; ++i) h = (h ^ px555(vbuf[i])) * 0x100000001b3ULL;
  return h;
}

static int write_ppm(const char* path) {
  FILE* f = fopen(path, "wb");
  if (!f) return 0;
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; ++i) {
    uint16_t p = px555(vbuf[i]);
    uint8_t r = p & 0x1F, g = (p >> 5) & 0x1F, b = (p >> 10) & 0x1F;
    uint8_t rgb[3] = {(r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)};
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
  return 1;
}

static void null_log(struct mLogger* log, int cat, enum mLogLevel level,
                     const char* format, va_list args) {
  (void) log; (void) cat; (void) level; (void) format; (void) args;
}
static struct mLogger g_logger = { .log = null_log };

static void reply(const char* s) { printf("%s\n", s); fflush(stdout); }

int main(int argc, char** argv) {
  const char* pos[2] = {0};
  int npos = 0, run_bios = 0;
  long long rtc_epoch = -1;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--run-bios")) run_bios = 1;
    else if (!strcmp(argv[i], "--rtc") && i + 1 < argc) rtc_epoch = atoll(argv[++i]);
    else if (npos < 2) pos[npos++] = argv[i];
  }
  if (npos != 2) {
    fprintf(stderr, "Usage: %s <rom> <bios> [--run-bios] [--rtc EPOCH]\n", argv[0]);
    return 2;
  }
  const char* rom = pos[0];
  mLogSetDefaultLogger(&g_logger);

  struct mCore* core = GBACoreCreate();
  core->init(core);
  mCoreInitConfig(core, NULL);
  mCoreConfigSetValue(&core->config, "idleOptimization", "ignore");
  core->opts.skipBios = !run_bios;
  core->loadConfig(core, &core->config);
  core->setVideoBuffer(core, (color_t*) vbuf, W);

  if (!mCoreLoadFile(core, rom)) { fprintf(stderr, "failed to load %s\n", rom); return 3; }
  char save[1024];
  snprintf(save, sizeof save, "%s", rom);
  char* dot = strrchr(save, '.');
  char* slash = strrchr(save, '/');
  if (dot && (!slash || dot > slash)) *dot = 0;
  strncat(save, ".sav", sizeof save - strlen(save) - 1);
  struct VFile* svf = VFileOpen(save, O_CREAT | O_RDWR);
  if (!svf || !core->loadSave(core, svf)) { fprintf(stderr, "cannot open save %s\n", save); return 3; }
  struct VFile* bvf = VFileOpen(pos[1], O_RDONLY);
  if (!bvf) { fprintf(stderr, "no bios %s\n", pos[1]); return 3; }
  core->loadBIOS(core, bvf, 0);
  if (rtc_epoch >= 0) {
    core->rtc.override = RTC_FIXED;
    core->rtc.value = rtc_epoch * 1000;
  }
  core->reset(core);

  int frame = 0;
  char buf[512], out[64];
  printf("ready mgba save=%s\n", save);
  fflush(stdout);
  static char hashes[17 * 100000];
  while (fgets(buf, sizeof buf, stdin)) {
    char cmd[32] = {0}, arg[480] = {0};
    int n = sscanf(buf, "%31s %479[^\n]", cmd, arg);
    if (n < 1) continue;
    if (!strcmp(cmd, "keys")) {
      core->setKeys(core, (uint32_t) atoi(arg));
      reply("ok");
    } else if (!strcmp(cmd, "run")) {
      for (int k = atoi(arg); k > 0; --k) { core->runFrame(core); ++frame; }
      snprintf(out, sizeof out, "ok %d", frame);
      reply(out);
    } else if (!strcmp(cmd, "runhash")) {
      int count = atoi(arg);
      if (count > 100000) count = 100000;
      char* p = hashes;
      for (int k = 0; k < count; ++k) {
        core->runFrame(core); ++frame;
        p += sprintf(p, " %016llX", (unsigned long long) fb_hash());
      }
      printf("ok%s\n", hashes);
      fflush(stdout);
      hashes[0] = 0;
    } else if (!strcmp(cmd, "hash")) {
      snprintf(out, sizeof out, "ok %016llX", (unsigned long long) fb_hash());
      reply(out);
    } else if (!strcmp(cmd, "frame")) {
      snprintf(out, sizeof out, "ok %d", frame);
      reply(out);
    } else if (!strcmp(cmd, "shot")) {
      reply(write_ppm(arg) ? "ok" : "err cannot write");
    } else if (!strcmp(cmd, "savedata")) {
      void* data = NULL;
      size_t size = core->savedataClone(core, &data);
      FILE* f = fopen(arg, "wb");
      if (f) { if (size) fwrite(data, 1, size, f); fclose(f); }
      free(data);
      snprintf(out, sizeof out, "ok %zu", size);
      reply(f ? out : "err cannot write");
    } else if (!strcmp(cmd, "flush")) {
      svf->sync(svf, NULL, 0);
      reply("ok");
    } else if (!strcmp(cmd, "state_save")) {
      struct VFile* vf = VFileOpen(arg, O_CREAT | O_TRUNC | O_RDWR);
      int ok = vf && mCoreSaveStateNamed(core, vf, SAVESTATE_RTC | SAVESTATE_SCREENSHOT);
      if (vf) vf->close(vf);
      reply(ok ? "ok" : "err state_save failed");
    } else if (!strcmp(cmd, "state_load")) {
      struct VFile* vf = VFileOpen(arg, O_RDONLY);
      int ok = vf && mCoreLoadStateNamed(core, vf, SAVESTATE_RTC | SAVESTATE_SCREENSHOT);
      if (vf) vf->close(vf);
      reply(ok ? "ok" : "err state_load failed");
    } else if (!strcmp(cmd, "peek")) {
      unsigned addr = 0; int len = 0;
      sscanf(arg, "%x %d", &addr, &len);
      printf("ok ");
      for (int k = 0; k < len; ++k) printf("%02X", core->rawRead8(core, addr + k, -1));
      printf("\n");
      fflush(stdout);
    } else if (!strcmp(cmd, "quit")) {
      core->deinit(core);
      reply("ok");
      return 0;
    } else {
      reply("err unknown command");
    }
  }
  core->deinit(core);
  return 0;
}
