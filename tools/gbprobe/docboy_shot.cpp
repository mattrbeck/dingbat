/* gbprobe's DocBoy leg.
 *
 *   docboy_shot <rom> <frames> <out.ppm>
 *
 * DocBoy ships devtools/runtakeframebuffer.cpp, which does almost this job,
 * but two things make it the wrong tool here:
 *
 *   - it links `testutils`, which only exists when the tree is configured with
 *     BUILD_TESTS=ON, and that flag compiles the whole emulator with
 *     ENABLE_TESTS. An oracle has to be the emulator as it ships, not the
 *     emulator with its test hooks compiled in;
 *   - it counts TICKS, not frames. Core::frame() is right there and gives the
 *     same frame-exact contract the other two legs have.
 *
 * DMG note: in a non-CGB build DocBoy's LCD carries a 4-entry palette, so the
 * shade index is recoverable exactly. We install the same four RGB565 values
 * the harness's other legs normalise to, and map them straight back to the
 * shared grey ramp on the way out; DMG output is then byte-comparable across
 * all three engines.
 *
 * CGB note: DocBoy stores the framebuffer as RGB565, so a CGB colour has been
 * through 555 -> 565 by the time we see it. That is lossy against dingbat's
 * and SameBoy's raw 555, so CGB frames are compared by structure (which column
 * changes colour where), never byte for byte. The probe ROMs are written with
 * that in mind: every colour they use survives the round trip distinctly.
 *
 * Built by build.sh, which copies this file into the scratch DocBoy checkout.
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
        /* A CGB frame can legitimately contain the four grey values, so the
         * snap is DMG-only; on CGB every pixel goes through the generic 565
         * expansion. */
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
