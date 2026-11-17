# DocBoy Test Suite - Detailed Results

*Generated: 2026-11-17 08:13:59 · Docheinstein/docboy 01e04d3d*

DocBoy's own ROMs (`docboy/` in its tests/config manifests), each
scored by the verdict its manifest names, the way DocBoy's runner
checks it: `$FFF0` = 1 pass / 2 fail, polled every 100,000 4 MHz
ticks, or an exact RGB565 match with the reference PNG at the next
VBlank (or at `ld b,b` / `ld c,c` when the row names one). DMG rows
run on a DMG ABC, the three CGB manifests on a CPU CGB E with the
cart header picking the mode. See tests/README.md for the mechanism
and docs/dev/gb-failure-triage.md for the failing families.

**8763/9186 passed.**

## docboy/dmg/cpu

All 11 tests passed (DMG dmgABC).

## docboy/dmg/ppu (1238/1303 passed)

1238/1303 tests passed on DMG dmgABC, 65 failed:

| Test | Result |
|------|--------|
| dmg/docboy/ppu/interactive/stop_read_ly_alt_alt_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_ly_alt_alt_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_ly_alt_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_ly_alt_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_ly_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_ly_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/ppu/interactive/stop_read_stat_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_stat_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_read_stat_round3 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/interactive/stop_trigger_interrupt | $FFF0=$02 = fail value (tick 100012) |
| dmg/docboy/ppu/visual/halt_ppu_off | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $1200 want $AD00 |
| dmg/docboy/ppu/visual/stop_during_hblank | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $84A0 want $AD00 |
| dmg/docboy/ppu/visual/stop_during_oam_scan | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $84A0 want $AD00 |
| dmg/docboy/ppu/visual/stop_during_pixel_transfer | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $84A0 want $AD00 |
| dmg/docboy/ppu/visual/stop_during_vblank | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $84A0 want $AD00 |
| dmg/docboy/ppu/visual/stop_ppu_off | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $84A0 want $AD00 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x3 | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 10: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x4 | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x5 | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x6 | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops22_sprite_x7 | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x0 | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x1 | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x2 | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops23_sprite_x3 | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x2 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x3 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x4 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x5 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x6 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops24_sprite_x7 | 4/23040 pixels differ at opcode $40 (tick 521876), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops25_sprite_x0 | 4/23040 pixels differ at opcode $40 (tick 521880), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_alt_nops25_sprite_x1 | 4/23040 pixels differ at opcode $40 (tick 521880), first at row 9 col 19: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x3_variation_a | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 10: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x3_variation_b | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 10: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4 | 5/23040 pixels differ at opcode $40 (tick 521892), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4_variation_a | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x4_variation_b | 6/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5 | 5/23040 pixels differ at opcode $40 (tick 521892), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5_variation_a | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x5_variation_b | 6/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6 | 5/23040 pixels differ at opcode $40 (tick 521892), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6_variation_a | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x6_variation_b | 6/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7 | 5/23040 pixels differ at opcode $40 (tick 521892), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7_variation_a | 4/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops22_sprite_x7_variation_b | 6/23040 pixels differ at opcode $40 (tick 521868), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0 | 5/23040 pixels differ at opcode $40 (tick 521864), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0_variation_a | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x0_variation_b | 6/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1 | 5/23040 pixels differ at opcode $40 (tick 521864), first at row 8 col 9: got $84A0 want $1200 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1_variation_a | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x1_variation_b | 6/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2 | 5/23040 pixels differ at opcode $40 (tick 521864), first at row 8 col 9: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2_variation_a | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x2_variation_b | 6/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3 | 5/23040 pixels differ at opcode $40 (tick 521864), first at row 8 col 9: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3_variation_a | 4/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_turn_off_nops23_sprite_x3_variation_b | 6/23040 pixels differ at opcode $40 (tick 521872), first at row 9 col 11: got $84A0 want $2AA0 |
| dmg/docboy/ppu/visual/window_wx0_scx1 | timeout, last check: 8/23040 pixels differ, first at row 0 col 7: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_wx0_scx2 | timeout, last check: 8/23040 pixels differ, first at row 0 col 6: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_wx0_scx3 | timeout, last check: 8/23040 pixels differ, first at row 0 col 5: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_wx0_scx4 | timeout, last check: 8/23040 pixels differ, first at row 0 col 4: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_wx0_scx5 | timeout, last check: 8/23040 pixels differ, first at row 0 col 3: got $1200 want $84A0 |
| dmg/docboy/ppu/visual/window_wx0_scx6 | timeout, last check: 8/23040 pixels differ, first at row 0 col 2: got $1200 want $84A0 |

## docboy/dmg/mbc/mbc1

All 11 tests passed (DMG dmgABC).

## docboy/dmg/mbc/mbc3

All 18 tests passed (DMG dmgABC).

## docboy/dmg/mbc/mbc5

All 1 tests passed (DMG dmgABC).

## docboy/dmg/mbc/huc3 (2/8 passed)

2/8 tests passed on DMG dmgABC, 6 failed:

| Test | Result |
|------|--------|
| dmg/docboy/mbc/huc3/huc3_command_3x | timeout: $FFF0=$00 |
| dmg/docboy/mbc/huc3/huc3_command_4x | timeout: $FFF0=$00 |
| dmg/docboy/mbc/huc3/huc3_command_5x | timeout: $FFF0=$00 |
| dmg/docboy/mbc/huc3/huc3_command_10 | timeout: $FFF0=$00 |
| dmg/docboy/mbc/huc3/huc3_command_62 | timeout: $FFF0=$00 |
| dmg/docboy/mbc/huc3/huc3_scratchpad | timeout: $FFF0=$00 |

## docboy/dmg/boot

All 21 tests passed (DMG dmgABC).

## docboy/dmg/memory

All 23 tests passed (DMG dmgABC).

## docboy/dmg/oam_bug (262/268 passed)

262/268 tests passed on DMG dmgABC, 6 failed:

| Test | Result |
|------|--------|
| dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5c | $FFF0=$02 = fail value (tick 1500000) |
| dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5e_noisy | $FFF0=$02 = fail value (tick 1500012) |
| dmg/docboy/oam_bug/oam_bug_ld_hl_a_round3_fe5f | $FFF0=$02 = fail value (tick 1500000) |
| dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5c | $FFF0=$02 = fail value (tick 1500000) |
| dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5e_noisy | $FFF0=$02 = fail value (tick 1500012) |
| dmg/docboy/oam_bug/oam_bug_ld_hli_a_round3_fe5f | $FFF0=$02 = fail value (tick 1500000) |

## docboy/dmg/stat_write_bug

All 29 tests passed (DMG dmgABC).

## docboy/dmg/timers

All 10 tests passed (DMG dmgABC).

## docboy/dmg/interrupts

All 158 tests passed (DMG dmgABC).

## docboy/dmg/dma

All 68 tests passed (DMG dmgABC).

## docboy/dmg/serial (76/77 passed)

76/77 tests passed on DMG dmgABC, 1 failed:

| Test | Result |
|------|--------|
| dmg/docboy/serial/serial_two_players_basic_transfer_master + serial_two_players_basic_transfer_slave_sc_00 | timeout, last check: master 8888 px (first at row 3 col 0: got $84A0 want $1200), slave 8888 px (first at row 3 col 0: got $84A0 want $1200) |

## docboy/dmg/joypad

All 32 tests passed (DMG dmgABC).

## docboy/dmg/apu (303/307 passed)

303/307 tests passed on DMG dmgABC, 4 failed:

| Test | Result |
|------|--------|
| dmg/docboy/apu/ch1_period_sweep_change_direction_twice_period_overflow_round1_2 | $FFF0=$02 = fail value (tick 100012) |
| dmg/docboy/apu/ch1_period_sweep_change_step_6_to_5_period152_round2 | $FFF0=$02 = fail value (tick 200012) |
| dmg/docboy/apu/ch1_period_sweep_step6_period93_round2 | $FFF0=$02 = fail value (tick 200000) |
| dmg/docboy/apu/ch1_period_sweep_step7_period247 | $FFF0=$02 = fail value (tick 600000) |

## docboy/cgb/boot (48/68 passed)

48/68 tests passed on CGB cgbE, 20 failed:

| Test | Result |
|------|--------|
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_3030_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_3030_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_3031_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_00_cgb_flag_00_old_license_01_new_license_3031_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_16_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_16_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_46A_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_46A_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/boot/boot_div_title_46E_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_46E_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_46R_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100008) |
| cgb/docboy/boot/boot_div_title_46R_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100012) |
| cgb/docboy/boot/boot_div_title_6F_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_6F_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_BF__cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_BF__cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/boot/boot_div_title_F4-_cgb_flag_00_old_license_01_new_license_00_round1 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/boot/boot_div_title_F4-_cgb_flag_00_old_license_01_new_license_00_round2 | $FFF0=$02 = fail value (tick 100000) |

## docboy/cgb/banks

All 2 tests passed (CGB cgbE).

## docboy/cgb/memory

All 20 tests passed (CGB cgbE).

## docboy/cgb/oam_bug

All 5 tests passed (CGB cgbE).

## docboy/cgb/stat_write_bug

All 1 tests passed (CGB cgbE).

## docboy/cgb/timers

All 2 tests passed (CGB cgbE).

## docboy/cgb/interrupts

All 27 tests passed (CGB cgbE).

## docboy/cgb/dma

All 41 tests passed (CGB cgbE).

## docboy/cgb/hdma

All 640 tests passed (CGB cgbE).

## docboy/cgb/serial

All 17 tests passed (CGB cgbE).

## docboy/cgb/ir

All 1 tests passed (CGB cgbE).

## docboy/cgb/mode

All 6 tests passed (CGB cgbE).

## docboy/cgb/undocumented

All 4 tests passed (CGB cgbE).

## docboy/cgb/ppu (391/427 passed)

391/427 tests passed on CGB cgbE, 36 failed:

| Test | Result |
|------|--------|
| cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops26 | timeout, last check: 688/23040 pixels differ, first at row 2 col 9: got $063F want $000B |
| cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops27 | timeout, last check: 392/23040 pixels differ, first at row 2 col 9: got $063F want $000B |
| cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops28 | timeout, last check: 688/23040 pixels differ, first at row 2 col 9: got $063F want $000B |
| cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29 | timeout, last check: 392/23040 pixels differ, first at row 2 col 9: got $063F want $000B |
| cgb/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops30 | timeout, last check: 688/23040 pixels differ, first at row 2 col 9: got $063F want $000B |
| cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops26 | timeout, last check: 176/23040 pixels differ, first at row 16 col 42: got $07FF want $39C7 |
| cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops27 | timeout, last check: 176/23040 pixels differ, first at row 32 col 44: got $FFE0 want $07FF |
| cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops28 | timeout, last check: 176/23040 pixels differ, first at row 16 col 50: got $07FF want $39C7 |
| cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops29 | timeout, last check: 176/23040 pixels differ, first at row 32 col 52: got $FFE0 want $07FF |
| cgb/docboy/ppu/visual/change_win_tile_data_glitch_window_nops30 | timeout, last check: 176/23040 pixels differ, first at row 16 col 58: got $07FF want $39C7 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx8_nops18 | timeout, last check: 4/23040 pixels differ, first at row 17 col 2: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx8_nops18_alt | timeout, last check: 4/23040 pixels differ, first at row 17 col 2: got $FFE0 want $39C7 |
| cgb/docboy/ppu/visual/stop_during_pixel_transfer_alt | timeout, last check: 22801/23040 pixels differ, first at row 1 col 79: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/stop_ly42_during_hblank | timeout, last check: 6880/23040 pixels differ, first at row 0 col 0: got $0000 want $07FF |
| cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round1 | 6765/23040 pixels differ at opcode $40 (tick 4740780), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round1 #2 | 6765/23040 pixels differ at opcode $49 (tick 4811008), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y42_turn_on_y148_round2 | 6765/23040 pixels differ at opcode $40 (tick 4740784), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y42_turn_on_y52_wait144 | 6765/23040 pixels differ at opcode $40 (tick 4762848), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y42_turn_on_y52_wait150 | 6765/23040 pixels differ at opcode $40 (tick 4765584), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops50 | 20346/23040 pixels differ at opcode $40 (tick 4739440), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops51 | 19210/23040 pixels differ at opcode $40 (tick 4740056), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops99 | 20365/23040 pixels differ at opcode $40 (tick 4769624), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_skip_y16_stall_nops100 | 8045/23040 pixels differ at opcode $40 (tick 4770240), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y48_skip_y16_stall_nops50 | 20426/23040 pixels differ at opcode $40 (tick 4738608), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y48_skip_y16_stall_nops51 | 20346/23040 pixels differ at opcode $40 (tick 4738528), first at row 0 col 0: got $07FF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_stall_nops50 | 22765/23040 pixels differ at opcode $40 (tick 4735024), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/turn_off_y50_stall_nops51 | 8045/23040 pixels differ at opcode $40 (tick 4735640), first at row 0 col 0: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/window_bg_reprise_wx25 | timeout, last check: 3/23040 pixels differ, first at row 12 col 26: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx1 | timeout, last check: 64/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx1_fancy_tile0 | timeout, last check: 1016/23040 pixels differ, first at row 0 col 0: got $39C7 want $F81F |
| cgb/docboy/ppu/visual/window_wx0_scx2 | timeout, last check: 56/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx3 | timeout, last check: 48/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx4 | timeout, last check: 40/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx5 | timeout, last check: 32/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx6 | timeout, last check: 24/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/window_wx0_scx7 | timeout, last check: 16/23040 pixels differ, first at row 0 col 0: got $39C7 want $FFE0 |

## docboy/cgb/mbc/mbc7

All 17 tests passed (CGB cgbE).

## docboy/cgb/apu/ch1 (1137/1141 passed)

1137/1141 tests passed on CGB cgbE, 4 failed:

| Test | Result |
|------|--------|
| cgb/docboy/apu/ch1/ch1_period_sweep_change_pace_4_to_6_during_recalc_round1_1 | $FFF0=$02 = fail value (tick 1500000) |
| cgb/docboy/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_delay14284 | $FFF0=$02 = fail value (tick 4400008) |
| cgb/docboy/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_step0_delay14284_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/apu/ch1/ch1_period_sweep_change_step_during_recalc_0_to_4_alt_round1_2 | $FFF0=$02 = fail value (tick 600004) |

## docboy/cgb/apu/ch2

All 26 tests passed (CGB cgbE).

## docboy/cgb/apu/ch3

All 109 tests passed (CGB cgbE).

## docboy/cgb/apu/ch4

All 69 tests passed (CGB cgbE).

## docboy/cgb/double_speed/apu/ch1 (608/613 passed)

608/613 tests passed on CGB cgbE, 5 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12243_period_round2 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12243_period_round4 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_step_7_to_0_during_recalc_delay16_after_trigger | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_disable_on_triple_trigger_step4_delay4_2_round1 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_disable_on_triple_trigger_step4_delay4_3_round1 | $FFF0=$02 = fail value (tick 100006) |

## docboy/cgb/double_speed/apu/ch2

All 63 tests passed (CGB cgbE).

## docboy/cgb/double_speed/apu/ch3

All 169 tests passed (CGB cgbE).

## docboy/cgb/double_speed/apu/ch4 (1846/1925 passed)

1846/1925 tests passed on CGB cgbE, 79 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay0_0_nops2_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay0_0_nops3_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay0_1_nops2_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay1_0_nops2_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay1_2_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay1_3_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay1_4_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay1_5_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_1_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_2_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_2_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_3_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_3_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_4_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_4_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay2_5_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_0_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_1_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_1_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_2_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_2_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_3_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_3_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay3_4_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_0_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_0_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_1_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_1_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_2_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_2_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay4_3_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_0_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_0_nops3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_1_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_1_nops3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_2_nops0_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_2_nops3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay5_3_nops3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_0_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_0_nops3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_1_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_1_nops3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_2_nops2_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_2_nops3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay6_3_nops2_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_0_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_0_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_1_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_1_nops2_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_2_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_2_nops2_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_double_retrigger_shift1_divider3_delay7_3_nops1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay0_nops0_round2 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay0_nops1_round2 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay0_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay0_nops3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay1_nops0_round2 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider0_delay1_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay0_nops0_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay0_nops1_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay1_nops0_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay5_nops3_round2 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay6_nops2_round2 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay6_nops3_round2 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider1_delay7_nops2_round2 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay0_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay0_nops3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay1_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay1_nops3_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay2_nops2_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay2_nops3_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift1_divider3_delay3_nops2_round1 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay0_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay0_nops1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay1_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay5_nops3_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay6_nops2_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay6_nops3_round2 | $FFF0=$02 = fail value (tick 100002) |
| cgb/docboy/double_speed/apu/ch4/double_speed_apu_ch4_retrigger_shift4_divider1_delay7_nops2_round2 | $FFF0=$02 = fail value (tick 100002) |

## docboy/cgb/double_speed/core

All 8 tests passed (CGB cgbE).

## docboy/cgb/double_speed/dma

All 14 tests passed (CGB cgbE).

## docboy/cgb/double_speed/hdma

All 50 tests passed (CGB cgbE).

## docboy/cgb/double_speed/interactive

All 67 tests passed (CGB cgbE).

## docboy/cgb/double_speed/interrupts

All 246 tests passed (CGB cgbE).

## docboy/cgb/double_speed/ppu

All 357 tests passed (CGB cgbE).

## docboy/cgb/double_speed/serial

All 4 tests passed (CGB cgbE).

## docboy/cgb/double_speed/timers

All 76 tests passed (CGB cgbE).

## docboy/cgb/double_speed/visual

All 5 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/apu

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/boot (16/18 passed)

16/18 tests passed on CGB cgbE, 2 failed:

| Test | Result |
|------|--------|
| cgb_dmg_mode/docboy/boot/boot_vram_nintendo_logo_checksum_43 | $FFF0=$02 = fail value (tick 100000) |
| cgb_dmg_mode/docboy/boot/boot_vram_nintendo_logo_checksum_58 | $FFF0=$02 = fail value (tick 100000) |

## docboy/cgb_dmg_mode/banks

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/hdma

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/ir

All 1 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/key0

All 1 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/key1

All 1 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/memory

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/mode

All 6 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/ppu (374/554 passed)

374/554 tests passed on CGB cgbE, 180 failed:

| Test | Result |
|------|--------|
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_shift8_delay0_alt_sprite_data_var4 | timeout, last check: 4/23040 pixels differ, first at row 80 col 31: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var8 | timeout, last check: 16/23040 pixels differ, first at row 56 col 53: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var9 | timeout, last check: 40/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var10 | timeout, last check: 40/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var11 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var12 | timeout, last check: 16/23040 pixels differ, first at row 56 col 53: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var13 | timeout, last check: 8/23040 pixels differ, first at row 16 col 68: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var14 | timeout, last check: 40/23040 pixels differ, first at row 16 col 68: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var15 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var16 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var17 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var18 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var19 | timeout, last check: 32/23040 pixels differ, first at row 88 col 53: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var20 | timeout, last check: 248/23040 pixels differ, first at row 24 col 30: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var21 | timeout, last check: 272/23040 pixels differ, first at row 8 col 39: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var24 | timeout, last check: 8/23040 pixels differ, first at row 14 col 36: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var40 | timeout, last check: 272/23040 pixels differ, first at row 8 col 39: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var41 | timeout, last check: 264/23040 pixels differ, first at row 16 col 38: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var42 | timeout, last check: 587/23040 pixels differ, first at row 24 col 25: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43 | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt2 | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt3 | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var43_alt4 | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var44 | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_mealybug_var44_alt | timeout, last check: 448/23040 pixels differ, first at row 24 col 25: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops26 | timeout, last check: 400/23040 pixels differ, first at row 24 col 40: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops27 | timeout, last check: 104/23040 pixels differ, first at row 8 col 40: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops28 | timeout, last check: 400/23040 pixels differ, first at row 24 col 48: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29 | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_a | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_b | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_c | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_d | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var1 | timeout, last check: 56/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var2 | timeout, last check: 56/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var3 | timeout, last check: 56/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops28 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops29 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops30 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops31 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops32 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops85 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops98 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops99 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops100 | timeout, last check: 12/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops101 | timeout, last check: 10/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var4_nops102 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var5_nops30 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var5_nops30_alt | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var6_nops30 | timeout, last check: 8/23040 pixels differ, first at row 8 col 55: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops29_var10 | timeout, last check: 104/23040 pixels differ, first at row 8 col 48: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops30 | timeout, last check: 400/23040 pixels differ, first at row 24 col 56: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops34 | timeout, last check: 400/23040 pixels differ, first at row 24 col 72: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops35 | timeout, last check: 104/23040 pixels differ, first at row 8 col 72: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops36 | timeout, last check: 400/23040 pixels differ, first at row 24 col 80: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops37 | timeout, last check: 104/23040 pixels differ, first at row 8 col 80: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_bg_tile_data_glitch_sprites_nops38 | timeout, last check: 400/23040 pixels differ, first at row 24 col 88: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_bgp_or_bug_checksum_d1 | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $0318 want $FA89 |
| cgb_dmg_mode/docboy/ppu/visual/change_bgp_or_bug_checksum_d1_first_dot | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $0318 want $FA89 |
| cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops26 | timeout, last check: 176/23040 pixels differ, first at row 16 col 42: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops27 | timeout, last check: 176/23040 pixels differ, first at row 32 col 44: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops28 | timeout, last check: 176/23040 pixels differ, first at row 16 col 50: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops29 | timeout, last check: 176/23040 pixels differ, first at row 32 col 52: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/change_win_tile_data_glitch_window_nops30 | timeout, last check: 176/23040 pixels differ, first at row 16 col 58: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_0000 | timeout, last check: 8/23040 pixels differ, first at row 6 col 6: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_00ff | timeout, last check: 71/23040 pixels differ, first at row 6 col 0: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_ff00 | timeout, last check: 52/23040 pixels differ, first at row 6 col 6: got $7FE6 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_0000_win_ffff | timeout, last check: 75/23040 pixels differ, first at row 6 col 0: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_0000 | timeout, last check: 45/23040 pixels differ, first at row 6 col 6: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_00ff | timeout, last check: 92/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_afff | timeout, last check: 124/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ff00 | timeout, last check: 89/23040 pixels differ, first at row 6 col 6: got $7FE6 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x16 | timeout, last check: 248/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x16_sources | timeout, last check: 239/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17 | timeout, last check: 120/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources | timeout, last check: 121/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources_b | timeout, last check: 121/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x17_sources_c | timeout, last check: 124/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x18 | timeout, last check: 126/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x18_sources | timeout, last check: 124/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19 | timeout, last check: 133/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_sources | timeout, last check: 133/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_sources_b | timeout, last check: 132/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x19_wly | timeout, last check: 464/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x20 | timeout, last check: 132/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x20_sources | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21 | timeout, last check: 131/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_b | timeout, last check: 134/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_c | timeout, last check: 134/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x21_sources_d | timeout, last check: 121/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x22 | timeout, last check: 131/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x22_sources | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x23 | timeout, last check: 131/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x23_sources | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_nops6_sprites_x24 | timeout, last check: 248/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_00ff_win_ffff_win_tilenum_02 | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_0000 | timeout, last check: 57/23040 pixels differ, first at row 6 col 6: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_00ff | timeout, last check: 96/23040 pixels differ, first at row 5 col 6: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_ff00 | timeout, last check: 29/23040 pixels differ, first at row 6 col 6: got $7FE6 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ff00_win_ffff | timeout, last check: 108/23040 pixels differ, first at row 5 col 6: got $7FE6 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_0000 | timeout, last check: 73/23040 pixels differ, first at row 6 col 6: got $FFFF want $0318 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_00ff | timeout, last check: 112/23040 pixels differ, first at row 5 col 6: got $0000 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_ff00 | timeout, last check: 61/23040 pixels differ, first at row 6 col 6: got $7FE6 want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_bg_ffff_win_ffff | timeout, last check: 108/23040 pixels differ, first at row 5 col 6: got $0000 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly10_second_tile_source_both_bytes | timeout, last check: 72/23040 pixels differ, first at row 6 col 0: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly10_second_tile_source | timeout, last check: 72/23040 pixels differ, first at row 6 col 0: got $0000 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly32_to_40_tilenums | timeout, last check: 120/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_a | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_b | timeout, last check: 128/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_c | timeout, last check: 129/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_d | timeout, last check: 127/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_e | timeout, last check: 135/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/m3_lcdc_win_en_change_multiple_wx_ly38_lx31_extra_pixel_f | timeout, last check: 134/23040 pixels differ, first at row 5 col 6: got $0318 want $FFFF |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_01 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_0c | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_10 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_14 | timeout, last check: 2688/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FC30 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_15 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FFE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_16 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_17 | timeout, last check: 1408/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_19 | timeout, last check: 2560/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FCE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_1d | timeout, last check: 21632/23040 pixels differ, first at row 0 col 0: got $FFFF want $A4FF |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_29 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_34 | timeout, last check: 2560/23040 pixels differ, first at row 8 col 0: got $7FE6 want $7FE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_35 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_36 | timeout, last check: 22848/23040 pixels differ, first at row 0 col 0: got $FFFF want $56E0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_39 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_3c | timeout, last check: 2688/23040 pixels differ, first at row 8 col 0: got $7FE6 want $653F |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_3d | timeout, last check: 2560/23040 pixels differ, first at row 8 col 0: got $7FE6 want $57E0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_3e | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FCE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_43 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_49 | timeout, last check: 21696/23040 pixels differ, first at row 0 col 0: got $FFFF want $A4FF |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_4b | timeout, last check: 1280/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_4e | timeout, last check: 2752/23040 pixels differ, first at row 8 col 0: got $7FE6 want $653F |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_52 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_58 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $A534 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_59 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $AD70 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_5c | timeout, last check: 21696/23040 pixels differ, first at row 0 col 0: got $FFFF want $A4FF |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_5d | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_67 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_68 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_69 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FFE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_6b | timeout, last check: 2944/23040 pixels differ, first at row 8 col 0: got $7FE6 want $8C7B |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_6d | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_6f | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FE60 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_70 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FC30 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_71 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FCE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_75 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_86 | timeout, last check: 22848/23040 pixels differ, first at row 0 col 0: got $FFFF want $FFF3 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_88 | timeout, last check: 21632/23040 pixels differ, first at row 0 col 0: got $FFFF want $A4FF |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_8b | timeout, last check: 1408/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_8c | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $AD70 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_90 | timeout, last check: 1280/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_92 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_95 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $57E0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_97 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_99 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_9a | timeout, last check: 1280/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_9c | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $8C7B |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_9d | timeout, last check: 2688/23040 pixels differ, first at row 8 col 0: got $7FE6 want $8C7B |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_a2 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_a5 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_a8 | timeout, last check: 22848/23040 pixels differ, first at row 0 col 0: got $FFFF want $FFF3 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_aa | timeout, last check: 128/23040 pixels differ, first at row 48 col 120: got $FC30 want $7FE6 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_b7 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_bd | timeout, last check: 1280/23040 pixels differ, first at row 16 col 0: got $0318 want $0420 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_c9 | timeout, last check: 22912/23040 pixels differ, first at row 0 col 0: got $FFFF want $FFF9 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_ce | timeout, last check: 21696/23040 pixels differ, first at row 0 col 0: got $FFFF want $6FE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_d1 | timeout, last check: 21696/23040 pixels differ, first at row 0 col 0: got $FFFF want $6FE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_db | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FFE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_e0 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FCE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_e8 | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $FFFF want $0000 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_f0 | timeout, last check: 21696/23040 pixels differ, first at row 0 col 0: got $FFFF want $6FE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_f2 | timeout, last check: 2880/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FFE0 |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_f6 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_checksum_f7 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |
| cgb_dmg_mode/docboy/ppu/visual/palettes_old_license_33_new_license_01_checksum_01 | timeout, last check: 2816/23040 pixels differ, first at row 8 col 0: got $7FE6 want $FD6C |

## docboy/cgb_dmg_mode/serial

All 1 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/stat_write_bug

All 1 tests passed (CGB cgbE).

## docboy/cgb_dmg_mode/undocumented

All 4 tests passed (CGB cgbE).

## docboy/cgb_dmg_ext_mode/apu

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_ext_mode/banks (0/2 passed)

0/2 tests passed on CGB cgbE, 2 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/banks/svbk_write_read | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/banks/vbk_write_read | $FFF0=$02 = fail value (tick 100000) |

## docboy/cgb_dmg_ext_mode/hdma

All 2 tests passed (CGB cgbE).

## docboy/cgb_dmg_ext_mode/ir (0/1 passed)

0/1 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/ir/rp_write_read | $FFF0=$02 = fail value (tick 100008) |

## docboy/cgb_dmg_ext_mode/key1 (0/1 passed)

0/1 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/key1/key1_write_read | $FFF0=$02 = fail value (tick 100008) |

## docboy/cgb_dmg_ext_mode/mode (0/8 passed)

0/8 tests passed on CGB cgbE, 8 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8a | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8b | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8c | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8d | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8e | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_8f | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_88 | $FFF0=$02 = fail value (tick 100008) |
| cgb_dmg_ext_mode/docboy/mode/mode_cgb_flag_89 | $FFF0=$02 = fail value (tick 100008) |

## docboy/cgb_dmg_ext_mode/ppu (4/5 passed)

4/5 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/ppu/opri_write_read | $FFF0=$02 = fail value (tick 100008) |

## docboy/cgb_dmg_ext_mode/serial (0/1 passed)

0/1 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/serial/sc_write_read | $FFF0=$02 = fail value (tick 100008) |

## docboy/cgb_dmg_ext_mode/undocumented (3/4 passed)

3/4 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb_dmg_ext_mode/docboy/undocumented/ff74_write_read | $FFF0=$02 = fail value (tick 100008) |
