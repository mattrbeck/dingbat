# pandocs-audit: where dingbat disagrees with Pan Docs

**Date:** 2026-08-14. A full sweep of Pan Docs (all 75 pages, gbdev/pandocs
master) against `src/dingbat/gb/`, run as seven parallel section audits
(PPU/rendering; OAM DMA + interrupts + halt; timer/serial/joypad; APU;
mappers + cart header; CGB regs + boot; SGB/printer/camera) with the
high-impact findings re-verified by hand. Excluded: the Star Trek window
insertion glitch (fixed 1f7daf9, flashcart axes in hwprobe-questions.md row
19), Pan Docs sections marked TODO, SM83 instruction-set pages (blargg
fully green), and analog-only matters invisible to both software and screen.

A disagreement is not automatically a dingbat bug: the tree is calibrated
against hardware-sourced suites, and in several places below the code's own
evidence beats the book. Tiers: **A** = likely dingbat defects worth fixing;
**B** = documented behavior knowingly or accidentally unmodeled, test-ROM
visible at most; **C** = dingbat deliberately disagrees and is probably
right (Pan Docs drift — candidate upstream corrections); **D** = whole
subsystems absent.

## Tier A — likely real defects (ranked by impact)

| # | finding | code | Pan Docs | notes |
|---|---|---|---|---|
| A1 | **Scanline (speed-mode) PPU draws sprite-vs-sprite priority INVERTED.** `do_scanline` iterates the sprite list first-to-last and every opaque pixel overwrites unconditionally, so the highest-X (DMG) / latest-OAM (CGB) sprite wins overlaps — backwards on both axes, and contradicting `scanline_get_sprites`'s own "first in array … drawn last (on top)" comment. The FIFO PPU is correct (`sprite_merge_planes` honors `oam_idx`). Any metasprite overlap renders wrong layering whenever speed mode's renderer is active | `scanline_ppu.nim:126-154`, sort at `:37-44` | OAM.md "Drawing priority" | Fix: iterate in reverse or skip claimed pixels. Byte-identical-screenshot gate exists for this renderer — re-baseline needed |
| A2 | **MBC30 unmodeled: RAM banks 4–7 unreachable.** `mbc_read`/`mbc_write` gate RAM on `ram_bank_num <= 3` unconditionally; correct for plain MBC3 (CasualPokePlayer's rtc-invalid-banks capture) but a $10-type cart with RAM code $05 (64 KiB = MBC30; JP Pokemon Crystal, the only retail title) loses the top half — its PC box storage. Loader allocates the 64 KiB; the mapper can never address it | `mbc/mbc3.nim:39-49`; loader `mbc/mbc.nim:159` | MBC3.md; The_Cartridge_Header.md ("MBC3 with 64 KiB of SRAM refers to MBC30") | Header-driven switch: RAM size $05 ⇒ allow banks 0–7. ROM side is fine (JP Crystal = 2 MiB = 7 bits). Repo's `PokemonCrystal.gbc` is Western ($03) — unaffected; needs a JP image to verify |
| A3 | **CGB palette RAM (BCPD/OCPD) never locks during mode 3.** Reads return live `pram` and writes land in any mode; hardware returns $FF / drops the write (auto-increment still fires on the blocked write, so a racing palette streamer ends up with data at *different indices* than dingbat produces) | reads `ppu.nim:2222,2227`; writes `ppu.nim:2510-2523` | Palettes.md; Rendering.md mode table | SameBoy/mGBA both model it. No suite row currently pins it (mealybug CGB rows write in blanking) |
| A4 | **NR43 clock shift 14/15 does not freeze the noise LFSR.** `ch4_frequency_timer` computes `divisor shl shift` for all 16 shifts; hardware sends the LFSR no clocks at 14/15 — output holds its current bit where dingbat ticks at ~1–16 Hz. PCM34-visible | `apu/channel4.nim:52-55,65` | Audio_Registers.md NR43; Audio_details.md | Untested by blargg/SameSuite — genuine oversight, cheap fix |
| A5 | **CGB gets the DMG-only timer-disable glitch tick.** Clearing TAC.2 with the selected tap high increments TIMA on every model; Pan Docs: "does not happen on Color models". No CGB gate in `timer_check_edge`/FF07 write | `timer.nim:88-97,230-260` | Timer_Obscure_Behaviour.md | mooneye `rapid_toggle` runs DMG-side only, so nothing pins the CGB arm. Companion nondeterminism (CGB enable-write "may or may not tick") — dingbat's never-tick pick is inside the envelope |
| A6 | **Glitch-caused TIMA overflows reload TMA immediately, skipping the 1-M-cycle window.** `timer_check_edge(on_write=true)` calls `timer_reload_tima` on the write's own M-cycle instead of arming `countdown=4`, for all write-glitch paths (DIV write, TAC writes, STOP's DIV reset). Hardware puts even glitch overflows through cycle-A/B (TIMA=0 for one M-cycle; TIMA write ignored / TMA write propagates in cycle B); IF also sets one M-cycle early | `timer.nim:88-97,219,248,260`; `memory.nim:1316,1361` | Timer_and_Divider_Registers.md; Timer_Obscure_Behaviour.md | The delay lives in the reload path, not the increment source. Normal overflows are correct |
| A7 | **HDMA/GDMA CPU-domain charge is half the documented cost in double speed.** Per block dingbat charges 32 dots (correct, gambatte-pinned) but also only 32 CPU-clock cycles regardless of speed = 8 fast M-cycles; Pan Docs says 16 fast M-cycles (8 µs both speeds). TIMA/serial/OAM-DMA advance 2× too little relative to the PPU across double-speed blocks | `ppu.nim:1712` (`mem_tick_components(…, 2, ignore_speed=true)`) | CGB_Registers.md | In-tree evidence (`gb.nim:277-349`) only pins the dot axis; the CPU-stall axis was never swept |
| A8 | **Plain OAM reads/writes during mode 2 don't corrupt OAM.** Only the 16-bit IDU family (inc/dec rr, ld [hl±], push/pop, dispatch) reaches `oam_bug_if`; `ld a,[hl]` / absolute loads into $FE00-$FEFF in mode 2 go through `cpu_oam_open` with no corruption | `opcodes.nim` IDU sites; `ppu.nim:2145-2147`; `memory.nim:682` | OAM_Corruption_Bug.md ("Any memory access instruction, if it accesses OAM") | blargg oam_bug is green without it — its causes ROMs don't test plain accesses. SameBoy corrupts on any mode-2 access |
| A9 | **Envelope timer misses the +1 reload when a trigger lands just before an envelope step.** `init_volume_envelope` sets `timer = period` unconditionally; the length analogue of this frame-sequencer-phase rule IS modeled | `apu/abstract_channels.nim:194-197` | Audio_details.md | First envelope step arrives one 64 Hz tick early. PCM-visible; no suite row pins it |
| A10 | **Sweep pace 0→nonzero write doesn't reload the sweep timer.** NR10 arm stores fields only; the timer keeps its stale countdown (next iteration up to 8 ticks late instead of `pace` after the write). The "instantly disabled" half IS modeled | `apu/channel1.nim:289-293` | Audio_Registers.md NR10 | |
| A11 | **First frame after LCD re-enable isn't blanked.** Hardware keeps the screen blank for the first frame after LCDC.7 on; dingbat presents it. One-frame flash difference in games that toggle the LCD mid-play | `ppu.nim:2235-2304` | LCDC.md | Presentation-only; no timing-suite risk |
| A12 | **CGB: clearing LCDC.5 doesn't reset the window Y condition.** `window_trigger` clears only at mode 1; the CGB-specific reset (WY must re-match to show the window again this frame) is absent | `ppu.nim:1769,2050-2079` | Window.md CGB note | No suite row covers it (mealybug m2_win_en_toggle is DMG). Flashcart-adjacent to hwprobe row 19 |
| A13 | **CGB object fetches skipped when LCDC.1 is off.** The trigger and the mode-3 length term both require `sprite_enabled` on every device; Pan Docs says CGB performs the fetch (and pays the penalty) regardless, gating only display. Up to ~110 dots/line of mode-3 length, STAT-poll visible | `fifo_ppu.nim:3345,3529` | pixel_fifo.md "(this condition is ignored on CGB)" | dingbat's own CGB no-abort evidence (`CGB_OBJ_ABORT=0`) points the same way. gambatte `sprites/enable/*_cgb` arms would arbitrate |
| A14 | **Post-boot P1/SC wrong on SGB/CGB.** P1: dingbat hands off with neither select line low ($FF); Pan Docs table says $C7/$CF (both low) for SGB/SGB2/CGB/AGB. SC on CGB: dingbat reads $7C (bit 0 and CGB bit 1 clear); table says $7F | `memory.nim:139-143`; `serial.nim:126-133` (no FF02 seed) | Power_Up_Sequence.md | Same mooneye boot_hwio sources both sides cite — worth a re-derive |
| A15 | **CGB/AGB DMG-compat boot registers ignore the header.** B = Nintendo-licensee title-byte sum (+1 AGB, F from the inc), HL = $991A for checksum $43/$58 — dingbat ships fixed B=0/HL=$007C. Right for homebrew/test ROMs, wrong for every Nintendo-published mono cart. Also DMG F=$B0 should drop H/C for header-checksum-$00 carts | `cpu.nim:17-37` | Power_Up_Sequence.md | Cheap: computed at boot, no runtime cost |
| A16 | **MBC5 RAM enable compares the full byte.** `val == $0A` exact; Pan Docs (current text): any value whose low nibble is $A enables. MBC1/2/3/MMM01 use the nibble test; MBC5 alone is exact, uncommented — looks like an oversight, not a choice (MBC7's exact test IS deliberate). MBC6 exact too (undocumented hardware, lower confidence) | `mbc/mbc5.nim:21`; `mbc/mbc6.nim:203` | MBC5.md | Test-ROM level: games write $0A/$00 |
| A17 | **RAM-size code $01 (2 KiB) indexes out of bounds.** Loader allocates 0x800 but the shared bank math assumes 8 KiB granularity; a RAM-enabled access at $A800-BFFF raises IndexDefect instead of wrapping. Pan Docs: "PD" ROMs use the $01 tag | `mbc/mbc.nim:155`; `gb.nim:3858-3860`; e.g. `mbc1.nim:34` | The_Cartridge_Header.md; MBCs.md wrap rule | Robustness/crash bug; licensed carts never hit it (why the 2613-ROM sweep stayed clean) |
| A18 | **GB GameShark SRAM-bank digit discarded.** `parse_gb_gameshark` drops `raw shr 24`; an $A000-BFFF code lands in whatever bank/enable state the game has mapped, not the named bank. Matches mGBA (deliberately), contradicts Pan Docs | `common/cheats.nim:160-169`; apply at `gb.nim:4722` | Shark_Cheats.md | WRAM codes (the vast majority) unaffected |
| A19 | **SGB multiplayer: every joypad ID reads the same physical pad.** MLT_REQ/ID-counter machinery is modeled in hardware detail, but `joypad_lines` has one source — 2P SGB games get P1's input duplicated | `sgb.nim:343-371,432-433`; `joypad.nim:3-12` | SGB_Command_Multiplayer.md | Needs a second input source routed by current ID (the 2P web/link plumbing exists for GB link mode) |
| A20 | **SGB auto-freeze on LCD off unmodeled → white flash.** Hardware freezes the picture whenever the GB LCD turns off; dingbat pushes blank white frames and `sgb_frame_end` then copies white into the freeze buffer | `ppu.nim:358-376`; `sgb.nim:478-481` | SGB_Command_System.md MASK_EN tip | Every SGB game's LCD-off transition flashes where hardware holds the image |
| A21 | **SGB ICON_EN bit 2 (packet suppression) ignored** — later packets still honored | `sgb.nim:376` | SGB_Command_System.md | Affects multi-game paks that lock out SGB traffic |
| A22 | **Printer: no 100 ms packet timeout** (aborted mid-packet stream never self-heals; buffered bands survive arbitrary pauses), and **PRINT executes without the required empty DATA packet**; margins byte ignored with sheet-eject keyed off `sheets != 0` (sheets=0 should feed only) | `printer.nim:147-168,290` | Gameboy_Printer.md | Lenient-direction differences; real traffic (GB Camera et al.) unaffected |
| A23 | **Scanline PPU: window Y condition retractable.** Gates on live `ly >= wy` AND the latch, so parking WY off-screen mid-frame hides the window — exactly what the FIFO renderer (gambatte `late_wy_1toFF_*`) refuses. Speed mode changes the picture for the WY-parking idiom | `scanline_ppu.nim:58-59,177` | Window.md ("remains so for subsequent scanlines") | Same bucket as A1: speed-mode renderer divergence |
| A24 | **High-pass filter uses the DMG charge constant on every model.** Pan Docs: CGB/MGB noticeably more aggressive (0.998943/sample vs 0.999958) — ~700 Hz vs ~24 Hz corner. Single `GB_DC_CHARGE` applied regardless of model | `gb.nim:3745`; `apu.nim:335-338` | Audio_details.md | Audible bass/click difference on CGB titles — but the in-tree SameBoy popscan cross-check ran CGB titles and matched, so investigate before changing |
| A25 | **SVBK written 0 reads back $F9 not $F8** (stores the mapped bank 1, not the written bits). Pan Docs "R/W" phrasing implies raw readback. Low confidence — cheap to check against mooneye/gambatte | `memory.nim:653-656,409-410` | CGB_Registers.md | |

## Tier B — documented, knowingly unmodeled (test-ROM visible at most)

- **RP $FF56 unmapped** (reads $FF vs post-boot $3E; bit 1 = 1 happens to be
  correct "no IR signal", so handshakes time out gracefully). Acknowledged at
  `gb.nim:3535`. The largest acknowledged register gap. `memory.nim:362-444`.
- **OPRI $FF6C / KEY0 $FF4C not decoded as registers** — behavior is derived
  from header/`cgb_native` instead; diverges only for readback or a custom
  boot ROM. Acknowledged `gb.nim:3518-3520`.
- **$FEA0-$FEFF while OAM blocked should read $FF** (and on DMG should
  corrupt); dingbat answers the per-revision idle model in every mode.
  Self-documented `memory.nim:329-352`.
- **PC executing inside OAM never triggers the corruption bug** — hottest
  interpreter path, no ROM or title reaches it. Self-documented
  `ppu.nim:590-593`.
- **SCY sampled per bitplane on every CGB revision** — correct for pre-CGB-D;
  CGB-D+ unify the two reads. Latent inconsistency with the tree's daid
  calibration explicitly targeting `--cgb-rev=D`. `fifo_ppu.nim:1468-1471`.
- **Serial: no per-bit SB blend on a live link, no irregular external
  clocks** — byte-duplex driver contract, extensively documented
  (`serial.nim:21-39`); disconnect 20 µs pull-up ramp unmodeled.
- **CH4 all-DACs-off disconnect** — hardware outputs hard 0 and holds the HPF
  charge; dingbat drains a decay tail. Sub-audible. `apu.nim:335-346`.
- **SGB/SGB1 clock (+2.41%) and SGB1 APU pitch** — runs at handheld speed,
  documented `sgb.nim:22-23`.
- **SGB PCT_TRN 29th tilemap row** ($700-$73F) not rendered — TV-edge
  cosmetic. `sgb.nim:306-308`.
- **Camera: interrupted capture leaves a complete new image** where hardware
  holds a partial one — documented, matches Pan Docs' own sample code.
  `mbc/camera.nim:83-91`.
- **Web frontend attaches the printer in SGB1 sessions** — SGB1 has no link
  port. `dingbat_wasm.nim:860-861`. Negligible.

## Tier C — dingbat deliberately disagrees, evidence on dingbat's side
(candidate Pan Docs corrections / known doc drift)

- **Speed-switch stall**: 131072 destination-clock cycles (gambatte
  `speedchange_tima00_*` +128 TIMA ticks, SameBoy's 0x20008, daid frames) vs
  Pan Docs' 2050 M-cycles — ~16× short. And the timer/serial/OAM-DMA domain
  *runs* through the stall ("DIV does not tick" describes the true-STOP
  leaves). `memory.nim:859-1069,1171-1203`.
- **IF bit clears at the END of dispatch** (T∈(15,19], gambatte
  `*_late_retrigger` families), not step 1. `cpu.nim:108-166`. Dispatch
  M-cycle order (pushes first vs waits first) remains suite-undecidable;
  Pan Docs' SonoSooS order is plausibly right — flashcart-able.
- **MBC3 RTC latch fires on ANY $6000 write** (CasualPokePlayer capture
  51/51 vs 28/51 for the $00→$01 edge rule Pan Docs describes).
  `mbc3.nim:72-93`.
- **HDMA5 early-termination readback**: the terminating write's own low bits
  land in the register (SameSuite `dma/hdma_lcd_off`); Pan Docs'
  "remaining blocks minus 1" only holds when software rewrites the count.
  `ppu.nim:1904`.
- **PPU reads the DMA unit's bus byte during OAM DMA, not $FF** — Hacktix
  `strikethrough.gb` pixel-exact. The mode-2 scan lock is the separate,
  known-open hwprobe row 18. `fifo_ppu.nim:1819-1945`.
- **DMG STAT-write glitch excludes mode 2** (GBMicrotest
  `stat_write_glitch_l0_c/l1_d/l154_c`; −11 gambatte to put it back).
  Pan Docs' "OAM scan" listing is at least imprecise. `ppu.nim:1602-1619`.
- **OAM writes admitted in mode 2's last M-cycle** (mooneye
  `lcdon_write_timing-GS`, GBMicrotest `oam_write_l1_c`). `ppu.nim:504-539`.
- **X=0 object penalty is a flat 11 dots** — Pan Docs contradicts itself
  (Rendering.md flat-11 vs pixel_fifo.md SCX-dependent); GBMicrotest
  `ppu_spritex_vs_scx` (153/153 cells) settles it for Rendering.md.
  `fifo_ppu.nim:1679-1697`.
- **TMA-write-during-reload propagates the NEW value** — Pan Docs' Timer
  page says old, its own Obscure page + mooneye `tma_write_reloading` say
  new. Internal Pan Docs contradiction. `timer.nim:227-229`.
- **Envelope "zombie mode"**: Pan Docs' rule is one-third of the SameSuite
  `channel_1_volume`/`nrx2_glitch` truth table dingbat ships.
  `abstract_channels.nim:206-250`.
- **Sweep trigger actions are NOT immediate** (3/9/7 M-cycle delays, NR10
  re-read at check time — SameSuite `channel_1_sweep_restart*`).
  `channel1.nim:24-130`.
- **CH3 sample buffer also clears on NR30 DAC-off** (SameSuite
  `channel_3_restart_stop_delay`) — Pan Docs names only APU power-on.
  `channel3.nim:107-119`.
- **CGB-visible-in-compat registers**: VBK reads $FE|bank and
  FF72/73/75/PCM12/34 answer in DMG-compat mode (mooneye
  `unused_hwio-C`) — Pan Docs' "$FF in Non-CGB Mode" footnote overreaches.
  `ppu.nim:2200`, `memory.nim:411-441`.
- **Printer status bit 2 is print-done, not "image data full"** (cross-checked
  vs SameBoy + Hello Kitty / Camera Gold on real carts). `printer.nim:163-168`.
- **MMM01 RAM-bank-high is bits 2-3** — Pan Docs' own diagrams agree; its
  heading ("Bits 1-2") is a typo. `mmm01.nim:145-149`.
- **DMG STOP-with-LCD leaves white** (daid `stop_instr.gb` reference frame),
  not a "horizontal black line" — analog panel decay a framebuffer can't
  show. `memory.nim:1225-1252`.
- **Compat colorization ships one fallback palette** — the per-title table is
  boot-ROM data dingbat deliberately doesn't lift. `gb.nim:3637-3661`.
- **"CPU can access only HRAM during OAM DMA"** — Pan Docs' simplification;
  dingbat's per-bus conflict model (314 gambatte `oamdma/busy*` rows, 0
  mismatches) is the hardware truth. `memory.nim:452-716`.
- Stale Pan Docs paraphrases in comments: `fifo_ppu.nim:987,4132` still call
  WX=0 / WX<7 "unreliable" — current Window.md documents both concretely
  (and dingbat implements the current text).

## Tier D — whole subsystems absent (one line each)

- 4-Player Adapter (DMG-07): no ping/transmission model; degrades as
  "not plugged in".
- SNES-side SGB commands (SOUND/SOU_TRN, OBJ_TRN, DATA_SND/TRN/JUMP,
  ATRC_EN/TEST_EN/PAL_PRI): accepted and dropped, `sgb.nim:376`. SOUND is
  audible on hardware, OBJ_TRN visible.
- Mappers: M161, EMS multicart, Wisdom Tree (>32 KiB images break), Bung
  detection — all "proposal"-status pages. HuC3 tone generator + MCU busy
  window deliberately instant/silent (`huc3.nim:28-36,98`).
- Header logo/checksum lockup: not enforced without a user boot ROM
  (standard emulator convenience).

## Suggested next actions

Quick wins, low risk: A4 (NR43 freeze), A16 (MBC5 nibble), A17 (2 KiB RAM
wrap), A1 (scanline sprite order — needs screenshot-gate re-baseline), A15
(boot B/F/HL), A14 (P1/SC seeds — re-derive from mooneye boot_hwio first).
Suite-checkable: A5/A6 (timer) against gambatte tima + GBMicrotest; A13
against gambatte `sprites/enable/*_cgb`; A3 (CRAM lock) — write a
micro-ROM. Needs the flashcart: A6's cycle-B observables, A12, dispatch
push order, hwprobe rows 18/19. Bigger lifts: A2 (MBC30 + a JP Crystal
image to verify), A19 (SGB 2P input routing), A20 (SGB freeze-on-LCD-off),
A22 (printer timeout).
