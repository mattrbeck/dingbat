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
#include <mgba/internal/gba/gba.h>

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

/* Cartridge RTC over the GPIO port through the core's bus, bit-banged exactly
 * as dingbat_driver's rtc_xfer does (commands MSB first, parameters LSB
 * first, one SCK low->high per bit). */
static void gpio_w(struct mCore* core, uint32_t reg, uint16_t v) {
  core->busWrite16(core, 0x08000000 + reg, v);
}

static int rtc_xfer(struct mCore* core, uint8_t cmd, const uint8_t* data, int nwrite,
                    uint8_t* out, int nread) {
  gpio_w(core, 0xC8, 1);
  gpio_w(core, 0xC6, 7);
  gpio_w(core, 0xC4, 1);
  gpio_w(core, 0xC4, 5);
  for (int i = 0; i < 8; ++i) {
    int b = (cmd >> (7 - i)) & 1;
    gpio_w(core, 0xC4, 4 | (b << 1));
    gpio_w(core, 0xC4, 5 | (b << 1));
  }
  for (int k = 0; k < nwrite; ++k)
    for (int i = 0; i < 8; ++i) {
      int b = (data[k] >> i) & 1;
      gpio_w(core, 0xC4, 4 | (b << 1));
      gpio_w(core, 0xC4, 5 | (b << 1));
    }
  if (nread > 0) {
    gpio_w(core, 0xC6, 5);
    for (int k = 0; k < nread; ++k) {
      uint8_t v = 0;
      for (int i = 0; i < 8; ++i) {
        gpio_w(core, 0xC4, 4);
        gpio_w(core, 0xC4, 5);
        v |= ((core->busRead16(core, 0x080000C4) >> 1) & 1) << i;
      }
      out[k] = v;
    }
  }
  gpio_w(core, 0xC6, 7);
  gpio_w(core, 0xC4, 1);
  return nread;
}

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
    } else if (!strcmp(cmd, "rtc_get")) {
      uint8_t dt[7], st[1];
      rtc_xfer(core, 0x65, NULL, 0, dt, 7);
      rtc_xfer(core, 0x63, NULL, 0, st, 1);
      printf("ok %02X%02X%02X%02X%02X%02X%02X %02X\n",
             dt[0], dt[1], dt[2], dt[3], dt[4], dt[5], dt[6], st[0]);
      fflush(stdout);
    } else if (!strcmp(cmd, "rtc_set")) {
      uint8_t dt[7];
      int ok = strlen(arg) >= 14;
      for (int k = 0; ok && k < 7; ++k) {
        unsigned v;
        ok = sscanf(arg + 2 * k, "%2x", &v) == 1;
        dt[k] = (uint8_t) v;
      }
      if (ok) rtc_xfer(core, 0x64, dt, 7, NULL, 0);
      reply(ok ? "ok" : "err rtc_set YYMMDDWWHHMMSS");
    } else if (!strcmp(cmd, "stepn")) {
      long want = 0;
      sscanf(arg, "%ld", &want);
      struct GBA* gba = core->board;
      for (long k = 0; k < want; ++k) core->step(core);
      printf("ok global=%llu vcount=%u pc=%08X\n",
             (unsigned long long) mTimingGlobalTime(&gba->timing),
             core->busRead16(core, 0x04000006), gba->cpu->gprs[15]);
      fflush(stdout);
    } else if (!strcmp(cmd, "stepuntil")) {
      /* stepuntil ADDR MASK: single-step until (busRead16(ADDR) & MASK) != 0;
       * reports the master clock (cycles since reset), VCOUNT, PC */
      unsigned addr = 0, mask = 0;
      sscanf(arg, "%x %x", &addr, &mask);
      struct GBA* gba = core->board;
      long n = 0;
      while (!(core->busRead16(core, addr) & mask) && n < 50000000) {
        core->step(core);
        ++n;
      }
      printf("ok steps=%ld global=%llu vcount=%u pc=%08X\n", n,
             (unsigned long long) mTimingGlobalTime(&gba->timing),
             core->busRead16(core, 0x04000006), gba->cpu->gprs[15]);
      fflush(stdout);
    } else if (!strcmp(cmd, "busread16")) {
      /* a CPU-visible read (I/O registers update lazily: timers, VCOUNT) */
      unsigned addr = 0;
      sscanf(arg, "%x", &addr);
      printf("ok %04X\n", core->busRead16(core, addr));
      fflush(stdout);
    } else if (!strcmp(cmd, "poke8")) {
      /* a bus write, e.g. a flash command sequence that dirties the save */
      unsigned addr = 0, val = 0;
      sscanf(arg, "%x %x", &addr, &val);
      core->busWrite8(core, addr, (uint8_t) val);
      reply("ok");
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
