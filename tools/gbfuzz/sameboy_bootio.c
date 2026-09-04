/* Dump the IO register file ($FF00-$FF7F) as the cartridge sees it on its
 * first instruction, i.e. the state the boot ROM hands off (links libsameboy).
 *
 *   sameboy_bootio <bootromdir> <dmg|mgb|sgb|sgb2|cgb0|cgbA..E|agb> [rom.gb]
 *
 * mooneye's boot_hwio ROMs report only their first mismatch; this answers the
 * whole table at once, per model. The model is an argument, not the cart
 * header (mooneye's `-C` ROMs carry $0143 = $00).
 *
 * Reads go through GB_safe_read_memory, so what is printed is what a
 * `LDH A,(n)` would return, read masks and all.
 *
 * With no ROM argument a 32 KiB stub that loops at $0150 is synthesised, so the
 * dump is a property of the boot ROM and the model alone. Pass a real ROM to
 * see the effect of the header (the CGB boot ROM's DMG-compatibility path keys
 * off $0143).
 */
#define GB_INTERNAL
#include <Core/gb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b) {
  (void) gb; return ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
}
static void vblank(GB_gameboy_t *gb, GB_vblank_type_t t) { (void) gb; (void) t; }
static void logcb(GB_gameboy_t *gb, const char *s, GB_log_attributes_t a) {
  (void) gb; (void) s; (void) a;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <bootromdir> <dmg|mgb|sgb|sgb2|cgb0|cgbA..E|agb> [rom.gb]\n"
                    "  without rom.gb a header-only stub cart is used; its logo is copied\n"
                    "  from GBFUZZ_LOGO_ROM (any bootable .gb, default tests/roms/gbedge.gb)\n", argv[0]);
    return 2;
  }
  const char *bootdir = argv[1], *m = argv[2];
  const char *rom = argc > 3 ? argv[3] : NULL;

  GB_model_t model; const char *bootname;
  if      (!strcmp(m, "dmg"))  { model = GB_MODEL_DMG_B;  bootname = "dmg_boot.bin"; }
  else if (!strcmp(m, "mgb"))  { model = GB_MODEL_MGB;    bootname = "mgb_boot.bin"; }
  else if (!strcmp(m, "sgb"))  { model = GB_MODEL_SGB;    bootname = "sgb_boot.bin"; }
  else if (!strcmp(m, "sgb2")) { model = GB_MODEL_SGB2;   bootname = "sgb2_boot.bin"; }
  else if (!strcmp(m, "cgb0")) { model = GB_MODEL_CGB_0;  bootname = "cgb0_boot.bin"; }
  else if (!strcmp(m, "cgbA")) { model = GB_MODEL_CGB_A;  bootname = "cgb_boot.bin"; }
  else if (!strcmp(m, "cgbB")) { model = GB_MODEL_CGB_B;  bootname = "cgb_boot.bin"; }
  else if (!strcmp(m, "cgbC")) { model = GB_MODEL_CGB_C;  bootname = "cgb_boot.bin"; }
  else if (!strcmp(m, "cgbD")) { model = GB_MODEL_CGB_D;  bootname = "cgb_boot.bin"; }
  else if (!strcmp(m, "cgbE")) { model = GB_MODEL_CGB_E;  bootname = "cgb_boot.bin"; }
  else if (!strcmp(m, "agb"))  { model = GB_MODEL_AGB_A;  bootname = "agb_boot.bin"; }
  else { fprintf(stderr, "unknown model %s\n", m); return 2; }

  GB_random_set_enabled(false);
  GB_random_seed(0);

  GB_gameboy_t gb;
  GB_init(&gb, model);
  GB_set_log_callback(&gb, logcb);
  char bp[1024];
  snprintf(bp, sizeof bp, "%s/%s", bootdir, bootname);
  if (GB_load_boot_rom(&gb, bp)) { fprintf(stderr, "boot rom load failed: %s\n", bp); return 3; }

  if (rom) {
    if (GB_load_rom(&gb, rom)) { fprintf(stderr, "rom load failed: %s\n", rom); return 3; }
  } else {
    /* A stub with a valid header logo (the boot ROM refuses to hand off
     * without one) and `jr .` at $0150. The logo bytes are not kept in this
     * tree; they are copied from the header of any bootable ROM. */
    static uint8_t stub[0x8000];
    const char *donor = getenv("GBFUZZ_LOGO_ROM");
    if (!donor) donor = "tests/roms/gbedge.gb";
    FILE *df = fopen(donor, "rb");
    if (!df || fseek(df, 0x104, SEEK_SET) || fread(stub + 0x104, 1, 48, df) != 48) {
      fprintf(stderr, "logo donor ROM unreadable: %s (set GBFUZZ_LOGO_ROM)\n", donor);
      return 3;
    }
    fclose(df);
    stub[0x143] = 0x80;                     /* CGB-compatible */
    stub[0x100] = 0x00; stub[0x101] = 0xC3; /* nop; jp $0150 */
    stub[0x102] = 0x50; stub[0x103] = 0x01;
    stub[0x150] = 0x18; stub[0x151] = 0xFE; /* jr . */
    uint8_t sum = 0;
    for (int i = 0x134; i <= 0x14C; i++) sum = sum - stub[i] - 1;
    stub[0x14D] = sum;
    GB_load_rom_from_buffer(&gb, stub, sizeof stub);
  }
  GB_set_rgb_encode_callback(&gb, rgb_encode);
  GB_set_vblank_callback(&gb, vblank);
  static uint32_t fb[160 * 144];
  GB_set_pixels_output(&gb, fb);

  /* Run until the cartridge's very first instruction is about to execute. */
  long guard = 200000000;
  GB_registers_t *r = GB_get_registers(&gb);
  while (guard > 0) {
    if (gb.boot_rom_finished && r->pc == 0x0100) break;
    guard -= GB_run(&gb);
  }
  if (guard <= 0) { fprintf(stderr, "never reached $0100\n"); return 4; }

  printf("# %s pc=%04X af=%04X bc=%04X de=%04X hl=%04X sp=%04X\n",
         m, r->pc, r->af, r->bc, r->de, r->hl, r->sp);
  for (int base = 0xFF00; base < 0xFF80; base += 16) {
    printf("%04X ", base);
    for (int i = 0; i < 16; i++) printf("%02X ", GB_safe_read_memory(&gb, base + i));
    printf("\n");
  }
  return 0;
}
