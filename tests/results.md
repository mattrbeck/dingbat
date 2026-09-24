# Dingbat Test Results

*Generated: 2026-09-23 22:55:48 · commit c40a3252d · game-boy-test-roms v7.0*

Device column: the hardware the row is scored on. `cart` = the cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific boot table/revision (`--model`); `—` = GBA, which has no device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. Sections where every row passes are collapsed to a single line — the per-row table comes back as soon as anything in them fails.

## Summary

- **Total:** 1435
- **Pass:** 1411
- **Fail:** 24

| Suite | Pass | Total |
|-------|------|-------|
| Game Boy - Blargg | 28 | 28 |
| Game Boy - Blargg dmg_sound | 12 | 12 |
| Game Boy - Blargg cgb_sound | 12 | 12 |
| Game Boy - Mooneye | 152 | 152 |
| GBA - mGBA Test Suite | 13 | 13 |
| GBA - jsmolka gba-tests | 13 | 13 |
| GBA - alyosha gba-tests | 107 | 126 |
| GBA - PeterLemon BIOS | 25 | 25 |
| GBA - Other test ROMs | 10 | 12 |
| GBA - hwverified (AGS-001) | 12 | 12 |
| GBA - FuzzARM | 5 | 5 |
| Game Boy - Acid2 | 2 | 2 |
| Game Boy - MagenTests | 7 | 7 |
| Game Boy - Mealybug Tearoom | 74 | 74 |
| Game Boy - GBMicrotest | 480 | 480 |
| Game Boy - AGE | 118 | 118 |
| Game Boy - Screenshot suites | 19 | 19 |
| Game Boy - SameSuite | 8 | 8 |
| Game Boy - SameSuite APU | 70 | 70 |
| Game Boy - Shootout ROMs | 15 | 15 |
| Game Boy - Mooneye (wilbertpol) | 184 | 184 |
| Game Boy - gambatte | 45 | 48 |

## Game Boy - Blargg (28/28)

**All 28 tests passed.**

## Game Boy - Blargg dmg_sound (12/12)

**All 12 tests passed.**

## Game Boy - Blargg cgb_sound (12/12)

**All 12 tests passed.**

## Game Boy - Mooneye (152/152)

**All 152 tests passed.**

## GBA - mGBA Test Suite (13/13)

**All 13 tests passed.**

See [detailed results](results_mgba_suite.md) for individual test outcomes.

## GBA - jsmolka gba-tests (13/13)

**All 13 tests passed.**

## GBA - alyosha gba-tests (107/126)

| Test | Device | Result |
|------|--------|--------|
| alyosha/Bus/DMA_CPU_Bus_Interaction | — | 👌 |
| alyosha/Bus/DMA_IWRAM_Bus | — | 👌 |
| alyosha/Bus/DMA_OAM_Bus | — | 👌 |
| alyosha/Bus/DMA_Outside_Bios_Bus | — | 👌 |
| alyosha/Bus/LDRSH_misaligned | — | 👌 |
| alyosha/Bus/Unused_location_update_bus | — | 👌 |
| alyosha/DMA/DMA_Mode_Change | — | 👌 |
| alyosha/DMA/DMA_ROM_Fixed | — | 👌 |
| alyosha/DMA/DMA_pause_timing_ROM_to_IWRAM | — | 👌 |
| alyosha/DMA/DMA_pause_timing_end_1 | — | 👌 |
| alyosha/DMA/DMA_pause_timing_end_2 | — | 👌 |
| alyosha/DMA/DMA_pause_timing_end_3 | — | 👌 |
| alyosha/DMA/DMA_pause_timing_end_4 | — | 👌 |
| alyosha/DMA/DMA_pause_timing_mid_1 | — | 👌 |
| alyosha/DMA/DMA_pause_timing_mid_2 | — | 👌 |
| alyosha/Interactions/Halt_DMA_IRQ | — | 👌 |
| alyosha/Interactions/Halt_DMA_IRQ_Read_OAM | — | 👀 Failed test 219 |
| alyosha/Interactions/Halt_IRQ | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_7 | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_Br_pre | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_Br_pre_tim | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_ST | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_ST_p3 | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_br | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_br1_IWRAM | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_ldr_IWRAM | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_IRQ_nop_IWRAM | — | 👌 |
| alyosha/Interactions/Internal_Cycle_DMA_MUL_IRQ | — | 👀 Failed test 189 |
| alyosha/Interactions/Internal_Cycle_DMA_Mul | — | 👌 |
| alyosha/LDM/LDM_ALU | — | 👌 |
| alyosha/LDM/LDM_ALU_IMM | — | 👌 |
| alyosha/LDM/LDM_ALU_Store | — | 👌 |
| alyosha/LDM/LDM_Bx | — | 👌 |
| alyosha/LDM/LDM_LD | — | 👌 |
| alyosha/LDM/LDM_MUL_UL_32 | — | 👌 |
| alyosha/LDM/LDM_MUL_UL_SL | — | 👌 |
| alyosha/LDM/LDM_Swap | — | 👌 |
| alyosha/STM_ALU_IMM | — | 👌 |
| alyosha/Serial/serial_read_data | — | 👌 |
| alyosha/Serial/serial_time | — | 👌 |
| alyosha/Serial/serial_time_2 | — | 👌 |
| alyosha/Serial/serial_time_2M | — | 👌 |
| alyosha/Serial/serial_time_2M_2 | — | 👌 |
| alyosha/Serial/serial_time_2M_3 | — | 👌 |
| alyosha/Serial/serial_time_3 | — | 👌 |
| alyosha/Serial/serial_time_start_bit | — | 👌 |
| alyosha/Serial/serial_time_start_bit_2 | — | 👌 |
| alyosha/arm/Coprocessor_14 | — | 👌 |
| alyosha/fifo_dma/fifo | — | 👀 Failed test 002 |
| alyosha/fifo_dma/fifo_2 | — | 👌 |
| alyosha/fifo_dma/fifo_3 | — | 👀 Failed test 174 |
| alyosha/fifo_dma/fifo_4 | — | 👌 |
| alyosha/fifo_dma/fifo_5 | — | 👀 Failed test 059 |
| alyosha/fifo_dma/fifo_6 | — | 👀 Failed test 155 |
| alyosha/fifo_dma/fifo_dma_disable_3 | — | 👌 |
| alyosha/fifo_dma/fifo_dma_disable_4 | — | 👌 |
| alyosha/fifo_dma/fifo_dma_disable_5 | — | 👌 |
| alyosha/irq/BL_1 | — | 👌 |
| alyosha/irq/BL_IRQ | — | 👌 |
| alyosha/irq/BL_IRQ_2 | — | 👀 Failed test 251 |
| alyosha/irq/BL_IRQ_3 | — | 👌 |
| alyosha/irq/BL_IRQ_R14 | — | 👌 |
| alyosha/irq/IE | — | 👌 |
| alyosha/irq/IF | — | 👌 |
| alyosha/irq/IF_Timer | — | 👌 |
| alyosha/irq/IRQ_sub | — | 👌 |
| alyosha/irq/IRQ_sub_2 | — | 👀 Failed test 201 |
| alyosha/irq/IRQ_sub_2_slow | — | 👀 no verdict on screen |
| alyosha/irq/IRQ_sub_slow | — | 👌 |
| alyosha/irq/halt_pc | — | 👌 |
| alyosha/irq/halt_pc_2 | — | 👌 |
| alyosha/irq/halt_pc_3 | — | 👌 |
| alyosha/irq/halt_pc_4 | — | 👌 |
| alyosha/memory/PAL_8_bit_writes | — | 👌 |
| alyosha/memory/VRAM_8_bit_writes | — | 👌 |
| alyosha/ppu/Sprite_Last_VRAM_Access | — | 👀 Failed test 141 |
| alyosha/ppu/Sprite_Last_VRAM_Access_Free | — | 👀 Failed test 119 |
| alyosha/ppu/start_up | — | 👌 |
| alyosha/ppu/start_up_vbl | — | 👌 |
| alyosha/ppu/start_up_vbl_irq | — | 👀 Failed test 049 |
| alyosha/ppu/start_up_vbl_irq_halt | — | 👌 |
| alyosha/prefetcher/bounday_test_1 | — | 👀 Failed test 033 |
| alyosha/prefetcher/prefetcher_boundary_1 | — | 👌 |
| alyosha/prefetcher/prefetcher_boundary_2 | — | 👌 |
| alyosha/prefetcher/prefetcher_boundary_3 | — | 👌 |
| alyosha/prefetcher/prefetcher_boundary_4 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_2 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_3 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_4 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_5 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_6 | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_arm | — | 👌 |
| alyosha/prefetcher/prefetcher_branch_thumb_arm_3 | — | 👀 Failed test 078 |
| alyosha/prefetcher/prefetcher_branch_thumb_arm_4 | — | 👌 |
| alyosha/prefetcher/prefetcher_dma | — | 👌 |
| alyosha/prefetcher/prefetcher_full_arm | — | 👌 |
| alyosha/prefetcher/prefetcher_full_arm_2 | — | 👌 |
| alyosha/prefetcher/prefetcher_full_thumb | — | 👌 |
| alyosha/psr/psr | — | 👌 |
| alyosha/thumb/Pop_no_regs | — | 👌 |
| alyosha/thumb/Push_no_regs | — | 👌 |
| alyosha/thumb/blx | — | 👌 |
| alyosha/thumb/cpy | — | 👌 |
| alyosha/timer/timer | — | 👌 |
| alyosha/timer/timer_disable | — | 👌 |
| alyosha/timer/timer_reset | — | 👀 Failed test 001 |
| alyosha/timing/cpy_data_bios | — | 👌 |
| alyosha/timing/dma_from_bios | — | 👀 Failed test 017 |
| alyosha/timing/dma_long | — | 👌 |
| alyosha/timing/prefetch_enable | — | 👌 |
| alyosha/timing/prefetch_enable_2 | — | 👌 |
| alyosha/unsafe/fifo_dma_disable_jam | — | 👌 |
| alyosha/unsafe/fifo_dma_disable_jam_2 | — | 👌 |
| alyosha/unsafe/prefetcher_branch_thumb_arm_2 | — | 👀 Failed test 078 |
| png183/DMA/dma_repeat_immediate | — | 👌 |
| png183/arm/arm | — | 👌 |
| png183/arm/branches | — | 👌 |
| png183/arm/data_swap | — | 👌 |
| png183/arm/halfword_transfer | — | 👌 |
| png183/arm/multiply | — | 👌 |
| png183/irq/halt_pc | — | 👌 |
| png183/memory/memory | — | 👀 Failed test 104 |
| png183/psr/psr2 | — | 👀 Failed test 013 |
| png183/timer/timer_check_count_up_presence | — | 👌 |

## GBA - PeterLemon BIOS (25/25)

**All 25 tests passed.**

## GBA - Other test ROMs (10/12)

| Test | Device | Result |
|------|--------|--------|
| gba-rtc-test/RtcTestROM | — | 👌 |
| hades/bios-openbus | — | 👌 |
| hades/timer-basic | — | 👌 |
| hades/dma-latch | — | 👀 no all-pass frame pinned yet (frame hash 009077408465C7EE) |
| hades/dma-start-delay | — | 👀 no all-pass frame pinned yet (frame hash 58A8421328C709E6) |
| swp/SwpBusLocking | — | 👌 |
| agbeeg/rom_access_during_prefetch | — | 👌 |
| agbeeg/toggle_prefetcher | — | 👌 |
| agbeeg/swp_locks_bus | — | 👌 |
| agbeeg/ldm_does_not_lock_bus | — | 👌 |
| agbeeg/stm_does_not_lock_bus | — | 👌 |
| agbeeg/cpu_runs_idles_during_dma | — | 👌 |

## GBA - hwverified (AGS-001) (12/12)

**All 12 tests passed.**

## GBA - FuzzARM (5/5)

**All 5 tests passed.**

## Game Boy - Acid2 (2/2)

**All 2 tests passed.**

## Game Boy - MagenTests (7/7)

**All 7 tests passed.**

## Game Boy - Mealybug Tearoom (74/74)

**All 74 tests passed.**

## Game Boy - GBMicrotest (480/480)

**All 480 tests passed.**

## Game Boy - AGE (118/118)

**All 118 tests passed.**

## Game Boy - Screenshot suites (19/19)

**All 19 tests passed.**

## Game Boy - SameSuite (8/8)

**All 8 tests passed.**

## Game Boy - SameSuite APU (70/70)

**All 70 tests passed.**

## Game Boy - Shootout ROMs (15/15)

**All 15 tests passed.**

## Game Boy - Mooneye (wilbertpol) (184/184)

**All 184 tests passed.**

## Game Boy - gambatte (45/48)

| Test | Device | Result |
|------|--------|--------|
| gambatte/bgen | per-ROM | 👌 2/2 passed |
| gambatte/bgtiledata | per-ROM | 👌 34/34 passed |
| gambatte/bgtilemap | per-ROM | 👌 40/40 passed |
| gambatte/cgbpal_m3 | per-ROM | 👌 44/44 passed |
| gambatte/display_startstate | per-ROM | 👌 14/14 passed |
| gambatte/div | per-ROM | 👌 8/8 passed |
| gambatte/dma | per-ROM | 👌 229/229 passed |
| gambatte/dmgpalette_during_m3 | per-ROM | 👀 9/17 passed |
| gambatte/enable_display | per-ROM | 👌 184/184 passed |
| gambatte/halt | per-ROM | 👌 158/158 passed |
| gambatte/irq_precedence | per-ROM | 👌 64/64 passed |
| gambatte/lcd_offset | per-ROM | 👌 62/62 passed |
| gambatte/lcdirq_precedence | per-ROM | 👌 62/62 passed |
| gambatte/ly0 | per-ROM | 👌 96/96 passed |
| gambatte/lyc0int_m0irq | per-ROM | 👌 6/6 passed |
| gambatte/lyc153int_m2irq | per-ROM | 👌 16/16 passed |
| gambatte/lycEnable | per-ROM | 👌 225/225 passed |
| gambatte/lycint_ly | per-ROM | 👌 6/6 passed |
| gambatte/lycint_lycflag | per-ROM | 👌 12/12 passed |
| gambatte/lycint_lycirq | per-ROM | 👌 4/4 passed |
| gambatte/lycint_m0stat | per-ROM | 👌 6/6 passed |
| gambatte/lycm2int | per-ROM | 👌 18/18 passed |
| gambatte/lywrite | per-ROM | 👌 8/8 passed |
| gambatte/m0enable | per-ROM | 👌 167/167 passed |
| gambatte/m0int_m0irq | per-ROM | 👌 4/4 passed |
| gambatte/m0int_m0stat | per-ROM | 👌 12/12 passed |
| gambatte/m0int_m3stat | per-ROM | 👌 6/6 passed |
| gambatte/m1 | per-ROM | 👌 170/170 passed |
| gambatte/m2enable | per-ROM | 👌 120/120 passed |
| gambatte/m2int_m0irq | per-ROM | 👌 72/72 passed |
| gambatte/m2int_m0stat | per-ROM | 👌 6/6 passed |
| gambatte/m2int_m2irq | per-ROM | 👌 18/18 passed |
| gambatte/m2int_m2stat | per-ROM | 👌 8/8 passed |
| gambatte/m2int_m3stat | per-ROM | 👌 44/44 passed |
| gambatte/miscmstatirq | per-ROM | 👌 279/279 passed |
| gambatte/oam_access | per-ROM | 👌 69/69 passed |
| gambatte/oamdma | per-ROM | 👌 802/802 passed |
| gambatte/scx_during_m3 | per-ROM | 👀 138/141 passed |
| gambatte/scy | per-ROM | 👌 67/67 passed |
| gambatte/serial | per-ROM | 👌 82/82 passed |
| gambatte/sound | per-ROM | 👌 300/300 passed |
| gambatte/speedchange | per-ROM | 👀 231/244 passed |
| gambatte/sprites | per-ROM | 👌 476/476 passed |
| gambatte/tima | per-ROM | 👌 232/232 passed |
| gambatte/undef_ops | per-ROM | 👌 20/20 passed |
| gambatte/vram_m3 | per-ROM | 👌 50/50 passed |
| gambatte/vramw_m3end | per-ROM | 👌 36/36 passed |
| gambatte/window | per-ROM | 👌 476/476 passed |

Each row is one gambatte subdirectory. See [detailed results](results_gambatte.md) for individual test outcomes.

## Deliberately not scored

Everything skipped on purpose, with the reason and the builder that skips it. If a suite's row count looks short, the answer is here.

- **blargg/oam_bug/7-timing_effect** — broken standalone build: its verbose output overruns the $A004..$BFFF text window into the $C000 copy of its own code, so it never reports — on real DMG hardware too (docboy#33: the maintainer reproduced the blank screen on a DMG through an Everdrive X7, and the shootout leaves it out for the same reason). Test 7 is scored through `blargg/oam_bug/combined` instead. (build_blargg_tests)
- **daid/rom_and_ram, acid/which** — ship no reference image; the shootout's test.py gives a test with no pass image the default result INFO, not pass/fail. (build_shootout_tests)
- **magen/oam_internal_priority** — its only stated criterion is prose ("2 pairs of rectangles connected or touching") plus a SameBoy window capture in the repo's images/ (318x295, an emulator's output, not a hardware frame); nothing machine-checkable to score against. The harness frame shows the same two touching pairs. (build_magen_tests)
- **mooneye/wilbertpol `ags` arms** — `ags` is AGB silicon in a different package — the suite's own README says so — and dingbat models one AGB, so a `-C`/`-A` token's `ags` member folds into its `agb` arm rather than inventing a machine. Everything else those tokens name IS run: see mooneye_machines_for. (build_mooneye_tests / build_wilbertpol_tests)
- **mooneye/wilbertpol revision 0 inside a bare model token** — `-cgb` and `-dmg` fan out across the revisions dingbat models but deliberately stop short of revision 0, which the suite treats as its own machine and ships separate `-cgb0`/`-dmg0` ROMs for precisely because it diverges. Those separate ROMs ARE scored. (build_mooneye_tests)
- **age `oam/oam-write-dmgC`** — the AGE emulator's own runner blacklists it (its test-blacklist.txt names this ROM, `_in-progress` and `speed-switch/caution`, nothing else of the suite), and the source marks the delay-2 line as depending on when the LCD was last switched off, changing when the test covers more frames; verified on one DMG-CPU-08 in 2021. Every other line of the ROM passes here; the CGB twin `oam-write-cgbBCE` is scored on B, C and E. (build_age_tests)
- **gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)** — their verdict is a byte of uninitialised WRAM. That source fetches through the echo, so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch rather than its own byte -- Pan Docs says WRAM is random on power-up and GB_POWERUP_WRAM_PATTERN honours that, so these encode gambatte's capture rig, not hardware. The non-colliding members of the same family (`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_wram)
- **gambatte's AGB column** — gambatte's runner marks it `FIXME: Actual AGB results` and feeds it the CGB expectations, so it asserts nothing about AGB. (build_gambatte_rows)
- **gbmicrotest: 31 ROMs that never write the $FF82 verdict byte** — scanned all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one and these 31 contain neither, so the harness would be scoring uninitialised HRAM rather than a result. The upstream sources agree (none of the 31 .s files calls a test_finish macro) and GateBoy's own test list never runs them. All 31 were failing rows before the skip. The honest suite denominator is 482. (build_gbmicrotest_tests)
- **gbmicrotest: 2 ROMs whose expected byte is unreachable** — `halt_op_dupe_delay` wants DIV = $55 about 62 M-cycles after resetting DIV, which needs a 5,440 M-cycle HALT its own HBlank-every-line setup rules out ($55 is the suite's scratch marker; its sibling `halt_op_dupe` is correctly written and passes). `stat_write_glitch_l154_d` is missing the `xor a ; ldh ($FF0F),a` its three siblings have, so it asserts IF = $E0 across a whole frame of LCD-on time it never cleared VBlank in -- restore that clear and it passes, strip it from `_c` at identical timing and `_c` produces `_d`'s byte. Both are ROM defects, not verdicts. The honest suite denominator is 480. (build_gbmicrotest_tests)
- **scribbltests/fairylake, scribbltests/winpos** — ship no reference image: the bundle's howto says so and upstream has only animated GIFs; fairylake is a WIP demo and winpos is a joypad-driven WX/WY explorer. (build_small_screenshot_tests)
- **little-things-gb/tellinglys** — needs scripted joypad input mid-run (all eight buttons, one after another), which the GB side of the harness has no way to inject. (build_small_screenshot_tests)
- **mbc3-tester CGB reference** — a CGB compatibility-mode capture the harness can run (--cgb) and matches pixel-for-pixel in layout at every CGB revision, except that its green is #7BFF4A where the howto beside it, every mealybug `_cgb_c` capture and the boot ROM's default compat palette ($1BEF) give #7BFF31 -- a colour no compat palette produces. An exact row fails on those 3,825 pixels alone, so only the DMG row is scored. (build_small_screenshot_tests)
- **mooneye/utils/ (bootrom_dumper, dump_boot_hwio)** — tools, not pass/fail tests. bootrom_dumper waits for a boot ROM to dump and can only time out (docs/gb-failure-triage.md calls it unrecoverable); dump_boot_hwio ends in quit_dump_mem, which sets the success byte unconditionally, so its green row was a gate that could not fail. (build_mooneye_tests)
- **mooneye-wilbertpol utils/, logic-analysis/** — tools and analysis captures, not pass/fail tests. (build_wilbertpol_tests)
- **rtc3test upstream single ROM** — needs menu input to select a sub-test; the shootout's three pre-split builds are scored instead. (build_shootout_tests)
