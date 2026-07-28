/* Frames-per-emulated-second probe for SameBoy — the reference half of the
 * frame-pacing comparison; dingbat_gb_fps.nim is the other half.
 *
 * Usage: sameboy_fps <rom> <bootromdir> <frames> [skipframes] [script] [window]
 *
 * Runs <frames> presented frames (a "frame" = one vblank callback, i.e. the
 * same event GB_run_frame returns on, which is what a frontend paces on) and
 * divides by the emulated time they spanned. A run whose LCD never turns off
 * reports exactly 4194304/70224 = 59.7275. Both emulators push extra frames
 * around LCD off/on transitions, so LCD-toggling titles legitimately read
 * above that; the point of this tool is that the two must agree on how much.
 *
 * script is the gbfuzz nav format: FRAME:KEY[:HOLD],... over the whole run
 * (frame numbers counted from power-on, i.e. including the skipped ones).
 * window>0 prints an fps line every <window> frames instead of one total —
 * use it to find the LCD-toggling stretches, which is where the two models
 * would diverge if they were going to.
 *
 * Emulated time is accumulated from GB_run()'s return value, which is in fixed
 * 8 MHz units regardless of CGB double-speed. cycles/2 = 4194304 Hz dots.
 * GB_run_frame() is NOT usable for this: it returns cycles_since_last_sync,
 * which GB_timing_sync zeroes from inside the vblank callback in turbo mode,
 * so the value it hands back is always 0.
 *
 * mGBA is deliberately not part of this comparison: it does not push a frame
 * on an LCD off/on transition at all, it lets the frame it is in run long (a
 * single 666480-dot "frame" on Link's Awakening), so its presents-per-second
 * is a different quantity rather than a second opinion on the same one.
 *
 * Build: see build.sh.
 */
#define GB_INTERNAL
#include <Core/gb.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_EV 65536

static const GB_palette_t GREY4 = {{
    {0x00, 0x00, 0x00}, {0x52, 0x52, 0x52}, {0xAD, 0xAD, 0xAD},
    {0xFF, 0xFF, 0xFF}, {0xFF, 0xFF, 0xFF},
}};

struct Ev { int frame; GB_key_t key; int press; };
static struct Ev g_ev[MAX_EV];
static int g_nev;

static GB_key_t key_id(const char *name) {
    static const char *names[] = {"RIGHT","LEFT","UP","DOWN","A","B","SELECT","START"};
    for (int i = 0; i < GB_KEY_MAX; ++i)
        if (!strcasecmp(name, names[i])) return (GB_key_t) i;
    fprintf(stderr, "unknown key %s\n", name);
    exit(2);
}

static void parse_script(char *s) {
    for (char *tok = strtok(s, ","); tok; tok = strtok(NULL, ",")) {
        int frame, hold = 10;
        char key[16];
        if (sscanf(tok, "%d:%15[^:]:%d", &frame, key, &hold) < 2) {
            fprintf(stderr, "bad script entry %s\n", tok);
            exit(2);
        }
        GB_key_t k = key_id(key);
        g_ev[g_nev++] = (struct Ev){frame, k, 1};
        g_ev[g_nev++] = (struct Ev){frame + hold, k, 0};
    }
}

static long g_type_count[8];
static const char *g_type_name[8] = {
    "NORMAL", "LCD_OFF", "ARTIFICIAL", "REPEAT", "SKIPPED", "?5", "?6", "?7",
};

static void vblank(GB_gameboy_t *gb, GB_vblank_type_t type) {
    (void) gb;
    if ((unsigned) type < 8) g_type_count[type]++;
}

static uint32_t rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b) {
    (void) gb;
    return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}

static void log_cb(GB_gameboy_t *gb, const char *s, GB_log_attributes_t a) {
    (void) gb; (void) s; (void) a;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <rom> <bootromdir> <frames> [skip] [script] [window]\n", argv[0]);
        return 2;
    }
    const char *rom = argv[1];
    const char *bootdir = argv[2];
    long want = atol(argv[3]);
    long skip = argc > 4 ? atol(argv[4]) : 0;
    if (argc > 5 && argv[5][0]) parse_script(strdup(argv[5]));
    long window = argc > 6 ? atol(argv[6]) : 0;

    FILE *rf = fopen(rom, "rb");
    if (!rf) { perror(rom); return 3; }
    uint8_t hdr[0x150];
    size_t got = fread(hdr, 1, sizeof hdr, rf);
    fclose(rf);
    if (got < sizeof hdr) { fprintf(stderr, "rom too small\n"); return 3; }
    int is_cgb = (hdr[0x143] & 0x80) != 0;

    GB_random_set_enabled(false);
    GB_random_seed(0);
    GB_gameboy_t gb;
    GB_init(&gb, is_cgb ? GB_MODEL_CGB_E : GB_MODEL_DMG_B);
    GB_set_log_callback(&gb, log_cb);

    char bootpath[1024];
    snprintf(bootpath, sizeof bootpath, "%s/%s", bootdir,
             is_cgb ? "cgb_boot.bin" : "dmg_boot.bin");
    if (GB_load_boot_rom(&gb, bootpath)) {
        fprintf(stderr, "failed to load boot rom %s\n", bootpath);
        return 3;
    }
    if (GB_load_rom(&gb, rom)) { fprintf(stderr, "failed to load %s\n", rom); return 3; }

    static uint32_t vbuf[160 * 144];
    GB_set_pixels_output(&gb, vbuf);
    GB_set_rgb_encode_callback(&gb, rgb_encode);
    GB_set_vblank_callback(&gb, vblank);
    GB_set_color_correction_mode(&gb, GB_COLOR_CORRECTION_DISABLED);
    GB_set_palette(&gb, &GREY4);
    GB_set_rendering_disabled(&gb, false);

    /* Never sleep, never skip frames. */
    gb.turbo = true;
    gb.turbo_dont_skip = true;
    gb.turbo_cap_multiplier = 0;

    uint64_t cyc8 = 0;          /* 8 MHz units */
    uint64_t prev = 0, wprev = 0;
    long shortest = 1 << 30, longest = 0;
    long frames = 0;
    static long hist[128];
    long wframes = 0;
    long counted = 0;
    uint64_t base = 0;
    while (counted < want) {
        for (int i = 0; i < g_nev; ++i)
            if (g_ev[i].frame == frames) GB_set_key_state(&gb, g_ev[i].key, g_ev[i].press);
        /* run until the next present */
        for (;;) {
            uint64_t c = GB_run(&gb);
            cyc8 += c;
            if (gb.vblank_just_occured) break;
        }
        frames++;
        if (frames <= skip) { prev = wprev = base = cyc8; memset(g_type_count, 0, sizeof g_type_count); continue; }
        counted++;
        long dots = (long) ((cyc8 - prev) / 2);
        prev = cyc8;
        if (dots < shortest) shortest = dots;
        if (dots > longest) longest = dots;
        long b = dots / 1000;
        if (b > 127) b = 127;
        hist[b]++;
        wframes++;
        if (window > 0 && wframes == window) {
            double ws = (double) ((cyc8 - wprev) / 2) / 4194304.0;
            printf("  win frame=%ld fps=%.4f\n", frames, wframes / ws);
            wprev = cyc8;
            wframes = 0;
        }
    }
    uint64_t dots = (cyc8 - base) / 2;
    double secs = (double) dots / 4194304.0;
    printf("emu=sameboy rom=%s frames=%ld dots=%llu secs=%.6f fps=%.4f\n", rom, counted,
           (unsigned long long) dots, secs, counted / secs);
    printf("  per-frame dots: min=%ld max=%ld mean=%.1f\n", shortest, longest,
           (double) dots / counted);
    printf("  vblank types:");
    for (int i = 0; i < 8; i++)
        if (g_type_count[i]) printf(" %s=%ld", g_type_name[i], g_type_count[i]);
    printf("\n  hist(kdots):");
    for (int i = 0; i < 128; i++) if (hist[i]) printf(" %d:%ld", i, hist[i]);
    printf("\n");
    GB_free(&gb);
    return 0;
}
