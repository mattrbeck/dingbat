# Dingbat Test Results

*Generated: 2026-08-09 10:14:48*

## Game Boy - Blargg

| Test | Result |
|------|--------|
| blargg/cpu_instrs/01-special | 👌 |
| blargg/cpu_instrs/02-interrupts | 👌 |
| blargg/cpu_instrs/03-op sp,hl | 👌 |
| blargg/cpu_instrs/04-op r,imm | 👌 |
| blargg/cpu_instrs/05-op rp | 👌 |
| blargg/cpu_instrs/06-ld r,r | 👌 |
| blargg/cpu_instrs/07-jr,jp,call,ret,rst | 👌 |
| blargg/cpu_instrs/08-misc instrs | 👌 |
| blargg/cpu_instrs/09-op r,r | 👌 |
| blargg/cpu_instrs/10-bit ops | 👌 |
| blargg/cpu_instrs/11-op a,(hl) | 👌 |
| blargg/instr_timing | 👌 |
| blargg/mem_timing/01-read_timing | 👌 |
| blargg/mem_timing/02-write_timing | 👌 |
| blargg/mem_timing/03-modify_timing | 👌 |
| blargg/oam_bug/1-lcd_sync | 👌 |
| blargg/oam_bug/2-causes | 👀 |
| blargg/oam_bug/3-non_causes | 👌 |
| blargg/oam_bug/4-scanline_timing | 👀 |
| blargg/oam_bug/5-timing_bug | 👀 |
| blargg/oam_bug/6-timing_no_bug | 👌 |
| blargg/oam_bug/7-timing_effect | 👀 |
| blargg/oam_bug/8-instr_effect | 👀 |
| blargg/mem_timing-2/01-read_timing | 👌 |
| blargg/mem_timing-2/02-write_timing | 👌 |
| blargg/mem_timing-2/03-modify_timing | 👌 |
| blargg/halt_bug | 👌 |
| blargg/interrupt_time | 👌 |

## Game Boy - Mooneye

| Test | Result |
|------|--------|
| mooneye/acceptance/add_sp_e_timing | 👌 |
| mooneye/acceptance/bits/mem_oam | 👌 |
| mooneye/acceptance/bits/reg_f | 👌 |
| mooneye/acceptance/bits/unused_hwio-GS | 👌 |
| mooneye/acceptance/boot_div-S | 👌 |
| mooneye/acceptance/boot_div-dmg0 | 👌 |
| mooneye/acceptance/boot_div-dmgABCmgb | 👌 |
| mooneye/acceptance/boot_div2-S | 👌 |
| mooneye/acceptance/boot_hwio-S | 👌 |
| mooneye/acceptance/boot_hwio-dmg0 | 👌 |
| mooneye/acceptance/boot_hwio-dmgABCmgb | 👌 |
| mooneye/acceptance/boot_regs-dmg0 | 👌 |
| mooneye/acceptance/boot_regs-dmgABC | 👌 |
| mooneye/acceptance/boot_regs-mgb | 👌 |
| mooneye/acceptance/boot_regs-sgb | 👌 |
| mooneye/acceptance/boot_regs-sgb2 | 👌 |
| mooneye/acceptance/call_cc_timing | 👌 |
| mooneye/acceptance/call_cc_timing2 | 👌 |
| mooneye/acceptance/call_timing | 👌 |
| mooneye/acceptance/call_timing2 | 👌 |
| mooneye/acceptance/di_timing-GS | 👌 |
| mooneye/acceptance/div_timing | 👌 |
| mooneye/acceptance/ei_sequence | 👌 |
| mooneye/acceptance/ei_timing | 👌 |
| mooneye/acceptance/halt_ime0_ei | 👌 |
| mooneye/acceptance/halt_ime0_nointr_timing | 👌 |
| mooneye/acceptance/halt_ime1_timing | 👌 |
| mooneye/acceptance/halt_ime1_timing2-GS | 👌 |
| mooneye/acceptance/if_ie_registers | 👌 |
| mooneye/acceptance/instr/daa | 👌 |
| mooneye/acceptance/interrupts/ie_push | 👌 |
| mooneye/acceptance/intr_timing | 👌 |
| mooneye/acceptance/jp_cc_timing | 👌 |
| mooneye/acceptance/jp_timing | 👌 |
| mooneye/acceptance/ld_hl_sp_e_timing | 👌 |
| mooneye/acceptance/oam_dma/basic | 👌 |
| mooneye/acceptance/oam_dma/reg_read | 👌 |
| mooneye/acceptance/oam_dma/sources-GS | 👌 |
| mooneye/acceptance/oam_dma_restart | 👌 |
| mooneye/acceptance/oam_dma_start | 👌 |
| mooneye/acceptance/oam_dma_timing | 👌 |
| mooneye/acceptance/pop_timing | 👌 |
| mooneye/acceptance/ppu/hblank_ly_scx_timing-GS | 👌 |
| mooneye/acceptance/ppu/intr_1_2_timing-GS | 👌 |
| mooneye/acceptance/ppu/intr_2_0_timing | 👌 |
| mooneye/acceptance/ppu/intr_2_mode0_timing | 👌 |
| mooneye/acceptance/ppu/intr_2_mode0_timing_sprites | 👀 |
| mooneye/acceptance/ppu/intr_2_mode3_timing | 👌 |
| mooneye/acceptance/ppu/intr_2_oam_ok_timing | 👌 |
| mooneye/acceptance/ppu/lcdon_timing-GS | 👌 |
| mooneye/acceptance/ppu/lcdon_write_timing-GS | 👌 |
| mooneye/acceptance/ppu/stat_irq_blocking | 👌 |
| mooneye/acceptance/ppu/stat_lyc_onoff | 👌 |
| mooneye/acceptance/ppu/vblank_stat_intr-GS | 👌 |
| mooneye/acceptance/push_timing | 👌 |
| mooneye/acceptance/rapid_di_ei | 👌 |
| mooneye/acceptance/ret_cc_timing | 👌 |
| mooneye/acceptance/ret_timing | 👌 |
| mooneye/acceptance/reti_intr_timing | 👌 |
| mooneye/acceptance/reti_timing | 👌 |
| mooneye/acceptance/rst_timing | 👌 |
| mooneye/acceptance/serial/boot_sclk_align-dmgABCmgb | 👌 |
| mooneye/acceptance/timer/div_write | 👌 |
| mooneye/acceptance/timer/rapid_toggle | 👌 |
| mooneye/acceptance/timer/tim00 | 👌 |
| mooneye/acceptance/timer/tim00_div_trigger | 👌 |
| mooneye/acceptance/timer/tim01 | 👌 |
| mooneye/acceptance/timer/tim01_div_trigger | 👌 |
| mooneye/acceptance/timer/tim10 | 👌 |
| mooneye/acceptance/timer/tim10_div_trigger | 👌 |
| mooneye/acceptance/timer/tim11 | 👌 |
| mooneye/acceptance/timer/tim11_div_trigger | 👌 |
| mooneye/acceptance/timer/tima_reload | 👌 |
| mooneye/acceptance/timer/tima_write_reloading | 👌 |
| mooneye/acceptance/timer/tma_write_reloading | 👌 |
| mooneye/emulator-only/mbc1/bits_bank1 | 👌 |
| mooneye/emulator-only/mbc1/bits_bank2 | 👌 |
| mooneye/emulator-only/mbc1/bits_mode | 👌 |
| mooneye/emulator-only/mbc1/bits_ramg | 👌 |
| mooneye/emulator-only/mbc1/multicart_rom_8Mb | 👌 |
| mooneye/emulator-only/mbc1/ram_256kb | 👌 |
| mooneye/emulator-only/mbc1/ram_64kb | 👌 |
| mooneye/emulator-only/mbc1/rom_16Mb | 👌 |
| mooneye/emulator-only/mbc1/rom_1Mb | 👌 |
| mooneye/emulator-only/mbc1/rom_2Mb | 👌 |
| mooneye/emulator-only/mbc1/rom_4Mb | 👌 |
| mooneye/emulator-only/mbc1/rom_512kb | 👌 |
| mooneye/emulator-only/mbc1/rom_8Mb | 👌 |
| mooneye/emulator-only/mbc2/bits_ramg | 👌 |
| mooneye/emulator-only/mbc2/bits_romb | 👌 |
| mooneye/emulator-only/mbc2/bits_unused | 👌 |
| mooneye/emulator-only/mbc2/ram | 👌 |
| mooneye/emulator-only/mbc2/rom_1Mb | 👌 |
| mooneye/emulator-only/mbc2/rom_2Mb | 👌 |
| mooneye/emulator-only/mbc2/rom_512kb | 👌 |
| mooneye/emulator-only/mbc5/rom_16Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_1Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_2Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_32Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_4Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_512kb | 👌 |
| mooneye/emulator-only/mbc5/rom_64Mb | 👌 |
| mooneye/emulator-only/mbc5/rom_8Mb | 👌 |
| mooneye/madness/mgb_oam_dma_halt_sprites | 👀 |
| mooneye/manual-only/sprite_priority | 👌 |
| mooneye/misc/bits/unused_hwio-C | 👌 |
| mooneye/misc/boot_div-A | 👌 |
| mooneye/misc/boot_div-cgb0 | 👌 |
| mooneye/misc/boot_div-cgbABCDE | 👌 |
| mooneye/misc/boot_hwio-C | 👌 |
| mooneye/misc/boot_regs-A | 👌 |
| mooneye/misc/boot_regs-cgb | 👌 |
| mooneye/misc/ppu/vblank_stat_intr-C | 👌 |
| mooneye/utils/bootrom_dumper | 👀 |
| mooneye/utils/dump_boot_hwio | 👌 |

## GBA - mGBA Test Suite

| Test | Result |
|------|--------|
| mgba-suite/Memory tests | 👌 |
| mgba-suite/I/O read tests | 👌 |
| mgba-suite/Timing tests | 👀 1988/2020 passed |
| mgba-suite/Timer count-up tests | 👀 935/936 passed |
| mgba-suite/Timer IRQ tests | 👌 |
| mgba-suite/Shifter tests | 👌 |
| mgba-suite/Carry tests | 👌 |
| mgba-suite/Multiply long tests | 👌 |
| mgba-suite/BIOS math tests | 👌 |
| mgba-suite/DMA tests | 👌 |
| mgba-suite/SIO register R/W tests | 👌 |
| mgba-suite/SIO timing tests | 👌 |
| mgba-suite/Misc. edge case tests | 👀 4/12 passed |

See [detailed results](results_mgba_suite.md) for individual test outcomes.

## GBA - jsmolka gba-tests

| Test | Result |
|------|--------|
| jsmolka/arm | 👌 |
| jsmolka/thumb | 👌 |
| jsmolka/memory | 👌 |
| jsmolka/bios | 👌 |
| jsmolka/none | 👌 |
| jsmolka/sram | 👌 |
| jsmolka/flash64 | 👌 |
| jsmolka/flash128 | 👌 |
| jsmolka/unsafe | 👌 |
| jsmolka/hello | 👌 |
| jsmolka/shades | 👌 |
| jsmolka/stripes | 👌 |
| jsmolka/nes | 👌 |

## GBA - FuzzARM

| Test | Result |
|------|--------|
| fuzzarm/ARM_DataProcessing | 👌 |
| fuzzarm/ARM_Any | 👌 |
| fuzzarm/THUMB_DataProcessing | 👌 |
| fuzzarm/THUMB_Any | 👌 |
| fuzzarm/FuzzARM | 👌 |

## Game Boy - Acid2

| Test | Result |
|------|--------|
| acid2/dmg-acid2 | 👌 |
| acid2/cgb-acid2 | 👌 |

## Game Boy - MagenTests

| Test | Result |
|------|--------|
| magen/hblank_vram_dma | 👌 |
| magen/key0_lock_after_boot | 👌 |
| magen/mbc_oob_sram_mbc1 | 👌 |
| magen/mbc_oob_sram_mbc3 | 👌 |
| magen/mbc_oob_sram_mbc5 | 👌 |
| magen/ppu_disabled_state | 👌 |
| magen/bg_oam_priority | 👌 |

## Game Boy - Mealybug Tearoom

| Test | Result |
|------|--------|
| mealybug/m2_win_en_toggle | 👌 |
| mealybug-cgb/m2_win_en_toggle | 👌 |
| mealybug/m3_bgp_change | 👀 100.0% correct (23039/23040 pixels match) |
| mealybug-cgb/m3_bgp_change | 👀 100.0% correct (23039/23040 pixels match) |
| mealybug/m3_bgp_change_sprites | 👀 99.5% correct (22936/23040 pixels match) |
| mealybug-cgb/m3_bgp_change_sprites | 👀 99.7% correct (22968/23040 pixels match) |
| mealybug/m3_lcdc_bg_en_change | 👀 99.7% correct (22981/23040 pixels match) |
| mealybug-cgb/m3_lcdc_bg_en_change | 👌 |
| mealybug-cgb/m3_lcdc_bg_en_change2 | 👌 |
| mealybug/m3_lcdc_bg_map_change | 👌 |
| mealybug-cgb/m3_lcdc_bg_map_change | 👀 98.3% correct (22656/23040 pixels match) |
| mealybug-cgb/m3_lcdc_bg_map_change2 | 👀 99.1% correct (22822/23040 pixels match) |
| mealybug/m3_lcdc_obj_en_change | 👀 100.0% correct (23038/23040 pixels match) |
| mealybug-cgb/m3_lcdc_obj_en_change | 👌 |
| mealybug/m3_lcdc_obj_en_change_variant | 👀 99.6% correct (22942/23040 pixels match) |
| mealybug-cgb/m3_lcdc_obj_en_change_variant | 👌 |
| mealybug/m3_lcdc_obj_size_change | 👀 99.8% correct (22983/23040 pixels match) |
| mealybug-cgb/m3_lcdc_obj_size_change | 👀 99.8% correct (22998/23040 pixels match) |
| mealybug/m3_lcdc_obj_size_change_scx | 👀 99.9% correct (23010/23040 pixels match) |
| mealybug-cgb/m3_lcdc_obj_size_change_scx | 👀 99.7% correct (22980/23040 pixels match) |
| mealybug/m3_lcdc_tile_sel_change | 👌 |
| mealybug-cgb/m3_lcdc_tile_sel_change | 👀 97.6% correct (22476/23040 pixels match) |
| mealybug-cgb/m3_lcdc_tile_sel_change2 | 👀 97.1% correct (22376/23040 pixels match) |
| mealybug/m3_lcdc_tile_sel_win_change | 👀 99.6% correct (22942/23040 pixels match) |
| mealybug-cgb/m3_lcdc_tile_sel_win_change | 👀 96.5% correct (22224/23040 pixels match) |
| mealybug-cgb/m3_lcdc_tile_sel_win_change2 | 👀 97.1% correct (22381/23040 pixels match) |
| mealybug/m3_lcdc_win_en_change_multiple | 👌 |
| mealybug-cgb/m3_lcdc_win_en_change_multiple | 👌 |
| mealybug/m3_lcdc_win_en_change_multiple_wx | 👀 98.5% correct (22697/23040 pixels match) |
| mealybug/m3_lcdc_win_map_change | 👀 99.9% correct (23006/23040 pixels match) |
| mealybug-cgb/m3_lcdc_win_map_change | 👀 99.1% correct (22824/23040 pixels match) |
| mealybug-cgb/m3_lcdc_win_map_change2 | 👀 99.4% correct (22900/23040 pixels match) |
| mealybug/m3_obp0_change | 👌 |
| mealybug-cgb/m3_obp0_change | 👌 |
| mealybug/m3_scx_high_5_bits | 👌 |
| mealybug-cgb/m3_scx_high_5_bits | 👌 |
| mealybug-cgb/m3_scx_high_5_bits_change2 | 👌 |
| mealybug/m3_scx_low_3_bits | 👌 |
| mealybug-cgb/m3_scx_low_3_bits | 👌 |
| mealybug/m3_scy_change | 👀 99.9% correct (23011/23040 pixels match) |
| mealybug-cgb/m3_scy_change | 👀 98.7% correct (22744/23040 pixels match) |
| mealybug-cgb/m3_scy_change2 | 👌 |
| mealybug/m3_window_timing | 👀 99.9% correct (23007/23040 pixels match) |
| mealybug-cgb/m3_window_timing | 👀 99.9% correct (23013/23040 pixels match) |
| mealybug/m3_window_timing_wx_0 | 👌 |
| mealybug-cgb/m3_window_timing_wx_0 | 👌 |
| mealybug/m3_wx_4_change | 👌 |
| mealybug/m3_wx_4_change_sprites | 👌 |
| mealybug-cgb/m3_wx_4_change_sprites | 👌 |
| mealybug/m3_wx_5_change | 👌 |
| mealybug/m3_wx_6_change | 👌 |

## Game Boy - GBMicrotest

| Test | Result |
|------|--------|
| gbmicrotest/000-oam_lock | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/000-write_to_x8000 | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/001-vram_unlocked | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/002-vram_locked | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/004-tima_boot_phase | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/004-tima_cycle_timer | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/007-lcd_on_stat | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/400-dma | 👀 actual=0xE0 expected=0x46 verdict=0x00 |
| gbmicrotest/500-scx-timing | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/800-ppu-latch-scx | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/801-ppu-latch-scy | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/802-ppu-latch-tileselect | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/803-ppu-latch-bgdisplay | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/audio_testbench | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/cpu_bus_1 | 👀 actual=0x55 expected=0x00 verdict=0x00 |
| gbmicrotest/div_inc_timing_a | 👌 |
| gbmicrotest/div_inc_timing_b | 👌 |
| gbmicrotest/dma_0x1000 | 👌 |
| gbmicrotest/dma_0x9000 | 👌 |
| gbmicrotest/dma_0xA000 | 👌 |
| gbmicrotest/dma_0xC000 | 👌 |
| gbmicrotest/dma_0xE000 | 👌 |
| gbmicrotest/dma_basic | 👀 actual=0xE0 expected=0x46 verdict=0x18 |
| gbmicrotest/dma_timing_a | 👌 |
| gbmicrotest/flood_vram | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/halt_bug | 👌 |
| gbmicrotest/halt_op_dupe | 👌 |
| gbmicrotest/halt_op_dupe_delay | 👀 actual=0x01 expected=0x55 verdict=0xFF |
| gbmicrotest/hblank_int_di_timing_a | 👌 |
| gbmicrotest/hblank_int_di_timing_b | 👌 |
| gbmicrotest/hblank_int_if_a | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_int_if_b | 👌 |
| gbmicrotest/hblank_int_l0 | 👌 |
| gbmicrotest/hblank_int_l1 | 👌 |
| gbmicrotest/hblank_int_l2 | 👌 |
| gbmicrotest/hblank_int_scx0 | 👌 |
| gbmicrotest/hblank_int_scx0_if_a | 👌 |
| gbmicrotest/hblank_int_scx0_if_b | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_int_scx0_if_c | 👌 |
| gbmicrotest/hblank_int_scx0_if_d | 👌 |
| gbmicrotest/hblank_int_scx1 | 👀 actual=0x2E expected=0x2D verdict=0xFF |
| gbmicrotest/hblank_int_scx1_if_a | 👌 |
| gbmicrotest/hblank_int_scx1_if_b | 👀 actual=0xE0 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx1_if_c | 👌 |
| gbmicrotest/hblank_int_scx1_if_d | 👀 actual=0xE2 expected=0x00 verdict=0xFF |
| gbmicrotest/hblank_int_scx1_nops_a | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx1_nops_b | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx2 | 👀 actual=0x2E expected=0x2D verdict=0xFF |
| gbmicrotest/hblank_int_scx2_if_a | 👌 |
| gbmicrotest/hblank_int_scx2_if_b | 👀 actual=0xE0 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx2_if_c | 👌 |
| gbmicrotest/hblank_int_scx2_if_d | 👀 actual=0xE2 expected=0x00 verdict=0xFF |
| gbmicrotest/hblank_int_scx2_nops_a | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx2_nops_b | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx3 | 👌 |
| gbmicrotest/hblank_int_scx3_if_a | 👌 |
| gbmicrotest/hblank_int_scx3_if_b | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_int_scx3_if_c | 👌 |
| gbmicrotest/hblank_int_scx3_if_d | 👌 |
| gbmicrotest/hblank_int_scx3_nops_a | 👌 |
| gbmicrotest/hblank_int_scx3_nops_b | 👌 |
| gbmicrotest/hblank_int_scx4 | 👌 |
| gbmicrotest/hblank_int_scx4_if_a | 👌 |
| gbmicrotest/hblank_int_scx4_if_b | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_int_scx4_if_c | 👌 |
| gbmicrotest/hblank_int_scx4_if_d | 👌 |
| gbmicrotest/hblank_int_scx4_nops_a | 👌 |
| gbmicrotest/hblank_int_scx4_nops_b | 👌 |
| gbmicrotest/hblank_int_scx5 | 👀 actual=0x2F expected=0x2E verdict=0xFF |
| gbmicrotest/hblank_int_scx5_if_a | 👌 |
| gbmicrotest/hblank_int_scx5_if_b | 👀 actual=0xE0 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx5_if_c | 👌 |
| gbmicrotest/hblank_int_scx5_if_d | 👀 actual=0xE2 expected=0x00 verdict=0xFF |
| gbmicrotest/hblank_int_scx5_nops_a | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx5_nops_b | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx6 | 👀 actual=0x2F expected=0x2E verdict=0xFF |
| gbmicrotest/hblank_int_scx6_if_a | 👌 |
| gbmicrotest/hblank_int_scx6_if_b | 👀 actual=0xE0 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx6_if_c | 👌 |
| gbmicrotest/hblank_int_scx6_if_d | 👀 actual=0xE2 expected=0x00 verdict=0xFF |
| gbmicrotest/hblank_int_scx6_nops_a | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx6_nops_b | 👀 actual=0x00 expected=0xFF verdict=0xFF |
| gbmicrotest/hblank_int_scx7 | 👌 |
| gbmicrotest/hblank_int_scx7_if_a | 👌 |
| gbmicrotest/hblank_int_scx7_if_b | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_int_scx7_if_c | 👌 |
| gbmicrotest/hblank_int_scx7_if_d | 👌 |
| gbmicrotest/hblank_int_scx7_nops_a | 👌 |
| gbmicrotest/hblank_int_scx7_nops_b | 👌 |
| gbmicrotest/hblank_scx2_if_a | 👌 |
| gbmicrotest/hblank_scx3_if_a | 👌 |
| gbmicrotest/hblank_scx3_if_b | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/hblank_scx3_if_c | 👌 |
| gbmicrotest/hblank_scx3_if_d | 👌 |
| gbmicrotest/hblank_scx3_int_a | 👌 |
| gbmicrotest/hblank_scx3_int_b | 👌 |
| gbmicrotest/int_hblank_halt_bug_a | 👌 |
| gbmicrotest/int_hblank_halt_bug_b | 👌 |
| gbmicrotest/int_hblank_halt_scx0 | 👀 actual=0x61 expected=0x62 verdict=0xFF |
| gbmicrotest/int_hblank_halt_scx1 | 👌 |
| gbmicrotest/int_hblank_halt_scx2 | 👌 |
| gbmicrotest/int_hblank_halt_scx3 | 👀 actual=0x62 expected=0x63 verdict=0xFF |
| gbmicrotest/int_hblank_halt_scx4 | 👀 actual=0x62 expected=0x63 verdict=0xFF |
| gbmicrotest/int_hblank_halt_scx5 | 👌 |
| gbmicrotest/int_hblank_halt_scx6 | 👌 |
| gbmicrotest/int_hblank_halt_scx7 | 👀 actual=0x63 expected=0x64 verdict=0xFF |
| gbmicrotest/int_hblank_incs_scx0 | 👌 |
| gbmicrotest/int_hblank_incs_scx1 | 👌 |
| gbmicrotest/int_hblank_incs_scx2 | 👌 |
| gbmicrotest/int_hblank_incs_scx3 | 👌 |
| gbmicrotest/int_hblank_incs_scx4 | 👌 |
| gbmicrotest/int_hblank_incs_scx5 | 👌 |
| gbmicrotest/int_hblank_incs_scx6 | 👌 |
| gbmicrotest/int_hblank_incs_scx7 | 👌 |
| gbmicrotest/int_hblank_nops_scx0 | 👌 |
| gbmicrotest/int_hblank_nops_scx1 | 👌 |
| gbmicrotest/int_hblank_nops_scx2 | 👌 |
| gbmicrotest/int_hblank_nops_scx3 | 👌 |
| gbmicrotest/int_hblank_nops_scx4 | 👌 |
| gbmicrotest/int_hblank_nops_scx5 | 👌 |
| gbmicrotest/int_hblank_nops_scx6 | 👌 |
| gbmicrotest/int_hblank_nops_scx7 | 👌 |
| gbmicrotest/int_lyc_halt | 👌 |
| gbmicrotest/int_lyc_incs | 👌 |
| gbmicrotest/int_lyc_nops | 👌 |
| gbmicrotest/int_oam_halt | 👌 |
| gbmicrotest/int_oam_incs | 👀 actual=0x70 expected=0x6F verdict=0xFF |
| gbmicrotest/int_oam_nops | 👀 actual=0x94 expected=0x93 verdict=0xFF |
| gbmicrotest/int_timer_halt | 👌 |
| gbmicrotest/int_timer_halt_div_a | 👌 |
| gbmicrotest/int_timer_halt_div_b | 👌 |
| gbmicrotest/int_timer_incs | 👀 actual=0x09 expected=0xFF verdict=0xFF |
| gbmicrotest/int_timer_nops | 👀 actual=0x05 expected=0xFF verdict=0xFF |
| gbmicrotest/int_timer_nops_div_a | 👀 actual=0x03 expected=0x02 verdict=0xFF |
| gbmicrotest/int_timer_nops_div_b | 👌 |
| gbmicrotest/int_vblank1_halt | 👌 |
| gbmicrotest/int_vblank1_incs | 👌 |
| gbmicrotest/int_vblank1_nops | 👌 |
| gbmicrotest/int_vblank2_halt | 👌 |
| gbmicrotest/int_vblank2_incs | 👌 |
| gbmicrotest/int_vblank2_nops | 👌 |
| gbmicrotest/is_if_set_during_ime0 | 👌 |
| gbmicrotest/lcdon_halt_to_vblank_int_a | 👌 |
| gbmicrotest/lcdon_halt_to_vblank_int_b | 👌 |
| gbmicrotest/lcdon_nops_to_vblank_int_a | 👌 |
| gbmicrotest/lcdon_nops_to_vblank_int_b | 👌 |
| gbmicrotest/lcdon_to_if_oam_a | 👌 |
| gbmicrotest/lcdon_to_if_oam_b | 👌 |
| gbmicrotest/lcdon_to_ly1_a | 👌 |
| gbmicrotest/lcdon_to_ly1_b | 👌 |
| gbmicrotest/lcdon_to_ly2_a | 👌 |
| gbmicrotest/lcdon_to_ly2_b | 👌 |
| gbmicrotest/lcdon_to_ly3_a | 👌 |
| gbmicrotest/lcdon_to_ly3_b | 👌 |
| gbmicrotest/lcdon_to_lyc1_int | 👌 |
| gbmicrotest/lcdon_to_lyc2_int | 👌 |
| gbmicrotest/lcdon_to_lyc3_int | 👌 |
| gbmicrotest/lcdon_to_oam_int_l0 | 👀 actual=0x70 expected=0x6F verdict=0xFF |
| gbmicrotest/lcdon_to_oam_int_l1 | 👀 actual=0x65 expected=0x64 verdict=0xFF |
| gbmicrotest/lcdon_to_oam_int_l2 | 👀 actual=0x65 expected=0x64 verdict=0xFF |
| gbmicrotest/lcdon_to_oam_unlock_a | 👌 |
| gbmicrotest/lcdon_to_oam_unlock_b | 👌 |
| gbmicrotest/lcdon_to_oam_unlock_c | 👌 |
| gbmicrotest/lcdon_to_oam_unlock_d | 👌 |
| gbmicrotest/lcdon_to_stat0_a | 👌 |
| gbmicrotest/lcdon_to_stat0_b | 👌 |
| gbmicrotest/lcdon_to_stat0_c | 👌 |
| gbmicrotest/lcdon_to_stat0_d | 👌 |
| gbmicrotest/lcdon_to_stat1_a | 👌 |
| gbmicrotest/lcdon_to_stat1_b | 👌 |
| gbmicrotest/lcdon_to_stat1_c | 👀 actual=0x81 expected=0x85 verdict=0xFF |
| gbmicrotest/lcdon_to_stat1_d | 👌 |
| gbmicrotest/lcdon_to_stat1_e | 👌 |
| gbmicrotest/lcdon_to_stat2_a | 👌 |
| gbmicrotest/lcdon_to_stat2_b | 👌 |
| gbmicrotest/lcdon_to_stat2_c | 👌 |
| gbmicrotest/lcdon_to_stat2_d | 👌 |
| gbmicrotest/lcdon_to_stat3_a | 👌 |
| gbmicrotest/lcdon_to_stat3_b | 👌 |
| gbmicrotest/lcdon_to_stat3_c | 👌 |
| gbmicrotest/lcdon_to_stat3_d | 👌 |
| gbmicrotest/lcdon_write_timing | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/line_144_oam_int_a | 👌 |
| gbmicrotest/line_144_oam_int_b | 👀 actual=0xE0 expected=0xFF verdict=0xFF |
| gbmicrotest/line_144_oam_int_c | 👀 actual=0xE3 expected=0xE2 verdict=0xFF |
| gbmicrotest/line_144_oam_int_d | 👀 actual=0xE3 expected=0x00 verdict=0xFF |
| gbmicrotest/line_153_ly_a | 👌 |
| gbmicrotest/line_153_ly_b | 👌 |
| gbmicrotest/line_153_ly_c | 👀 actual=0x99 expected=0x00 verdict=0xFF |
| gbmicrotest/line_153_ly_d | 👌 |
| gbmicrotest/line_153_ly_e | 👌 |
| gbmicrotest/line_153_ly_f | 👌 |
| gbmicrotest/line_153_lyc0_int_inc_sled | 👀 actual=0x62 expected=0xFF verdict=0xFF |
| gbmicrotest/line_153_lyc0_stat_timing_a | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_b | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_c | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_d | 👀 actual=0xC1 expected=0xC5 verdict=0xFF |
| gbmicrotest/line_153_lyc0_stat_timing_e | 👀 actual=0xC1 expected=0xC5 verdict=0xFF |
| gbmicrotest/line_153_lyc0_stat_timing_f | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_g | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_h | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_i | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_j | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_k | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_l | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_m | 👌 |
| gbmicrotest/line_153_lyc0_stat_timing_n | 👌 |
| gbmicrotest/line_153_lyc153_stat_timing_a | 👌 |
| gbmicrotest/line_153_lyc153_stat_timing_b | 👌 |
| gbmicrotest/line_153_lyc153_stat_timing_c | 👀 actual=0xC5 expected=0xC1 verdict=0xFF |
| gbmicrotest/line_153_lyc153_stat_timing_d | 👀 actual=0xC5 expected=0xC1 verdict=0xFF |
| gbmicrotest/line_153_lyc153_stat_timing_e | 👌 |
| gbmicrotest/line_153_lyc153_stat_timing_f | 👌 |
| gbmicrotest/line_153_lyc_a | 👌 |
| gbmicrotest/line_153_lyc_b | 👌 |
| gbmicrotest/line_153_lyc_c | 👀 actual=0x85 expected=0x81 verdict=0xFF |
| gbmicrotest/line_153_lyc_int_a | 👌 |
| gbmicrotest/line_153_lyc_int_b | 👌 |
| gbmicrotest/line_65_ly | 👌 |
| gbmicrotest/ly_while_lcd_off | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/lyc1_int_halt_a | 👌 |
| gbmicrotest/lyc1_int_halt_b | 👌 |
| gbmicrotest/lyc1_int_if_edge_a | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/lyc1_int_if_edge_b | 👌 |
| gbmicrotest/lyc1_int_if_edge_c | 👌 |
| gbmicrotest/lyc1_int_if_edge_d | 👌 |
| gbmicrotest/lyc1_int_nops_a | 👌 |
| gbmicrotest/lyc1_int_nops_b | 👌 |
| gbmicrotest/lyc1_write_timing_a | 👌 |
| gbmicrotest/lyc1_write_timing_b | 👌 |
| gbmicrotest/lyc1_write_timing_c | 👌 |
| gbmicrotest/lyc1_write_timing_d | 👌 |
| gbmicrotest/lyc2_int_halt_a | 👌 |
| gbmicrotest/lyc2_int_halt_b | 👌 |
| gbmicrotest/lyc_int_halt_a | 👌 |
| gbmicrotest/lyc_int_halt_b | 👌 |
| gbmicrotest/mbc1_ram_banks | 👌 |
| gbmicrotest/mbc1_rom_banks | 👌 |
| gbmicrotest/minimal | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/mode2_stat_int_to_oam_unlock | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/oam_int_halt_a | 👌 |
| gbmicrotest/oam_int_halt_b | 👌 |
| gbmicrotest/oam_int_if_edge_a | 👌 |
| gbmicrotest/oam_int_if_edge_b | 👌 |
| gbmicrotest/oam_int_if_edge_c | 👌 |
| gbmicrotest/oam_int_if_edge_d | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/oam_int_if_level_c | 👌 |
| gbmicrotest/oam_int_if_level_d | 👌 |
| gbmicrotest/oam_int_inc_sled | 👀 actual=0x65 expected=0x64 verdict=0xFF |
| gbmicrotest/oam_int_nops_a | 👀 actual=0x02 expected=0x01 verdict=0xFF |
| gbmicrotest/oam_int_nops_b | 👌 |
| gbmicrotest/oam_read_l0_a | 👌 |
| gbmicrotest/oam_read_l0_b | 👌 |
| gbmicrotest/oam_read_l0_c | 👌 |
| gbmicrotest/oam_read_l0_d | 👌 |
| gbmicrotest/oam_read_l1_a | 👌 |
| gbmicrotest/oam_read_l1_b | 👌 |
| gbmicrotest/oam_read_l1_c | 👌 |
| gbmicrotest/oam_read_l1_d | 👌 |
| gbmicrotest/oam_read_l1_e | 👌 |
| gbmicrotest/oam_read_l1_f | 👌 |
| gbmicrotest/oam_sprite_trashing | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/oam_write_l0_a | 👌 |
| gbmicrotest/oam_write_l0_b | 👌 |
| gbmicrotest/oam_write_l0_c | 👌 |
| gbmicrotest/oam_write_l0_d | 👌 |
| gbmicrotest/oam_write_l0_e | 👌 |
| gbmicrotest/oam_write_l1_a | 👌 |
| gbmicrotest/oam_write_l1_b | 👌 |
| gbmicrotest/oam_write_l1_c | 👌 |
| gbmicrotest/oam_write_l1_d | 👌 |
| gbmicrotest/oam_write_l1_e | 👌 |
| gbmicrotest/oam_write_l1_f | 👌 |
| gbmicrotest/poweron | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/poweron_bgp_000 | 👌 |
| gbmicrotest/poweron_div_000 | 👌 |
| gbmicrotest/poweron_div_004 | 👌 |
| gbmicrotest/poweron_div_005 | 👌 |
| gbmicrotest/poweron_dma_000 | 👌 |
| gbmicrotest/poweron_if_000 | 👌 |
| gbmicrotest/poweron_joy_000 | 👌 |
| gbmicrotest/poweron_lcdc_000 | 👌 |
| gbmicrotest/poweron_ly_000 | 👌 |
| gbmicrotest/poweron_ly_119 | 👌 |
| gbmicrotest/poweron_ly_120 | 👌 |
| gbmicrotest/poweron_ly_233 | 👌 |
| gbmicrotest/poweron_ly_234 | 👌 |
| gbmicrotest/poweron_lyc_000 | 👌 |
| gbmicrotest/poweron_oam_000 | 👌 |
| gbmicrotest/poweron_oam_005 | 👌 |
| gbmicrotest/poweron_oam_006 | 👌 |
| gbmicrotest/poweron_oam_069 | 👌 |
| gbmicrotest/poweron_oam_070 | 👌 |
| gbmicrotest/poweron_oam_119 | 👌 |
| gbmicrotest/poweron_oam_120 | 👌 |
| gbmicrotest/poweron_oam_121 | 👌 |
| gbmicrotest/poweron_oam_183 | 👌 |
| gbmicrotest/poweron_oam_184 | 👌 |
| gbmicrotest/poweron_oam_233 | 👌 |
| gbmicrotest/poweron_oam_234 | 👌 |
| gbmicrotest/poweron_oam_235 | 👌 |
| gbmicrotest/poweron_obp0_000 | 👌 |
| gbmicrotest/poweron_obp1_000 | 👌 |
| gbmicrotest/poweron_sb_000 | 👌 |
| gbmicrotest/poweron_sc_000 | 👌 |
| gbmicrotest/poweron_scx_000 | 👌 |
| gbmicrotest/poweron_scy_000 | 👌 |
| gbmicrotest/poweron_stat_000 | 👌 |
| gbmicrotest/poweron_stat_005 | 👌 |
| gbmicrotest/poweron_stat_006 | 👌 |
| gbmicrotest/poweron_stat_007 | 👌 |
| gbmicrotest/poweron_stat_026 | 👌 |
| gbmicrotest/poweron_stat_027 | 👌 |
| gbmicrotest/poweron_stat_069 | 👌 |
| gbmicrotest/poweron_stat_070 | 👌 |
| gbmicrotest/poweron_stat_119 | 👌 |
| gbmicrotest/poweron_stat_120 | 👌 |
| gbmicrotest/poweron_stat_121 | 👌 |
| gbmicrotest/poweron_stat_140 | 👌 |
| gbmicrotest/poweron_stat_141 | 👌 |
| gbmicrotest/poweron_stat_183 | 👌 |
| gbmicrotest/poweron_stat_184 | 👌 |
| gbmicrotest/poweron_stat_234 | 👌 |
| gbmicrotest/poweron_stat_235 | 👌 |
| gbmicrotest/poweron_tac_000 | 👌 |
| gbmicrotest/poweron_tima_000 | 👌 |
| gbmicrotest/poweron_tma_000 | 👌 |
| gbmicrotest/poweron_vram_000 | 👌 |
| gbmicrotest/poweron_vram_025 | 👌 |
| gbmicrotest/poweron_vram_026 | 👌 |
| gbmicrotest/poweron_vram_069 | 👌 |
| gbmicrotest/poweron_vram_070 | 👌 |
| gbmicrotest/poweron_vram_139 | 👌 |
| gbmicrotest/poweron_vram_140 | 👌 |
| gbmicrotest/poweron_vram_183 | 👌 |
| gbmicrotest/poweron_vram_184 | 👌 |
| gbmicrotest/poweron_wx_000 | 👌 |
| gbmicrotest/poweron_wy_000 | 👌 |
| gbmicrotest/ppu_scx_vs_bgp | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/ppu_sprite0_scx0_a | 👌 |
| gbmicrotest/ppu_sprite0_scx0_b | 👌 |
| gbmicrotest/ppu_sprite0_scx1_a | 👌 |
| gbmicrotest/ppu_sprite0_scx1_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite0_scx2_a | 👌 |
| gbmicrotest/ppu_sprite0_scx2_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite0_scx3_a | 👌 |
| gbmicrotest/ppu_sprite0_scx3_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite0_scx4_a | 👌 |
| gbmicrotest/ppu_sprite0_scx4_b | 👌 |
| gbmicrotest/ppu_sprite0_scx5_a | 👌 |
| gbmicrotest/ppu_sprite0_scx5_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite0_scx6_a | 👌 |
| gbmicrotest/ppu_sprite0_scx6_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite0_scx7_a | 👌 |
| gbmicrotest/ppu_sprite0_scx7_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/ppu_sprite_testbench | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/ppu_spritex_vs_scx | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/ppu_win_vs_wx | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/ppu_wx_early | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/sprite4_0_a | 👌 |
| gbmicrotest/sprite4_0_b | 👌 |
| gbmicrotest/sprite4_1_a | 👌 |
| gbmicrotest/sprite4_1_b | 👌 |
| gbmicrotest/sprite4_2_a | 👌 |
| gbmicrotest/sprite4_2_b | 👌 |
| gbmicrotest/sprite4_3_a | 👌 |
| gbmicrotest/sprite4_3_b | 👌 |
| gbmicrotest/sprite4_4_a | 👌 |
| gbmicrotest/sprite4_4_b | 👌 |
| gbmicrotest/sprite4_5_a | 👌 |
| gbmicrotest/sprite4_5_b | 👌 |
| gbmicrotest/sprite4_6_a | 👌 |
| gbmicrotest/sprite4_6_b | 👌 |
| gbmicrotest/sprite4_7_a | 👌 |
| gbmicrotest/sprite4_7_b | 👌 |
| gbmicrotest/sprite_0_a | 👌 |
| gbmicrotest/sprite_0_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/sprite_1_a | 👌 |
| gbmicrotest/sprite_1_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/stat_write_glitch_l0_a | 👌 |
| gbmicrotest/stat_write_glitch_l0_b | 👌 |
| gbmicrotest/stat_write_glitch_l0_c | 👌 |
| gbmicrotest/stat_write_glitch_l143_a | 👌 |
| gbmicrotest/stat_write_glitch_l143_b | 👌 |
| gbmicrotest/stat_write_glitch_l143_c | 👀 actual=0xE3 expected=0xE2 verdict=0xFF |
| gbmicrotest/stat_write_glitch_l143_d | 👌 |
| gbmicrotest/stat_write_glitch_l154_a | 👌 |
| gbmicrotest/stat_write_glitch_l154_b | 👌 |
| gbmicrotest/stat_write_glitch_l154_c | 👌 |
| gbmicrotest/stat_write_glitch_l154_d | 👀 actual=0xE1 expected=0xE0 verdict=0xFF |
| gbmicrotest/stat_write_glitch_l1_a | 👌 |
| gbmicrotest/stat_write_glitch_l1_b | 👌 |
| gbmicrotest/stat_write_glitch_l1_c | 👌 |
| gbmicrotest/stat_write_glitch_l1_d | 👌 |
| gbmicrotest/temp | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/timer_div_phase_c | 👌 |
| gbmicrotest/timer_div_phase_d | 👌 |
| gbmicrotest/timer_tima_inc_256k_a | 👌 |
| gbmicrotest/timer_tima_inc_256k_b | 👌 |
| gbmicrotest/timer_tima_inc_256k_c | 👌 |
| gbmicrotest/timer_tima_inc_256k_d | 👌 |
| gbmicrotest/timer_tima_inc_256k_e | 👌 |
| gbmicrotest/timer_tima_inc_256k_f | 👌 |
| gbmicrotest/timer_tima_inc_256k_g | 👌 |
| gbmicrotest/timer_tima_inc_256k_h | 👌 |
| gbmicrotest/timer_tima_inc_256k_i | 👌 |
| gbmicrotest/timer_tima_inc_256k_j | 👌 |
| gbmicrotest/timer_tima_inc_256k_k | 👌 |
| gbmicrotest/timer_tima_inc_64k_a | 👌 |
| gbmicrotest/timer_tima_inc_64k_b | 👌 |
| gbmicrotest/timer_tima_inc_64k_c | 👌 |
| gbmicrotest/timer_tima_inc_64k_d | 👌 |
| gbmicrotest/timer_tima_phase_a | 👌 |
| gbmicrotest/timer_tima_phase_b | 👌 |
| gbmicrotest/timer_tima_phase_c | 👌 |
| gbmicrotest/timer_tima_phase_d | 👌 |
| gbmicrotest/timer_tima_phase_e | 👌 |
| gbmicrotest/timer_tima_phase_f | 👌 |
| gbmicrotest/timer_tima_phase_g | 👌 |
| gbmicrotest/timer_tima_phase_h | 👌 |
| gbmicrotest/timer_tima_phase_i | 👌 |
| gbmicrotest/timer_tima_phase_j | 👌 |
| gbmicrotest/timer_tima_reload_256k_a | 👌 |
| gbmicrotest/timer_tima_reload_256k_b | 👌 |
| gbmicrotest/timer_tima_reload_256k_c | 👌 |
| gbmicrotest/timer_tima_reload_256k_d | 👌 |
| gbmicrotest/timer_tima_reload_256k_e | 👌 |
| gbmicrotest/timer_tima_reload_256k_f | 👌 |
| gbmicrotest/timer_tima_reload_256k_g | 👌 |
| gbmicrotest/timer_tima_reload_256k_h | 👌 |
| gbmicrotest/timer_tima_reload_256k_i | 👌 |
| gbmicrotest/timer_tima_reload_256k_j | 👌 |
| gbmicrotest/timer_tima_reload_256k_k | 👌 |
| gbmicrotest/timer_tima_write_a | 👌 |
| gbmicrotest/timer_tima_write_b | 👌 |
| gbmicrotest/timer_tima_write_c | 👌 |
| gbmicrotest/timer_tima_write_d | 👌 |
| gbmicrotest/timer_tima_write_e | 👌 |
| gbmicrotest/timer_tima_write_f | 👌 |
| gbmicrotest/timer_tma_write_a | 👌 |
| gbmicrotest/timer_tma_write_b | 👌 |
| gbmicrotest/toggle_lcdc | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/vblank2_int_halt_a | 👌 |
| gbmicrotest/vblank2_int_halt_b | 👌 |
| gbmicrotest/vblank2_int_if_a | 👀 actual=0xE1 expected=0xE0 verdict=0xFF |
| gbmicrotest/vblank2_int_if_b | 👌 |
| gbmicrotest/vblank2_int_if_c | 👌 |
| gbmicrotest/vblank2_int_if_d | 👌 |
| gbmicrotest/vblank2_int_inc_sled | 👌 |
| gbmicrotest/vblank2_int_nops_a | 👌 |
| gbmicrotest/vblank2_int_nops_b | 👌 |
| gbmicrotest/vblank_int_halt_a | 👌 |
| gbmicrotest/vblank_int_halt_b | 👌 |
| gbmicrotest/vblank_int_if_a | 👀 actual=0xE2 expected=0xE0 verdict=0xFF |
| gbmicrotest/vblank_int_if_b | 👌 |
| gbmicrotest/vblank_int_if_c | 👌 |
| gbmicrotest/vblank_int_if_d | 👌 |
| gbmicrotest/vblank_int_inc_sled | 👌 |
| gbmicrotest/vblank_int_nops_a | 👌 |
| gbmicrotest/vblank_int_nops_b | 👌 |
| gbmicrotest/vram_read_l0_a | 👌 |
| gbmicrotest/vram_read_l0_b | 👌 |
| gbmicrotest/vram_read_l0_c | 👌 |
| gbmicrotest/vram_read_l0_d | 👌 |
| gbmicrotest/vram_read_l1_a | 👌 |
| gbmicrotest/vram_read_l1_b | 👌 |
| gbmicrotest/vram_read_l1_c | 👌 |
| gbmicrotest/vram_read_l1_d | 👌 |
| gbmicrotest/vram_write_l0_a | 👌 |
| gbmicrotest/vram_write_l0_b | 👌 |
| gbmicrotest/vram_write_l0_c | 👌 |
| gbmicrotest/vram_write_l0_d | 👌 |
| gbmicrotest/vram_write_l1_a | 👌 |
| gbmicrotest/vram_write_l1_b | 👌 |
| gbmicrotest/vram_write_l1_c | 👌 |
| gbmicrotest/vram_write_l1_d | 👌 |
| gbmicrotest/wave_write_to_0xC003 | 👀 actual=0x00 expected=0x00 verdict=0x00 |
| gbmicrotest/win0_a | 👌 |
| gbmicrotest/win0_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win0_scx3_a | 👌 |
| gbmicrotest/win0_scx3_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win10_a | 👌 |
| gbmicrotest/win10_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win10_scx3_a | 👌 |
| gbmicrotest/win10_scx3_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win11_a | 👌 |
| gbmicrotest/win11_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win12_a | 👌 |
| gbmicrotest/win12_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win13_a | 👌 |
| gbmicrotest/win13_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win14_a | 👌 |
| gbmicrotest/win14_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win15_a | 👌 |
| gbmicrotest/win15_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win1_a | 👌 |
| gbmicrotest/win1_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win2_a | 👌 |
| gbmicrotest/win2_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win3_a | 👌 |
| gbmicrotest/win3_b | 👌 |
| gbmicrotest/win4_a | 👌 |
| gbmicrotest/win4_b | 👌 |
| gbmicrotest/win5_a | 👌 |
| gbmicrotest/win5_b | 👌 |
| gbmicrotest/win6_a | 👌 |
| gbmicrotest/win6_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win7_a | 👌 |
| gbmicrotest/win7_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win8_a | 👌 |
| gbmicrotest/win8_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |
| gbmicrotest/win9_a | 👌 |
| gbmicrotest/win9_b | 👀 actual=0x83 expected=0x80 verdict=0xFF |

## Game Boy - AGE

| Test | Result |
|------|--------|
| age/halt/ei-halt-dmgC-cgbBCE | 👀 |
| age/halt/halt-m0-interrupt-dmgC-cgbBCE | 👀 |
| age/halt/halt-prefetch-dmgC-cgbBCE | 👌 |
| age/lcd-align-ly/lcd-align-ly-cgbBC | 👀 |
| age/lcd-align-ly/lcd-align-ly-cgbE | 👀 |
| age/ly/ly-cgbE | 👌 |
| age/ly/ly-dmgC-cgbBC | 👀 |
| age/m3-bg-bgp/m3-bg-bgp-dmgC | 👀 100.0% correct (23038/23040 pixels match) |
| age/m3-bg-lcdc/m3-bg-lcdc-ds-cgbBCE | 👌 |
| age/m3-bg-lcdc/m3-bg-lcdc-cgbBCE | 👀 98.9% correct (22784/23040 pixels match) |
| age/m3-bg-lcdc/m3-bg-lcdc-dmgC | 👌 |
| age/m3-bg-scx/m3-bg-scx-ds-cgbBCE | 👀 99.4% correct (22900/23040 pixels match) |
| age/m3-bg-scx/m3-bg-scx-cgbBCE | 👀 99.4% correct (22900/23040 pixels match) |
| age/m3-bg-scx/m3-bg-scx-dmgC | 👀 99.5% correct (22928/23040 pixels match) |
| age/oam/oam-read-cgbE | 👀 |
| age/oam/oam-read-dmgC-cgbBC | 👀 |
| age/oam/oam-write-cgbBCE | 👀 |
| age/oam/oam-write-dmgC | 👀 |
| age/speed-switch/caution/spsw-interrupts-cgbBC | 👀 |
| age/speed-switch/caution/spsw-interrupts-cgbE | 👀 |
| age/speed-switch/spsw-ch2-lc-delay-cgbBCE | 👀 |
| age/speed-switch/spsw-div-cgbBCE | 👌 |
| age/speed-switch/spsw-mode0-cgbBCE | 👀 |
| age/speed-switch/spsw-stop-prefetch-cgbBCE | 👀 |
| age/speed-switch/spsw-tima-cgbBC | 👀 |
| age/speed-switch/spsw-tima-cgbE | 👀 |
| age/stat-interrupt/stat-int-dmgC-cgbBCE | 👀 |
| age/stat-mode-sprites/stat-mode-sprites-dmgC-cgbBCE | 👀 |
| age/stat-mode-sprites/stat-mode-sprites-ds-cgbBCE | 👀 |
| age/stat-mode-window/stat-mode-window-cgbBCE | 👀 |
| age/stat-mode-window/stat-mode-window-dmgC | 👀 |
| age/stat-mode-window/stat-mode-window-ds-cgbBCE | 👀 |
| age/stat-mode/stat-mode-cgbE | 👀 |
| age/stat-mode/stat-mode-dmgC-cgbBC | 👀 |
| age/stat-mode/stat-mode-ds-cgbBCE | 👀 |
| age/vram/vram-read-cgbBCE | 👀 |
| age/vram/vram-read-dmgC | 👀 |

## Game Boy - Screenshot suites

| Test | Result |
|------|--------|
| bully/bully | 👀 98.2% correct (22620/23040 pixels match) |
| strikethrough/strikethrough-dmg | 👌 |
| strikethrough/strikethrough-cgb | 👌 |
| scribbltests/lycscx | 👌 |
| scribbltests/lycscy | 👌 |
| scribbltests/palettely | 👌 |
| scribbltests/scxly | 👌 |
| scribbltests/statcount-auto | 👌 |
| turtle-tests/window_y_trigger | 👌 |
| turtle-tests/window_y_trigger_wx_offscreen | 👌 |
| cgb-acid-hell/cgb-acid-hell | 👀 100.0% correct (23038/23040 pixels match) |
| little-things-gb/firstwhite | 👀 89.2% correct (20552/23040 pixels match) |
| mbc3-tester/mbc3-tester | 👀 94.4% correct (21760/23040 pixels match) |

## Game Boy - SameSuite

| Test | Result |
|------|--------|
| same-suite/dma/gbc_dma_cont | 👌 |
| same-suite/dma/gdma_addr_mask | 👌 |
| same-suite/dma/hdma_lcd_off | 👌 |
| same-suite/dma/hdma_mode0 | 👌 |
| same-suite/ppu/blocking_bgpi_increase | 👌 |
| same-suite/interrupt/ei_delay_halt | 👀 |
| same-suite/sgb/command_mlt_req | 👌 |
| same-suite/sgb/command_mlt_req_1_incrementing | 👌 |

## Game Boy - Shootout ROMs

| Test | Result |
|------|--------|
| rtc3test/rtc3test-1 | 👀 97.5% correct (22459/23040 pixels match) |
| rtc3test/rtc3test-2 | 👌 |
| rtc3test/rtc3test-3 | 👀 98.0% correct (22571/23040 pixels match) |
| cpp/rtc-invalid-banks-test | 👌 |
| cpp/latch-rtc-test | 👌 |
| cpp/ramg-mbc3-test | 👌 |
| daid/ppu_scanline_bgp-dmg | 👀 68.8% correct (15854/23040 pixels match) vs ppu_scanline_bgp_2.dmg.png |
| daid/stop_instr-dmg | 👌 |
| daid/speed_switch_timing_div | 👌 |
| daid/speed_switch_timing_ly | 👌 |
| daid/speed_switch_timing_stat | 👌 |

## Game Boy - Mooneye (wilbertpol)

| Test | Result |
|------|--------|
| mooneye-wilbertpol/acceptance/add_sp_e_timing | 👌 |
| mooneye-wilbertpol/acceptance/bits/mem_oam | 👌 |
| mooneye-wilbertpol/acceptance/bits/reg_f | 👌 |
| mooneye-wilbertpol/acceptance/bits/unused_hwio-GS | 👌 |
| mooneye-wilbertpol/acceptance/boot_hwio-G | 👌 |
| mooneye-wilbertpol/acceptance/boot_regs-dmg | 👌 |
| mooneye-wilbertpol/acceptance/call_cc_timing | 👌 |
| mooneye-wilbertpol/acceptance/call_cc_timing2 | 👌 |
| mooneye-wilbertpol/acceptance/call_timing | 👌 |
| mooneye-wilbertpol/acceptance/call_timing2 | 👌 |
| mooneye-wilbertpol/acceptance/di_timing-GS | 👌 |
| mooneye-wilbertpol/acceptance/div_timing | 👌 |
| mooneye-wilbertpol/acceptance/ei_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing-GS | 👌 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/hblank_ly_scx_timing_variant_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_0_timing | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_2_timing-GS | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_1_timing | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_0_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx1_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx2_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx3_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx4_timing_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx5_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx6_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx7_timing_nops | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx8_timing_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx1_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx2_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx3_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx4_nops | 👀 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_mode3_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_oam_ok_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/intr_2_timing | 👀 |
| mooneye-wilbertpol/acceptance/gpu/lcdon_mode_timing | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_01_mode0_2 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode0_2-GS | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_0-GS | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode1_2-C | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode2_3 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly00_mode3_0 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_145 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_152_153 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_mode0_1 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly143_144_mode3_0 | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_0_write-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_144-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_153_write-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/ly_lyc_write-GS | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-C | 👌 |
| mooneye-wilbertpol/acceptance/gpu/ly_new_frame-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/stat_irq_blocking | 👌 |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-C | 👀 |
| mooneye-wilbertpol/acceptance/gpu/stat_write_if-GS | 👀 |
| mooneye-wilbertpol/acceptance/gpu/vblank_if_timing | 👀 |
| mooneye-wilbertpol/acceptance/gpu/vblank_stat_intr-GS | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime0_ei | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime0_nointr_timing | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing | 👌 |
| mooneye-wilbertpol/acceptance/halt_ime1_timing2-GS | 👌 |
| mooneye-wilbertpol/acceptance/if_ie_registers | 👌 |
| mooneye-wilbertpol/acceptance/intr_timing | 👌 |
| mooneye-wilbertpol/acceptance/jp_cc_timing | 👌 |
| mooneye-wilbertpol/acceptance/jp_timing | 👌 |
| mooneye-wilbertpol/acceptance/ld_hl_sp_e_timing | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_restart | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_start | 👌 |
| mooneye-wilbertpol/acceptance/oam_dma_timing | 👌 |
| mooneye-wilbertpol/acceptance/pop_timing | 👌 |
| mooneye-wilbertpol/acceptance/push_timing | 👌 |
| mooneye-wilbertpol/acceptance/rapid_di_ei | 👌 |
| mooneye-wilbertpol/acceptance/ret_cc_timing | 👌 |
| mooneye-wilbertpol/acceptance/ret_timing | 👌 |
| mooneye-wilbertpol/acceptance/reti_intr_timing | 👌 |
| mooneye-wilbertpol/acceptance/reti_timing | 👌 |
| mooneye-wilbertpol/acceptance/rst_timing | 👌 |
| mooneye-wilbertpol/acceptance/timer/div_write | 👌 |
| mooneye-wilbertpol/acceptance/timer/rapid_toggle | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim00 | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim00_div_trigger | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim01 | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim01_div_trigger | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim10 | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim10_div_trigger | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim11 | 👌 |
| mooneye-wilbertpol/acceptance/timer/tim11_div_trigger | 👌 |
| mooneye-wilbertpol/acceptance/timer/tima_reload | 👌 |
| mooneye-wilbertpol/acceptance/timer/tima_write_reloading | 👌 |
| mooneye-wilbertpol/acceptance/timer/timer_if | 👀 |
| mooneye-wilbertpol/acceptance/timer/tma_write_reloading | 👌 |
| mooneye-wilbertpol/emulator-only/mbc1_rom_4banks | 👌 |
| mooneye-wilbertpol/madness/mgb_oam_dma_halt_sprites | 👀 50.0% correct (11517/23040 pixels match) |
| mooneye-wilbertpol/manual-only/sprite_priority | 👌 |
| mooneye-wilbertpol/misc/bits/unused_hwio-C | 👌 |
| mooneye-wilbertpol/misc/boot_hwio-C | 👀 |
| mooneye-wilbertpol/misc/boot_hwio-S | 👀 |
| mooneye-wilbertpol/misc/boot_regs-A | 👌 |
| mooneye-wilbertpol/misc/boot_regs-cgb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-mgb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-sgb | 👌 |
| mooneye-wilbertpol/misc/boot_regs-sgb2 | 👌 |
| mooneye-wilbertpol/misc/gpu/vblank_stat_intr-C | 👌 |

## Game Boy - gambatte

| Test | Result |
|------|--------|
| gambatte/bgen | 👌 2/2 passed |
| gambatte/bgtiledata | 👀 26/34 passed |
| gambatte/bgtilemap | 👀 28/40 passed |
| gambatte/cgbpal_m3 | 👀 16/44 passed |
| gambatte/display_startstate | 👀 10/14 passed |
| gambatte/div | 👌 8/8 passed |
| gambatte/dma | 👀 124/229 passed |
| gambatte/dmgpalette_during_m3 | 👀 7/17 passed |
| gambatte/enable_display | 👀 135/184 passed |
| gambatte/halt | 👀 124/158 passed |
| gambatte/irq_precedence | 👀 41/64 passed |
| gambatte/lcd_offset | 👀 40/62 passed |
| gambatte/lcdirq_precedence | 👀 54/62 passed |
| gambatte/ly0 | 👀 66/96 passed |
| gambatte/lyc0int_m0irq | 👀 3/6 passed |
| gambatte/lyc153int_m2irq | 👀 11/16 passed |
| gambatte/lycEnable | 👀 172/225 passed |
| gambatte/lycint_ly | 👌 6/6 passed |
| gambatte/lycint_lycflag | 👀 11/12 passed |
| gambatte/lycint_lycirq | 👀 2/4 passed |
| gambatte/lycint_m0stat | 👌 6/6 passed |
| gambatte/lycm2int | 👀 8/18 passed |
| gambatte/lywrite | 👌 8/8 passed |
| gambatte/m0enable | 👀 153/167 passed |
| gambatte/m0int_m0irq | 👀 2/4 passed |
| gambatte/m0int_m0stat | 👀 10/12 passed |
| gambatte/m0int_m3stat | 👌 6/6 passed |
| gambatte/m1 | 👀 122/170 passed |
| gambatte/m2enable | 👀 93/120 passed |
| gambatte/m2int_m0irq | 👀 45/72 passed |
| gambatte/m2int_m0stat | 👀 3/6 passed |
| gambatte/m2int_m2irq | 👀 12/18 passed |
| gambatte/m2int_m2stat | 👀 4/8 passed |
| gambatte/m2int_m3stat | 👀 29/44 passed |
| gambatte/miscmstatirq | 👀 260/279 passed |
| gambatte/oam_access | 👀 52/69 passed |
| gambatte/oamdma | 👀 681/811 passed |
| gambatte/scx_during_m3 | 👀 43/141 passed |
| gambatte/scy | 👀 61/67 passed |
| gambatte/serial | 👀 48/82 passed |
| gambatte/sound | 👀 113/116 passed |
| gambatte/speedchange | 👀 112/208 passed |
| gambatte/sprites | 👀 394/476 passed |
| gambatte/tima | 👀 216/232 passed |
| gambatte/undef_ops | 👌 20/20 passed |
| gambatte/vram_m3 | 👀 35/50 passed |
| gambatte/vramw_m3end | 👀 32/36 passed |
| gambatte/window | 👀 327/476 passed |

Each row is one gambatte subdirectory. See [detailed results](results_gambatte.md) for individual test outcomes.

## Summary

- **Total:** 981
- **Pass:** 716
- **Fail:** 265
