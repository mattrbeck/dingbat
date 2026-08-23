/* Headless docboy runner (links docboy's library as a black-box oracle, via
 * the public Core/Lcd interface only) for cross-emulator screenshot comparison.
 *
 * Usage: docboy_gb_runner <rom.gb> <bootromdir> <outprefix> <script> <shots>
 *   script: comma-separated FRAME:KEY[:HOLD] (empty string for none),
 *           KEY in A,B,SELECT,START,RIGHT,LEFT,UP,DOWN; HOLD defaults 10
 *   shots:  comma-separated frame numbers; writes <outprefix>.f<frame>.ppm
 *
 * Same CLI contract and frame loop as tools/gbfuzz/sameboy_runner.c and
 * dingbat_gb_nav.nim: per frame, apply that frame's input events, step one
 * frame, then shoot, so shot N is the display after N+1 stepped frames in
 * every runner. All runners play the boot ROM out of <bootromdir> and count
 * frame 0 from power-on; docboy's boot ROM support is compile-time
 * (ENABLE_BOOTROM), so there is no skip-boot mode here.
 *
 * Model selection is compile-time too (ENABLE_CGB): build.sh produces two
 * binaries and the driver picks on the cartridge CGB flag (0x143 bit 7).
 *
 * Palette normalisation, so bytes are comparable:
 *   DMG build   Lcd's palette is one entry per shade; set to the identity so
 *               the shade index comes out untouched, then mapped to GREY4.
 *   CGB build   Lcd's palette is a 32768-entry RGB555 LUT; set to the
 *               identity so the framebuffer word is the raw CGB palette word
 *               (red in the low 5 bits), the layout dingbat's framebuffer
 *               uses. The 5->8 expansion is the one in tools/gbgate/fb2png.py.
 *
 * Environment:
 *   GBDIFF_DUMP=1   alongside each shot, write <prefix>.f<frame>.mem: OAM,
 *                   both VRAM banks, work RAM and HRAM, in the layout
 *                   sameboy_runner.c and dingbat_gb_nav.nim use, minus their
 *                   palette blocks (private to docboy's Ppu).
 *
 * Build: see build.sh (added to the docboy tree as an extra frontend target,
 * so it inherits the compile definitions libdocboy was built with).
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "docboy/bootrom/factory.h"
#include "docboy/core/core.h"
#include "docboy/gameboy/gameboy.h"

namespace {

constexpr int W = 160;
constexpr int H = 144;

/* Shared four-shade DMG ramp, lightest first, matching dingbat_gb_nav.nim's
 * GREY4 (sameboy_runner.c lists it darkest first). Every value survives an
 * 8->5->8 bit round trip, so all four runners emit equal bytes. */
constexpr uint8_t GREY4[4] = {0xFF, 0xAD, 0x52, 0x00};

struct Ev {
    int frame;
    Joypad::Key key;
    bool press;
};

std::vector<Ev> g_ev;
std::vector<int> g_shots;

/* Globals: GameBoy is far too large to sit on the stack (docboy's own nogui
 * frontend does the same). */
GameBoy gb {};
Core core {gb};

Joypad::Key key_id(const std::string& name) {
    static const struct {
        const char* name;
        Joypad::Key key;
    } names[] = {
        {"RIGHT", Joypad::Key::Right}, {"LEFT", Joypad::Key::Left},
        {"UP", Joypad::Key::Up},       {"DOWN", Joypad::Key::Down},
        {"A", Joypad::Key::A},         {"B", Joypad::Key::B},
        {"SELECT", Joypad::Key::Select}, {"START", Joypad::Key::Start},
    };
    for (const auto& n : names) {
        if (strcasecmp(name.c_str(), n.name) == 0) {
            return n.key;
        }
    }
    fprintf(stderr, "unknown key %s\n", name.c_str());
    exit(2);
}

void parse_script(char* s) {
    for (char* tok = strtok(s, ","); tok; tok = strtok(nullptr, ",")) {
        int frame, hold = 10;
        char key[16];
        if (sscanf(tok, "%d:%15[^:]:%d", &frame, key, &hold) < 2) {
            fprintf(stderr, "bad script entry %s\n", tok);
            exit(2);
        }
        const Joypad::Key k = key_id(key);
        g_ev.push_back({frame, k, true});
        g_ev.push_back({frame + hold, k, false});
    }
}

void write_ppm(const std::string& path) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) {
        perror(path.c_str());
        exit(3);
    }
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    const PixelRgb565* px = gb.lcd.get_pixels();
    for (int i = 0; i < W * H; ++i) {
        const uint16_t v = px[i];
        uint8_t rgb[3];
#ifdef ENABLE_CGB
        const uint8_t r5 = v & 31, g5 = (v >> 5) & 31, b5 = (v >> 10) & 31;
        rgb[0] = (uint8_t)((r5 << 3) | (r5 >> 2));
        rgb[1] = (uint8_t)((g5 << 3) | (g5 >> 2));
        rgb[2] = (uint8_t)((b5 << 3) | (b5 >> 2));
#else
        /* Identity palette, so v is the shade index. Anything else means the
         * PPU pushed a colour it should not have; let it through as a
         * difference rather than quantising it away. */
        const uint8_t shade = v < 4 ? GREY4[v] : 0x7F;
        rgb[0] = rgb[1] = rgb[2] = shade;
#endif
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

/* Companion to gbfuzz's GBFUZZ_DUMP, same layout minus the palette blocks:
 * OAM (160) | VRAM bank 0 (8K) | VRAM bank 1 (8K, zero-padded on DMG) |
 * work RAM (32K, zero-padded on DMG) | HRAM (127). */
void write_dump(const std::string& path) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) {
        perror(path.c_str());
        return;
    }
    static const uint8_t ZERO[0x2000] = {0};

    for (uint16_t i = 0; i < Oam::Size; ++i) {
        const uint8_t b = gb.oam[i];
        fwrite(&b, 1, 1, f);
    }
    for (uint16_t i = 0; i < Vram0::Size; ++i) {
        const uint8_t b = gb.vram0[i];
        fwrite(&b, 1, 1, f);
    }
#ifdef ENABLE_CGB
    for (uint16_t i = 0; i < Vram1::Size; ++i) {
        const uint8_t b = gb.vram1[i];
        fwrite(&b, 1, 1, f);
    }
#else
    fwrite(ZERO, 1, 0x2000, f);
#endif
    for (uint16_t i = 0; i < Wram1::Size; ++i) {
        const uint8_t b = gb.wram1[i];
        fwrite(&b, 1, 1, f);
    }
    /* gb.wram2 is an array in both builds -- 7 banks on CGB, 1 on DMG -- so
     * one loop covers both, and the DMG case is zero-padded up to the CGB
     * layout so a dump from either model has the same offsets. */
    constexpr int WRAM2_BANKS = (int)(sizeof gb.wram2 / sizeof gb.wram2[0]);
    for (int bank = 0; bank < WRAM2_BANKS; ++bank) {
        for (uint16_t i = 0; i < Wram2::Size; ++i) {
            const uint8_t b = gb.wram2[bank][i];
            fwrite(&b, 1, 1, f);
        }
    }
    for (int bank = WRAM2_BANKS; bank < 7; ++bank) {
        fwrite(ZERO, 1, Wram2::Size, f);
    }
    for (uint16_t i = 0; i < Hram::Size; ++i) {
        const uint8_t b = gb.hram[i];
        fwrite(&b, 1, 1, f);
    }
    fclose(f);
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 6) {
        fprintf(stderr, "Usage: %s <rom> <bootromdir> <outprefix> <script> <shots>\n", argv[0]);
        return 2;
    }
    const char* rom = argv[1];
    const char* bootdir = argv[2];
    const std::string prefix = argv[3];
    char* script = strdup(argv[4]);
    char* shots = strdup(argv[5]);

    if (script[0]) {
        parse_script(script);
    }
    for (char* tok = strtok(shots, ","); tok; tok = strtok(nullptr, ",")) {
        g_shots.push_back(atoi(tok));
    }

    /* Cartridge CGB flag can only be checked here, not acted on: the model
     * is compile-time, so the driver routes a ROM to the right binary. */
    FILE* rf = fopen(rom, "rb");
    if (!rf) {
        perror(rom);
        return 3;
    }
    uint8_t hdr[0x150];
    const size_t got = fread(hdr, 1, sizeof hdr, rf);
    fclose(rf);
    if (got < sizeof hdr) {
        fprintf(stderr, "rom too small: %s\n", rom);
        return 3;
    }
    const bool is_cgb = (hdr[0x143] & 0x80) != 0;
#ifdef ENABLE_CGB
    const bool build_is_cgb = true;
#else
    const bool build_is_cgb = false;
#endif
    if (is_cgb != build_is_cgb) {
        fprintf(stderr, "model mismatch: rom wants %s, this build is %s\n", is_cgb ? "CGB" : "DMG",
                build_is_cgb ? "CGB" : "DMG");
        return 4;
    }

    /* Identity palette: see the header comment. */
    Appearance appearance {};
#ifdef ENABLE_CGB
    for (uint32_t i = 0; i < Appearance::NUM_COLORS; ++i) {
        appearance.palette[i] = (PixelRgb565)i;
    }
    appearance.default_color = 0x7FFF; /* LCD off reads white */
#else
    for (uint32_t i = 0; i < Appearance::NUM_COLORS; ++i) {
        appearance.palette[i] = (PixelRgb565)i;
    }
    appearance.default_color = 0; /* shade 0 -> GREY4[0] == white */
#endif
    gb.lcd.set_appearance(appearance);

    const std::string bootpath = std::string(bootdir) + "/" + (is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
    core.load_boot_rom(bootpath);
    core.load_rom(rom);

    const bool want_dump = getenv("GBDIFF_DUMP") != nullptr && getenv("GBDIFF_DUMP")[0];

    int max_frame = 0;
    for (int s : g_shots) {
        if (s > max_frame) {
            max_frame = s;
        }
    }

    char buf[32];
    for (int f = 0; f <= max_frame; ++f) {
        for (const Ev& e : g_ev) {
            if (e.frame == f) {
                core.set_key(e.key, e.press ? Joypad::KeyState::Pressed : Joypad::KeyState::Released);
            }
        }
        core.frame();
        for (int s : g_shots) {
            if (s == f) {
                snprintf(buf, sizeof buf, ".f%04d", f);
                write_ppm(prefix + buf + ".ppm");
                if (want_dump) {
                    write_dump(prefix + buf + ".mem");
                }
                break;
            }
        }
    }

    return 0;
}
