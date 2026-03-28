# Dingbat Test Results

*Generated: 2026-03-28 09:55:49*

## Game Boy - Blargg

| Test | Result |
|------|--------|
| cpu_instrs/01-special | 👌 |
| cpu_instrs/02-interrupts | 👌 |
| cpu_instrs/03-op sp,hl | 👀 |
| cpu_instrs/04-op r,imm | 👌 |
| cpu_instrs/05-op rp | 👌 |
| cpu_instrs/06-ld r,r | 👀 |
| cpu_instrs/07-jr,jp,call,ret,rst | 👌 |
| cpu_instrs/08-misc instrs | 👌 |
| cpu_instrs/09-op r,r | 👌 |
| cpu_instrs/10-bit ops | 👌 |
| cpu_instrs/11-op a,(hl) | 👌 |
| instr_timing | 👀 |
| mem_timing/01-read_timing | 👌 |
| mem_timing/02-write_timing | 👌 |
| mem_timing/03-modify_timing | 👌 |

## Game Boy - Mooneye

| Test | Result |
|------|--------|
| acceptance/add_sp_e_timing | 👌 |
| acceptance/bits/mem_oam | 👌 |
| acceptance/bits/reg_f | 👌 |
| acceptance/bits/unused_hwio-GS | 👀 |
| acceptance/boot_div-S | 👀 |
| acceptance/boot_div-dmg0 | 👀 |
| acceptance/boot_div-dmgABCmgb | 👀 |
| acceptance/boot_div2-S | 👀 |
| acceptance/boot_hwio-S | 👀 |
| acceptance/boot_hwio-dmg0 | 👀 |
| acceptance/boot_hwio-dmgABCmgb | 👀 |
| acceptance/boot_regs-dmg0 | 👀 |
| acceptance/boot_regs-dmgABC | 👀 |
| acceptance/boot_regs-mgb | 👀 |
| acceptance/boot_regs-sgb | 👀 |
| acceptance/boot_regs-sgb2 | 👀 |
| acceptance/call_cc_timing | 👌 |
| acceptance/call_cc_timing2 | 👌 |
| acceptance/call_timing | 👌 |
| acceptance/call_timing2 | 👌 |
| acceptance/di_timing-GS | 👌 |
| acceptance/div_timing | 👌 |
| acceptance/ei_sequence | 👌 |
| acceptance/ei_timing | 👌 |
| acceptance/halt_ime0_ei | 👌 |
| acceptance/halt_ime0_nointr_timing | 👌 |
| acceptance/halt_ime1_timing | 👌 |
| acceptance/halt_ime1_timing2-GS | 👌 |
| acceptance/if_ie_registers | 👌 |
| acceptance/instr/daa | 👌 |
| acceptance/interrupts/ie_push | 👌 |
| acceptance/intr_timing | 👌 |
| acceptance/jp_cc_timing | 👌 |
| acceptance/jp_timing | 👌 |
| acceptance/ld_hl_sp_e_timing | 👌 |
| acceptance/oam_dma/basic | 👌 |
| acceptance/oam_dma/reg_read | 👀 |
| acceptance/oam_dma/sources-GS | 👀 |
| acceptance/oam_dma_restart | 👌 |
| acceptance/oam_dma_start | 👌 |
| acceptance/oam_dma_timing | 👌 |
| acceptance/pop_timing | 👌 |
| acceptance/ppu/hblank_ly_scx_timing-GS | 👀 |
| acceptance/ppu/intr_1_2_timing-GS | 👌 |
| acceptance/ppu/intr_2_0_timing | 👀 |
| acceptance/ppu/intr_2_mode0_timing | 👀 |
| acceptance/ppu/intr_2_mode0_timing_sprites | 👀 |
| acceptance/ppu/intr_2_mode3_timing | 👀 |
| acceptance/ppu/intr_2_oam_ok_timing | 👀 |
| acceptance/ppu/lcdon_timing-GS | 👀 |
| acceptance/ppu/lcdon_write_timing-GS | 👀 |
| acceptance/ppu/stat_irq_blocking | 👌 |
| acceptance/ppu/stat_lyc_onoff | 👀 |
| acceptance/ppu/vblank_stat_intr-GS | 👀 |
| acceptance/push_timing | 👌 |
| acceptance/rapid_di_ei | 👌 |
| acceptance/ret_cc_timing | 👌 |
| acceptance/ret_timing | 👌 |
| acceptance/reti_intr_timing | 👌 |
| acceptance/reti_timing | 👌 |
| acceptance/rst_timing | 👌 |
| acceptance/serial/boot_sclk_align-dmgABCmgb | 👀 |
| acceptance/timer/div_write | 👌 |
| acceptance/timer/rapid_toggle | 👌 |
| acceptance/timer/tim00 | 👌 |
| acceptance/timer/tim00_div_trigger | 👌 |
| acceptance/timer/tim01 | 👌 |
| acceptance/timer/tim01_div_trigger | 👌 |
| acceptance/timer/tim10 | 👌 |
| acceptance/timer/tim10_div_trigger | 👌 |
| acceptance/timer/tim11 | 👌 |
| acceptance/timer/tim11_div_trigger | 👌 |
| acceptance/timer/tima_reload | 👌 |
| acceptance/timer/tima_write_reloading | 👌 |
| acceptance/timer/tma_write_reloading | 👌 |
| emulator-only/mbc1/bits_bank1 | 👌 |
| emulator-only/mbc1/bits_bank2 | 👌 |
| emulator-only/mbc1/bits_mode | 👌 |
| emulator-only/mbc1/bits_ramg | 👌 |
| emulator-only/mbc1/multicart_rom_8Mb | 👀 |
| emulator-only/mbc1/ram_256kb | 👌 |
| emulator-only/mbc1/ram_64kb | 👌 |
| emulator-only/mbc1/rom_16Mb | 👌 |
| emulator-only/mbc1/rom_1Mb | 👌 |
| emulator-only/mbc1/rom_2Mb | 👌 |
| emulator-only/mbc1/rom_4Mb | 👌 |
| emulator-only/mbc1/rom_512kb | 👌 |
| emulator-only/mbc1/rom_8Mb | 👌 |
| emulator-only/mbc2/bits_ramg | 👌 |
| emulator-only/mbc2/bits_romb | 👌 |
| emulator-only/mbc2/bits_unused | 👌 |
| emulator-only/mbc2/ram | 👌 |
| emulator-only/mbc2/rom_1Mb | 👌 |
| emulator-only/mbc2/rom_2Mb | 👌 |
| emulator-only/mbc2/rom_512kb | 👌 |
| emulator-only/mbc5/rom_16Mb | 👌 |
| emulator-only/mbc5/rom_1Mb | 👌 |
| emulator-only/mbc5/rom_2Mb | 👌 |
| emulator-only/mbc5/rom_32Mb | 👌 |
| emulator-only/mbc5/rom_4Mb | 👌 |
| emulator-only/mbc5/rom_512kb | 👌 |
| emulator-only/mbc5/rom_64Mb | 👌 |
| emulator-only/mbc5/rom_8Mb | 👌 |
| madness/mgb_oam_dma_halt_sprites | 👀 |
| manual-only/sprite_priority | 👀 |
| misc/bits/unused_hwio-C | 👌 |
| misc/boot_div-A | 👀 |
| misc/boot_div-cgb0 | 👀 |
| misc/boot_div-cgbABCDE | 👌 |
| misc/boot_hwio-C | 👀 |
| misc/boot_regs-A | 👀 |
| misc/boot_regs-cgb | 👌 |
| misc/ppu/vblank_stat_intr-C | 👀 |
| utils/bootrom_dumper | 👀 |
| utils/dump_boot_hwio | 👌 |

## GBA - mGBA Test Suite

| Test | Result |
|------|--------|
| Memory tests | 👀 1398/1552 passed |
| I/O read tests | 👌 |
| Timing tests | 👀 177/2020 passed |
| Timer count-up tests | 👀 333/936 passed |
| Timer IRQ tests | 👀 0/90 passed |
| Shifter tests | 👌 |
| Carry tests | 👌 |
| Multiply long tests | 👌 |
| BIOS math tests | 👌 |
| DMA tests | 👀 1044/1256 passed |
| SIO register R/W tests | 👌 |
| SIO timing tests | 👀 0/4 passed |
| Misc. edge case tests | 👀 1/10 passed |
| Video tests | 👀 timed out |

See [detailed results](results_mgba_suite.md) for individual test outcomes.

## Game Boy - Acid2

| Test | Result |
|------|--------|
| dmg-acid2 | 👌 |
| cgb-acid2 | 👌 |

## Game Boy - Mealybug Tearoom

| Test | Result |
|------|--------|
| m2_win_en_toggle | 👀 21.6% correct (4980/23040 pixels match) |
| m3_bgp_change | 👀 65.4% correct (15076/23040 pixels match) |
| m3_bgp_change_sprites | 👀 55.9% correct (12878/23040 pixels match) |
| m3_lcdc_bg_en_change | 👀 87.1% correct (20060/23040 pixels match) |
| m3_lcdc_bg_map_change | 👀 89.6% correct (20654/23040 pixels match) |
| m3_lcdc_obj_en_change | 👀 99.4% correct (22894/23040 pixels match) |
| m3_lcdc_obj_en_change_variant | 👀 94.2% correct (21706/23040 pixels match) |
| m3_lcdc_obj_size_change | 👀 98.8% correct (22755/23040 pixels match) |
| m3_lcdc_obj_size_change_scx | 👀 99.1% correct (22830/23040 pixels match) |
| m3_lcdc_tile_sel_change | 👀 88.8% correct (20466/23040 pixels match) |
| m3_lcdc_tile_sel_win_change | 👀 87.5% correct (20150/23040 pixels match) |
| m3_lcdc_win_en_change_multiple | 👀 63.9% correct (14724/23040 pixels match) |
| m3_lcdc_win_en_change_multiple_wx | 👀 73.6% correct (16963/23040 pixels match) |
| m3_lcdc_win_map_change | 👀 90.0% correct (20732/23040 pixels match) |
| m3_obp0_change | 👀 98.1% correct (22608/23040 pixels match) |
| m3_scx_high_5_bits | 👀 98.5% correct (22698/23040 pixels match) |
| m3_scx_low_3_bits | 👀 97.7% correct (22500/23040 pixels match) |
| m3_scy_change | 👀 57.5% correct (13258/23040 pixels match) |
| m3_window_timing | 👀 88.7% correct (20436/23040 pixels match) |
| m3_window_timing_wx_0 | 👀 90.4% correct (20831/23040 pixels match) |
| m3_wx_4_change | 👀 99.0% correct (22811/23040 pixels match) |
| m3_wx_4_change_sprites | 👀 100.0% correct (23030/23040 pixels match) |
| m3_wx_5_change | 👀 97.2% correct (22402/23040 pixels match) |
| m3_wx_6_change | 👀 40.1% correct (9241/23040 pixels match) |

## Summary

- **Total:** 170
- **Pass:** 100
- **Fail:** 70
