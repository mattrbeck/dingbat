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
 * GBFUZZ_BATTERY=<path> loads and re-saves a battery save around the run, for
 * comparing what a title does on a second boot.
 *
 * GBFUZZ_PCM=<path> with GBFUZZ_PCM_FRAMES=<N> dumps N frames of audio as raw
 * s16le stereo at 32768 Hz -- the same bytes dingbat's DINGBAT_GB_AUDIO_DUMP
 * writes, for tools/pcmdiff.py. See the block in main() for the knobs. Sample
 * equality with dingbat is not achievable: SameBoy band-limits each channel
 * and models DAC charge/discharge, dingbat emits the raw DAC mix. Use
 * pcmdiff.py --correlate for this pair.
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

/* GBFUZZ_DUMP: alongside each shot, write the PPU-visible memory that produced
 * it — OAM, both VRAM banks and the two palette blocks — so a divergence can be
 * traced to whichever of them differs rather than guessed at from pixels. */
static void write_dump(const char* path, GB_gameboy_t* gb) {
  FILE* f = fopen(path, "wb");
  if (!f) { perror(path); return; }
  fwrite(gb->oam, 1, sizeof gb->oam, f);
  fwrite(gb->vram, 1, gb->vram_size, f);
  if (gb->vram_size < 0x4000) {   /* pad DMG's single bank to the CGB layout */
    static const uint8_t zero[0x2000] = {0};
    fwrite(zero, 1, 0x4000 - gb->vram_size, f);
  }
  fwrite(gb->background_palettes_data, 1, 0x40, f);
  fwrite(gb->object_palettes_data, 1, 0x40, f);
  /* Work RAM and HRAM too: when VRAM diverges but OAM and the palettes do not,
   * the CPU computed different data, and this is where it computed it. */
  fwrite(gb->ram, 1, gb->ram_size, f);
  if (gb->ram_size < 0x8000) {          /* pad DMG's 8K to the CGB 32K layout */
    static const uint8_t zero[0x8000] = {0};
    fwrite(zero, 1, 0x8000 - gb->ram_size, f);
  }
  fwrite(gb->hram, 1, 0x7F, f);
  fclose(f);
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

/* GBFUZZ_PCM=<path> — write every mixed sample as raw s16le stereo, the same
 * byte format dingbat's DINGBAT_GB_AUDIO_DUMP produces, so tools/pcmdiff.py
 * reads both. GB_sample_t is {int16_t left; int16_t right;} (a union with a
 * uint32 under GB_INTERNAL, same layout), so the struct goes straight out. */
static FILE* g_pcm;
static bool g_pcm_armed;
static void pcm_cb(GB_gameboy_t* gb, GB_sample_t* sample) {
  (void) gb;
  /* Armed only once the boot ROM is out of the way, so the dump starts at the
   * same point in the timeline as dingbat's (which never runs the boot ROM). */
  if (g_pcm_armed) fwrite(sample, sizeof *sample, 1, g_pcm);
}

/* GBFUZZ_TRACE=<path>:<startframe>:<count> — log <count> instructions as
 * "PC OP" from the start of <startframe>, in the same format the dingbat
 * runner emits, so the two can be diffed directly. */
static FILE* g_trace;
static long g_trace_left;
static void exec_cb(GB_gameboy_t* gb, uint16_t addr, uint8_t opcode) {
  (void) gb;
  if (g_trace && g_trace_left > 0) {
    fprintf(g_trace, "%04X %02X\n", addr, opcode);
    --g_trace_left;
  }
}

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

  /* GBFUZZ_MODEL=cgb|dmg overrides that. Needed for the one case the header
   * cannot express: a DMG-FLAGGED cart on a CGB, i.e. CGB COMPATIBILITY MODE.
   * daid's ppu_scanline_bgp is exactly that -- $143 = $00, and its .gbc.png
   * reference is a compat capture (its only colours come from the compat
   * background palette) -- so without this the oracle runs it as a DMG and
   * answers a different machine's question. Setting the CGB flag in the header
   * instead would NOT do: that boots CGB-native, which is a third machine. */
  /* `agb` additionally selects GB_MODEL_AGB_A and the AGB boot ROM. The AGB
   * boot ROM is the CGB one with a handful of conditionals (SameBoy builds it
   * from cgb_boot.asm with DEF AGB=1), so it is a genuinely different handoff
   * and the only way to ask this oracle an AGB-vs-CGB question. */
  int is_agb = 0;
  const char* mdl = getenv("GBFUZZ_MODEL");
  if (mdl) {
    if (!strcmp(mdl, "cgb")) is_cgb = 1;
    else if (!strcmp(mdl, "dmg")) is_cgb = 0;
    else if (!strcmp(mdl, "agb")) { is_cgb = 1; is_agb = 1; }
    else { fprintf(stderr, "GBFUZZ_MODEL must be cgb, dmg or agb\n"); return 3; }
  }

  /* Determinism, and it has to come first: GB_init seeds RAM, OAM and the CGB
   * palettes through GB_random(), whose generator is seeded from time(NULL) by
   * a library constructor. Disabling it afterwards leaves that one power-up
   * fill drawn from the wall clock, so every run of the same ROM starts from
   * different uninitialised memory and any game that reads it before writing
   * it diverges non-reproducibly. Disabled, GB_random() returns 0, which is
   * also what the other two emulators power up with. */
  GB_random_set_enabled(false);
  GB_random_seed(0);
  GB_gameboy_t gb;
  GB_init(&gb, is_agb ? GB_MODEL_AGB_A : (is_cgb ? GB_MODEL_CGB_E : GB_MODEL_DMG_B));
  GB_set_log_callback(&gb, log_cb);

  char bootpath[1024];
  snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
           is_agb ? "agb_boot.bin" : (is_cgb ? "cgb_boot.bin" : "dmg_boot.bin"));
  if (GB_load_boot_rom(&gb, bootpath)) {
    fprintf(stderr, "failed to load boot rom %s\n", bootpath);
    return 3;
  }
  if (GB_load_rom(&gb, rom)) {
    fprintf(stderr, "failed to load %s\n", rom);
    return 3;
  }

  /* GBFUZZ_BATTERY=<path>: load that battery save before running and write it
   * back afterwards. Off by default — a sweep must not carry state between
   * runs — but battery-backed behaviour (does the title find its save on the
   * second boot?) cannot be compared without it. dingbat's runner does the
   * same implicitly, via the .sav it keeps beside the ROM. */
  const char* battery = getenv("GBFUZZ_BATTERY");
  if (battery && battery[0]) GB_load_battery(&gb, battery);

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

  /* PCM dump.
   *   GBFUZZ_PCM=<path>          enable; raw s16le stereo, no header
   *   GBFUZZ_PCM_FRAMES=<N>      run N frames for the dump (default: the
   *                              highest requested screenshot frame + 1)
   *   GBFUZZ_PCM_RATE=<hz>       default 32768, matching GB_SAMPLE_RATE
   *   GBFUZZ_PCM_HIGHPASS=off|accurate|dc   default off, i.e. dingbat's
   *                              unfiltered DAC output is the target
   *   GBFUZZ_PCM_INTERFERENCE=<f>  default 0. The analog interference model
   *                              uses rand(), so any nonzero value makes the
   *                              run non-reproducible -- leave it off.
   *
   * The sample rate has to be set here, before the boot burn below, not once
   * the boot ROM has finished: GB_set_sample_rate shrinks
   * apu_output.max_cycles_per_sample from 0x400 to ~64, and switching it
   * mid-run lets one already-scheduled coarse APU batch through, which trips
   * `assert(sample_fraction < (4 << 28))` in GB_apu_run. Enabling it before
   * the first GB_run_frame keeps the batch size small throughout; the boot
   * ROM's own audio is discarded by g_pcm_armed instead.
   *
   * Rate and callback go together: SameBoy asserts a callback is installed
   * whenever the sample rate is nonzero. */
  const char* pcm_path = getenv("GBFUZZ_PCM");
  if (pcm_path && pcm_path[0]) {
    g_pcm = fopen(pcm_path, "wb");
    if (!g_pcm) { perror(pcm_path); return 3; }
    const char* hp = getenv("GBFUZZ_PCM_HIGHPASS");
    GB_highpass_mode_t hpmode = GB_HIGHPASS_OFF;
    if (hp && !strcasecmp(hp, "accurate")) hpmode = GB_HIGHPASS_ACCURATE;
    else if (hp && !strcasecmp(hp, "dc"))  hpmode = GB_HIGHPASS_REMOVE_DC_OFFSET;
    GB_set_highpass_filter_mode(&gb, hpmode);
    const char* itf = getenv("GBFUZZ_PCM_INTERFERENCE");
    GB_set_interference_volume(&gb, itf ? atof(itf) : 0.0);
    const char* rate = getenv("GBFUZZ_PCM_RATE");
    unsigned hz = rate && rate[0] ? (unsigned) atoi(rate) : 32768u;
    GB_apu_set_sample_callback(&gb, pcm_cb);
    GB_set_sample_rate(&gb, hz);
    /* GBFUZZ_CHANNELS=<4 chars, '1' or '0'> — per-channel mute (CH1 CH2 CH3
     * CH4), matching dingbat_gb_nav's identically-spelled variable, so one
     * channel can be isolated on both sides and the dumps diffed. */
    const char* chsel = getenv("GBFUZZ_CHANNELS");
    if (chsel && strlen(chsel) == 4)
      for (int i = 0; i < 4; ++i)
        GB_set_channel_muted(&gb, (GB_channel_t) i, chsel[i] == '0');
    const char* pf = getenv("GBFUZZ_PCM_FRAMES");
    if (pf && pf[0]) {
      int n = atoi(pf);
      if (n > max_frame + 1) max_frame = n - 1;
    }
  }

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

  if (g_pcm) g_pcm_armed = true;   /* boot ROM is done; start recording */

  char trpath[1024] = {0};
  int tr_start = -1;
  const char* tr = getenv("GBFUZZ_TRACE");
  if (tr && sscanf(tr, "%1023[^:]:%d:%ld", trpath, &tr_start, &g_trace_left) == 3)
    GB_set_execution_callback(&gb, exec_cb);

  for (int f = 0; f <= max_frame; ++f) {
    if (f == tr_start && trpath[0]) g_trace = fopen(trpath, "w");
    for (int i = 0; i < g_nev; ++i)
      if (g_ev[i].frame == f) GB_set_key_state(&gb, g_ev[i].key, g_ev[i].press);
    GB_run_frame(&gb);
    for (int i = 0; i < g_nshots; ++i)
      if (g_shots[i] == f) {
        char path[1024];
        snprintf(path, sizeof path, "%s.f%04d.ppm", prefix, f);
        write_ppm(path, vbuf);
        if (getenv("GBFUZZ_DUMP")) {
          snprintf(path, sizeof path, "%s.f%04d.mem", prefix, f);
          write_dump(path, &gb);
        }
      }
  }
  if (g_trace) fclose(g_trace);
  if (g_pcm) {
    /* Detach before the file closes: GB_free runs the APU one last time. */
    GB_set_sample_rate(&gb, 0);
    GB_apu_set_sample_callback(&gb, NULL);
    fclose(g_pcm);
    g_pcm = NULL;
  }
  if (battery && battery[0]) GB_save_battery(&gb, battery);
  GB_free(&gb);
  return 0;
}
