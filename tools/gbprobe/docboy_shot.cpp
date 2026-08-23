/* gbprobe's DocBoy leg: built inside DocBoy's devtools as a black-box
 * reference (build.sh copies this file into the scratch checkout).
 *
 *   docboy_shot <rom> <frames> <out.ppm>
 *
 * Not DocBoy's own runtakeframebuffer: that links `testutils`, which needs
 * BUILD_TESTS=ON and compiles the emulator with ENABLE_TESTS, and it counts
 * ticks rather than frames (Core::frame() gives the frame-exact contract).
 *
 * DMG: a non-CGB build carries a 4-entry palette, so the shade index is
 * recoverable; the same four RGB565 values the other legs normalise to are
 * installed and mapped back to the shared grey ramp on output.
 *
 * CGB: the framebuffer is RGB565, so colours have been through 555 -> 565 and
 * are lossy against the other legs' raw 555; CGB frames compare by structure,
 * never byte for byte.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>

#include "docboy/core/core.h"
#include "docboy/gameboy/gameboy.h"

static const uint16_t GREY565[4] = {0xFFFF, 0xAD55, 0x52AA, 0x0000};
static const uint8_t GREY8[4] = {0xFF, 0xAD, 0x52, 0x00};

int main(int argc, char** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: docboy_shot <rom> <frames> <out.ppm>\n");
        return 2;
    }

    auto gb = std::make_unique<GameBoy>();
    Core core {*gb};

#ifndef ENABLE_CGB
    Appearance grey {};
    grey.default_color = GREY565[0];
    for (int i = 0; i < 4; ++i) {
        grey.palette[i] = GREY565[i];
    }
    gb->lcd.set_appearance(grey);
#endif

    core.load_rom(argv[1]);

    const long frames = strtol(argv[2], nullptr, 10);
    for (long f = 0; f < frames; ++f) {
        core.frame();
    }

    const uint16_t* px = gb->lcd.get_pixels();
    FILE* out = fopen(argv[3], "wb");
    if (!out) {
        perror(argv[3]);
        return 3;
    }
    fprintf(out, "P6\n160 144\n255\n");
    for (int i = 0; i < 160 * 144; ++i) {
        const uint16_t p = px[i];
        uint8_t rgb[3];
        int shade = -1;
        for (int s = 0; s < 4; ++s) {
            if (p == GREY565[s]) {
                shade = s;
                break;
            }
        }
#ifdef ENABLE_CGB
        /* The grey snap is DMG-only: a CGB frame can contain the four grey
         * values legitimately. */
        shade = -1;
#endif
        if (shade >= 0) {
            rgb[0] = rgb[1] = rgb[2] = GREY8[shade];
        } else {
            const uint8_t r5 = (p >> 11) & 0x1F;
            const uint8_t g6 = (p >> 5) & 0x3F;
            const uint8_t b5 = p & 0x1F;
            rgb[0] = (uint8_t) ((r5 << 3) | (r5 >> 2));
            rgb[1] = (uint8_t) ((g6 << 2) | (g6 >> 4));
            rgb[2] = (uint8_t) ((b5 << 3) | (b5 >> 2));
        }
        fwrite(rgb, 1, 3, out);
    }
    fclose(out);
    return 0;
}
