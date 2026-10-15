# Dingbat Test Results

*Generated: 2026-10-14 22:58:46 · commit 4f7da82d · game-boy-test-roms v7.0*

Device column: the hardware the row is scored on. `cart` = the cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific boot table/revision (`--model`); `—` = GBA, which has no device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. A suite where every row passes has only its summary row — its per-row section comes back as soon as anything in it fails.

## Summary

- **Total:** 1587
- **Pass:** 1549
- **Fail:** 38

| Suite | Pass | Total | Status |
|-------|------|-------|--------|
| Game Boy - Acid2 | 2 | 2 | 👌 |
| Game Boy - AGE | 118 | 118 | 👌 |
| Game Boy - Blargg | 28 | 28 | 👌 |
| Game Boy - Blargg cgb_sound | 12 | 12 | 👌 |
| Game Boy - Blargg dmg_sound | 12 | 12 | 👌 |
| [Game Boy - DocBoy](results_docboy.md) | 39 | 70 | 👀 |
| [Game Boy - gambatte](results_gambatte.md) | 48 | 48 | 👌 |
| Game Boy - GBMicrotest | 480 | 480 | 👌 |
| Game Boy - MagenTests | 7 | 7 | 👌 |
| Game Boy - MBC | 6 | 6 | 👌 |
| Game Boy - Mealybug Tearoom | 74 | 74 | 👌 |
| Game Boy - Mooneye | 152 | 152 | 👌 |
| Game Boy - Mooneye (wilbertpol) | 184 | 184 | 👌 |
| Game Boy - SameSuite | 8 | 8 | 👌 |
| Game Boy - SameSuite APU | 70 | 70 | 👌 |
| Game Boy - Screenshot suites | 21 | 21 | 👌 |
| Game Boy - Shootout ROMs | 15 | 15 | 👌 |
| [Game Boy - SingleStepTests SM83](results_singlestep.md) | 20 | 20 | 👌 |
| GBA - alyosha gba-tests | 123 | 126 | 👀 |
| [GBA - dbsuite (AGS-001)](results_dbsuite.md) | 5 | 8 | 👀 |
| GBA - FuzzARM | 5 | 5 | 👌 |
| GBA - hwverified (AGS-001) | 12 | 12 | 👌 |
| GBA - jsmolka gba-tests | 13 | 13 | 👌 |
| [GBA - mGBA Test Suite](results_mgba_suite.md) | 13 | 13 | 👌 |
| GBA - Other test ROMs | 12 | 13 | 👀 |
| GBA - PeterLemon BIOS | 25 | 25 | 👌 |
| [GBA - SingleStepTests ARM7TDMI](results_singlestep.md) | 45 | 45 | 👌 |

## Game Boy - DocBoy (39/70)

| Test | Device | Result |
|------|--------|--------|
| docboy/dmg/cpu | DMG dmgABC | 👀 11/12 passed |
| docboy/dmg/ppu | DMG dmgABC | 👀 1238/1303 passed |
| docboy/dmg/mbc/mbc1 | DMG dmgABC | 👀 11/12 passed |
| docboy/dmg/mbc/mbc3 | DMG dmgABC | 👀 18/21 passed |
| docboy/dmg/mbc/mbc5 | DMG dmgABC | 👌 1/1 passed |
| docboy/dmg/mbc/huc3 | DMG dmgABC | 👀 2/8 passed |
| docboy/dmg/boot | DMG dmgABC | 👀 21/23 passed |
| docboy/dmg/memory | DMG dmgABC | 👌 23/23 passed |
| docboy/dmg/oam_bug | DMG dmgABC | 👀 258/268 passed |
| docboy/dmg/stat_write_bug | DMG dmgABC | 👌 29/29 passed |
| docboy/dmg/timers | DMG dmgABC | 👀 8/10 passed |
| docboy/dmg/interrupts | DMG dmgABC | 👌 158/158 passed |
| docboy/dmg/dma | DMG dmgABC | 👌 68/68 passed |
| docboy/dmg/serial | DMG dmgABC | 👀 76/77 passed |
| docboy/dmg/joypad | DMG dmgABC | 👀 32/34 passed |
| docboy/dmg/apu | DMG dmgABC | 👀 238/307 passed |
| docboy/cgb/boot | CGB cgbE | 👀 48/69 passed |
| docboy/cgb/banks | CGB cgbE | 👌 2/2 passed |
| docboy/cgb/memory | CGB cgbE | 👀 20/33 passed |
| docboy/cgb/oam_bug | CGB cgbE | 👌 5/5 passed |
| docboy/cgb/stat_write_bug | CGB cgbE | 👌 1/1 passed |
| docboy/cgb/timers | CGB cgbE | 👌 2/2 passed |
| docboy/cgb/interrupts | CGB cgbE | 👌 27/27 passed |
| docboy/cgb/dma | CGB cgbE | 👌 41/41 passed |
| docboy/cgb/hdma | CGB cgbE | 👀 468/643 passed |
| docboy/cgb/serial | CGB cgbE | 👌 17/17 passed |
| docboy/cgb/ir | CGB cgbE | 👌 1/1 passed |
| docboy/cgb/mode | CGB cgbE | 👌 6/6 passed |
| docboy/cgb/undocumented | CGB cgbE | 👌 4/4 passed |
| docboy/cgb/ppu | CGB cgbE | 👀 381/427 passed |
| docboy/cgb/mbc/mbc7 | CGB cgbE | 👌 17/17 passed |
| docboy/cgb/apu/ch1 | CGB cgbE | 👀 1048/1134 passed |
| docboy/cgb/apu/ch2 | CGB cgbE | 👌 26/26 passed |
| docboy/cgb/apu/ch3 | CGB cgbE | 👌 109/109 passed |
| docboy/cgb/apu/ch4 | CGB cgbE | 👌 69/69 passed |
| docboy/cgb/double_speed/apu/ch1 | CGB cgbE | 👀 374/613 passed |
| docboy/cgb/double_speed/apu/ch2 | CGB cgbE | 👌 63/63 passed |
| docboy/cgb/double_speed/apu/ch3 | CGB cgbE | 👌 169/169 passed |
| docboy/cgb/double_speed/apu/ch4 | CGB cgbE | 👀 1846/1925 passed |
| docboy/cgb/double_speed/core | CGB cgbE | 👌 8/8 passed |
| docboy/cgb/double_speed/dma | CGB cgbE | 👌 14/14 passed |
| docboy/cgb/double_speed/hdma | CGB cgbE | 👀 49/50 passed |
| docboy/cgb/double_speed/interactive | CGB cgbE | 👀 55/75 passed |
| docboy/cgb/double_speed/interrupts | CGB cgbE | 👌 246/246 passed |
| docboy/cgb/double_speed/ppu | CGB cgbE | 👀 355/357 passed |
| docboy/cgb/double_speed/serial | CGB cgbE | 👌 4/4 passed |
| docboy/cgb/double_speed/timers | CGB cgbE | 👌 76/76 passed |
| docboy/cgb/double_speed/visual | CGB cgbE | 👌 5/5 passed |
| docboy/cgb_dmg_mode/apu | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/boot | CGB cgbE | 👀 16/19 passed |
| docboy/cgb_dmg_mode/banks | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/hdma | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/ir | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/key0 | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/key1 | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/memory | CGB cgbE | 👀 2/15 passed |
| docboy/cgb_dmg_mode/mode | CGB cgbE | 👌 6/6 passed |
| docboy/cgb_dmg_mode/ppu | CGB cgbE | 👀 321/554 passed |
| docboy/cgb_dmg_mode/serial | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/stat_write_bug | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/undocumented | CGB cgbE | 👌 4/4 passed |
| docboy/cgb_dmg_ext_mode/apu | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_ext_mode/banks | CGB cgbE | 👀 0/2 passed |
| docboy/cgb_dmg_ext_mode/hdma | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_ext_mode/ir | CGB cgbE | 👀 0/1 passed |
| docboy/cgb_dmg_ext_mode/key1 | CGB cgbE | 👀 0/1 passed |
| docboy/cgb_dmg_ext_mode/mode | CGB cgbE | 👀 0/8 passed |
| docboy/cgb_dmg_ext_mode/ppu | CGB cgbE | 👀 4/5 passed |
| docboy/cgb_dmg_ext_mode/serial | CGB cgbE | 👀 0/1 passed |
| docboy/cgb_dmg_ext_mode/undocumented | CGB cgbE | 👀 3/4 passed |

Each row is one section of a DocBoy manifest (`docboy/<manifest>/<section>`). See [detailed results](results_docboy.md) for individual test outcomes.

## GBA - alyosha gba-tests (123/126)

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
| alyosha/Interactions/Halt_DMA_IRQ_Read_OAM | — | 👌 |
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
| alyosha/Interactions/Internal_Cycle_DMA_MUL_IRQ | — | 👌 |
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
| alyosha/fifo_dma/fifo_3 | — | 👌 |
| alyosha/fifo_dma/fifo_4 | — | 👌 |
| alyosha/fifo_dma/fifo_5 | — | 👌 |
| alyosha/fifo_dma/fifo_6 | — | 👀 Failed test 156 |
| alyosha/fifo_dma/fifo_dma_disable_3 | — | 👌 |
| alyosha/fifo_dma/fifo_dma_disable_4 | — | 👌 |
| alyosha/fifo_dma/fifo_dma_disable_5 | — | 👌 |
| alyosha/irq/BL_1 | — | 👌 |
| alyosha/irq/BL_IRQ | — | 👌 |
| alyosha/irq/BL_IRQ_2 | — | 👌 |
| alyosha/irq/BL_IRQ_3 | — | 👌 |
| alyosha/irq/BL_IRQ_R14 | — | 👌 |
| alyosha/irq/IE | — | 👌 |
| alyosha/irq/IF | — | 👌 |
| alyosha/irq/IF_Timer | — | 👌 |
| alyosha/irq/IRQ_sub | — | 👌 |
| alyosha/irq/IRQ_sub_2 | — | 👌 |
| alyosha/irq/IRQ_sub_2_slow | — | 👌 |
| alyosha/irq/IRQ_sub_slow | — | 👌 |
| alyosha/irq/halt_pc | — | 👌 |
| alyosha/irq/halt_pc_2 | — | 👌 |
| alyosha/irq/halt_pc_3 | — | 👌 |
| alyosha/irq/halt_pc_4 | — | 👌 |
| alyosha/memory/PAL_8_bit_writes | — | 👌 |
| alyosha/memory/VRAM_8_bit_writes | — | 👌 |
| alyosha/ppu/Sprite_Last_VRAM_Access | — | 👌 |
| alyosha/ppu/Sprite_Last_VRAM_Access_Free | — | 👌 |
| alyosha/ppu/start_up | — | 👌 |
| alyosha/ppu/start_up_vbl | — | 👌 |
| alyosha/ppu/start_up_vbl_irq | — | 👌 |
| alyosha/ppu/start_up_vbl_irq_halt | — | 👌 |
| alyosha/prefetcher/bounday_test_1 | — | 👌 |
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
| alyosha/prefetcher/prefetcher_branch_thumb_arm_3 | — | 👌 |
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
| alyosha/timer/timer_reset | — | 👌 |
| alyosha/timing/cpy_data_bios | — | 👌 |
| alyosha/timing/dma_from_bios | — | 👌 |
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
| png183/memory/memory | — | 👌 |
| png183/psr/psr2 | — | 👌 |
| png183/timer/timer_check_count_up_presence | — | 👌 |

## GBA - dbsuite (AGS-001) (5/8)

| Test | Device | Result |
|------|--------|--------|
| dbsuite/cpu | — | 👌 117/117 passed |
| dbsuite/irq | — | 👌 145/145 passed |
| dbsuite/timer | — | 👌 26/26 passed |
| dbsuite/dma | — | 👀 261/262 passed |
| dbsuite/bus | — | 👀 76/79 passed |
| dbsuite/ppu | — | 👌 156/156 passed |
| dbsuite/apu | — | 👀 50/52 passed |
| dbsuite/bios | — | 👌 47/47 passed |

One row per dbsuite sub-suite (tests/roms/dbsuite). See [detailed results](results_dbsuite.md) for every case that is not a pass.

## GBA - Other test ROMs (12/13)

| Test | Device | Result |
|------|--------|--------|
| gba-rtc-test/RtcTestROM | — | 👌 |
| hades/bios-openbus | — | 👌 |
| hades/timer-basic | — | 👌 |
| hades/dma-latch | — | 👀 no all-pass frame pinned yet (frame hash 009077408465C7EE) |
| hades/dma-start-delay | — | 👌 |
| swp/SwpBusLocking | — | 👌 |
| agbeeg/rom_access_during_prefetch | — | 👌 |
| agbeeg/toggle_prefetcher | — | 👌 |
| agbeeg/swp_locks_bus | — | 👌 |
| agbeeg/ldm_does_not_lock_bus | — | 👌 |
| agbeeg/stm_does_not_lock_bus | — | 👌 |
| agbeeg/cpu_runs_idles_during_dma | — | 👌 |
| dingbat/semiobjwin | — | 👌 |

## Deliberately not scored

Everything skipped on purpose, with the reason and the builder that skips it. If a suite's row count looks short, the answer is here.

- **blargg/oam_bug/7-timing_effect** — broken standalone build: its verbose output overruns the $A004..$BFFF text window into the $C000 copy of its own code, so it never reports — on real DMG hardware too (docboy#33: the maintainer reproduced the blank screen on a DMG through an Everdrive X7, and the shootout leaves it out for the same reason). Test 7 is scored through `blargg/oam_bug/combined` instead. (build_blargg_tests)
- **daid/rom_and_ram, acid/which** — ship no reference image; the shootout's test.py gives a test with no pass image the default result INFO, not pass/fail. (build_shootout_tests)
- **magen/oam_internal_priority** — its only stated criterion is prose ("2 pairs of rectangles connected or touching") plus a SameBoy window capture in the repo's images/ (318x295, an emulator's output, not a hardware frame); nothing machine-checkable to score against. The harness frame shows the same two touching pairs. (build_magen_tests)
- **mooneye/wilbertpol `ags` arms** — `ags` is AGB silicon in a different package — the suite's own README says so — and dingbat models one AGB, so a `-C`/`-A` token's `ags` member folds into its `agb` arm rather than inventing a machine. Everything else those tokens name IS run: see mooneye_machines_for. (build_mooneye_tests / build_wilbertpol_tests)
- **mooneye/wilbertpol revision 0 inside a bare model token** — `-cgb` and `-dmg` fan out across the revisions dingbat models but deliberately stop short of revision 0, which the suite treats as its own machine and ships separate `-cgb0`/`-dmg0` ROMs for precisely because it diverges. Those separate ROMs ARE scored. (build_mooneye_tests)
- **age `oam/oam-write-dmgC`** — the AGE emulator's own runner blacklists it (its test-blacklist.txt names this ROM, `_in-progress` and `speed-switch/caution`, nothing else of the suite), and the source marks the delay-2 line as depending on when the LCD was last switched off, changing when the test covers more frames; verified on one DMG-CPU-08 in 2021. Every other line of the ROM passes here; the CGB twin `oam-write-cgbBCE` is scored on B, C and E. (build_age_tests)
- **gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)** — their verdict is a byte of uninitialised WRAM. That source fetches through the echo, so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch rather than its own byte -- Pan Docs says WRAM is random on power-up and GB_POWERUP_WRAM_PATTERN honours that, so these encode gambatte's capture rig, not hardware. The non-colliding members of the same family (`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_wram)
- **gambatte `scx_during_m3_spx2{,_ds}`, `scx_attrib_during_m3_spx2_ds` CGB rows (3)** — their only disagreement is x = 0 on lines 0-7, the object's column 6 in OBJ palette 0 colour 2, which the ROM never writes (no OCPS/OCPD store in any of the three). Pan Docs: in CGB mode the boot ROM leaves object colours uninitialised apart from byte 0, and the CGB boot ROM disassembly agrees. The reference colour is the word gambatte-core's power-on table holds there; with that one word in place dingbat matches all three frames, and SameBoy draws the same pixel in its own random word. The DMG halves, `spx0`/`spx1` and the other scx_during_m3 rows ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_objpal)
- **gambatte's AGB column** — gambatte's runner marks it `FIXME: Actual AGB results` and feeds it the CGB expectations, so it asserts nothing about AGB. (build_gambatte_rows)
- **gbmicrotest: 31 ROMs that never write the $FF82 verdict byte** — scanned all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one and these 31 contain neither, so the harness would be scoring uninitialised HRAM rather than a result. The upstream sources agree (none of the 31 .s files calls a test_finish macro) and GateBoy's own test list never runs them. All 31 were failing rows before the skip. The honest suite denominator is 482. (build_gbmicrotest_tests)
- **gbmicrotest: 2 ROMs whose expected byte is unreachable** — `halt_op_dupe_delay` wants DIV = $55 about 62 M-cycles after resetting DIV, which needs a 5,440 M-cycle HALT its own HBlank-every-line setup rules out ($55 is the suite's scratch marker; its sibling `halt_op_dupe` is correctly written and passes). `stat_write_glitch_l154_d` is missing the `xor a ; ldh ($FF0F),a` its three siblings have, so it asserts IF = $E0 across a whole frame of LCD-on time it never cleared VBlank in -- restore that clear and it passes, strip it from `_c` at identical timing and `_c` produces `_d`'s byte. Both are ROM defects, not verdicts. The honest suite denominator is 480. (build_gbmicrotest_tests)
- **scribbltests/fairylake, scribbltests/winpos** — ship no reference image: the bundle's howto says so and upstream has only animated GIFs; fairylake is a WIP demo and winpos is a joypad-driven WX/WY explorer. (build_small_screenshot_tests)
- **gambatte/jpadirq_1, gambatte/jpadirq_2** — interactive observation ROMs with no expected result: each shows a running hex count of joypad interrupts (jpadirq_2 also the live P1 nibble while it flips the selected group) for a person pressing buttons on hardware. The filenames carry no `_out` verdict, gambatte's testrunner does not run them, and gambatte's own note on them (test/hwtests/jpadirq.txt) says a real press bounces several times on DMG and CGB, so the count for a press has no single right value. (build_gambatte_rows)
- **gambatte root: cgb_bgp_dumper, cgb_objp_dumper, fexx_ffxx_dumper, fexx_read_reset_set_dumper, ioregs_reset_dumper, vram_dumper, wram_dumper, sram** — tools, not tests: the dumpers copy palette, $FExx/$FFxx, I/O, VRAM or WRAM contents into cart RAM for study on hardware, and sram writes four bytes to cart RAM and shows $00. No `_out` verdict, no reference beside them in the bundle, and gambatte's testrunner does not run them. (gambatte-core's test/hwtests keeps hardware cart-RAM dumps for five of the seven dumpers; the bundle does not ship them.) (build_gambatte_rows)
- **mbc3-tester CGB reference** — a CGB compatibility-mode capture the harness can run (--cgb) and matches pixel-for-pixel in layout at every CGB revision, except that its green is #7BFF4A where the howto beside it, every mealybug `_cgb_c` capture and the boot ROM's default compat palette ($1BEF) give #7BFF31 -- a colour no compat palette produces. An exact row fails on those 3,825 pixels alone, so only the DMG row is scored. (build_small_screenshot_tests)
- **mooneye/utils/ (bootrom_dumper, dump_boot_hwio)** — tools, not pass/fail tests. bootrom_dumper waits for a boot ROM to dump and can only time out (docs/gb-failure-triage.md calls it unrecoverable); dump_boot_hwio ends in quit_dump_mem, which sets the success byte unconditionally, so its green row was a gate that could not fail. (build_mooneye_tests)
- **mooneye-wilbertpol utils/, logic-analysis/** — tools and analysis captures, not pass/fail tests. (build_wilbertpol_tests)
- **rtc3test upstream single ROM** — needs menu input to select a sub-test; the shootout's three pre-split builds are scored instead. (build_shootout_tests)
- **DocBoy: 645 rows its own manifests disable** — `"enabled": false`, so DocBoy's runner never runs them and states no verdict for them: 640 `double_speed/apu/ch4` and 2 `double_speed/apu/ch3` CGB rows, `mbc/huc3/huc3_tick` ("takes a long time (1 real minute)") and two `cgb_dmg_mode` `m3_lcdc_win_en_change_multiple_wx_*_signed_addressing_source` rows ("glitch is different, probably uses another memory bus"). (build_docboy_rows)
- **DocBoy manifests: 725 vendored ROMs of other suites** — everything outside `docboy/` in its manifests (blargg, mooneye, gbmicrotest, mealybug, SameSuite, daid, magen, acid2, little-things-gb, hacktix, firstwhite, rtc3test, cpp, zoomten, tepples). Those are scored from their upstream releases in the sections above, each by its own author's verdict; DocBoy's entries re-check them against DocBoy's own frame dumps, and 8 are DocBoy edits (`samesuite/apu/channel_1/*-cgbE`, expectations rewritten for CPU CGB E). (build_docboy_rows)
