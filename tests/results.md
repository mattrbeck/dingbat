# Dingbat Test Results

*Generated: 2026-11-18 19:42:40 · commit 534ba2ec · game-boy-test-roms v7.0*

Device column: the hardware the row is scored on. `cart` = the cart header picks the device (DMG-ABC for a DMG cart, CPU CGB C for a CGB one); `DMG`/`CGB`/`SGB` = forced; a trailing token is a specific boot table/revision (`--model`); `—` = GBA, which has no device axis here. A row name ending `@<model>` is one ARM of a test whose name declares several machines: a ROM that states the devices it was verified on (AGE's `ei-halt-dmgC-cgbBCE`, mealybug's `_cgb_c`/`_cgb_d` capture pair, mooneye's `-GS` family) gets one row per revision rather than one row on whichever machine happened to be the default, so each revision is actually covered. A suite where every row passes has only its summary row — its per-row section comes back as soon as anything in it fails.

## Summary

- **Total:** 1587
- **Pass:** 1576
- **Fail:** 11

| Suite | Pass | Total | Status |
|-------|------|-------|--------|
| Game Boy - Acid2 | 2 | 2 | 👌 |
| Game Boy - AGE | 119 | 119 | 👌 |
| Game Boy - Blargg | 28 | 28 | 👌 |
| Game Boy - Blargg cgb_sound | 12 | 12 | 👌 |
| Game Boy - Blargg dmg_sound | 12 | 12 | 👌 |
| [Game Boy - DocBoy](results_docboy.md) | 59 | 70 | 👀 |
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
| GBA - alyosha gba-tests | 125 | 125 | 👌 |
| [GBA - dbsuite (AGS-001)](results_dbsuite.md) | 8 | 8 | 👌 |
| GBA - FuzzARM | 5 | 5 | 👌 |
| GBA - hwverified (AGS-001) | 12 | 12 | 👌 |
| GBA - jsmolka gba-tests | 13 | 13 | 👌 |
| [GBA - mGBA Test Suite](results_mgba_suite.md) | 13 | 13 | 👌 |
| GBA - Other test ROMs | 13 | 13 | 👌 |
| GBA - PeterLemon BIOS | 25 | 25 | 👌 |
| [GBA - SingleStepTests ARM7TDMI](results_singlestep.md) | 45 | 45 | 👌 |

## Game Boy - DocBoy (59/70)

| Test | Device | Result |
|------|--------|--------|
| docboy/dmg/cpu | DMG dmgABC | 👌 11/11 passed |
| docboy/dmg/ppu | DMG dmgABC | 👀 1297/1303 passed |
| docboy/dmg/mbc/mbc1 | DMG dmgABC | 👌 11/11 passed |
| docboy/dmg/mbc/mbc3 | DMG dmgABC | 👌 18/18 passed |
| docboy/dmg/mbc/mbc5 | DMG dmgABC | 👌 1/1 passed |
| docboy/dmg/mbc/huc3 | DMG dmgABC | 👀 2/8 passed |
| docboy/dmg/boot | DMG dmgABC | 👌 21/21 passed |
| docboy/dmg/memory | DMG dmgABC | 👌 23/23 passed |
| docboy/dmg/oam_bug | DMG dmgABC | 👀 262/268 passed |
| docboy/dmg/stat_write_bug | DMG dmgABC | 👌 29/29 passed |
| docboy/dmg/timers | DMG dmgABC | 👌 10/10 passed |
| docboy/dmg/interrupts | DMG dmgABC | 👌 158/158 passed |
| docboy/dmg/dma | DMG dmgABC | 👌 68/68 passed |
| docboy/dmg/serial | DMG dmgABC | 👀 76/77 passed |
| docboy/dmg/joypad | DMG dmgABC | 👌 32/32 passed |
| docboy/dmg/apu | DMG dmgABC | 👀 303/307 passed |
| docboy/cgb/boot | CGB cgbE | 👀 48/68 passed |
| docboy/cgb/banks | CGB cgbE | 👌 2/2 passed |
| docboy/cgb/memory | CGB cgbE | 👌 20/20 passed |
| docboy/cgb/oam_bug | CGB cgbE | 👌 5/5 passed |
| docboy/cgb/stat_write_bug | CGB cgbE | 👌 1/1 passed |
| docboy/cgb/timers | CGB cgbE | 👌 2/2 passed |
| docboy/cgb/interrupts | CGB cgbE | 👌 27/27 passed |
| docboy/cgb/dma | CGB cgbE | 👌 41/41 passed |
| docboy/cgb/hdma | CGB cgbE | 👌 640/640 passed |
| docboy/cgb/serial | CGB cgbE | 👌 17/17 passed |
| docboy/cgb/ir | CGB cgbE | 👌 1/1 passed |
| docboy/cgb/mode | CGB cgbE | 👌 6/6 passed |
| docboy/cgb/undocumented | CGB cgbE | 👌 4/4 passed |
| docboy/cgb/ppu | CGB cgbE | 👀 392/427 passed |
| docboy/cgb/mbc/mbc7 | CGB cgbE | 👌 17/17 passed |
| docboy/cgb/apu/ch1 | CGB cgbE | 👀 1139/1141 passed |
| docboy/cgb/apu/ch2 | CGB cgbE | 👌 26/26 passed |
| docboy/cgb/apu/ch3 | CGB cgbE | 👌 109/109 passed |
| docboy/cgb/apu/ch4 | CGB cgbE | 👌 69/69 passed |
| docboy/cgb/double_speed/apu/ch1 | CGB cgbE | 👀 611/613 passed |
| docboy/cgb/double_speed/apu/ch2 | CGB cgbE | 👌 63/63 passed |
| docboy/cgb/double_speed/apu/ch3 | CGB cgbE | 👌 169/169 passed |
| docboy/cgb/double_speed/apu/ch4 | CGB cgbE | 👌 1925/1925 passed |
| docboy/cgb/double_speed/core | CGB cgbE | 👌 8/8 passed |
| docboy/cgb/double_speed/dma | CGB cgbE | 👌 14/14 passed |
| docboy/cgb/double_speed/hdma | CGB cgbE | 👌 50/50 passed |
| docboy/cgb/double_speed/interactive | CGB cgbE | 👌 67/67 passed |
| docboy/cgb/double_speed/interrupts | CGB cgbE | 👌 246/246 passed |
| docboy/cgb/double_speed/ppu | CGB cgbE | 👌 357/357 passed |
| docboy/cgb/double_speed/serial | CGB cgbE | 👌 4/4 passed |
| docboy/cgb/double_speed/timers | CGB cgbE | 👌 76/76 passed |
| docboy/cgb/double_speed/visual | CGB cgbE | 👌 5/5 passed |
| docboy/cgb_dmg_mode/apu | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/boot | CGB cgbE | 👌 18/18 passed |
| docboy/cgb_dmg_mode/banks | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/hdma | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/ir | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/key0 | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/key1 | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/memory | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_mode/mode | CGB cgbE | 👌 6/6 passed |
| docboy/cgb_dmg_mode/ppu | CGB cgbE | 👀 425/554 passed |
| docboy/cgb_dmg_mode/serial | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/stat_write_bug | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_mode/undocumented | CGB cgbE | 👌 4/4 passed |
| docboy/cgb_dmg_ext_mode/apu | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_ext_mode/banks | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_ext_mode/hdma | CGB cgbE | 👌 2/2 passed |
| docboy/cgb_dmg_ext_mode/ir | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_ext_mode/key1 | CGB cgbE | 👀 0/1 passed |
| docboy/cgb_dmg_ext_mode/mode | CGB cgbE | 👌 8/8 passed |
| docboy/cgb_dmg_ext_mode/ppu | CGB cgbE | 👌 5/5 passed |
| docboy/cgb_dmg_ext_mode/serial | CGB cgbE | 👌 1/1 passed |
| docboy/cgb_dmg_ext_mode/undocumented | CGB cgbE | 👌 4/4 passed |

Each row is one section of a DocBoy manifest (`docboy/<manifest>/<section>`). See [detailed results](results_docboy.md) for individual test outcomes.

## Deliberately not scored

Everything skipped on purpose, with the reason and the builder that skips it. If a suite's row count looks short, the answer is here.

- **blargg/oam_bug/7-timing_effect** — broken standalone build: its verbose output overruns the $A004..$BFFF text window into the $C000 copy of its own code, so it never reports. The shootout's test list comments it out ("This test is broken."), and DocBoy's maintainer keeps an open issue on the hang (docboy#67, "blargg's 7-timing_effect.gb hangs with a blank screen (Issue #33)"; #33 itself no longer resolves). Test 7 is scored through `blargg/oam_bug/combined` instead. (build_blargg_tests)
- **daid/rom_and_ram, acid/which** — ship no reference image; the shootout's test.py gives a test with no pass image the default result INFO, not pass/fail. (build_shootout_tests)
- **magen/oam_internal_priority** — its only stated criterion is prose ("2 pairs of rectangles connected or touching") plus a SameBoy window capture in the repo's images/ (318x295, an emulator's output, not a hardware frame); nothing machine-checkable to score against. The harness frame shows the same two touching pairs. (build_magen_tests)
- **mooneye/wilbertpol `ags` arms** — `ags` is AGB silicon in a different package — the suite's own README says so — and dingbat models one AGB, so a `-C`/`-A` token's `ags` member folds into its `agb` arm rather than inventing a machine. Everything else those tokens name IS run: see mooneye_machines_for. (build_mooneye_tests / build_wilbertpol_tests)
- **mooneye/wilbertpol revision 0 under a bare model token** — an open coverage gap, not a justified skip. mooneye_machines_for runs one representative revision per bare token: `G` -> dmgABC and mgb, `-dmg` -> dmgABC, `-cgb` and `C` -> cgbc (Gekkio) or cgbe (wilbertpol), plus agb for `C`. The suite's README defines the tokens by model ("dmg = Game Boy", "cgb = Game Boy Color") and does not exclude revision 0; separate revision-0 ROMs exist only for four Gekkio boot tests (`boot_div-dmg0`, `boot_hwio-dmg0`, `boot_regs-dmg0`, `misc/boot_div-cgb0`), which are scored. Run at revision 0, the 47 bare-token arms pass except, at dmg0, Gekkio `ppu/hblank_ly_scx_timing-GS` and `ppu/vblank_stat_intr-GS` and wilbertpol `boot_regs-dmg`, `gpu/hblank_ly_scx_timing-GS` and `gpu/vblank_stat_intr-GS`, and at cgb0 wilbertpol `ly_lyc-C`, `ly_lyc_0-C`, `ly_lyc_144-C`, `ly_lyc_153-C`, `ly_new_frame-C` and `ly00_mode1_2-C`. (build_mooneye_tests / build_wilbertpol_tests)
- **gambatte `oamdma_src{FE00,FF00}_*read*` DMG rows (9)** — their verdict is uninitialised WRAM. That source fetches through the echo, so it reads $DE00/$DF00, and a colliding CPU read gets the DMA's latch rather than its own byte. No single fill value passes them: they need $FF at $DE00/$DE9E and $00 at $DF00/$DF45/$DF9E, and all-zero WRAM passes the 5 FF00 rows and fails the 4 FE00 rows. Pan Docs says WRAM is random on power-up and GB_POWERUP_WRAM_PATTERN honours that, so these record one console's power-up bytes, not a rule. The non-colliding members of the same family (`busyread8000`, `busyreadFF4B`) and every CGB arm ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_wram)
- **gambatte `scx_during_m3_spx2{,_ds}`, `scx_attrib_during_m3_spx2_ds` CGB rows (3)** — their only disagreement is x = 0 on lines 0-7, the object's column 6 in OBJ palette 0 colour 2, which the ROM never writes (no OCPS/OCPD store in any of the three). Pan Docs: in CGB mode the boot ROM leaves object colours uninitialised apart from byte 0, and the CGB boot ROM disassembly agrees. The reference colour is a word no ROM write sets; with that one word in place dingbat matches all three frames, and SameBoy draws the same pixel in its own random word. The DMG halves, `spx0`/`spx1` and the other scx_during_m3 rows ARE scored. (build_gambatte_rows / gambatte_row_reads_powerup_objpal)
- **gambatte's AGB column** — gambatte's runner marks it `FIXME: Actual AGB results` and feeds it the CGB expectations, so it asserts nothing about AGB. (build_gambatte_rows)
- **gbmicrotest: 31 ROMs that never write the $FF82 verdict byte** — scanned all 513 bundled ROMs for `ldh ($82),a` / `ld ($ff82),a`; 482 contain one and these 31 contain neither, so the harness would be scoring uninitialised HRAM rather than a result. The upstream sources agree (none of the 31 .s files calls a test_finish macro) and GateBoy's own test list never runs them. All 31 were failing rows before the skip. The honest suite denominator is 482. (build_gbmicrotest_tests)
- **gbmicrotest: 2 ROMs whose expected byte is unreachable** — `halt_op_dupe_delay` wants DIV = $55 about 62 M-cycles after resetting DIV, which needs a 5,440 M-cycle HALT its own HBlank-every-line setup rules out ($55 is the suite's scratch marker; its sibling `halt_op_dupe` is correctly written and passes). `stat_write_glitch_l154_d` is missing the `xor a ; ldh ($FF0F),a` its three siblings have, so it asserts IF = $E0 across a whole frame of LCD-on time it never cleared VBlank in -- restore that clear and it passes, strip it from `_c` at identical timing and `_c` produces `_d`'s byte. Both are ROM defects, not verdicts. The honest suite denominator is 480. (build_gbmicrotest_tests)
- **scribbltests/fairylake, scribbltests/winpos** — ship no reference image: the bundle's howto says so and upstream has only animated GIFs; fairylake is a WIP demo and winpos is a joypad-driven WX/WY explorer. (build_small_screenshot_tests)
- **gambatte/jpadirq_1, gambatte/jpadirq_2** — interactive observation ROMs with no expected result: each shows a running hex count of joypad interrupts (jpadirq_2 also the live P1 nibble while it flips the selected group) for a person pressing buttons on hardware. The filenames carry no `_out` verdict, gambatte's testrunner does not run them, and gambatte's own note on them (test/hwtests/jpadirq.txt) says a real press bounces several times on DMG and CGB, so the count for a press has no single right value. (build_gambatte_rows)
- **gambatte root: cgb_bgp_dumper, cgb_objp_dumper, fexx_ffxx_dumper, fexx_read_reset_set_dumper, ioregs_reset_dumper, vram_dumper, wram_dumper, sram** — tools, not tests: the dumpers copy palette, $FExx/$FFxx, I/O, VRAM or WRAM contents into cart RAM for study on hardware, and sram writes four bytes to cart RAM and shows $00. No `_out` verdict, no reference beside them in the bundle, and gambatte's testrunner does not run them. (gambatte-core's test/hwtests keeps hardware cart-RAM dumps for five of the seven dumpers; the bundle does not ship them.) (build_gambatte_rows)
- **mbc3-tester CGB reference** — a CGB compatibility-mode capture the harness can run (--cgb) and matches pixel-for-pixel in layout at every CGB revision, except that its green is #7BFF4A where the howto beside it, every mealybug `_cgb_c` capture and the boot ROM's default compat palette ($1BEF) give #7BFF31 -- a colour no compat palette produces. An exact row fails on those 3,825 pixels alone, so only the DMG row is scored. (build_small_screenshot_tests)
- **mooneye/utils/ (bootrom_dumper, dump_boot_hwio)** — tools, not pass/fail tests. bootrom_dumper waits for a boot ROM to dump and can only time out (docs/dev/gb-failure-triage.md calls it unrecoverable); dump_boot_hwio ends in quit_dump_mem, which sets the success byte unconditionally, so its green row was a gate that could not fail. (build_mooneye_tests)
- **mooneye-wilbertpol utils/, logic-analysis/** — tools and analysis captures, not pass/fail tests. (build_wilbertpol_tests)
- **DocBoy: 645 rows its own manifests disable** — `"enabled": false`, so DocBoy's runner never runs them and states no verdict for them: 640 `double_speed/apu/ch4` and 2 `double_speed/apu/ch3` CGB rows, `mbc/huc3/huc3_tick` ("takes a long time (1 real minute)") and two `cgb_dmg_mode` `m3_lcdc_win_en_change_multiple_wx_*_signed_addressing_source` rows ("glitch is different, probably uses another memory bus"). (build_docboy_rows)
- **alyosha `unsafe/prefetcher_branch_thumb_arm_2`** — its expected values were never produced by a console: the suite's own unsafe/README.md says the ROM "crashes on console due to the prefetcher being misaligned when switching from thumb to arm mode", and the author moved it out of `prefetcher/` (whose `_arm`, `_arm_3` and `_arm_4` siblings are scored) for that reason. The check it fails is that switch: TM0 after the Thumb `bx r2` at 0x0800019E into ARM code at 0x080001A4, a branch from an odd halfword, expected 0x53, read 0x4E here. Its first check, the ARM-to-Thumb branch before it, reads the expected 0x3A. (build_alyosha_tests)
- **DocBoy manifests: 717 vendored ROMs of other suites** — everything outside `docboy/` in its manifests (blargg, mooneye, gbmicrotest, mealybug, SameSuite, daid, magen, acid2, little-things-gb, hacktix, firstwhite, rtc3test, cpp, zoomten, tepples) but the 8 SameSuite ROMs DocBoy edited. Those suites are scored from their upstream releases in the sections above, each by its own author's verdict; DocBoy's entries re-check them against DocBoy's own frame dumps. The 8 edits (`samesuite/apu/channel_1/*-cgbE`, expectations rewritten for CPU CGB E) are DocBoy rows, scored but for `channel_1_sweep_restart_2-cgbE` (its own entry). (build_docboy_rows)
- **DocBoy: the KEY1 switch's IME-set leaf (8)** — `{,double_speed_}stop_key1_joypad0_interrupt1_ime1_*_div_round1`: `EI; STOP` with a request pending; DocBoy wants the divider held 8 T. AGE `speed-switch/caution/spsw-interrupts-cgbE` (source header: "Verified: 2022-02-11 pass: CPU CGB E - CPU-CGB-06"), scored and passing here, runs the same sequence and needs 4 (`spsw_irq_leaf_hold_short`): with an 8 T hold all 8 DocBoy rows pass and exactly that AGE row breaks. The two ROMs disagree by one M-cycle. (AGE's own runner blacklists `speed-switch/caution`; its WARNING.md reports the author's CGB E unstable for a while after running those ROMs several times in a row.) Pan Docs' STOP chart does not settle it: the rendered `imgs/stop_diagram.svg` puts "The CPU glitches non-deterministically" on IME disabled, the older `imgs/gb_stop.png` in the same repo on IME enabled. The IME-clear leaf beside it IS scored. (build_docboy_rows, DocboyNotScored)
- **DocBoy: a joypad interrupt on key release (3)** — `joypad_{buttons,dpad}_interrupt_release` want the interrupt when the key is let go, and `cpu/interactive_visual/stop_immediate_exit_joypad_interrupt` wants a release to end a STOP (its comment, the only one on bounce: "even on button release, because of switch bouncing"), while `joypad_keep_pressed_interrupt` wants exactly one interrupt for a held press. Pan Docs ("INT $60") raises it on a high-to-low edge; gambatte's hardware note (test/hwtests/jpadirq.txt) has transitions "multiple times per button press/release", so release bounce is real but its count varies. Here the two release rows read the fail value and the STOP row never reports ($FFF0 stays $00). (build_docboy_rows, DocboyNotScored)
- **DocBoy: $FEA0-$FEFF as RAM on the CGB E (29)** — 13 rows in `cgb/memory` and 13 in `cgb_dmg_mode/memory` write the area outside modes 2/3 and read it back as RAM, `$FEC0-$FEFF` repeating 16 bytes. Pan Docs ("FEA0-FEFF range") gives that kind of answer only to CGB revisions 0-D ("a unique RAM area, but is masked with a revision-specific value"), and has CGB E, AGB, AGS and GBP return the high nibble of the low address byte twice, which dingbat follows. Under dingbat's CGB D model 14 of the 26 memory rows pass. Three `cgb/hdma/gdma_source_wram_dma_source_ram_{160,256,480_bytes_overflow}` rows compare `$FE00-$FEFF` after an OAM DMA beside a GDMA: OAM matches byte for byte and only `$FEA0-$FEFF` differs. Settling it needs a CGB E with a real cart (a flashcart answers for that range itself, docs/dev/hwprobe-questions.md). The two read-while-blocked rows per manifest ($FF) ARE scored. (build_docboy_rows, DocboyNotScored)
- **DocBoy: `boot_hram` (4)** — 3 ROMs (dmg, cgb, cgb_dmg_mode; the dmg manifest lists its ROM twice) expect `$FFFE` = $4C (dmg) or $C0 (cgb, cgb_dmg_mode). Every other byte they check matches what Nintendo's boot ROMs leave (dingbat's skip-boot carries it); no boot ROM writes `$FFFE`, and DocBoy's source says "FFFE seems to be hardcoded to C0 even before boot rom" (4C on the DMG). Pan Docs ("Power Up Sequence"): "The console's WRAM and HRAM are random on power-up." (build_docboy_rows, DocboyNotScored)
- **DocBoy: an MBC3 RTC latch on a bit-0 rising edge only (3)** — `mbc3_rtc_latch_{0_to_2,1_to_0,1_to_1}`: DocBoy latches on a rising edge of bit 0 (0->1, 0->3 and 4->3 latch, the scored `0_to_1`, `0_to_3`, `4_to_3`; 0->2, 1->0 and 1->1 do not). The scored Shootout row `cpp/latch-rtc-test` has low->low, high->low and high->high writes all latching in its reference, and dingbat latches on any write to `$6000-$7FFF` (mbc3.nim): a bit-0 rule passes DocBoy's 3 and fails that row. Provenance as known: the capture's author states it was run on his own flashcart with a real MBC3+RTC chip; DocBoy's maintainer runs an Everdrive X7. (build_docboy_rows, DocboyNotScored)
- **DocBoy: fresh cart RAM reading $FF (1)** — `dmg/mbc/mbc1/mbc1_initial_ram` wants every byte of a new MBC1 cart's RAM to read $FF before anything is written. Pan Docs ("Power Up Sequence"): "external RAM in the cartridge, when present, usually contains random garbage data when first powered on." No suite in the tree reads cart RAM before writing it; mooneye's `emulator-only/mbc1/ram_*` read it disabled ($FF, open bus) and clear it first. dingbat keeps $00 for a cart with no save file; $FF stays a choice open to Matt (it would change every new save's first boot). (build_docboy_rows, DocboyNotScored)
- **DocBoy: SameSuite `channel_1_sweep_restart_2` rewritten for CGB E (1)** — `cgb/samesuite/apu/channel_1/channel_1_sweep_restart_2-cgbE`: DocBoy's maintainer rebuilt SameSuite's ROM with a new expectation (docboy ccb5b248, "Update samesuite tests roms not even passing on real hardware"; its bytes differ from the bundle's). It fails here, while upstream `channel_1_sweep_restart_2`, scored on CGB E in SameSuite APU, passes, and SameSuite's apu README says "CPU-CGB-E – passes all tests": two CGB E claims for one test that cannot both be met. The other 7 edited ROMs are scored. (build_docboy_rows, DocboyNotScored)
