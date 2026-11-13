# DocBoy Test Suite - Detailed Results

*Generated: 2026-11-13 15:29:15 · Docheinstein/docboy 01e04d3d*

DocBoy's own ROMs (`docboy/` in its tests/config manifests), each
scored by the verdict its manifest names, the way DocBoy's runner
checks it: `$FFF0` = 1 pass / 2 fail, polled every 100,000 4 MHz
ticks, or an exact RGB565 match with the reference PNG at the next
VBlank (or at `ld b,b` / `ld c,c` when the row names one). DMG rows
run on a DMG ABC, the three CGB manifests on a CPU CGB E with the
cart header picking the mode. See tests/README.md for the mechanism
and docs/gb-failure-triage.md for the failing families.

**8483/8984 passed.**

## docboy/dmg/cpu (10/11 passed)

10/11 tests passed on DMG dmgABC, 1 failed:

| Test | Result |
|------|--------|
| dmg/docboy/cpu/halt_ime1_interrupt1_ret | $FFF0=$02 = fail value (tick 100000) |

## docboy/dmg/ppu (1208/1260 passed)

1208/1260 tests passed on DMG dmgABC, 52 failed:

| Test | Result |
|------|--------|
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops101_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops102_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops103_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops104_round1 | $FFF0=$02 = fail value (tick 400008) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops105_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops116_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops117_round1 | $FFF0=$02 = fail value (tick 400004) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops118_round1 | $FFF0=$02 = fail value (tick 400004) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops119_round1 | $FFF0=$02 = fail value (tick 400004) |
| dmg/docboy/ppu/oam_scan_blocked_by_dma_nops120_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx0_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx0_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx15_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx17_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx1_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx1_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx7_scx0_round1 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx7_scx7_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx8_scx7_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx128_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx129_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx130_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx131_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx132_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx133_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx134_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_window_wx_reenable_retrigger_wx135_round1 | $FFF0=$02 = fail value (tick 400000) |
| dmg/docboy/ppu/pixel_transfer_timing_winon_bgoff_round1 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/ppu/turn_on_ly0_sprites_round2 | $FFF0=$02 = fail value (tick 100004) |
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
| dmg/docboy/ppu/visual/window_trigger_win_disabled_blink_enabled | timeout, last check: 2268/23040 pixels differ, first at row 13 col 1: got $84A0 want $4B40 |
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

## docboy/dmg/oam_bug

All 258 tests passed (DMG dmgABC).

## docboy/dmg/stat_write_bug (25/29 passed)

25/29 tests passed on DMG dmgABC, 4 failed:

| Test | Result |
|------|--------|
| dmg/docboy/stat_write_bug/stat_write_bug_hblank_scx1_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/stat_write_bug/stat_write_bug_hblank_scx2_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/stat_write_bug/stat_write_bug_hblank_scx5_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/stat_write_bug/stat_write_bug_hblank_scx6_round2 | $FFF0=$02 = fail value (tick 100004) |

## docboy/dmg/timers

All 10 tests passed (DMG dmgABC).

## docboy/dmg/interrupts (156/158 passed)

156/158 tests passed on DMG dmgABC, 2 failed:

| Test | Result |
|------|--------|
| dmg/docboy/interrupts/hblank_stat_interrupt_reset_if_scx3_round2 | $FFF0=$02 = fail value (tick 100012) |
| dmg/docboy/interrupts/hblank_stat_interrupt_reset_if_scx7_round3 | $FFF0=$02 = fail value (tick 100000) |

## docboy/dmg/dma

All 68 tests passed (DMG dmgABC).

## docboy/dmg/serial (58/76 passed)

58/76 tests passed on DMG dmgABC, 18 failed:

| Test | Result |
|------|--------|
| dmg/docboy/serial/serial_timing_change_sb_during_transfer_sb_round1 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_change_sb_during_transfer_sb_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_change_sb_during_transfer_sc_round1 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_change_sb_during_transfer_sc_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_nops64_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_reset_div_during_transfer_sc_alt_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_reset_div_during_transfer_sc_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_reset_div_during_transfer_ticks_alt_sb_round2 | $FFF0=$02 = fail value (tick 100012) |
| dmg/docboy/serial/serial_timing_reset_div_during_transfer_ticks_sb | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_sb_bit0_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_sb_bit1_round2 | $FFF0=$02 = fail value (tick 100008) |
| dmg/docboy/serial/serial_timing_sb_bit2_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_sb_bit3_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_sb_bit4_round2 | $FFF0=$02 = fail value (tick 100004) |
| dmg/docboy/serial/serial_timing_sb_bit5_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_sb_bit6_round2 | $FFF0=$02 = fail value (tick 100000) |
| dmg/docboy/serial/serial_timing_sb_bit7_round2 | $FFF0=$02 = fail value (tick 100000) |

## docboy/dmg/joypad

All 32 tests passed (DMG dmgABC).

## docboy/dmg/apu (302/307 passed)

302/307 tests passed on DMG dmgABC, 5 failed:

| Test | Result |
|------|--------|
| dmg/docboy/apu/ch1_period_sweep_change_direction_twice_period_overflow_round1_2 | $FFF0=$02 = fail value (tick 100012) |
| dmg/docboy/apu/ch1_period_sweep_change_period_nr14_during_recalc_delay14285_round2 | $FFF0=$02 = fail value (tick 300000) |
| dmg/docboy/apu/ch1_period_sweep_change_step_6_to_5_period152_round2 | $FFF0=$02 = fail value (tick 200012) |
| dmg/docboy/apu/ch1_period_sweep_step6_period93_round2 | $FFF0=$02 = fail value (tick 200000) |
| dmg/docboy/apu/ch1_period_sweep_step7_period247 | $FFF0=$02 = fail value (tick 600000) |

## docboy/cgb/boot (47/68 passed)

47/68 tests passed on CGB cgbE, 21 failed:

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
| cgb/docboy/boot/boot_regs_cgb | $FFF0=$02 = fail value (tick 100000) |

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

## docboy/cgb/hdma (522/639 passed)

522/639 tests passed on CGB cgbE, 117 failed:

| Test | Result |
|------|--------|
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx0 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx2 | $FFF0=$02 = fail value (tick 100008) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx3 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx4 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx5 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx6 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_128_bytes_scx7 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_48_bytes_sprite_y16_x16 | $FFF0=$02 = fail value (tick 100012) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x01 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x02 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x03 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x04 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x05 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x06 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x08 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x09 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x10 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x11 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x12 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x13 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x14 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x15 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x16 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x17 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x18 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x19 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x20 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x21 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x22 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x23 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x32 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x33 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x34 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x35 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x36 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x37 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x38 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x39 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x40 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x41 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x42 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x43 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x44 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x45 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x46 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x47 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x48 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x49 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_sprite_y16_x50 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx16 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx17 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx18 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx19 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx20 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx21 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx22 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_64_bytes_window_wy1_wx23 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x16 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x17 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x18 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x19 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x20 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x21 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x22 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x23 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x10_x24 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x16 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x25 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x26 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x27 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x28 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x29 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x30 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x31 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x32 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x33 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x24_x34 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x32 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_80_bytes_sprite_y16_x48 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_echo_ram | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_from_vram_to_ram | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_hram | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_io | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_source_not_usable | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_oam | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_overflow_source_illegal | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_vram | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/gdma_source_vram_corruption | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_vram_jp_in_ram | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c000_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c000_8000_source_overflow_illegal | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c000_8010 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c010_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c010_8010 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c020_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c020_8000_d | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c100_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c110_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_c120_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/gdma_source_wram_dma_source_ram_d000_8000 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_46_nops_scx0 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_46_nops_scx1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_46_nops_scx2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_46_nops_scx3 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_47_nops_scx0 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_47_nops_scx1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_47_nops_scx2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_47_nops_scx3 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_stat_vblank_at_oam_scan | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_timer_interrupt_halt_at_hblank_wake_at_hblank_wait_oam_scan_to_turn_off | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_halt_resume_with_timer_interrupt_halt_at_hblank_wake_at_pixel_transfer | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/hdma/hdma_halt_resume_with_timer_interrupt_halt_at_pixel_transfer_wake_at_hblank_wait_oam_scan_to_turn_off | $FFF0=$02 = fail value (tick 100008) |
| cgb/docboy/hdma/hdma_halt_resume_with_timer_interrupt_halt_at_pixel_transfer_wake_at_pixel_transfer | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_ppu_on_turn_off_during_ly1_oam_scan | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/hdma/hdma_source_wram_dma_source_ram_during_oam_scan | $FFF0=$02 = fail value (tick 100000) |

## docboy/cgb/serial (13/17 passed)

13/17 tests passed on CGB cgbE, 4 failed:

| Test | Result |
|------|--------|
| cgb/docboy/serial/serial_timing_change_to_high_speed_during_transfer_alt_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/serial/serial_timing_high_speed_nops0_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/serial/serial_timing_high_speed_nops2_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/serial/serial_timing_high_speed_nops32_round2 | $FFF0=$02 = fail value (tick 100012) |

## docboy/cgb/ir

All 1 tests passed (CGB cgbE).

## docboy/cgb/mode

All 6 tests passed (CGB cgbE).

## docboy/cgb/undocumented

All 4 tests passed (CGB cgbE).

## docboy/cgb/ppu (382/403 passed)

382/403 tests passed on CGB cgbE, 21 failed:

| Test | Result |
|------|--------|
| cgb/docboy/ppu/visual/change_wx_glitch_wx6_nops16 | timeout, last check: 3042/23040 pixels differ, first at row 10 col 6: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx6_nops17 | timeout, last check: 7353/23040 pixels differ, first at row 8 col 10: got $FFE0 want $39C7 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx7_nops17 | timeout, last check: 2895/23040 pixels differ, first at row 14 col 10: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx8_nops17 | timeout, last check: 2895/23040 pixels differ, first at row 14 col 10: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx8_nops18 | timeout, last check: 4/23040 pixels differ, first at row 17 col 2: got $39C7 want $FFE0 |
| cgb/docboy/ppu/visual/change_wx_glitch_wx8_nops18_alt | timeout, last check: 4/23040 pixels differ, first at row 17 col 2: got $FFE0 want $39C7 |
| cgb/docboy/ppu/visual/stop_during_pixel_transfer_alt | timeout, last check: 22801/23040 pixels differ, first at row 1 col 79: got $FFFF want $FFE0 |
| cgb/docboy/ppu/visual/stop_ly42_during_hblank | timeout, last check: 6880/23040 pixels differ, first at row 0 col 0: got $0000 want $07FF |
| cgb/docboy/ppu/visual/window_bg_reprise_wx14 | timeout, last check: 8/23040 pixels differ, first at row 12 col 23: got $39C7 want $F81F |
| cgb/docboy/ppu/visual/window_bg_reprise_wx15 | timeout, last check: 8/23040 pixels differ, first at row 12 col 24: got $39C7 want $F81F |
| cgb/docboy/ppu/visual/window_bg_reprise_wx22 | timeout, last check: 8/23040 pixels differ, first at row 12 col 23: got $39C7 want $F81F |
| cgb/docboy/ppu/visual/window_bg_reprise_wx23 | timeout, last check: 8/23040 pixels differ, first at row 12 col 24: got $39C7 want $F81F |
| cgb/docboy/ppu/visual/window_bg_reprise_wx23 #2 | timeout, last check: 8/23040 pixels differ, first at row 12 col 24: got $39C7 want $F81F |
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

## docboy/cgb/apu/ch1 (1129/1132 passed)

1129/1132 tests passed on CGB cgbE, 3 failed:

| Test | Result |
|------|--------|
| cgb/docboy/apu/ch1/ch1_period_sweep_change_pace_4_to_6_during_recalc_round1_1 | $FFF0=$02 = fail value (tick 1500000) |
| cgb/docboy/apu/ch1/ch1_period_sweep_change_period_nr14_during_recalc_delay14285_round2 | $FFF0=$02 = fail value (tick 300004) |
| cgb/docboy/apu/ch1/ch1_period_sweep_change_step_during_recalc_0_to_4_alt_round1_2 | $FFF0=$02 = fail value (tick 600004) |

## docboy/cgb/apu/ch2 (24/26 passed)

24/26 tests passed on CGB cgbE, 2 failed:

| Test | Result |
|------|--------|
| cgb/docboy/apu/ch2/ch2_volume_sweep_retrigger_divapu0_round1 | $FFF0=$02 = fail value (tick 200008) |
| cgb/docboy/apu/ch2/ch2_volume_sweep_retrigger_divapu0_round2 | $FFF0=$02 = fail value (tick 200012) |

## docboy/cgb/apu/ch3

All 109 tests passed (CGB cgbE).

## docboy/cgb/apu/ch4

All 69 tests passed (CGB cgbE).

## docboy/cgb/double_speed/apu/ch1 (600/613 passed)

600/613 tests passed on CGB cgbE, 13 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12241_round2 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12242_round2 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12243_period_round2 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_delay12243_period_round4 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay0_delay12243_round1 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay0_delay12244_round1 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay1_delay12244_round1 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay1_delay12245_round1 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay2_delay12245_round1 | $FFF0=$02 = fail value (tick 400000) |
| cgb/docboy/double_speed/apu/ch1/double_speed_apu_ch1_period_sweep_change_period_nr14_during_recalc_double_trigger_delay2_delay12246_round1 | $FFF0=$02 = fail value (tick 400000) |
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

## docboy/cgb/double_speed/hdma (49/50 passed)

49/50 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/hdma/double_speed_hdma_basic_transfer | $FFF0=$02 = fail value (tick 100000) |

## docboy/cgb/double_speed/interactive

All 67 tests passed (CGB cgbE).

## docboy/cgb/double_speed/interrupts (233/246 passed)

233/246 tests passed on CGB cgbE, 13 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/interrupts/double_speed_interrupt_stat_a_scx1 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/interrupts/double_speed_interrupt_stat_a_scx3 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/double_speed_interrupt_stat_b_scx1 | $FFF0=$02 = fail value (tick 100004) |
| cgb/docboy/double_speed/interrupts/double_speed_interrupt_stat_b_scx3 | $FFF0=$02 = fail value (tick 100006) |
| cgb/docboy/double_speed/interrupts/single_speed_interrupt_vblank_c | $FFF0=$02 = fail value (tick 500012) |
| cgb/docboy/double_speed/interrupts/single_speed_interrupt_vblank_c_halted_round1 | $FFF0=$02 = fail value (tick 500004) |
| cgb/docboy/double_speed/interrupts/single_speed_interrupt_vblank_d_halted_round1 | $FFF0=$02 = fail value (tick 500004) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_double_interrupt_stat_aligned_with_stop_nops_36_scx1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_double_interrupt_stat_aligned_with_stop_nops_36_scx3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_double_interrupt_stat_aligned_with_stop_nops_37_scx3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_double_interrupt_stat_scx1_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_double_interrupt_stat_scx3_round2 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/interrupts/speed_switch_to_single_interrupt_vblank_c_round1 | $FFF0=$02 = fail value (tick 400002) |

## docboy/cgb/double_speed/ppu (346/357 passed)

346/357 tests passed on CGB cgbE, 11 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/ppu/double_speed_ppu_d3_oam_round2 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_d3_px_round2 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_hblank_if_a_scx1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_hblank_if_a_scx3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_hblank_if_b_scx1_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_hblank_if_b_scx3_round1 | $FFF0=$02 = fail value (tick 100000) |
| cgb/docboy/double_speed/ppu/double_speed_ppu_vram_write_block_timing_ly0_1_out_of_4 | $FFF0=$02 = fail value (tick 3900000) |
| cgb/docboy/double_speed/ppu/single_speed_ppu_s3_vblank_round1 | $FFF0=$02 = fail value (tick 300000) |
| cgb/docboy/double_speed/ppu/single_speed_ppu_s3b_vblank_round1 | $FFF0=$02 = fail value (tick 300002) |
| cgb/docboy/double_speed/ppu/single_speed_ppu_s4b_vblank_round1 | $FFF0=$02 = fail value (tick 300002) |
| cgb/docboy/double_speed/ppu/single_speed_ppu_sx_vblank_round1 | $FFF0=$02 = fail value (tick 1500000) |

## docboy/cgb/double_speed/serial (3/4 passed)

3/4 tests passed on CGB cgbE, 1 failed:

| Test | Result |
|------|--------|
| cgb/docboy/double_speed/serial/double_speed_serial_high_speed_round2 | $FFF0=$02 = fail value (tick 100000) |

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

## docboy/cgb_dmg_mode/ppu (330/440 passed)

330/440 tests passed on CGB cgbE, 110 failed:

| Test | Result |
|------|--------|
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x79 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x81 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x82 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x83 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x84 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x85 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x86 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly32_sprites_x87 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x79 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x81 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x82 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x83 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x84 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x85 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x86 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly33_sprites_x87 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x79 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x80 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x83 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x84 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x85 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x86 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x87 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly34_sprites_x88 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x79 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x80 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x84 | $FFF0=$02 = fail value (tick 300012) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x85 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x86 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x87 | $FFF0=$02 = fail value (tick 300008) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly35_sprites_x88 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x79 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x80 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x85 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x86 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x87 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly36_sprites_x88 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x79 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x80 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x85 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x86 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x87 | $FFF0=$02 = fail value (tick 300000) |
| cgb_dmg_mode/docboy/ppu/m3_lcdc_win_en_change_multiple_wx_timing_ly37_sprites_x88 | $FFF0=$02 = fail value (tick 300004) |
| cgb_dmg_mode/docboy/ppu/visual/change_bgp_or_bug_checksum_d1 | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $0318 want $FA89 |
| cgb_dmg_mode/docboy/ppu/visual/change_bgp_or_bug_checksum_d1_first_dot | timeout, last check: 23040/23040 pixels differ, first at row 0 col 0: got $0318 want $FA89 |
| cgb_dmg_mode/docboy/ppu/visual/enable_win_during_pixel_transfer_round1 | timeout, last check: 128/23040 pixels differ, first at row 8 col 15: got $0318 want $FFFF |
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
