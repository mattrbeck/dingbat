/* gbprobe's SameBoy leg: links libsameboy.a as a black-box reference.
 *
 *   sameboy_shot <rom> <model> <frames> <out.ppm>
 *
 *   model: dmg | cgb0 | cgbA | cgbB | cgbC | cgbD | cgbE | cgb (=cgbE) | agb
 *
 * SameBoy has no skip-boot entry point, so build.sh assembles its boot ROMs
 * and points here through GBPROBE_BOOTROMS; the boot animation is burned off
 * before frame counting starts, matching the other legs' skip-boot timeline.
 *
 * For byte-comparability: colour correction off (raw 555 out) and the shared
 * four-shade DMG ramp. GB_random must be disabled BEFORE GB_init so power-up
 * memory is all zero like the other legs.
 */
#define GB_INTERNAL
#include <Core/gb.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 160
#define H 144

/* Darkest first: colors[3] is shade 0. Every value survives an 8->5->8
 * round trip. */
static const GB_palette_t GREY4 = {{
    {0x00, 0x00, 0x00}, {0x52, 0x52, 0x52}, {0xAD, 0xAD, 0xAD},
    {0xFF, 0xFF, 0xFF}, {0xFF, 0xFF, 0xFF},
}};

static uint32_t rgb_encode(GB_gameboy_t* gb, uint8_t r, uint8_t g, uint8_t b) {
    (void) gb;
    return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}

static void vblank(GB_gameboy_t* gb, GB_vblank_type_t type) { (void) gb; (void) type; }
static void log_cb(GB_gameboy_t* gb, const char* s, GB_log_attributes_t a) {
    (void) gb; (void) s; (void) a;
}

static GB_model_t model_id(const char* m, const char** bootrom) {
    struct { const char* name; GB_model_t model; const char* boot; } t[] = {
        {"dmg",  GB_MODEL_DMG_B, "dmg_boot.bin"},
        {"cgb0", GB_MODEL_CGB_0, "cgb0_boot.bin"},
        {"cgba", GB_MODEL_CGB_A, "cgb_boot.bin"},
        {"cgbb", GB_MODEL_CGB_B, "cgb_boot.bin"},
        {"cgbc", GB_MODEL_CGB_C, "cgb_boot.bin"},
        {"cgbd", GB_MODEL_CGB_D, "cgb_boot.bin"},
        {"cgbe", GB_MODEL_CGB_E, "cgb_boot.bin"},
        {"cgb",  GB_MODEL_CGB_E, "cgb_boot.bin"},
        {"agb",  GB_MODEL_AGB_A, "agb_boot.bin"},
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; ++i) {
        if (!strcasecmp(m, t[i].name)) { *bootrom = t[i].boot; return t[i].model; }
    }
    fprintf(stderr, "unknown model %s\n", m);
    exit(2);
}

int main(int argc, char** argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <rom> <model> <frames> <out.ppm>\n", argv[0]);
        return 2;
    }
    const char* rom = argv[1];
    const char* bootname;
    GB_model_t model = model_id(argv[2], &bootname);
    long frames = strtol(argv[3], NULL, 10);
    const char* out = argv[4];

    GB_random_set_enabled(false);
    GB_random_seed(0);

    GB_gameboy_t gb;
    GB_init(&gb, model);
    GB_set_log_callback(&gb, log_cb);

    const char* bootdir = getenv("GBPROBE_BOOTROMS");
    if (!bootdir || !bootdir[0]) {
        fprintf(stderr, "GBPROBE_BOOTROMS is not set (see build.sh)\n");
        return 3;
    }
    char bootpath[1024];
    snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir, bootname);
    if (GB_load_boot_rom(&gb, bootpath)) {
        fprintf(stderr, "failed to load boot rom %s\n", bootpath);
        return 3;
    }
    if (GB_load_rom(&gb, rom)) {
        fprintf(stderr, "failed to load %s\n", rom);
        return 3;
    }

    static uint32_t vbuf[W * H];
    GB_set_pixels_output(&gb, vbuf);
    GB_set_rgb_encode_callback(&gb, rgb_encode);
    GB_set_vblank_callback(&gb, vblank);
    GB_set_color_correction_mode(&gb, GB_COLOR_CORRECTION_DISABLED);
    GB_set_palette(&gb, &GREY4);
    GB_set_rendering_disabled(&gb, false);

    /* Burn the boot animation, bounded. */
    for (int i = 0; i < 1000 && !gb.boot_rom_finished; ++i) GB_run_frame(&gb);
    if (!gb.boot_rom_finished) {
        fprintf(stderr, "boot rom never finished\n");
        return 4;
    }

    for (long f = 0; f < frames; ++f) GB_run_frame(&gb);

    FILE* f = fopen(out, "wb");
    if (!f) { perror(out); return 3; }
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; ++i) {
        uint8_t rgb[3] = {(vbuf[i] >> 16) & 0xFF, (vbuf[i] >> 8) & 0xFF, vbuf[i] & 0xFF};
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    return 0;
}
