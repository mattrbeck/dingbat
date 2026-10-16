/* Persistent headless driver for the second reference emulator (links its
 * static libs as a black box). Speaks the line protocol in
 * tools/playtest/README.md.
 *
 * Usage: nba_driver <rom.gba> <bios.bin> [--run-bios] [--rtc EPOCH] [--audio PATH]
 *   --audio writes the core's output, s16le stereo at 32768 Hz: the capture
 *   device pulls, after every frame, the samples of the cycles the core ran.
 *   --rtc freezes the cartridge clock at that unix epoch, as the other
 *   drivers do (run with TZ=UTC); without it the clock is the host's.
 *   The battery save is <rom minus extension>.sav, as its frontend names it.
 *   `savedata` is unsupported (the core exposes no backup accessor); the
 *   harness reads the file written at `quit` instead.
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
#include <ctime>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <sys/time.h>

// --rtc. The core has no clock setting: its cartridge RTC reads the C
// library's time() (the only clock its static library imports, with
// localtime). This definition is linked ahead of the C library's, so the
// core's calls land here and read the frozen epoch, as dingbat and mGBA
// do with --rtc; without --rtc it answers the host clock as before. Left on
// the host clock, Shin Bokura no Taiyou's boot (a date-dependent soft-float
// computation) took 53 frames instead of 60 and its first screens ran 7
// frames ahead of dingbat's (docs/playtest-bugs.md, "Shin Bokura no Taiyou:
// the sensor notice").
static long long g_rtc_epoch = -1;
extern "C" time_t time(time_t* out) {
  time_t now;
  if (g_rtc_epoch >= 0) {
    now = time_t(g_rtc_epoch);
  } else {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    now = tv.tv_sec;
  }
  if (out) *out = now;
  return now;
}

static constexpr int W = 240;
static constexpr int H = 160;

static const nba::Key KEY_ORDER[10] = {
  nba::Key::A, nba::Key::B, nba::Key::Select, nba::Key::Start, nba::Key::Right,
  nba::Key::Left, nba::Key::Up, nba::Key::Down, nba::Key::R, nba::Key::L
};

// The core presents a frame at the end of its V-blank (line 227 -> 0), 68
// lines after dingbat and mGBA end theirs, and it double-buffers: the buffer
// it is drawing into is the one it presented two frames ago, and at line 160
// it already holds this frame's picture (400 of 400 frames equal to the next
// presentation, Donkey Kong Country). `frame` is the harness's picture, taken
// from that buffer when a harness frame ends (run_frame).
struct CaptureVideo final : nba::VideoDevice {
  u32 frame[W * H] = {};
  u32* shown = nullptr;   // the buffer last presented
  u32* drawing = nullptr; // the other one: the frame being drawn
  long presented = 0;     // presentations so far: one per V-blank's end
  void Draw(u32* buffer) override {
    ++presented;
    if (buffer != shown) { drawing = shown; shown = buffer; }
    if (!drawing) memcpy(frame, buffer, sizeof frame);  // before the second presentation
  }
  void Capture() { if (drawing) memcpy(frame, drawing, sizeof frame); }
};

// Audio is pulled, not pushed: the core hands its device a callback that
// fills a buffer; calling it after each frame for exactly the samples that
// frame produced keeps the stream in step with emulated time. "Produced" is
// the core's own clock (its scheduler's timestamp), not the cycles the driver
// asked Run for: Run finishes the instruction or DMA it is in, so each
// 4-cycle step to line 160 runs a little over. Counting the requested cycles
// pulled ~1.3 samples a frame fewer than the core made (Driv3r: 547.28 a
// frame, not 548.58). The rest waited in the core's buffer, so the file was
// the right stream with its last 0.24% missing, and the audio check, which
// spreads each dump over the run's frames, read this emulator's audio
// progressively early: 4 frames by f1750, 25 by Driv3r's end, more on longer
// scripts (docs/playtest-bugs.md, "Driv3r's audio: the second reference's
// capture ran 0.24% short").
struct CaptureAudio final : nba::AudioDevice {
  void* userdata = nullptr;
  Callback callback = nullptr;
  FILE* file = nullptr;
  double owed = 0;
  u64 pulled_to = 0;  // core timestamp the samples written so far reach
  auto GetSampleRate() -> int override { return 32768; }
  auto GetBlockSize() -> int override { return 4096; }
  bool Open(void* ud, Callback cb) override { userdata = ud; callback = cb; return true; }
  void SetPause(bool) override {}
  void Close() override {}
  // a state load moves the core's clock: the stream carries on from there
  void Rebase(u64 now) { pulled_to = now; }
  void Frame(u64 now) {
    u64 cycles = now > pulled_to ? now - pulled_to : 0;
    pulled_to = now;
    if (!callback || !file) return;
    owed += 32768.0 * double(cycles) / 16777216.0;
    int n = int(owed);
    owed -= n;
    static s16 buf[4096 * 2];
    while (n > 0) {
      int k = n > 4096 ? 4096 : n;
      callback(userdata, buf, k * 4);
      fwrite(buf, 4, k, file);
      n -= k;
    }
  }
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
  const char* audio_path = nullptr;
  auto backup = nba::Config::BackupType::Detect;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--run-bios")) run_bios = true;
    else if (!strcmp(argv[i], "--rtc") && i + 1 < argc) g_rtc_epoch = atoll(argv[++i]);
    else if (!strcmp(argv[i], "--audio") && i + 1 < argc) audio_path = argv[++i];
    else if (!strcmp(argv[i], "--backup") && i + 1 < argc) {
      // the chip as dingbat sized it (emu.py); the core's own guess sizes a
      // 4 Kbit EEPROM as 64 Kbit and then cannot read its file back (§94)
      std::string t = argv[++i];
      if (t == "eeprom4") backup = nba::Config::BackupType::EEPROM_4;
      else if (t == "eeprom64") backup = nba::Config::BackupType::EEPROM_64;
      else {
        fprintf(stderr, "unknown --backup %s\n", t.c_str());
        return 2;
      }
    }
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
  auto audio = std::make_shared<CaptureAudio>();
  if (audio_path) audio->file = fopen(audio_path, "wb");
  config->audio_dev = audio;
  config->skip_bios = !run_bios;
  auto core = nba::CreateCore(config);
  if (nba::BIOSLoader::Load(core, pos[1]) != nba::BIOSLoader::Result::Success) {
    fprintf(stderr, "failed to load bios %s\n", pos[1].c_str());
    return 3;
  }
  if (nba::ROMLoader::Load(core, rom, save, backup) != nba::ROMLoader::Result::Success) {
    fprintf(stderr, "failed to load rom %s\n", rom.c_str());
    return 3;
  }
  core->Reset();
  if (!run_bios) {
    // the BIOS hands the cartridge System mode with IRQ and FIQ enabled
    // (CPSR 0x1F); the core's skipped boot enters with both masked (0xDF).
    // A game that never writes the I bit itself then waits for its first
    // interrupt forever: V-Rally 3 spun at a timer flag from f100 and showed
    // no picture, as did Driv3r and Asterix XXL (docs/playtest-bugs.md §94)
    static nba::SaveState st;
    core->CopyState(st);
    st.arm.regs.cpsr &= ~0xC0u;
    core->LoadState(st);
  }

  int frame = 0;
  int held = 0;
  // A harness frame ends at the V-blank's start (VCOUNT 160), as dingbat's
  // and mGBA's drivers end theirs: keys set between frames reach a V-blank
  // handler at the same point, RAM is read at the same point, and the picture
  // is the frame just drawn. Running kCyclesPerFrame a call instead stopped
  // at a drifting line before 160 (142-159), so the picture shown was the
  // previous frame's (docs/playtest-bugs.md, "The second reference's pictures
  // are a frame stale"). Whole lines to line 159, then 4-cycle steps until
  // VCOUNT reaches the V-blank lines. Not until it reads 160: a DMA that
  // starts on line 159 runs as one step past 160 (Mega Man Battle Network
  // 2's boot: 16k cycles, to line 172), and waiting for 160 ran a second
  // frame into the first (docs/playtest-bugs.md §83, "Mega Man Battle Network
  // 2"). dingbat and mGBA end such a frame at the DMA's end too.
  //
  // The core runs a DMA burst whole: a Run that starts one runs to its end,
  // however far past the requested cycles. Super Mario Advance 3's crt0
  // clears EWRAM with one 65536-word DMA (458,761 cycles, 1.6 frames); from
  // line 131 it ended at line 47 two frames later, the 4-cycle steps went on
  // to the next line 160, and the one harness frame held three V-blank
  // starts. Every later frame was then two frames ahead of dingbat's and
  // mGBA's, whose frames end at the V-blank start inside the burst
  // (docs/playtest-bugs.md §82, "Super Mario Advance 3: 1-1 after a soft
  // reset"). The V-blank ends a frame covered are counted (one presentation
  // each); the starts it swallowed are owed, and the next harness frames end
  // at once, one per start, so frame n is the n-th V-blank start again.
  // Their picture and RAM are the burst's end.
  long owed = 0;
  auto now = [&]() { return core->GetScheduler().GetTimestampNow(); };
  audio->Rebase(now());
  auto run_frame = [&]() {
    if (owed > 0) {
      --owed;
      video->Capture();
      audio->Frame(now());  // nothing new: the burst's frame pulled these cycles
      return;
    }
    long ran = 0;
    int v = core->PeekByteIO(0x04000006);
    int lines = (160 - v + 228) % 228;
    if (lines == 0) lines = 228;
    // a frame from line 160-227 holds one V-blank end (227 -> 0), from
    // below 160 none
    long expected = v >= 160 ? 1 : 0;
    long before = video->presented;
    if (lines > 1) { core->Run((lines - 1) * 1232); ran += (lines - 1) * 1232; }
    while (core->PeekByteIO(0x04000006) < 160 && ran < 2 * 280896) { core->Run(4); ran += 4; }
    long extra = video->presented - before - expected;
    video->Capture();
    if (extra > 0) owed = extra;
    audio->Frame(now());
  };
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
      for (int k = atoi(arg.c_str()); k > 0; --k) { run_frame(); ++frame; }
      reply("ok " + std::to_string(frame));
    } else if (cmd == "runhash") {
      std::string out = "ok";
      for (int k = atoi(arg.c_str()); k > 0; --k) {
        run_frame(); ++frame;
        out += " " + fb_hash(video->frame);
      }
      reply(out);
    } else if (cmd == "hash") {
      reply("ok " + fb_hash(video->frame));
    } else if (cmd == "frame") {
      reply("ok " + std::to_string(frame));
    } else if (cmd == "shot") {
      reply(write_ppm(arg, video->frame) ? "ok" : "err cannot write");
    } else if (cmd == "peek") {
      // work RAM, palette, VRAM and OAM through the core's save-state copy
      // (no timed bus access, nothing moved), I/O through its peek calls;
      // other regions unsupported
      std::istringstream a(arg);
      std::string hex;
      unsigned long len = 0;
      a >> hex >> len;
      u32 addr = u32(strtoul(hex.c_str(), nullptr, 16));
      static nba::SaveState state;
      bool need_state = (addr >> 24) != 4;
      if (need_state) core->CopyState(state);
      std::string out = "ok ";
      bool ok = true;
      for (unsigned long k = 0; k < len && ok; ++k) {
        u32 x = addr + u32(k);
        u8 v = 0;
        switch (x >> 24) {
          case 2: v = state.bus.memory.wram[x & 0x3FFFF]; break;
          case 3: v = state.bus.memory.iram[x & 0x7FFF]; break;
          case 4: v = core->PeekByteIO(x); break;
          case 5: v = state.bus.memory.pram[x & 0x3FF]; break;
          case 6: {
            u32 o = x & 0x1FFFF;
            v = state.bus.memory.vram[o >= 0x18000 ? o - 0x8000 : o];
            break;
          }
          case 7: v = state.bus.memory.oam[x & 0x3FF]; break;
          default: ok = false;
        }
        char b[3];
        snprintf(b, sizeof b, "%02X", v);
        out += b;
      }
      reply(ok ? out : "err unsupported region");
    } else if (cmd == "regs") {
      // the CPU's registers from the save-state copy: r0-r15 then CPSR, hex
      static nba::SaveState state;
      core->CopyState(state);
      std::string out = "ok";
      char b[12];
      for (int k = 0; k < 16; ++k) { snprintf(b, sizeof b, " %08X", state.arm.regs.gpr[k]); out += b; }
      snprintf(b, sizeof b, " %08X", state.arm.regs.cpsr);
      out += b;
      reply(out);
    } else if (cmd == "ppuio") {
      // the PPU's register latches from the save-state copy, write-only ones
      // included: DISPCNT BG0-3CNT BG0-3HOFS BG0-3VOFS BG2PA-PD BG3PA-PD
      // BG2X BG2Y BG3X BG3Y WIN0H WIN1H WIN0V WIN1V WININ WINOUT MOSAIC
      // BLDCNT BLDALPHA BLDY, hex. MOSAIC is as the core keeps it, not the
      // register: 1111 where dingbat and mGBA latch 0000 (each size plus one)
      static nba::SaveState state;
      core->CopyState(state);
      auto& io = state.ppu.io;
      std::string out = "ok";
      char b[12];
      auto put = [&](unsigned long v, int w) { snprintf(b, sizeof b, " %0*lX", w, v); out += b; };
      put(io.dispcnt, 4);
      for (int k = 0; k < 4; ++k) put(io.bgcnt[k], 4);
      for (int k = 0; k < 4; ++k) put(io.bghofs[k], 4);
      for (int k = 0; k < 4; ++k) put(io.bgvofs[k], 4);
      for (int k = 0; k < 2; ++k) { put(io.bgpa[k], 4); put(io.bgpb[k], 4); put(io.bgpc[k], 4); put(io.bgpd[k], 4); }
      for (int k = 0; k < 2; ++k) { put(io.bgx[k], 8); put(io.bgy[k], 8); }
      put(io.winh[0], 4); put(io.winh[1], 4); put(io.winv[0], 4); put(io.winv[1], 4);
      put(io.winin, 4); put(io.winout, 4); put(io.mosaic, 4);
      put(io.bldcnt, 4); put(io.bldalpha, 4); put(io.bldy, 4);
      reply(out);
    } else if (cmd == "savedata" || cmd == "flush") {
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
      // the core only redraws when a frame runs, so the screen rides along
      bool ok = f && fwrite(state.get(), sizeof(nba::SaveState), 1, f) == 1 &&
                fwrite(video->frame, sizeof video->frame, 1, f) == 1;
      if (f) fclose(f);
      reply(ok ? "ok" : "err state_save failed");
    } else if (cmd == "state_load") {
      auto state = std::make_unique<nba::SaveState>();
      FILE* f = fopen(arg.c_str(), "rb");
      bool ok = f && fread(state.get(), sizeof(nba::SaveState), 1, f) == 1 &&
                fread(video->frame, sizeof video->frame, 1, f) == 1;
      if (f) fclose(f);
      if (ok) { core->LoadState(*state); owed = 0; audio->Rebase(now()); }
      reply(ok ? "ok" : "err state_load failed");
    } else if (cmd == "quit") {
      if (audio->file) fclose(audio->file);
      audio->file = nullptr;
      core.reset();
      reply("ok");
      return 0;
    } else {
      reply("err unknown command");
    }
  }
  return 0;
}
