# Dingbat Test Results

*Generated: 2026-08-21 16:19:45 · commit f398fe3a · game-boy-test-roms v7.0*

Device column: the hardware the row is scored on. `cart` = the cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific boot table/revision (`--model`); `—` = GBA, which has no device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. Sections where every row passes are collapsed to a single line — the per-row table comes back as soon as anything in them fails.

## Summary

- **Total:** 1223
- **Pass:** 1121
- **Fail:** 102

| Suite | Pass | Total |
|-------|------|-------|
| Game Boy - Blargg | 28 | 28 |
| Game Boy - Blargg dmg_sound | 12 | 12 |
| Game Boy - Blargg cgb_sound | 12 | 12 |
| Game Boy - Mooneye | 152 | 152 |
| GBA - mGBA Test Suite | 12 | 13 |
| GBA - jsmolka gba-tests | 13 | 13 |
| GBA - FuzzARM | 5 | 5 |
| Game Boy - Acid2 | 2 | 2 |
| Game Boy - MagenTests | 7 | 7 |
| Game Boy - Mealybug Tearoom | 73 | 74 |
| Game Boy - GBMicrotest | 480 | 480 |
| Game Boy - AGE | 45 | 89 |
| Game Boy - Screenshot suites | 13 | 13 |
| Game Boy - SameSuite | 8 | 8 |
| Game Boy - SameSuite APU | 68 | 70 |
| Game Boy - Shootout ROMs | 13 | 13 |
| Game Boy - Mooneye (wilbertpol) | 159 | 184 |
| Game Boy - gambatte | 19 | 48 |

## Game Boy - Blargg (28/28)

**All 28 tests passed.**

## Game Boy - Blargg dmg_sound (12/12)

**All 12 tests passed.**

## Game Boy - Blargg cgb_sound (12/12)

**All 12 tests passed.**

## Game Boy - Mooneye (152/152)

**All 152 tests passed.**

## GBA - mGBA Test Suite (12/13)

| Test | Device | Result |
|------|--------|--------|
| mgba-suite/Memory tests | — | 👌 |
| mgba-suite/I/O read tests | — | 👌 |
| mgba-suite/Timing tests | — | 👌 |
| mgba-suite/Timer count-up tests | — | 👌 |
| mgba-suite/Timer IRQ tests | — | 👌 |
| mgba-suite/Shifter tests | — | 👌 |
| mgba-suite/Carry tests | — | 👌 |
| mgba-suite/Multiply long tests | — | 👌 |
| mgba-suite/BIOS math tests | — | 👌 |
| mgba-suite/DMA tests | — | 👌 |
| mgba-suite/SIO register R/W tests | — | 👌 |
| mgba-suite/SIO timing tests | — | 👌 |
| mgba-suite/Misc. edge case tests | — | 👀 4/12 passed |

See [detailed results](results_mgba_suite.md) for individual test outcomes.

## GBA - jsmolka gba-tests (13/13)

**All 13 tests passed.**

## GBA - FuzzARM (5/5)

**All 5 tests passed.**

## Game Boy - Acid2 (2/2)

**All 2 tests passed.**

## Game Boy - MagenTests (7/7)

**All 7 tests passed.**

## Game Boy - Mealybug Tearoom (73/74)

| Test | Device | Result |
|------|--------|--------|
| mealybug/m2_win_en_toggle | DMG | 👌 |
| mealybug-cgb/m2_win_en_toggle | CGB cgbc | 👌 |
| mealybug-cgbd/m2_win_en_toggle | CGB cgbd | 👌 |
| mealybug/m3_bgp_change | DMG | 👌 |
| mealybug-cgb/m3_bgp_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_bgp_change | CGB cgbd | 👌 |
| mealybug/m3_bgp_change_sprites | DMG | 👌 |
| mealybug-cgb/m3_bgp_change_sprites | CGB cgbc | 👌 |
| mealybug-cgbd/m3_bgp_change_sprites | CGB cgbd | 👌 |
| mealybug/m3_lcdc_bg_en_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_bg_en_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_bg_en_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_lcdc_bg_en_change2 | CGB cgbc | 👌 |
| mealybug/m3_lcdc_bg_map_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_bg_map_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_bg_map_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_lcdc_bg_map_change2 | CGB cgbc | 👌 |
| mealybug/m3_lcdc_obj_en_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_obj_en_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_obj_en_change | CGB cgbd | 👌 |
| mealybug/m3_lcdc_obj_en_change_variant | DMG | 👌 |
| mealybug-cgb/m3_lcdc_obj_en_change_variant | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_obj_en_change_variant | CGB cgbd | 👌 |
| mealybug/m3_lcdc_obj_size_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_obj_size_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_obj_size_change | CGB cgbd | 👌 |
| mealybug/m3_lcdc_obj_size_change_scx | DMG | 👌 |
| mealybug-cgb/m3_lcdc_obj_size_change_scx | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_obj_size_change_scx | CGB cgbd | 👌 |
| mealybug/m3_lcdc_tile_sel_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_tile_sel_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_tile_sel_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_lcdc_tile_sel_change2 | CGB cgbc | 👌 |
| mealybug/m3_lcdc_tile_sel_win_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_tile_sel_win_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_tile_sel_win_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_lcdc_tile_sel_win_change2 | CGB cgbc | 👌 |
| mealybug/m3_lcdc_win_en_change_multiple | DMG | 👌 |
| mealybug-cgb/m3_lcdc_win_en_change_multiple | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_win_en_change_multiple | CGB cgbd | 👌 |
| mealybug/m3_lcdc_win_en_change_multiple_wx | DMG | 👌 |
| mealybug/m3_lcdc_win_map_change | DMG | 👌 |
| mealybug-cgb/m3_lcdc_win_map_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_lcdc_win_map_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_lcdc_win_map_change2 | CGB cgbc | 👌 |
| mealybug/m3_obp0_change | DMG | 👌 |
| mealybug-cgb/m3_obp0_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_obp0_change | CGB cgbd | 👌 |
| mealybug/m3_scx_high_5_bits | DMG | 👌 |
| mealybug-cgb/m3_scx_high_5_bits | CGB cgbc | 👌 |
| mealybug-cgbd/m3_scx_high_5_bits | CGB cgbd | 👌 |
| mealybug-cgb/m3_scx_high_5_bits_change2 | CGB cgbc | 👌 |
| mealybug/m3_scx_low_3_bits | DMG | 👌 |
| mealybug-cgb/m3_scx_low_3_bits | CGB cgbc | 👌 |
| mealybug-cgbd/m3_scx_low_3_bits | CGB cgbd | 👌 |
| mealybug/m3_scy_change | DMG | 👌 |
| mealybug-cgb/m3_scy_change | CGB cgbc | 👌 |
| mealybug-cgbd/m3_scy_change | CGB cgbd | 👌 |
| mealybug-cgb/m3_scy_change2 | CGB cgbc | 👌 |
| mealybug/m3_window_timing | DMG | 👌 |
| mealybug-cgb/m3_window_timing | CGB cgbc | 👌 |
| mealybug-cgbd/m3_window_timing | CGB cgbd | 👌 |
| mealybug/m3_window_timing_wx_0 | DMG | 👌 |
| mealybug-cgb/m3_window_timing_wx_0 | CGB cgbc | 👌 |
| mealybug-cgbd/m3_window_timing_wx_0 | CGB cgbd | 👌 |
| mealybug/m3_wx_4_change | DMG | 👌 |
| mealybug/m3_wx_4_change_sprites | DMG | 👌 |
| mealybug-cgb/m3_wx_4_change_sprites | CGB cgbc | 👌 |
| mealybug-cgbd/m3_wx_4_change_sprites | CGB cgbd | 👌 |
| mealybug/m3_wx_5_change | DMG | 👌 |
| mealybug/m3_wx_6_change | DMG | 👌 |
| mealybug/dma/hdma_during_halt-C | CGB cgbc | 👌 |
| mealybug/dma/hdma_timing-C | CGB cgbc | 👀 Mooneye: FAIL |
| mealybug/mbc/mbc3_rtc | cart | 👌 |

## Game Boy - GBMicrotest (480/480)

**All 480 tests passed.**

## Game Boy - AGE (45/89)

| Test | Device | Result |
|------|--------|--------|
| age/halt/ei-halt-dmgC-cgbBCE@dmgC | DMG dmgC | 👌 |
| age/halt/ei-halt-dmgC-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/halt/ei-halt-dmgC-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/halt/ei-halt-dmgC-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/halt/halt-m0-interrupt-dmgC-cgbBCE@dmgC | DMG dmgC | 👌 |
| age/halt/halt-m0-interrupt-dmgC-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/halt/halt-m0-interrupt-dmgC-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/halt/halt-m0-interrupt-dmgC-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/halt/halt-prefetch-dmgC-cgbBCE@dmgC | DMG dmgC | 👌 |
| age/halt/halt-prefetch-dmgC-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/halt/halt-prefetch-dmgC-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/halt/halt-prefetch-dmgC-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/lcd-align-ly/lcd-align-ly-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/lcd-align-ly/lcd-align-ly-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/lcd-align-ly/lcd-align-ly-cgbE | CGB cgbe | 👀 Mooneye: FAIL |
| age/ly/ly-cgbE | CGB cgbe | 👌 |
| age/ly/ly-dmgC-cgbBC@dmgC | DMG dmgC | 👌 |
| age/ly/ly-dmgC-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/ly/ly-dmgC-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/m3-bg-bgp/m3-bg-bgp-dmgC | DMG dmgC | 👀 100.0% correct (23038/23040 pixels match) |
| age/m3-bg-lcdc/m3-bg-lcdc-ds-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-ds-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-ds-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-dmgC | DMG dmgC | 👌 |
| age/m3-bg-scx/m3-bg-scx-ds-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/m3-bg-scx/m3-bg-scx-ds-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/m3-bg-scx/m3-bg-scx-ds-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/m3-bg-scx/m3-bg-scx-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/m3-bg-scx/m3-bg-scx-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/m3-bg-scx/m3-bg-scx-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/m3-bg-scx/m3-bg-scx-dmgC | DMG dmgC | 👌 |
| age/oam/oam-read-cgbE | CGB cgbe | 👀 Mooneye: FAIL |
| age/oam/oam-read-dmgC-cgbBC@dmgC | DMG dmgC | 👀 Mooneye: FAIL |
| age/oam/oam-read-dmgC-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/oam/oam-read-dmgC-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/oam/oam-write-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/oam/oam-write-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/oam/oam-write-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/oam/oam-write-dmgC | DMG dmgC | 👀 Mooneye: FAIL |
| age/speed-switch/caution/spsw-interrupts-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/speed-switch/caution/spsw-interrupts-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/speed-switch/caution/spsw-interrupts-cgbE | CGB cgbe | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-ch2-lc-delay-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-ch2-lc-delay-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-ch2-lc-delay-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-div-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/speed-switch/spsw-div-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/speed-switch/spsw-div-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/speed-switch/spsw-mode0-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/speed-switch/spsw-mode0-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/speed-switch/spsw-mode0-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/speed-switch/spsw-stop-prefetch-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/speed-switch/spsw-stop-prefetch-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/speed-switch/spsw-stop-prefetch-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/speed-switch/spsw-tima-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-tima-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/speed-switch/spsw-tima-cgbE | CGB cgbe | 👀 Mooneye: FAIL |
| age/stat-interrupt/stat-int-dmgC-cgbBCE@dmgC | DMG dmgC | 👌 |
| age/stat-interrupt/stat-int-dmgC-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/stat-interrupt/stat-int-dmgC-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/stat-interrupt/stat-int-dmgC-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE@dmgC | DMG dmgC | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-ds-cgbBCE@cgbab | CGB cgbab | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-ds-cgbBCE@cgbc | CGB cgbc | 👌 |
| age/stat-mode-sprites/stat-mode-sprites-ds-cgbBCE@cgbe | CGB cgbe | 👌 |
| age/stat-mode-window/stat-mode-window-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-dmgC | DMG dmgC | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-ds-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-ds-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/stat-mode-window/stat-mode-window-ds-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-cgbE | CGB cgbe | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-dmgC-cgbBC@dmgC | DMG dmgC | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-dmgC-cgbBC@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-dmgC-cgbBC@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-ds-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-ds-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/stat-mode/stat-mode-ds-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/vram/vram-read-cgbBCE@cgbab | CGB cgbab | 👀 Mooneye: FAIL |
| age/vram/vram-read-cgbBCE@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| age/vram/vram-read-cgbBCE@cgbe | CGB cgbe | 👀 Mooneye: FAIL |
| age/vram/vram-read-dmgC | DMG dmgC | 👀 Mooneye: FAIL |

## Game Boy - Screenshot suites (13/13)

**All 13 tests passed.**

## Game Boy - SameSuite (8/8)

**All 8 tests passed.**

## Game Boy - SameSuite APU (68/70)

| Test | Device | Result |
|------|--------|--------|
| same-suite/apu/channel_1/channel_1_align | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_align_cpu | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_delay | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_duty | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_duty_delay | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_extra_length_clocking-cgb0B | CGB cgb0B | 👌 |
| same-suite/apu/channel_1/channel_1_freq_change | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_freq_change_timing-A | CGB A | 👌 |
| same-suite/apu/channel_1/channel_1_freq_change_timing-cgb0BC | CGB cgb0BC | 👀 Mooneye: FAIL |
| same-suite/apu/channel_1/channel_1_freq_change_timing-cgbDE | CGB cgbDE | 👀 Mooneye: FAIL |
| same-suite/apu/channel_1/channel_1_nrx2_glitch | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_nrx2_speed_change | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_restart | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_restart_nrx2_glitch | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_stop_div | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_stop_restart | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_sweep | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_sweep_restart | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_sweep_restart_2 | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_volume | CGB | 👌 |
| same-suite/apu/channel_1/channel_1_volume_div | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_align | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_align_cpu | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_delay | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_duty | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_duty_delay | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_extra_length_clocking-cgb0B | CGB cgb0B | 👌 |
| same-suite/apu/channel_2/channel_2_freq_change | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_nrx2_glitch | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_nrx2_speed_change | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_restart | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_restart_nrx2_glitch | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_stop_div | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_stop_restart | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_volume | CGB | 👌 |
| same-suite/apu/channel_2/channel_2_volume_div | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_and_glitch | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_extra_length_clocking-cgb0 | CGB cgb0 | 👌 |
| same-suite/apu/channel_3/channel_3_extra_length_clocking-cgbB | CGB cgbB | 👌 |
| same-suite/apu/channel_3/channel_3_first_sample | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_freq_change_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_restart_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_restart_during_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_restart_stop_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_shift_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_shift_skip_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_stop_delay | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_stop_div | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_wave_ram_dac_on_rw | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_wave_ram_locked_write | CGB | 👌 |
| same-suite/apu/channel_3/channel_3_wave_ram_sync | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_align | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_delay | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_equivalent_frequencies | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_extra_length_clocking-cgb0B | CGB cgb0B | 👌 |
| same-suite/apu/channel_4/channel_4_freq_change | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_frequency_alignment | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr15 | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr_15_7 | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr_7_15 | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr_restart | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_lfsr_restart_fast | CGB | 👌 |
| same-suite/apu/channel_4/channel_4_volume_div | CGB | 👌 |
| same-suite/apu/div_trigger_volume_10 | CGB | 👌 |
| same-suite/apu/div_write_trigger | CGB | 👌 |
| same-suite/apu/div_write_trigger_10 | CGB | 👌 |
| same-suite/apu/div_write_trigger_volume | CGB | 👌 |
| same-suite/apu/div_write_trigger_volume_10 | CGB | 👌 |

## Game Boy - Shootout ROMs (13/13)

**All 13 tests passed.**

## Game Boy - Mooneye (wilbertpol) (159/184)

| Test | Device | Result |
|------|--------|--------|
| mooneye-wilbertpol/acceptance/add_sp_e_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/bits/mem_oam | cart | 👌 |
| mooneye-wilbertpol/acceptance/bits/reg_f | cart | 👌 |
| mooneye-wilbertpol/acceptance/bits/unused_hwio-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/bits/unused_hwio-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/bits/unused_hwio-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/bits/unused_hwio-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/boot_hwio-G@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/boot_hwio-G@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/boot_regs-dmg | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/call_cc_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/call_cc_timing2 | cart | 👌 |
| mooneye-wilbertpol/acceptance/call_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/call_timing2 | cart | 👌 |
| mooneye-wilbertpol/acceptance/di_timing-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/di_timing-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/di_timing-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/di_timing-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/div_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/ei_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_variant_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_0_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_2_timing-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_2_timing-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_2_timing-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_2_timing-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_0_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx1_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx2_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx3_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx4_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx5_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx6_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx7_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx8_timing_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx1_nops | cart | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx2_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx3_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx4_nops | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode3_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_oam_ok_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/lcdon_mode_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_01_mode0_2 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode0_2-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode0_2-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode0_2-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode0_2-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_0-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_0-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_0-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_0-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_2-C@cgbc | CGB cgbc | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_2-C@agb | CGB agb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode2_3 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode3_0 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_145 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_152_153 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_mode0_1 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_mode3_0 | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-C@cgbc | CGB cgbc | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-C@agb | CGB agb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/stat_irq_blocking | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-GS@dmgABC | DMG dmgABC | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-GS@mgb | DMG mgb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-GS@sgb | SGB sgb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-GS@sgb2 | SGB sgb2 | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/acceptance/gpu/vblank_if_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/gpu/vblank_stat_intr-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/gpu/vblank_stat_intr-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/vblank_stat_intr-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/gpu/vblank_stat_intr-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime0_ei | cart | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime0_nointr_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing2-GS@dmgABC | DMG dmgABC | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing2-GS@mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing2-GS@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing2-GS@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/acceptance/if_ie_registers | cart | 👌 |
| mooneye-wilbertpol/acceptance/intr_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/jp_cc_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/jp_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/ld_hl_sp_e_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_restart | cart | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_start | cart | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/pop_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/push_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/rapid_di_ei | cart | 👌 |
| mooneye-wilbertpol/acceptance/ret_cc_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/ret_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/reti_intr_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/reti_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/rst_timing | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/div_write | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/rapid_toggle | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim00 | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim00_div_trigger | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim01 | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim01_div_trigger | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim10 | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim10_div_trigger | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim11 | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim11_div_trigger | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tima_reload | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tima_write_reloading | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/timer_if | cart | 👌 |
| mooneye-wilbertpol/acceptance/timer/tma_write_reloading | cart | 👌 |
| mooneye-wilbertpol/emulator-only/mbc1_rom_4banks | cart | 👌 |
| mooneye-wilbertpol/madness/mgb_oam_dma_halt_sprites | DMG mgb | 👌 |
| mooneye-wilbertpol/manual-only/sprite_priority | DMG | 👌 |
| mooneye-wilbertpol/misc/bits/unused_hwio-C@cgbc | CGB cgbc | 👌 |
| mooneye-wilbertpol/misc/bits/unused_hwio-C@agb | CGB agb | 👌 |
| mooneye-wilbertpol/misc/boot_hwio-C@cgbc | CGB cgbc | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/misc/boot_hwio-C@agb | CGB agb | 👀 Mooneye: FAIL |
| mooneye-wilbertpol/misc/boot_hwio-S@sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/misc/boot_hwio-S@sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/misc/boot_regs-A | CGB agb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-cgb | CGB cgbc | 👌 |
| mooneye-wilbertpol/misc/boot_regs-mgb | DMG mgb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-sgb | SGB sgb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-sgb2 | SGB sgb2 | 👌 |
| mooneye-wilbertpol/misc/gpu/vblank_stat_intr-C@cgbc | CGB cgbc | 👌 |
| mooneye-wilbertpol/misc/gpu/vblank_stat_intr-C@agb | CGB agb | 👌 |

## Game Boy - gambatte (19/48)

| Test | Device | Result |
|------|--------|--------|
| gambatte/bgen | per-ROM | 👌 2/2 passed |
| gambatte/bgtiledata | per-ROM | 👌 34/34 passed |
| gambatte/bgtilemap | per-ROM | 👌 40/40 passed |
| gambatte/cgbpal_m3 | per-ROM | 👀 33/44 passed |
| gambatte/display_startstate | per-ROM | 👀 10/14 passed |
| gambatte/div | per-ROM | 👌 8/8 passed |
| gambatte/dma | per-ROM | 👀 186/229 passed |
| gambatte/dmgpalette_during_m3 | per-ROM | 👀 9/17 passed |
| gambatte/enable_display | per-ROM | 👀 158/184 passed |
| gambatte/halt | per-ROM | 👀 141/158 passed |
| gambatte/irq_precedence | per-ROM | 👀 48/64 passed |
| gambatte/lcd_offset | per-ROM | 👀 42/62 passed |
| gambatte/lcdirq_precedence | per-ROM | 👌 62/62 passed |
| gambatte/ly0 | per-ROM | 👀 88/96 passed |
| gambatte/lyc0int_m0irq | per-ROM | 👌 6/6 passed |
| gambatte/lyc153int_m2irq | per-ROM | 👀 14/16 passed |
| gambatte/lycEnable | per-ROM | 👀 185/225 passed |
| gambatte/lycint_ly | per-ROM | 👌 6/6 passed |
| gambatte/lycint_lycflag | per-ROM | 👀 11/12 passed |
| gambatte/lycint_lycirq | per-ROM | 👌 4/4 passed |
| gambatte/lycint_m0stat | per-ROM | 👌 6/6 passed |
| gambatte/lycm2int | per-ROM | 👌 18/18 passed |
| gambatte/lywrite | per-ROM | 👌 8/8 passed |
| gambatte/m0enable | per-ROM | 👀 148/167 passed |
| gambatte/m0int_m0irq | per-ROM | 👌 4/4 passed |
| gambatte/m0int_m0stat | per-ROM | 👀 11/12 passed |
| gambatte/m0int_m3stat | per-ROM | 👌 6/6 passed |
| gambatte/m1 | per-ROM | 👀 142/170 passed |
| gambatte/m2enable | per-ROM | 👀 101/120 passed |
| gambatte/m2int_m0irq | per-ROM | 👀 67/72 passed |
| gambatte/m2int_m0stat | per-ROM | 👌 6/6 passed |
| gambatte/m2int_m2irq | per-ROM | 👌 18/18 passed |
| gambatte/m2int_m2stat | per-ROM | 👌 8/8 passed |
| gambatte/m2int_m3stat | per-ROM | 👌 44/44 passed |
| gambatte/miscmstatirq | per-ROM | 👀 271/279 passed |
| gambatte/oam_access | per-ROM | 👀 54/69 passed |
| gambatte/oamdma | per-ROM | 👀 788/802 passed |
| gambatte/scx_during_m3 | per-ROM | 👀 131/141 passed |
| gambatte/scy | per-ROM | 👌 67/67 passed |
| gambatte/serial | per-ROM | 👀 75/82 passed |
| gambatte/sound | per-ROM | 👀 113/116 passed |
| gambatte/speedchange | per-ROM | 👀 202/208 passed |
| gambatte/sprites | per-ROM | 👀 470/476 passed |
| gambatte/tima | per-ROM | 👀 224/232 passed |
| gambatte/undef_ops | per-ROM | 👌 20/20 passed |
| gambatte/vram_m3 | per-ROM | 👀 42/50 passed |
| gambatte/vramw_m3end | per-ROM | 👀 32/36 passed |
| gambatte/window | per-ROM | 👀 425/476 passed |

Each row is one gambatte subdirectory. See [detailed results](results_gambatte.md) for individual test outcomes.

## Deliberately not scored

Everything skipped on purpose, with the reason and the builder that skips it. If a suite's row count looks short, the answer is here.

- **blargg/oam_bug/7-timing_effect** — broken standalone build: its verbose output overruns the $A004..$BFFF text window into the $C000 copy of its own code, so it never reports — on real DMG hardware too (docboy#33). Test 7 is scored through `blargg/oam_bug/combined` instead. (build_blargg_tests)
- **daid/ppu_scanline_bgp (GBC)** — its reference captures a CGB-D-or-later palette-write dot; the tree deliberately scores CPU CGB C, which mealybug's 27 compat-mode rows pin from the other side. (build_shootout_tests)
- **daid/stop_instr (GBC)** — reference is an all-black frame, which a blanked panel matches however STOP got there — a gate that cannot fail. (build_shootout_tests)
- **daid/rom_and_ram, acid/which** — ship no reference image; the shootout classes them INFO, not pass/fail. (build_shootout_tests)
- **cpp/sgb-ext-test** — SGB packet-protocol test the shootout scores on an SGB; not covered by dingbat's SGB adapter model. (build_shootout_tests)
- **magen/oam_internal_priority** — its only stated criterion is prose ("2 pairs of rectangles connected or touching"); nothing machine-checkable to score against. (build_magen_tests)
- **mooneye/wilbertpol `ags` arms** — `ags` is AGB silicon in a different package — the suite's own README says so — and dingbat models one AGB, so a `-C`/`-A` token's `ags` member folds into its `agb` arm rather than inventing a machine. Everything else those tokens name IS run: see mooneye_machines_for. (build_mooneye_tests / build_wilbertpol_tests)
- **mooneye/wilbertpol revision 0 inside a bare model token** — `-cgb` and `-dmg` fan out across the revisions dingbat models but deliberately stop short of revision 0, which the suite treats as its own machine and ships separate `-cgb0`/`-dmg0` ROMs for precisely because it diverges. Those separate ROMs ARE scored. (build_mooneye_tests)
- **age `ncm*` rows** — CGB running in non-CGB mode, a device this harness does not model. (build_age_tests)
- **gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)** — their verdict is a byte of uninitialised WRAM. That source fetches through the echo, so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch rather than its own byte -- Pan Docs says WRAM is random on power-up and GB_POWERUP_WRAM_PATTERN honours that, so these encode gambatte's capture rig, not hardware. The non-colliding members of the same family (`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_wram)
- **gambatte `_outaudio0/1` rows (220) + the AGB column** — audio-register sampling and the AGB device are not scored; see results_gambatte.md's source notes. (build_gambatte_rows)
- **gbmicrotest: 31 ROMs that never write the $FF82 verdict byte** — scanned all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one and these 31 contain neither, so the harness would be scoring uninitialised HRAM rather than a result. All 31 were failing rows before the skip. The honest suite denominator is 482. (build_gbmicrotest_tests)
- **gbmicrotest: 2 ROMs whose expected byte is unreachable** — `halt_op_dupe_delay` wants DIV = $55 about 62 M-cycles after resetting DIV, which needs a 5,440 M-cycle HALT its own HBlank-every-line setup rules out ($55 is the suite's scratch marker; its sibling `halt_op_dupe` is correctly written and passes). `stat_write_glitch_l154_d` is missing the `xor a ; ldh ($FF0F),a` its three siblings have, so it asserts IF = $E0 across a whole frame of LCD-on time it never cleared VBlank in -- restore that clear and it passes, strip it from `_c` at identical timing and `_c` produces `_d`'s byte, on dingbat and on SameBoy alike. Both are ROM defects, not verdicts. The honest suite denominator is 480. (build_gbmicrotest_tests)
- **scribbltests/fairylake, scribbltests/winpos** — ship no reference image. (build_small_screenshot_tests)
- **little-things-gb/tellinglys** — needs scripted joypad input mid-run. (build_small_screenshot_tests)
- **mbc3-tester CGB reference** — a CGB compat-mode capture; only the DMG row is scored. (build_small_screenshot_tests)
- **mooneye/utils/ (bootrom_dumper, dump_boot_hwio)** — tools, not pass/fail tests. bootrom_dumper waits for a boot ROM to dump and can only time out (docs/gb-failure-triage.md calls it unrecoverable); dump_boot_hwio ends in quit_dump_mem, which sets the success byte unconditionally, so its green row was a gate that could not fail. (build_mooneye_tests)
- **mooneye-wilbertpol utils/, logic-analysis/** — tools and analysis captures, not pass/fail tests. (build_wilbertpol_tests)
- **rtc3test upstream single ROM** — needs menu input to select a sub-test; the shootout's three pre-split builds are scored instead. (build_shootout_tests)
