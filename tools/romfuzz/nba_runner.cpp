/* Headless NanoBoyAdvance runner for cross-emulator screenshot comparison.
 *
 * Usage: nba_runner <rom.gba> <bios.bin> <outprefix> <script> <shots>
 * Same CLI contract as mgba_runner.c / dingbat_nav.nim.
 *
 * Build: see build.sh (links ~/code/NanoBoyAdvance/build static libs)
 */
#include <nba/core.hpp>
#include <platform/loader/bios.hpp>
#include <platform/loader/rom.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

static constexpr int W = 240;
static constexpr int H = 160;

struct Ev { int frame; nba::Key key; bool press; };

static nba::Key key_by_name(const std::string& name) {
  if (name == "A") return nba::Key::A;
  if (name == "B") return nba::Key::B;
  if (name == "SELECT") return nba::Key::Select;
  if (name == "START") return nba::Key::Start;
  if (name == "RIGHT") return nba::Key::Right;
  if (name == "LEFT") return nba::Key::Left;
  if (name == "UP") return nba::Key::Up;
  if (name == "DOWN") return nba::Key::Down;
  if (name == "R") return nba::Key::R;
  if (name == "L") return nba::Key::L;
  fprintf(stderr, "unknown key %s\n", name.c_str());
  exit(2);
}

struct CaptureVideo final : nba::VideoDevice {
  u32 frame[W * H] = {};
  void Draw(u32* buffer) override { memcpy(frame, buffer, sizeof frame); }
};

static std::vector<std::string> split(const std::string& s, char sep) {
  std::vector<std::string> out;
  size_t start = 0;
  while (start <= s.size()) {
    size_t end = s.find(sep, start);
    if (end == std::string::npos) end = s.size();
    if (end > start) out.push_back(s.substr(start, end - start));
    start = end + 1;
  }
  return out;
}

static void write_ppm(const std::string& path, const u32* buf) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) { perror(path.c_str()); exit(3); }
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; ++i) {
    /* NBA PPU output is ARGB8888: B low byte, G mid, R high */
    unsigned char rgb[3] = {
      (unsigned char) ((buf[i] >> 16) & 0xFF),
      (unsigned char) ((buf[i] >> 8) & 0xFF),
      (unsigned char) (buf[i] & 0xFF)
    };
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
}

int main(int argc, char** argv) {
  if (argc != 6) {
    fprintf(stderr, "Usage: %s <rom> <bios> <outprefix> <script> <shots>\n", argv[0]);
    return 2;
  }
  std::string rom = argv[1], bios = argv[2], prefix = argv[3];

  std::vector<Ev> evs;
  for (auto& tok : split(argv[4], ',')) {
    auto parts = split(tok, ':');
    if (parts.size() < 2) { fprintf(stderr, "bad script entry %s\n", tok.c_str()); return 2; }
    int frame = atoi(parts[0].c_str());
    int hold = parts.size() > 2 ? atoi(parts[2].c_str()) : 10;
    nba::Key key = key_by_name(parts[1]);
    evs.push_back({frame, key, true});
    evs.push_back({frame + hold, key, false});
  }
  std::vector<int> shots;
  for (auto& tok : split(argv[5], ',')) shots.push_back(atoi(tok.c_str()));

  auto config = std::make_shared<nba::Config>();
  auto video = std::make_shared<CaptureVideo>();
  config->video_dev = video;
  /* skip the boot logo so frame 0 is the first game frame in every emulator,
   * unless ROMFUZZ_RUN_BIOS is set (full-BIOS timing experiments) */
  config->skip_bios = getenv("ROMFUZZ_RUN_BIOS") == nullptr;

  auto core = nba::CreateCore(config);
  if (nba::BIOSLoader::Load(core, bios) != nba::BIOSLoader::Result::Success) {
    fprintf(stderr, "failed to load bios %s\n", bios.c_str());
    return 3;
  }
  std::string save_path = prefix + ".sav";
  if (nba::ROMLoader::Load(core, rom, save_path) != nba::ROMLoader::Result::Success) {
    fprintf(stderr, "failed to load rom %s\n", rom.c_str());
    return 3;
  }
  core->Reset();

  int max_frame = 0;
  for (int s : shots) if (s > max_frame) max_frame = s;

  for (int f = 0; f <= max_frame; ++f) {
    for (auto& ev : evs)
      if (ev.frame == f) core->SetKeyStatus(ev.key, ev.press);
    core->Run(nba::CoreBase::kCyclesPerFrame);
    for (int s : shots)
      if (s == f) {
        char path[1024];
        snprintf(path, sizeof path, "%s.f%04d.ppm", prefix.c_str(), f);
        write_ppm(path, video->frame);
      }
  }
  return 0;
}
