/* Persistent headless driver for the second reference emulator (links its
 * static libs as a black box). Speaks the line protocol in
 * tools/playtest/README.md.
 *
 * Usage: nba_driver <rom.gba> <bios.bin> [--run-bios]
 *   The battery save is <rom minus extension>.sav, as its frontend names it.
 *   It has no RTC override: run with TZ=UTC. `savedata` is unsupported (the
 *   core exposes no backup accessor); the harness reads the file written at
 *   `quit` instead.
 *
 * Build: tools/playtest/build.sh
 */
#include <nba/core.hpp>
#include <platform/loader/bios.hpp>
#include <platform/loader/rom.hpp>
#include <nba/save_state.hpp>

#include <cstdio>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

static constexpr int W = 240;
static constexpr int H = 160;

static const nba::Key KEY_ORDER[10] = {
  nba::Key::A, nba::Key::B, nba::Key::Select, nba::Key::Start, nba::Key::Right,
  nba::Key::Left, nba::Key::Up, nba::Key::Down, nba::Key::R, nba::Key::L
};

struct CaptureVideo final : nba::VideoDevice {
  u32 frame[W * H] = {};
  void Draw(u32* buffer) override { memcpy(frame, buffer, sizeof frame); }
};

static u16 px555(u32 c) {
  /* ARGB8888 */
  u16 r = ((c >> 16) & 0xFF) >> 3, g = ((c >> 8) & 0xFF) >> 3, b = (c & 0xFF) >> 3;
  return r | (g << 5) | (b << 10);
}

static std::string fb_hash(const u32* fb) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (int i = 0; i < W * H; ++i) h = (h ^ px555(fb[i])) * 0x100000001b3ULL;
  char s[20];
  snprintf(s, sizeof s, "%016llX", (unsigned long long) h);
  return s;
}

static bool write_ppm(const std::string& path, const u32* fb) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; ++i) {
    u16 p = px555(fb[i]);
    u8 r = p & 0x1F, g = (p >> 5) & 0x1F, b = (p >> 10) & 0x1F;
    u8 rgb[3] = {u8((r << 3) | (r >> 2)), u8((g << 3) | (g >> 2)), u8((b << 3) | (b >> 2))};
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
  return true;
}

// The core logs to stdout; replies go to a private copy of the original
// stdout and fd 1 is pointed at stderr (see main).
static FILE* g_out = stdout;
static void reply(const std::string& s) { fprintf(g_out, "%s\n", s.c_str()); fflush(g_out); }

int main(int argc, char** argv) {
  std::string pos[2];
  int npos = 0;
  bool run_bios = false;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--run-bios")) run_bios = true;
    else if (!strcmp(argv[i], "--rtc") && i + 1 < argc) ++i;
    else if (npos < 2) pos[npos++] = argv[i];
  }
  if (npos != 2) {
    fprintf(stderr, "Usage: %s <rom> <bios> [--run-bios]\n", argv[0]);
    return 2;
  }
  g_out = fdopen(dup(1), "w");
  fflush(stdout);
  dup2(2, 1);
  std::string rom = pos[0];
  std::string save = rom;
  auto dot = save.rfind('.');
  auto slash = save.rfind('/');
  if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) save.resize(dot);
  save += ".sav";

  auto config = std::make_shared<nba::Config>();
  auto video = std::make_shared<CaptureVideo>();
  config->video_dev = video;
  config->skip_bios = !run_bios;
  auto core = nba::CreateCore(config);
  if (nba::BIOSLoader::Load(core, pos[1]) != nba::BIOSLoader::Result::Success) {
    fprintf(stderr, "failed to load bios %s\n", pos[1].c_str());
    return 3;
  }
  if (nba::ROMLoader::Load(core, rom, save) != nba::ROMLoader::Result::Success) {
    fprintf(stderr, "failed to load rom %s\n", rom.c_str());
    return 3;
  }
  core->Reset();

  int frame = 0;
  int held = 0;
  reply("ready nba save=" + save);
  std::string line;
  while (std::getline(std::cin, line)) {
    std::istringstream in(line);
    std::string cmd, arg;
    in >> cmd;
    std::getline(in >> std::ws, arg);
    if (cmd.empty()) continue;
    if (cmd == "keys") {
      int mask = atoi(arg.c_str());
      for (int b = 0; b < 10; ++b)
        if (((mask ^ held) >> b) & 1) core->SetKeyStatus(KEY_ORDER[b], (mask >> b) & 1);
      held = mask;
      reply("ok");
    } else if (cmd == "run") {
      for (int k = atoi(arg.c_str()); k > 0; --k) { core->Run(nba::CoreBase::kCyclesPerFrame); ++frame; }
      reply("ok " + std::to_string(frame));
    } else if (cmd == "runhash") {
      std::string out = "ok";
      for (int k = atoi(arg.c_str()); k > 0; --k) {
        core->Run(nba::CoreBase::kCyclesPerFrame); ++frame;
        out += " " + fb_hash(video->frame);
      }
      reply(out);
    } else if (cmd == "hash") {
      reply("ok " + fb_hash(video->frame));
    } else if (cmd == "frame") {
      reply("ok " + std::to_string(frame));
    } else if (cmd == "shot") {
      reply(write_ppm(arg, video->frame) ? "ok" : "err cannot write");
    } else if (cmd == "savedata" || cmd == "flush" || cmd == "peek") {
      reply("err unsupported");
    } else if (cmd == "state_save") {
      // The core's own writer leaves fields of absent hardware (the RTC on
      // carts without one) uninitialised, and its loader then rejects many
      // of those states. A zeroed struct dumped raw round-trips within this
      // binary, which is all a session needs.
      auto state = std::make_unique<nba::SaveState>();
      memset(state.get(), 0, sizeof(nba::SaveState));
      core->CopyState(*state);
      FILE* f = fopen(arg.c_str(), "wb");
      bool ok = f && fwrite(state.get(), sizeof(nba::SaveState), 1, f) == 1;
      if (f) fclose(f);
      reply(ok ? "ok" : "err state_save failed");
    } else if (cmd == "state_load") {
      auto state = std::make_unique<nba::SaveState>();
      FILE* f = fopen(arg.c_str(), "rb");
      bool ok = f && fread(state.get(), sizeof(nba::SaveState), 1, f) == 1;
      if (f) fclose(f);
      if (ok) core->LoadState(*state);
      reply(ok ? "ok" : "err state_load failed");
    } else if (cmd == "quit") {
      core.reset();
      reply("ok");
      return 0;
    } else {
      reply("err unknown command");
    }
  }
  return 0;
}
