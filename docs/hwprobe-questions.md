# hwprobe-questions: what dingbat assumes without hardware evidence

The catalogue of hardware questions the test suites cannot settle. Each row
names what the code assumes and where, which probe ROM measures it, and what a
hardware answer would move. Probe column: **[pNN]** = a `gbedge`/`gbaedge`
page (docs/hwprobe.md); **tools/gbprobe/\*** = a standalone probe cart;
**visual** = needs a photographed frame; **analog** = scope/audio capture;
**open** = no probe yet. Hardware results to date: AGS-101 sessions
(`tests/roms/expected/agb-sp-{1..4}.txt`), MGB + GBA SP GB-slot session
(`tests/roms/expected/gb-mgb-1.txt`, `gb-agbsp-1.txt`), photos in
`hwphotos/` (docs/flashcart-runbook.md).

Why this list exists: the GB core carries ~58 `{.intdefine.}` knobs, most
bracketed by test-suite expectations, which inherit whatever the suite's author
measured; several knobs' own comments admit a plateau midpoint or a
single-oracle fit. The GBA timing constants are calibrated against the mGBA
suite, and the HLE BIOS body costs against real-BIOS execution *in dingbat*,
i.e. against the same bus model.

## GB — CPU-visible, probe built

| # | question | code | probe | status |
|---|---|---|---|---|
| 1 | Does the CGB `$D000` window bank under SVBK, or does SVBK=2 alias bank 0? 64 gambatte `oamdma` rows assert the alias; two banking ROMs deny it | `memory.nim` SVBK | **[p18 CGBWRAM]** byte 0A = 77 alias, 5C banking | **AGS: 5C — it banks** (banks 2–7 distinct, SVBK 0→1 alias only). CGB arm unrun |
| 2 | Halt-woken handler vs timed sled across the same mode-0 edge: GBMicrotest (TIMA oracle) and mooneye (LY oracle) place it on opposite sides | `STAT_M2_LEAD`, `M3_PIPE_AHEAD` (ship OFF) | **[p16 HALTPHASE]** both shapes, 1 M-cycle grids, SCX 0 and 3 | photographed MGB + AGS, not decoded |
| 3 | Does the mode-1 STAT source assert on entering vblank, and in what order against the vblank IF bit? (42 gambatte `m1` rows) | `ppu.nim` STAT sources | **[p15 M1STAT]** IF bits 0+1 in one byte at 4-dot resolution | **hardware (MGB and AGS identical, CRC F5C8): byte 08 = E0, byte 1B = E2; dingbat E3 / E3** — the model is not yet changed |
| 4 | Where do DMG and CGB sample WY, and why does CGB sample it earlier (the only backwards CGB latency)? `late_wy_*`: 13/14 families expect different values per device | `gb.nim` WY notes ("a negative latency is not expressible here") | **[p17 WYLATCH]** the k-transition per device is the sample dot | photographed MGB + AGS, not decoded |
| 5 | `HALT_IF_SAMPLE_T`: the halted CPU samples IF at T=2 or T=4 (tree ships 4 on one mooneye row + perf) | `cpu.nim` | **[p16 HALTPHASE]** | as row 2 |
| 6 | `STAT_READ_SAMPLE` at both speeds: the cc−2 constant and the double-speed "+1" half-dot phase | `gb.nim`, `ppu.nim` STAT read | **[p08 STATSEQ + p13 DSTAT]** | photographed; DSTAT ran for real on the SP; not decoded |
| 7 | Serial tap DMG=4 / CGB=2, pinned only by the gambatte serial plateau, entangled with the boot DIV seed | `serial.nim` | **[p06 SERIAL]** | **Closed 2026-09-01:** all 8 scored bytes identical on MGB (64 FF 63 46 0F FF FE 5A) and AGS (64 FF 03 46 0F FD FC 5A); byte 00 pins the half-rate toggle, 02 the CGB fast tap, 03 the DIV-reset interplay |
| 8 | Boot DIV seeds are sweep-window centres; the SGB seed is a line through two points | `timer.nim` | **[p00 IDENT]** | MGB page matches dingbat; AGS values recorded (DIV $1F, LY $91, STAT $81); SGB/DMG0 unrun |
| 9 | Boot LCD phases: DMG0's 624 is the midpoint of a 168-dot window; CGB's 161 borrows the DMG sub-M-cycle argument | `ppu.nim` | **[p00/p0A LCDON]** | DMG0 hardware unavailable |
| 10 | The 2-dot CPU↔PPU grid residual: line 0, line 1 and steady state disagree; `LCD_ON_LINE0_TRIM=2` / `LINE1_TRIM=-2` fit but nothing derives them | `gb.nim`, `fifo_ppu.nim` | **run on AGS 2026-09-04** — probe_k_lcdon: lines 0 and 1 exactly as modelled; the line-40 read lands 4–6 dots earlier than dingbat with a 2-per-row slope the page cannot produce, so the trims are not the answer; re-shoot with a `DBASE` sweep (docs/flashcart-runbook.md) | |
| 11 | `IRQ_SAMPLE_T=16` (bracketed 15<T≤19) and the dispatch push order | `cpu.nim` | **[p05 IEPUSH]** | **matches hardware byte-for-byte on MGB and AGS**; push order still needs a swept page |
| 12 | OAM bug on the first line after LCD-on: corrupts or not (no blargg row) | `ppu.nim` `oam_bug_if` | **[p0E OAMCORRUPT]**; add an LCD-on-line-0 run | |
| 13 | Where GDMA leaves the PPU (`GDMA_SETUP_MCYCLES=0` "no value works"; residual tracks SCX) | `gb.nim` | **[p11 HDMA]** coarse; needs an SCX sweep | |
| 14 | Noise divisor codes 5–7, sweep-delay split, wave access window | `apu/abstract_channels.nim`, `channel1.nim`, `channel3.nim` | **built, unrun** — gbedge pages 1B–20 (CH2PHASE, SWPPHASE, NOISEWAVE, ENVPHASE, NR10PACE, SEQRESET; tests/roms/gbedge_apu_notes.md) | |
| 15 | PCM12 sample position (SameSuite ch1/2 per-revision leftovers; PCM12 read glitch on CGB ≤ C) | `docs/samesuite-apu.md` | **[p12 PCMPSG]** | run on CGB-C vs CGB-E vs AGB; AGS captured |
| 16 | Is the second sweep overflow check (AGS `gbaedge` SWEEPQ/SWEEP2: linear `shadow + 2·(shadow>>s)`, kills strictly above $800) present in the GB-slot APU? Porting it to the GB core fails blargg `dmg_sound`/`cgb_sound` 04/05/06 and SameSuite `channel_1_sweep*` | `gb/apu/channel1.nim` (`do_check` comment); `gba/apu/channel1.nim` keeps it | **[p1A SWEEP]** | **closed: AGS GB-slot page byte-identical to MGB — no second check**; AGB-native only |
| 17 | **strikethrough's LY-68 frame draws OAM entry 39 although an OAM DMA covers that line's mode 2.** `CGB_HALT_PPU_LEAD=1` and `OAM_SCAN_DMA_LOCK=1` (+57–75 gambatte rows between them) each break those 7 px on both devices; every narrower lock fails too. Either the bundled reference is not what silicon draws, or the scan reads OAM mid-DMA | `fifo_ppu.nim` `OAM_SCAN_DMA_LOCK`, `CGB_HALT_PPU_LEAD` | **built, unrun** — tools/gbprobe probe_i_oamdma (entries 0 and 39 under an OAM DMA covering line 67's scan); the bundle ROM photo at LY 68 remains a cross-check | | **AGS 2026-09-04: probe_i_oamdma pixel-exact, the strikethrough reference and `OAM_SCAN_DMA_LOCK` stand.**
| 18 | **Window insertion glitch (Pan Docs "Window"; Star Trek 25th Anniversary).** dingbat gates `WIN_EN_HOLD_ZERO` on `window_trigger` (WY match seen while LCDC.5 set) because an ungated version whites out x = 0 of Pokemon Blue. Open axes: (a) the arming condition — full activation, WY-match-while-enabled latch, or Pan Docs' enable-free Y condition (silicon refutes the last: Pokemon Blue); (b) insert (rest of line shifted right; nitro2k01: "the rest of the line is delayed") vs replace (mealybug reads back unshifted either side; dingbat replaces); (c) does CGB glitch at all; (d) WX = 7 on the line's first push with the latch armed, `(WX&7) == 7−(SCX&7)` — no ROM pins that phase | `window_refuse_start` / `WIN_EN_HOLD_ZERO` (`gb.nim`); `window_trigger` set sites in `ppu.nim` | **built, unrun** — tools/gbprobe probe_k_winglitch_{a0,a1,a2,scx} (arming × WX × SCX; insert vs replace; CGB); nitro2k01's windesync ROM + photo remains a cross-check | flashcart-runbook folder 2 | **AGS 2026-09-04: no glitch on any of the four winglitch pages; the arming/insert/phase questions are DMG-only now.**
| 19 | **Window latch vs LCDC.5 (AGS 2026-09-04, probe_g_wy1).** Setting LCDC.5 mid-line on the line after WY matched starts **no window for the rest of the frame** on hardware; dingbat draws one from that line on every model (probe_g_wy0, the WY-match-with-LCDC.5-set case, is exact). The per-line WY == LY latch must itself require LCDC.5 set at the match, not just the store-time re-check | `ppu.nim` window latch, `window_trigger` | probe_g_wy1 | **landed on audit**: one latch, taken only with LCDC.5 set (mode-2 match and the LCDC.5-on store re-check); probe_g_wy1 now predicts no window on all four models; runner, gambatte and the 261-ROM shootout unchanged. DMG/CGB photos still pending |

Other MGB-vs-dingbat deltas from the same session, undecoded: **P0F UNUSED**
bytes 1C/1D read 50 (dingbat 51); **P19 DIVTAPS** bytes 08/09 read 88 00
(dingbat 00 20), identical on AGS. Model splits captured on AGS and awaiting
decode: P02 TIMAGLITCH bytes 10–13 (the CGB TAC-disable family — decoded
2026-09-01: bytes 00–0F identical on MGB and AGS; AGS bytes 11–12, the TAC
$05→$06 switch glitch, read 02 02 where the model gives 01 01, open), P0B STATWBUG
(DMG-only glitch absent), P0D OAMDMA, P0F (`$FEA0` echo `AA..FF`), P10
VRAMLOCK, P13/P14 double-speed pages. AGS IDENT port bytes: SC = $7C, SVBK =
$F8, RP = $3E, VBK $FE, KEY1 $7E, FF75 $8F, OPRI $FE. **P1 = $CF on that page
is flashcart-menu contamination, not boot-ROM output** (docs/flashcart-runbook.md).

## GB — the CGB phase constants (g-series)

Each rests on one ROM, one comparison, or a plateau midpoint; suite agreement
is not evidence.

| # | constant | rests on | ROM that settles it | status |
|---|---|---|---|---|
| g1 | `CGB_HALT_PPU_LEAD` + `CGB_HALT_LEAD_SKIP_LYC0` | daid `ppu_scanline_bgp` + `cgb-acid-hell` (both rebuilt byte-exact; `tools/gbppu/daidsweep.py`): the advance is present on a normal-line LYC wake and absent on the LY 153→0 snapback | `tools/gbprobe/g1_scx0.gb`, `g1_scx4.gb` (probe (e), anchor line 16, objects off; read with `read_g1.sh`) | **shot on GBA SP: dingbat 2 M out with the lead off, 4 M with it on** — the numbers and what is known about the 2 M are in `docs/flashcart-runbook.md`, "g1, GBA SP"; the lead stays shipped (acid-hell and daid are exact only with it, and an instrument 2 M wrong cannot arbitrate a 1 M answer) |
| g2 | the same, by STAT source | suite only (`CGB_HALT_LEAD_LYC_ONLY=1` loses gambatte rows) | probe (e) with the anchor's STAT source as a second parameter | needs a 3-line ROM edit |
| g3 | `OBJ_DMA_BUS_LEAD` (+ its halt-lead term) | `strikethrough` alone | a ROM arming OAM DMA N M-cycles after a halt wake with an object over the transfer | open |
| g4 | `HDMA_VISIBLE_DOTS` (+ lead term) | gambatte `dma`, bracketed 4/8/12; the `hdma_late_disable_*` residue is `docs/gb-failure-triage.md` D1 | HDMA one block per line, disable write swept in M-cycles, read back the destination | open |
| g5 | `CGB_TDSEL_LATENCY` / `CGB_TDSEL_IDX_DOTS` | the 8..15-dot window is populated by `cgb-acid-hell` alone | `tools/gbprobe/probe_d_tdsel_*` toggles LCDC.4; add a second toggle at a settable distance | probe built, needs the second toggle | AGS 2026-09-04: probe_h_lcdc4 confirms `CGB_TDSEL_LATENCY = 1`.
| g6 | `STAT_M0_FIELD_TAIL` + `STAT_M0_TAIL_MAX_MC` | read idiom and suite are perfectly confounded in every existing ROM | `tools/gbprobe/probe_a_statidiom.gb` — **built, unrun on a DMG** (the SP arm only checks the CGB-side zero) | built, unrun |
| g7 | `CGB_SCY_LATENCY` / `CGB_SCX_LATENCY` / `CGB_OBJ_SIZE_LATENCY` / `CGB_MIXER_LATENCY` | mealybug `_cgb_c` captures — one revision of one console | a paged ROM writing each register at a swept dot, one page per register | **AGS 2026-09-04 (probe_h pages):** SCX 2 and map 2 confirmed; **SCY behaves as CGB-D/E (`scy_fetch_latch`, AGB added on audit), WX latency is 1 not 0**; mixer/BGP needs the compat-flag cart; OBJ size untested |

Revision note: `cgb-acid-hell`, mealybug and their `expected/` images share one
author. The `_cgb_c`/`_cgb_d` pairs that differ are the only revision axis on
disk; `m3_scy_change` (6217 px) is the one dingbat does not switch on
(docs/gb-mealybug-sources.md, SCY).

## GB — pixel-only (needs a visual ROM + photographs)

Every one is currently pinned by one mealybug ROM or one reference PNG.

- **CGB TILE_SEL glitch substitution source** — `cgb-acid-hell`'s mouth pixels
  demand the tile index at a SET transition that 48/48 mealybug `*_change2`
  cells refuse; the distinguishing fact is an 8-dot latch with one stale read.
  A page generating back-to-back glitched fetches at varied staleness over a
  legible tile pattern, photographed on CGB-C and CGB-D/E. The ROM's `$FEA0`
  gate draws different pictures per revision — shoot IDENT first.
- **Window single-oracle cluster** — `WIN_LINE_START_WX=6` (gambatte has
  nothing at WX 4/5/6) and the five 1-px phase knobs read off
  `m3_lcdc_win_en_change_multiple_wx`.
- **`OBJ_ABORT_LEAD=2` / `FLAG_HOLD=1`** — two numbers against two instruments;
  no third ROM separates them from "one instrument is a dot out". Re-cut the
  gambatte geometry with a BGP pulse instead of a STAT read.
- **The `MIXER_*` tail model** — DMG references are the only oracle; the window
  start inside the tail at WX = 166 is invisible to every ROM.
- **`CGB_OBJ_ABORT`** — "no cancel" vs "LCDC.1 arrives 4+ dots later": every
  distinguishing row is double-speed.
- **DMG palette transition pixel** — does a mid-line BGP write emit `old|new`
  for one dot? mealybug photos side with OR at 65–93 % per column; a
  high-contrast close-up settles it, per DMG unit (daid reports unit
  dependence).

## GBA — open after sessions 1–4

Sessions 1–4 on an AGS-001 settled most of the gbaedge catalogue
(docs/hwprobe-results-agb.md). Still open:

| question | what hardware said so far | probe |
|---|---|---|
| IRQ delivery pipeline per source: synchronizer latencies 3 (timer) / 6 (hblank) are one-row fits; DMA3 entry +18, hblank +7/+31, vblank +12/+18 vs dingbat in session 1; handler entry +6 fixed as a gamepak-context cost | IRQLAT, IRQLAT2 | **run 2026-09-04** — gbaedge p40 IRQDECOMP: halted H-blank wake +19 (`HBLANK_IRQ_SYNC_DELAY` 6 → ~25); other halted rows and the ack race exact; running-CPU deltas are sub-instruction, no knob (docs/hwprobe-results-agb.md, session 5) |
| PPU/CPU contention under load (128 OBJs on a line, modes 0/2 with all BGs, hblank-free on/off); dingbat models none and the unloaded CONTEND page matched | CONTEND exact | **run 2026-09-04** — p41 CONTEND2 refutes "none": VRAM +1 per CPU read in mode 0, CPU locked out of VRAM under two affine BGs, OAM zero; plus a 37-cycle VRAM code-fetch undercharge with the renderer off |
| MUL/MLA carry: hardware clears C for operand pairs 0/1/2/5/6/7 with C preset (nibbles `04 00 00 02 0A 04 08 08` vs dingbat `06 02 02 02 0A 06 0A 0A`); UMULL/SMULL rows match | MULFLAGS | **closed 2026-09-04** — p42 MULTIME byte-exact |
| Timer prescaler boot phase (hw staircase `07 07 07 06 06 06` vs dingbat `06 07 07 06 06 07`); is the prescaler one free-running divider shared across timers, does enable reset it; PSG length expiry 14 % early (hw 2E1E vs 283A) and the length-63 trigger-adjacent clock; does SOUNDCNT_X master-off reset the sequencer | TIMERS, PSGSTAT, SWEEPQ | **run 2026-09-04** — p43 TIMPHASE ratifies the shared free-running divider (no change); p44 PSGPHASE: the first trigger after a SOUNDCNT_X power-on dies for any length, ch2 two stores later lives — mechanism open, one more page decides it |
| `0x04000800` reads `0D000020` on hardware; dingbat unimplemented (open bus) | IDENT | **closed 2026-09-04** — p45 MEMCTL: EWRAM wait field is live, `waits = 15 − WS`, 321/289/609 cycles at WS 13/14/4; **landed** in `update_waitcnt` (page matches byte-for-byte) |
| DMA start delay, per-region cost, hblank/vblank trigger instant vs DISPSTAT edges, completion-IRQ vs CPU-resume order | — | **run 2026-09-04** — p46 DMATIME: start delays and five region bursts exact; VRAM burst +21 (contention); completion IRQ +15 to a running CPU only |
| IntrWait/VBlankIntrWait return-path cost and the `0x03007FF8` flag protocol (HLE gaps; real-BIOS path proved exact) | SWITIME | **closed 2026-09-04** — p47 IWCYCLE: immediate return 192 = real BIOS, HLE 160; **landed** (+32 on the no-halt path, row exact). Residual: the handler-to-return rows read 3 short (259 vs 262) and the wake-path constant cannot absorb it (41 costs 70 Timer count-up rows) |
| Halfword-aligned T-clearing `cmp pc`: hardware resumes past both overlay words (A+10 or A+14), dingbat `(A+2)&~3` | THUMBPC3 (a) | **built, unrun** — v7 slot-35 row (c): ladder W+8/W+12/W+16, r4 captured; prediction r4 = `C0DEC0DE`, r6 = 06 or 04 |
| Thumb open-bus halfword composition (`$+4` vs `$+6` by alignment) | — | deferred (THUMBBUS) |
| HLE body costs: Sqrt up to 3× off (hw `00CC/0118/0164/01C3` vs HLE `0106/020B/0368/051C`), CpuFastSet 256 words 450 cycles slow, Sqrt/ArcTan2/BgAffineSet 1–4 cycles in SWITIME | SWITIME, SWIREGION | data in hand; model work |
| OBJ per-line cycle budget 1210/954 and cutoff granularity (dingbat: the exhausting sprite draws fully; hardware truncates) | — | **visual**, or CONTEND2's CPU-visible face |
| Affine reference latch semantics (per-line during vblank vs once at vcount 160) | — | **visual** — mid-frame BG2X write |
| PSG volume-3 mute; GB/GBA output filters, `GB_DC_CHARGE` | — | **analog** |
| Near-BX encoding `0xE120FF11` (SBO violated) wedges the console with IRQs masked; `0xE12FFF31` executes as BX | BXDECODE | dingbat takes `E120FF11` as BX and falls through `E12FFF31` — both wrong; no further probe, model decision |

Zero-code item: run the same gbaedge build on every other GBA-family console
(AGB-001, micro, DS/DS Lite in GBA mode). Page 0's `ALL` CRC reports whether
any probe differs across silicon; MODEL separates BIOS families (DS reads
`18 80`).

## Probe ROMs written, awaiting hardware

Each closes a row that docs/oracles.md marks `Assumed`, or a disagreement
found while decoding the session 1–2 captures. All but the first two rows
were written on 2026-09-03 with dingbat's prediction beside each ROM; the
kit and its READMEs are listed in docs/flashcart-runbook.md "Session 3 kit".

| ROM / page | Rig | Answers |
|---|---|---|
| gbedge p02 re-shoot on AGS and on a CGB | GB flashcart | bytes 11–12 (TAC $05→$06 switch glitch) read 02 02 on AGS where the model gives 01 01 — confirms or refutes the model's CGB reload window (`timer.nim` timer_check_edge) |
| gbedge full run on a GBC (unrun) | GB flashcart | the CGB-C vs CGB-D splits (`GbQuirks.lyc_compare_hold`, `ly_read_edge_late`) that today rest on per-revision comparison runs; the CGB side of the timer reload |
| gbvis page: LCDC.5 turned on mid-line on the WY line | GB flashcart, photograph | whether the window re-checks WY on the LCDC write (`ppu.nim` ppu_store_lcdc, Assumed; disabling it changes no verdict) |
| gbvis pages: one register per page (SCX, SCY, WX, BGP, LCDC) written at a known dot | GB flashcart, photograph | the per-register CGB write latencies (`memory.nim`, six independent numbers Assumed; hwprobe row 4's WY LATCH photos are the first of these, undecoded) |
| gbaedge page: OBJ line budget exhausted mid-sprite | GBA flashcart | whether the sprite that exhausts the per-line budget draws fully or truncates (`gba/ppu.nim` render_sprites) |
| gbaedge page: 8×8 OBJ at X 448..511 and Y 160..255; a multi-tile 8bpp OBJ named tile 1023 | GBA flashcart | the signed-coordinate thresholds and OBJ VRAM wrap (`obj_geometry`, `render_sprites`) |
| gbaedge page: open-bus reads by the DMA itself and by instructions 1–3 after a burst | GBA flashcart | how long the last DMA word stays on the bus (`bus.nim` read_open_bus_value; window Assumed) |
| line-out capture: PSG volume 3 vs 2; SOUNDBIAS resolutions 0–3 on a full-scale tone | GBA + audio capture | whether volume 3 mutes; the DAC resolution mask depth (`gba/apu.nim`) |
| multiboot probe (sender ROM on the flashcart GBA, link cable to a GBA holding the retail cart): TM0-timed busy poll after an EEPROM block write | retail 64k-EEPROM cart (e.g. Super Mario Advance 2) | the write-settle time (`storage/eeprom.nim`, 108368 cycles from GBATEK) |
| multiboot probe: tilt status bit poll count; gyro bit order per clock edge | Yoshi Topsy-Turvy; WarioWare Twisted | `bus.nim` tilt_read always-ready; `gpio.nim` gyro edge |
| multiboot probe: read $08100000 / $08400000 | a Classic NES Series cart | the ROM mirror window (`cartridge.nim`) |
| playtest only | Kirby Tilt 'n' Tumble on a CGB | MBC7 idle accelerometer value and .sav order (`mbc/mbc7.nim`) — no code path can read it back |

## Un-probeable or not worth it

- `GB_DC_CHARGE` / mix scale / output filters: analog capture only.
- ROM-past-end open bus (GBA) and `$FEA0-$FEFF` on a flashcart: the cart
  answers, not the console.
- TAMA5 `0x46/0x47` readback: needs the real mapper cart.
- MBC questions of any kind on a flashcart (MBC5 `$1A` enable, MBC3 latch,
  MBC30): the flashcart's FPGA answers.
- bully's residual: a per-check readout harness, not silicon.

## Method notes

- Rebuild a published test ROM byte-exact (verify the md5; pre-0.6 rgbds
  spellings, and a `nop` after every `halt` that old rgbasm inserted) before
  sweeping one parameter of it — a model error and a phase error look
  identical on the shipped ROM and separate the moment the parameter moves.
- Boot-handoff *port* bytes read through a flashcart menu are not evidence
  (docs/flashcart-runbook.md).
- Probe ROMs drawn on black cannot be registered by `photowarp.py`; give them
  corner marks.
