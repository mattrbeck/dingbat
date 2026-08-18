# hwprobe-questions: what dingbat assumes without hardware evidence

**Date:** 2026-08-10.  The research catalog behind the hwprobe v2 pages —
a full audit of derived constants and unfounded assumptions across
`src/dingbat/gb/` and `src/dingbat/gba/`, cross-referenced against
`docs/gb-failure-triage.md`'s buckets and the shootout status.  Each entry
says what the code assumes, where, what silicon measurement would replace
the assumption, and what it pays.  Probe column: **[built pNN]** = a
gbedge/gbaedge page already measures it; **visual** = needs a photographed
frame; **analog** = needs a scope/audio capture; **open** = no probe yet.

The structural finding first: the GB core carries **58 `intdefine` knobs**
(declared in `gb.nim` with the derivation in the comment, used elsewhere).
Most ship with a two-sided ROM bracket, which is honest — but a bracket
made of *test-suite expectations* inherits any error those suites baked
in, and several knobs' own comments admit a plateau midpoint, a
single-oracle fit, or another emulator as the tiebreak.  The GBA side is
worse: nearly every timing constant is calibrated against the mGBA suite,
and the HLE BIOS body costs are "verified against real-BIOS execution *in
dingbat*" — i.e. against the same bus model they run on.  Silicon
measurements are the only way off that circle.

## Tier 0 — worth flashing a cart for TODAY (biggest row payoff)

| # | question | code / trigger | probe | pays |
|---|---|---|---|---|
| 1 | Does the CGB `$D000` window really bank, or does SVBK=2 alias it onto bank 0? 64 gambatte oamdma rows *assert* the alias; two banking ROMs deny it | triage bucket 16, verbatim "**Declined pending hardware**: dump WRAM on a real CGB after `LDH ($70),$02`" | **[built p18 CGBWRAM]** — byte 0A = 77 means alias, 5C means banking | 64 rows, or their removal from the denominator |
| 2 | The halt-vs-sled contradiction: GBMicrotest (TIMA oracle) and mooneye (LY oracle) place a halt-woken handler on opposite sides of the same mode-0 boundary | bucket 24; gates `STAT_M2_LEAD`/`M3_PIPE_AHEAD` (built, ships OFF), worth ~+21 runner rows composed | **[built p16 HALTPHASE]** — both shapes, both oracles, 1 M-cycle grids | ~21 runner rows + un-ships two refused knobs |
| 3 | Does the mode-1 STAT source assert at all on entering vblank, and in what order against the vblank IF bit? | bucket 18 (42 `m1` rows are *value* failures); also gates the last 2 rows of bucket 4 | **[built p15 M1STAT]** — both IF bits in one byte, 4-dot resolution | 42-44 rows |
| 4 | Where exactly do DMG and CGB sample WY — and why does CGB sample it *earlier* (the only backwards CGB latency)? | `late_wy_*`: 13/14 families expect different values per device; dingbat models no split (`gb.nim:508-537` admits "a negative latency is not expressible here") | **[built p17 WYLATCH]** — the k-transition per device IS the sample dot; DMG-vs-CGB delta is the split | ~26 late_wy rows + 51-row WY-LATCH sub-bucket |
| 5 | `HALT_IF_SAMPLE_T`: the halted CPU samples IF at T=2 (measured) but the tree ships T=4 (one mooneye row + perf) | `cpu.nim:355` "4 is … what this tree ships … 2 is the measurement" | **[built p16 HALTPHASE]** (same page as #2) | +21 whole-runner rows if 2 confirms |
| 6 | ~~Speed-switch stall~~ **RESOLVED IN EMULATION 2026-08-13, superseded by #18.** The PPU re-alignment is TWO constants, derived from the switch-count ladder to a 0.4-dot residual: +8 dots into double, +3 back into single (`SPEED_SWITCH_PPU_EXTRA_DOTS*`, `memory.nim`). The model ships OFF because daid's halt-prefixed rows pin *halt-lead + switch-extra* = 12 and the ladder pins switch-extra = 8, so the 4-dot difference IS `CGB_HALT_PPU_LEAD` — the whole bucket lands (+41 gambatte net) the day #18 arbitrates the lead. What a probe can still add: nothing about the stall itself; the open silicon question moved to #18 | bucket 13 (closed as a model); `memory.nim` derivation comment | **[built p14 SPEED]** now confirmatory only | folded into #18 |
| 7 | `STAT_READ_SAMPLE` at both speeds — the cc-2 constant, and the double-speed "+1" that is admittedly a parked half-dot phase error | `gb.nim:49/52`, `ppu.nim:729-800`; bucket 15's residue | **[built p08 STATSEQ + p13 DSTAT]** | closes the half-dot question; ~13 SCX-residue rows |
| 19 | **The window insertion glitch's three open axes** (the Star Trek 25th Anniversary glitch — Pan Docs "Window", SameBoy issue #278). Found 2026-08-14 when `WIN_EN_HOLD_ZERO` (ea96ed1, ungated) whited out x = 0 of every Pokemon Blue frame; now gated on `window_trigger_en` (WY match seen while LCDC.5 set — SameBoy/DocBoy's frame latch), which mealybug cannot check because its ruler always arms the latch. To validate on the flashcart: (a) **the gate** — nitro2k01's SGB traces say the glitch needs the window "activated once", but is the arming condition his full WY/WX *activation*, the WY-match-while-enabled *latch* SameBoy/DocBoy ship (what dingbat now models), or Pan Docs' enable-free Y condition (which would put the white line back in Pokemon Blue — silicon already refutes this one)? A DMG/CGB run of nitro2k01's windesync ROM with the window never enabled, vs enabled-once-then-disabled, separates all three. (b) **insert vs replace** — SameBoy/DocBoy push the colour-0 pixel alone into the empty FIFO and shift the rest of the line right one px (nitro2k01: "the rest of the line is delayed"); dingbat REPLACES because the mealybug reference reads back unshifted either side. Photograph a glitch line against a checkered BG: shifted tail = insert, clean tail = replace; also does mode 3 stretch a dot? (c) **the device axis** — SameBoy is DMG-only, DocBoy says CGB glitches too but only mid-window-fetch, dingbat gates only by the shared hold path. Also worth firing at WX = 7 on the line's FIRST push with the latch armed (window enabled on some earlier line, disabled, WY still matching) — the alignment condition `(WX&7)==7-(SCX&7)` covers x = 0 and no test ROM pins that phase | `fifo_ppu.nim` `window_refuse_start` / `WIN_EN_HOLD_ZERO` (gb.nim); `window_trigger_en` set sites in ppu.nim | **open** — nitro2k01's windesync ROM (SameBoy issue #278 attachments) + a photo; a v3 gbvis page could sweep WX×SCX×arming | keeps the ruler's 2 px honest; protects every WX=7-parked DMG game (Pokemon R/B at minimum) |
| 18 | **The strikethrough arbitration — now the single highest-leverage silicon question on the GB side.** Three built-and-refused mechanisms all die on ONE observable: strikethrough's LY-68 frame draws OAM entry 39 even though an OAM DMA covers that line's entire mode 2. `CGB_HALT_PPU_LEAD=1` (gates bucket 14's pair AND the whole speed-switch model of #6: +41 gambatte) breaks it by 7 px; `OAM_SCAN_DMA_LOCK=1` (+16 gambatte, edges pinned by two independent derivations) breaks the same 7 px on BOTH devices; every narrower lock duration was measured and also fails. Either the bundled reference is not what silicon draws, or the scan really can read OAM mid-DMA (and the lock model is wrong in kind). Probe: run strikethrough on real DMG + CGB and photograph LY 68 (entry 39, screen x 71..78 — the 7-px bbox), or a v3 gbvis page that arms one on-line object at entry 39 and starts an OAM DMA covering mode 2 | `fifo_ppu.nim` `OAM_SCAN_DMA_LOCK` + `CGB_HALT_PPU_LEAD` notes; triage bucket 13/19/22 (2026-08-13 sections) | **open — v3 gbvis candidate**, or a plain photo of the ROM the bundle already ships | 57-75 gambatte rows + un-ships three refused knobs |

## Tier 1 — CPU-visible, probes built, run when convenient

| # | question | code | probe |
|---|---|---|---|
| 8 | Serial tap: DMG=4/CGB=2 is "pinned empirically … (the gambatte serial suite's plateau)", entangled with the boot DIV seed | `serial.nim:83-91` | **[built p06 SERIAL]** (DIV-reset-mid-transfer sub-test); an explicit phase-sweep page is a worthy v3 addition |
| 9 | Boot DIV seeds: sweep centres of ~4-wide windows; the SGB seed is a linear model through TWO data points | `timer.nim:8-40` | **[built p00 IDENT]** byte 0A per model |
| 10 | Boot LCD phases: DMG0's 624 is the midpoint of a **168-dot-wide window**; CGB's 161 borrows the DMG sub-M-cycle argument by assumption | `ppu.nim:11/15/283-285` | **[built p00/p0A]** — LCDON + IDENT anchor them; run on DMG0 hardware if available |
| 11 | The 2-dot CPU↔PPU grid residual: line 0 vs line 1 vs steady state disagree; `LCD_ON_LINE0_TRIM=2/LINE1_TRIM=-2` fits +33/−5 but "nothing derives it" | `gb.nim:1315-1360`, `fifo_ppu.nim:1660-1681` | **[built p0A LCDON]** partially; **open**: an H-Blank-IRQ count-at-N-lines-after-enable page would separate the three carriers |
| 12 | `IRQ_SAMPLE_T=16` (bracketed 15<T≤19, boundary chosen) and the dispatch push order that "scores the same but trades differently" | `cpu.nim:85/143` | **[built p05 IEPUSH]** partially (records IF disposition); a swept re-request page is v3 material |
| 13 | OAM-bug first-line-after-LCD-on: corrupts or not — "NOT established by any of blargg's rows … follows the lock rather than guessing" | `ppu.nim:658` | **[built p0E OAMCORRUPT]** — add an LCD-on-line-0 run in v3 |
| 14 | GDMA leaves the PPU where? (`GDMA_SETUP_MCYCLES=0` "records that no value works"; residual tracks SCX) | `gb.nim:93` | **[built p11 HDMA]** coarse; the SCX-dependence needs a v3 sweep |
| 15 | Noise divisor codes 5-7, sweep-delay split, wave access window | `apu/abstract_channels.nim:131`, `channel1.nim:24/43`, `channel3.nim:34` | **open** — an APU timing page (NR52/PCM polls) is straightforward v3 |
| 16 | PCM12 sample-position question (SameSuite ch1/2 leftovers are per-revision; PCM12 read glitch on CGB≤C) | notes/samesuite-apu.md | **[built p12 PCMPSG]** — run on CGB-C vs CGB-E vs AGB |
| 17 | **AGB/CGB sweep divergence candidate**: AGS-001 (gbaedge SWEEPQ/SWEEP2) proves a SECOND trigger overflow check — linear shadow+2*(shadow>>s), kills strictly above $800.  Porting it to the GB core (2026-08-11) regressed 8 rows — blargg dmg_sound 04-sweep/05-sweep details/06-overflow on trigger, blargg cgb_sound same three, SameSuite channel_1_sweep, channel_1_sweep_restart — blargg 06 triggers every shift's boundary frequency ($556 s1 … $7E2 s7), each far over the linear second limit, and its DMG+CGB CRCs say those channels LIVE.  So the second check is AGB-only silicon; reverted, divergence documented in channel1.nim's do_check comment | `gb/apu/channel1.nim` ch1_sweep_run; `gba/apu/channel1.nim:138-152` keeps the AGB check | **[built gbedge p1A SWEEP]** — raw-value re-anchor on CGB: freq 1300/940/1024/1000 s1 + divider-0 cap; 0 polls at +0 would overturn the suite verdict, ~$440 confirms it |

## Tier 2 — GBA: the calibration circle

| # | question | code | probe |
|---|---|---|---|
| 17 | Prefetch dead-cycle rule `elapsed mod s == s-1` — fitted per-row to the mGBA CPU column; `docs/prefetch-model-rewrite.md` proves the shape cannot fit the DMA rows | `bus.nim:150-177` | **[built p0C PFPHASE]** — cost-vs-k wobble is the rule |
| 18 | Prefetch buffer: depth 8, linear credit, full-buffer-serves-32-bit-in-1 — three separable unmeasured claims | `bus.nim:120-141` | **[built p0C/p0B]** partially; a gap-sweep (off-bus g cycles before an N-fetch run) is the v3 completion |
| 19 | `SWI_HLE_BASE=48` + the "S16−1" refill residual (comment says "against hardware"; the oracle was mGBA-suite columns) | `hle_bios.nim:214-218/388-390` | **[built p03 SWITIME + p0D SWIREGION]** — HLE vs `--bios` vs silicon, per caller region |
| 20 | Every HLE body-cost model is "verified against real-BIOS execution **in dingbat**" — circular through the bus model; Sqrt is a 3-point piecewise fit, `INTRWAIT_TUNE=44` is a rationalized tuned number | `hle_bios.nim:230-244/571-581/194-200` | **[built p0D SWIREGION]** for Sqrt/Div/CpuSet; IntrWait needs an IRQ-context v3 page |
| 21 | MSR T-bit hand-off: "mGBA-verified hardware model" means verified against mGBA; the synthesized Thumb nop at A+4 is a fabrication for PC arithmetic | `arm/arm.nim:311-324` | **[built p08 MSRTBIT]** — dingbat reads r7=04 (resume A+8, skip A+10); silicon answer wanted |
| 22 | MUL/MLA carry left untouched while UMULL/SMULL gets an elaborate Booth model with an uncited `Rs[31:29]==7` special case | `arm/arm.nim:69-117` | **[built p07 MULFLAGS]** |
| 23 | Timer: `TIMER_START_DELAY=2` (no citation), zero-delay recursive cascade, 1-cycle reload window, prescaler phase anchored to emulator cycle 0 | `timer.nim:6-37` | **[built p04 TIMERS]** — the cascade row already looks wrong in dingbat (TM1=0x33, TM0 stuck at reload) |
| 24 | IRQ synchronizer latencies: 3 (timer) vs 6 (hblank, midpoint of an admitted 5-cycle plateau), shared by DMA/keypad without evidence | `interrupts.nim:18-21`, `ppu.nim:72-80` | **[built p0F IRQLAT]** — and dingbat never delivers the TM2-overflow IRQ it arms (reload 0, enable+IRQ one word store): fresh divergence |
| 25 | Open bus: Thumb duplicates the halfword (hardware: region-dependent pair), DMA-latch window "until next instruction boundary" (one game's evidence), page-0 DMA carve-out unexplained | `bus.nim:952-976/502-506` | **[built p01 OPENBUS + p05 DMALATCH]**; add a Thumb-odd-PC read in v3 |
| 26 | OBJ per-line cycle budget 1210/954 + cutoff granularity **copied from mGBA** ("the sprite that exhausts the budget still draws fully" — hardware truncates) | `ppu.nim:540-551` | **open** — sprite-overflow readback page (marker sprite visibility), or visual |
| 27 | Affine reference latched once at vcount 160 and updated immediately on write (hardware: per-line during vblank, latch semantics differ) | `ppu.nim:125-127/1449-1455` | **visual** — mid-frame BG2X write ROM, photograph |
| 28 | No PPU/CPU memory contention modeled at all (PRAM/VRAM/OAM constant cost while rendering) | `bus.nim:3-6` | **[built p0E CONTEND]** — dingbat baseline shows visible == forced-blank exactly, as predicted |
| 29 | GBA APU: frame sequencer free-running vs DIV-tapped, SOUNDBIAS resolution changes depth but not rate, PSG volume-3 mute is an emulator-consensus vote | `apu.nim:19-27/358-360/458-466` | **[built p0A PSGSTAT]** partially; volume-3 needs **analog** |

### The mechanism consolidations (what "getting it for free" looks like)

Three clusters of knobs are plausibly shadows of ONE quantity each; the
probes are designed so a single parameter either explains all their
columns (mechanism found — replace the knobs) or provably cannot
(model shape wrong — stop tuning it):

1. **The sub-M-cycle event grid** — `STAT_READ_SAMPLE`, `HALT_IF_SAMPLE_T`,
   `IRQ_SAMPLE_T`, the serial tap, the half-dot, the 2-dot residual are
   all "at which T-cycle inside an M-cycle does event X happen".  Pages:
   STATSEQ/DSTAT + HALTPHASE + IEPUSH + SERIAL.  One consistent grid
   fitted to all five pages' hardware columns replaces six knobs.
2. **One counter, many taps** — DIV, TIMA mux, serial clock, APU frame
   sequencer.  Page: DIVTAPS (staircase periods ARE the tap bits), plus
   DIVPHASE/TIMAGLITCH.  Replaces the seed/tap constants with bit
   indices off a single modeled counter.
3. **The CGB write-latency table** — per-register constants
   (`CGB_*_LATENCY`) that mealybug's own notes describe as "writes take
   effect 2 T-cycles later" with per-fetcher-stage sampling.  WYLATCH's
   per-device transition-k, plus the visual ROM below, either collapse
   the table into "CGB bus commit is N T-cycles later + each PPU
   register is sampled at fetcher stage S" or prove the per-register
   shape is real.

## Tier 3 — pixel-only: needs a visual ROM + photographs (v3: "gbvis.gb")

These cannot be read back by the CPU; the probe is a paginated *visual*
ROM (one mechanism per page, photograph vs emulator screenshot).  The
single-oracle clusters are the priority — every one is currently pinned by
exactly one mealybug ROM or one reference PNG:

- **The CGB TILE_SEL glitch substitution source** — cgb-acid-hell's last
  2 pixels demand the tile index at a SET transition that 48/48
  `*_change2` cells refuse; the one distinguishing fact is the latch being
  8 dots and one read stale.  H1 ("back-to-back glitched fetches
  substitute the index") is fitted to two pixels with no independent
  confirmation.  A page generating back-to-back glitched fetches at
  varied staleness, over a tile pattern that makes the substituted byte
  legible, photographed on CGB-C *and* CGB-D/E, settles it — and the
  triage doc explicitly prices this "worth it the day a second
  acid-hell-shaped ROM appears."  Note the ROM's own `$FEA0` gate: CGB
  revisions draw different pictures, so shoot page 0's IDENT first.
- **The window single-oracle cluster**: `WIN_LINE_START_WX=6` (gambatte
  has NOTHING at WX 4/5/6 — mealybug's three ROMs are the whole
  evidence), plus the five 1-px phase knobs all read off
  `m3_lcdc_win_en_change_multiple_wx`.
- **`OBJ_ABORT_LEAD=2 / FLAG_HOLD=1`** — "two numbers against two
  instruments, and no third ROM separates it from 'one of the two
  instruments is a dot out'."  The triage names the experiment: the
  gambatte geometry re-cut with a BGP pulse instead of a STAT read.
- **The seven-knob mixer-tail model** (`MIXER_*`) — DMG references are
  the only oracle; the open corner (window start inside the tail at
  WX=166) is invisible to every ROM in the tree.
- **`CGB_OBJ_ABORT`** — "no cancel" vs "LCDC.1 arrives 4+ dots later":
  every distinguishing row is double-speed; a purpose-built visual page
  in double speed can split them.
- **DMG palette transition pixel** — does hardware emit an `old|new`
  pixel on a mid-line BGP write?  The gambatte PNGs carry none; the
  mealybug photos side with OR at 65-93% confidence.  A high-contrast
  visual page photographed close-up would settle it cleanly.
- **`line_0_fix`**: mealybug asserts line 0's mode-2 STAT IRQ is 4
  T-cycles later relative to drawing; dingbat is at dot 101 vs 105 —
  "the cheapest well-evidenced item left" and CPU-visible, actually:
  fold into a v3 STAT page.

## Tier 4 — un-probeable or not worth it

- `GB_DC_CHARGE` / mix scale / output filters (GB and GBA): **analog**
  capture territory; SameBoy-comparable by construction, low risk.
- ROM-past-end open bus (GBA) and `$FEA0-$FEFF` on a flashcart: the cart
  hardware answers, not the console — never cleanly pinnable.
- TAMA5 `0x46/0x47` readback: "nobody has published a capture" — needs
  the actual mapper cart, not a flashcart.
- bully's 420-px residual: needs a per-check readout harness, not silicon.

## Priorities, stated plainly

If only one hardware session happens: flash **gbedge.gb** on one DMG and
every distinct CGB revision available, photograph pages 15-18 plus 00 —
that alone arbitrates buckets 16, 18, 24, the late_wy split, and
HALT_IF_SAMPLE_T: roughly **200 test rows' worth of open questions**, and
three of the tree's most confessed knobs.  The GBA session's PFPHASE /
SWIREGION / MSRTBIT trio breaks the mGBA-calibration circle at its three
most load-bearing points.  The v3 items above (a gbvis.gb visual ROM, the
VRAM-contention timer page, per-source IRQ latency, the LCD-on H-Blank
count page) are the next build, best shaped after the first photo set
shows where silicon actually disagrees.

## v4 SHIPPED — the guessed-at-behavior pages (gbaedge 16-24)

A survey of behaviors GBA emulators visibly guess at rather than measure
(unhandled corners, hedged constants, copied rumors) produced the list
below; each is now a gbaedge page.  Nothing in the field answers these
from hardware — dingbat included — so whatever the photos say is new
data for everyone.

| open question | page |
|---|---|
| which CPSR/SPSR bits are actually writable; is SPSR bit4 forced high; what does mrs SPSR return in a mode with no SPSR | 17 CPSRBITS |
| when are CPSR.I / the IRQ line sampled; IE/IF/IME written in the same cycle an IRQ asserts | 20 IRQWIN |
| does Thumb `CMP r15, rX` load SPSR into CPSR; stored-PC offsets for str/stm/ldm forms | 18 THUMBPC |
| SPSR read in the cycle after an ldm^ — OR'd with CPSR? user-list transfer with a banked base register | 19 LDMUSER |
| MSR that alters the Thumb bit | 8 MSRTBIT (**silicon-answered: resume A+8, skip A+10**) |
| do near-BX encodings execute as BX, fall through, or trap | 24 BXDECODE |
| can a byte write of 0x80 enable a DMA via bus byte-mirroring; disable-while-starting | 21 DMAEDGE |
| does video-capture DMA3 really run only every other frame | 22 CAPDMA |
| write-only/unused IO reads: 0 or open bus, per register | 16 IORW |
| sweep divider 0 / immediate trigger recalc / the unwritten second recalc / mid-note divider change | 23 SWEEPQ |
| Thumb open-bus halfword composition ($+4 vs $+6 by alignment) | deferred (THUMBBUS) |
| SPSR-load scope (full CPSR or flags only?) + hi-reg ADD/MOV pc + r15 writeback | 25 THUMBPC2 (v5) |
| gate windows in cycles + same-cycle IF-ack priority | 26 IRQWIN2 (v5) |
| byte-write mirroring: bus-wide or DMA-specific? | 27 IOBYTE (v5) |
| envelope timer mid-note reload | not CPU-visible on AGB; PCM12/34 makes it a **gbedge** (CGB) item |
| backup-chip (EEPROM/flash/RTC) corner behaviors | unanswerable from a flashcart (the EverDrive emulates those chips) |
| 17-bit VRAM fetch addresses, mid-line OAM remap, mosaic timing | pixel-only — the gbvis visual ROM |

Building these found and fixed a dingbat CPU bug on the spot: Thumb
hi-reg CMP with rd=pc never advanced the PC (thumb.nim step gate) — the
THUMBPC pad hung dingbat until the `op == 0b01` arm was added.  Fresh
dingbat baseline oddities the pages already exposed: CAPDMA fires exactly
one Special-DMA3 trigger ever; CPSRBITS shows dingbat latching CPSR bits
8-27 that ARM7TDMI probably doesn't have; BXDECODE shows the 12-bit
decode LUT ignoring the SBO fields (0xE120FF11 taken as BX) and
0xE12FFF31 routing into the MSR path mid-decode.

## v4 candidates — shaped by AGB hardware session 1 (2026-08-10)

Session 1 (docs/hwprobe-results-agb.md) confirmed 9/16 GBA pages outright
and left six divergences, each of which is a *single anchor* that a
follow-up page can turn into a *mechanism*.  Ranked by leverage:

1. **IRQDECOMP** — decompose the undelivered reload-0 one-shot timer IRQ
   (IRQLAT +0/+2): reload-0 vs reload-1 vs reload-0xFFF0; enable+IRQ in
   one write vs two; IF-ack racing a new source; the IME=1→dispatch
   window in instructions; halt-exit latency per source vs non-halt
   latency.  Converts divergence #1 and the two synchronizer knobs into
   a delivery-pipeline model.
2. **CONTEND2** — session 1's CONTEND (mode 3, OBJ on, no sprites)
   matched dingbat exactly; the *loaded* cases are where emulators
   disagree: 128 OBJs on one line, modes 0/2 with all BGs, hblank-free
   bit on/off — VRAM/OAM/palette access cost during visible vs hblank
   vs vblank.  This is the CPU-visible face of the OBJ cycle budget
   (Tier 3's visual item, without photographs).
3. **MULTIME** — MULFLAGS gave 8 carry anchors (hardware CLEARS C where
   dingbat keeps it); add the timing half: MUL/MLA/UMULL/SMLAL cycle
   counts across operand byte-lengths (early-termination sweep) plus a
   16-pair carry matrix, enough to fit the actual carry function rather
   than patch the 6 known-wrong rows.
4. **TIMPHASE + PSGPHASE** — the one-counter-many-taps cluster on AGB:
   is the timer prescaler a single free-running divider (session 1's
   staircase says the phase survives boot) shared across timers?  Does
   enable reset it?  And the PSG frame sequencer: sweep ch1 trigger
   phase against a timer to staircase the length-expiry tick (PSGSTAT's
   ~14% divergence), and test whether SOUNDCNT_X master-off resets the
   sequencer phase.
5. **MEMCTL** — 0x04000800 read back 0D000020 on hardware (dingbat:
   unimplemented, open bus).  Probe field writability, the 64K mirrors,
   and the EWRAM-waitstate field's measured effect on a timed EWRAM
   loop (write documented-safe values only; restore).
6. **DMATIME** — DMA start delay, per-region transfer cost, the exact
   trigger instant of hblank/vblank DMA vs DISPSTAT edges (TM0
   timestamps), and DMA-completion-IRQ vs CPU-resume ordering.
7. **IWCYCLE** — IntrWait/VBlankIntrWait return-path cost and the
   0x03007FF8 BIOS-flag protocol: the known-deliberate HLE gaps become
   measured quantities (real-BIOS path proved byte-exact in session 1,
   so dingbat's own real-BIOS run can pre-verify the probe).

Zero-code item with immediate payoff: run the *same* gbaedge build on
every other GBA-family console available (AGB-001, micro, DS/DS Lite in
GBA mode).  Page 0's ALL CRC instantly reports whether any probe differs
across silicon revisions; MODEL separates the BIOS families (DS reads
`18 80`).  Divergent consoles get their own expected/ directory.

## v6 SHIPPED — the discrimination pages (gbaedge 28-36, 37-page build)

Sessions 1-3 left a handful of measurements that a single anchor could
not turn into a model (the 2026-08-10 amendments in
docs/hwprobe-results-agb.md list them).  v6 adds one page per ambiguity;
every row below states which hardware outcome selects which model, and
the **dingbat baseline** (37-page build; HLE and real BIOS agree on all
nine pages).  v6 also fixes the `irq_arm` r5 clobber that invalidated
session 1's IRQLAT TM2 row (the arming word hit IME; both machines read
a stale stamp).

| pg | row | outcome -> model | dingbat baseline |
|---|---|---|---|
| 28 LDMUSER2 | +0 SPSR read in the ldm^ shadow (SPSR flags N\|V, CPSR flags Z\|C — disjoint at last) | 0x90000092 unchanged; 0xF0000092 OR'd with CPSR; 0x60000092 read returns CPSR | 0x90000092 (unchanged), same at +4 (one nop later); control/sanity exact |
| 29 PCWB2 | +0 `str r1,[r15],#8` r7 | 18 = PC:=writeback (base+8); 1C = fixed base+4 | 18 (writeback model) |
| 29 | +1 `ldr r1,[r15],#8` r7, +8 loaded r1 | 10 = wb+4 (base+12); 18 = fixed base+8; r1 0 = load suppressed | 10, r1=0 (wb+4, suppressed) |
| 29 | +2 `str r1,[r15],#-4` r7 | 1F = wb (base-4); 1C = fixed base+4 | 1F (writeback model) |
| 29 | +3 `str r1,[r15,#4]!` r7 | 1C = pre-indexed wb reaches PC (= base+4 under both post-models); 18 = fixed base+8 | 1C |
| 29 | +4 `stmia r15!,{r1}` r7, +12/+16 block words, +20 r1 | 1C = wb base+4; 1F = no-wb (ldm-style); 18 = base+8 | 18 (base+8 — matches neither pure model) |
| 30 DMABYTE2 | +0..+10 DMA1/DMA2/DMA0 hi-strb 0x80 | ran + readback 0080 = bit7 mirror on that channel too; ran + 0000 = normal byte write, no mirror | all three: ran=1, 0080 (mirror modeled bus-wide) |
| 30 | +12 DMA3 hi-strb 0xC0 | 40C0 = WHOLE-VALUE mirror; 4080 = bit7-only mirror; 4000 = no mirror | 4080 (bit7-only) |
| 30 | +16 DMA3 lo-strb 0xC0 | 0000 = fully dropped; 0040 = bit6 stores, bit7 dropped; 00C0 = full store | 0040 (partial) |
| 30 | +20 DMA3 hi-strb 0x40 control | 4000 + no run = normal store | 4000, no run |
| 31 SWEEP2 | +0 freq 512 s1 (~0xF75 polls/tick) | die tick 2 = writeback-at-trigger + tick-2nd-check; tick 3 = (no-wb + check) or (wb + no-check); tick 4 = no-wb + no-check | 3532 (~tick 3) |
| 31 | +4 freq 2018 s7 (trigger calc2 = exactly 2048) | 0 polls = trigger 2nd check >=2048 (re-anchors the single 1024-anchor strictness); ~1 tick = tick 2nd check >=2048; ~2 ticks = tick primary kills 2048 (documented >2047); ~3 ticks = 2048 writes back, boundary >2048 everywhere | 09D8 (~tick 1) |
| 31 | +8 freq 940 s1 (same-offset 2nd = 1880, recalc'd = 2115) | 0 polls = the trigger 2nd check RECALCULATES; survives trigger = same-offset (extra anchor) | 109D (~tick 1: survives trigger) |
| 31 | +12 freq 2033 s7 (calc1 = exactly 2048) | 0 polls under either strictness (calc2 2063 kills what calc1 spares); surviving to a tick falsifies the two-check model | 0000 |
| 31 | (note) | the task-spec "freq 2046/2047 shift 10" rows are unencodable (shift is 3 bits); 2018/2033 shift 7 preserve the 2048 discriminators exactly | — |
| 32 IRQWIN3 | +0/+2/+4 IME-gate sled offsets (mul / ROM-ldr / mixed) | a cycle-window W predicts ceil(W/cost) instructions per sled; identical counts across sleds = instruction-counted | 8 / 8 / C bytes (2 muls / 2 ldrs / 3 mixed — cycle-shaped) |
| 32 | +8..+15 ack-race, overflow (8+4k)+latency cycles after enable | the k where bit0 flips is the ack instant; bit0=1 beyond it = assert-beats-ack in the same cycle | 00 x6 then 03 03 (flip between k=5 and k=6) |
| 33 IRQLAT2 | +0/+2 TM2 reload-0 one-word (r5 fixed) | delta = synchronizer latency + arming offset, mod 2^16 | 0116-00E3 = 0x33 |
| 33 | +4..+10 reload 0xFF00 one-word vs two-write arming | equal deltas = arming shape irrelevant | both 0x13D (equal) |
| 33 | +12/+14 reload 0xFFF0 (overflow ~16 cy out) | entry stamp BEFORE trigger stamp = overflow landed inside the arming code | entry 0B4F < trigger 0C4F (inside) |
| 34 IOBYTE2 | +0 DISPSTAT lo-strb 0x38 (real IRQ-enable bits — falsifiable, unlike 0x44) | 0039 = byte writes store; 0001 = lo byte ignores byte writes (session 3's hardware hint) | 0039 (stores) |
| 34 | +2 hi-strb 0x38 (LYC) / +4 16-bit control / +6 byte-clear after 16-bit 0x0038 | 3801 stores; 0039 control; +6: 0001 = byte-clear stores, 0039 = ignored | 3801 / 0039 / 0001 |
| 35 THUMBPC3 | +0/+4/+8 cmp pc at A%4==2, SPSR.T=0 (N set) | scratch=C0DEC0DE & r6=2 -> resumed ARM at A&~3; scratch=0 & r6=2 -> (A+2)&~3; scratch=0 & r6=0 & CPSR 0x200000xx -> stayed Thumb (no restore) | 80000012 / 0 / 02: full restore, resumes (A+2)&~3 |
| 35 | +12 cmp pc in System mode (flags preset N\|Z, unreachable by a compare) | C00000xx = "restore" writes CPSR-as-SPSR (no-op); 200000xx = plain compare; else garbage restore (phase byte flags a wander) | C000001F (no-op restore), clean |
| 36 MSRTBIT2 | +0 immediate-form `msr CPSR_c,#0x3F` r7 | 04 = A+8-skip-A+10 quirk is form-independent; 15/14/12/08 = other resume points; 00 = continued as ARM | 04 (quirk holds), clean |
| 36 | +8/+10 register form, T + IRQ->SYS in one write | r7 04 + recovery mode byte 1F = quirk unchanged AND the mode switch lands | 04 / 1F (both) |

**ANSWERED 2026-08-11 (session 4, `tests/roms/expected/agb-sp-4.txt`,
analysis in docs/hwprobe-results-agb.md):** every row above is settled.
Hardware selected the dingbat baseline on all pages except three
divergences: `stmia r15!` performs NO writeback (ldm-style — dingbat's
base+8 is wrong; **fixed**, PCWB2 now byte-perfect), handler-entry
latency runs +6 cycles later than dingbat in every IRQLAT2 shape
(**fixed** as a gamepak-execution-context entry cost — IRQLAT2 now
byte-perfect, mGBA suite unmoved at 6957/6998), and the
halfword-aligned `cmp pc` T-clearing restore resumes past BOTH overlay
words (scratch=0, r6=0 — an outcome the prediction key did not list:
resume at A+10/A+14, not (A+2)&~3).  Open follow-up for a later rev:
the frame-sequencer phase family from earlier sessions.

## v7 SHIPPED — the THUMBPC3 resume-ladder row (page 35 extended)

One follow-up row, appended to slot 35 as experiment (c): the
halfword-aligned T-clearing `cmp pc` again, with the overlay block's
resume ladder extended so session 4's "past both overlay words" outcome
splits.  Distinct breadcrumb adds sit at W+8/W+12/W+16 (= A+6/A+10/
A+14), the bx-r5 escape moves to W+20 (A+18) with a safety at W+24, and
r4 is captured after recovery to show whether the ARM word at W+4
(`orr r4, r7, #0xA00000` — the (A+2)&~3 resume dingbat models)
executed.  Dingbat baseline from the v7 build (HLE and real BIOS
`--bios tests/roms/gba_bios.bin` identical; page CRC 2333, ALL 2446
HLE / FAF0 real-BIOS):

| pg | row | outcome -> model | dingbat baseline |
|---|---|---|---|
| 35 THUMBPC3 | +18 r6 ladder key | 07 = resumed W+8 (A+6); 06 = W+12 (**A+10** — the session-4 escape slot); 04 = W+16 (**A+14** — the session-4 safety slot); 00 = W+20 or stayed Thumb | 07 (but see r4: dingbat resumes earlier and runs the whole ladder) |
| 35 | +20 r4 | 0xC0DEC0DE = W+4 never executed; 0x02A01080 = the W+4 orr ran -> resumed (A+2)&~3 | 0x02A01080 ((A+2)&~3 model) |
| 35 | +24 scratch / +28 CPSR / +17 phase | 0xC0DEC0DE = resumed A&~3 (strmi ran); CPSR 0x800000xx = full restore happened; phase 01 = clean | 0 / 0x80000012 / 01 |

Silicon prediction from session 4's old-block outcome: r4 untouched,
scratch 0, r6 = 06 or 04 — whichever comes back pins the resume at
A+10 vs A+14 and finally licenses the model change (dingbat's
(A+2)&~3 resume is already known wrong at halfword alignment).

## v8 candidates — the CGB phase constants, and how to stop fitting them (2026-08-18)

`cgb-acid-hell` closed at 261/261 on a new constant
(`CGB_HALT_PPU_LEAD = 1`, gated by `CGB_HALT_LEAD_SKIP_LYC0`), and the way it
was derived is worth generalising, because it is the first one in this tree
derived from **the test ROM's own source** rather than from a knob sweep:

1. Get the ROM's source (both `cgb-acid-hell` and daid's set are published;
   daid's ships *inside* the shootout at `testroms/daid/`).
2. Rebuild it **byte-exact** — verify the md5. Both need pre-0.6 rgbds
   spellings fixed, and both need a `nop` after every `halt` that old rgbasm
   inserted for you. Miss that and you have introduced the very M-cycle you
   are trying to measure.
3. Change **one parameter** and re-run both dingbat and SameBoy on the result.
   A model error and a phase error look identical on the shipped ROM; they
   separate the moment the parameter moves.

That is what turned "acid-hell and daid demand opposite phases" into "the
advance is present on a normal-line LYC wake and absent on the LY 153->0
snapback" — a LYC sweep of daid, same ROM and same entry, only the wake line
changing (`tools/gbppu/daidsweep.py`).

**The point of the table below is that suite agreement is not evidence.** Each
of these constants currently rests on one ROM, one emulator, or a plateau
midpoint. A photograph settles them.

| # | constant | what it rests on now | ROM that would settle it | status |
|---|---|---|---|---|
| g1 | `CGB_HALT_PPU_LEAD` + `CGB_HALT_LEAD_SKIP_LYC0` | daid + acid-hell + shootout 261/261 — **and probe (e) DISSENTS, see below** | **probe (e) already takes `-DANCHOR_LINE=n`.** Photograph the band column at n = 16 and compare against the two builds' predictions, which differ by exactly one 4-dot step there. Also shoot n = 0, where the two builds agree — that pair is the control | **one build away, and it is now the most important shot in this file** |
| g2 | the same, by STAT source | refuted by suite only (`CGB_HALT_LEAD_LYC_ONLY=1`: gambatte 4246 -> 4240) | probe (e) with the anchor's `rSTAT` source as a second parameter — LYC vs mode 0 vs mode 2, same line, same code | needs a 3-line ROM edit |
| g3 | `OBJ_DMA_BUS_LEAD` (and its new `CGB_HALT_PPU_LEAD` term) | `strikethrough` alone, two consoles | a ROM that arms OAM DMA a settable number of M-cycles after a halt wake and draws an object over the transfer — the lead is the offset at which the object's byte changes | open |
| g4 | `HDMA_VISIBLE_DOTS` (+ lead term) | gambatte `dma`, bracketed 4/8/12 but only a partial account — seven `hdma_late_disable_*` still red | HDMA one block per line with the disable write swept in M-cycles; read back the destination | open |
| g5 | `CGB_TDSEL_LATENCY` / `CGB_TDSEL_IDX_DOTS` (H1) | the 8..15-dot window is populated by `cgb-acid-hell` **alone** | probe (d) already toggles LCDC.4; add a second toggle at a settable distance so the "back-to-back glitched fetch" bucket has a ROM other than acid-hell | probe (d) exists, needs the second toggle |
| g6 | `STAT_M0_FIELD_TAIL` + `STAT_M0_TAIL_MAX_MC` | its own note admits idiom and suite are **perfectly confounded** in every existing ROM | probe (a) is exactly this and is **already built** — it was specced for a session that has not happened | **built, unrun** |
| g7 | `CGB_SCY_LATENCY` / `CGB_SCX_LATENCY` / `CGB_OBJ_SIZE_LATENCY` / `CGB_MIXER_LATENCY` | mealybug `_cgb_c` captures, i.e. one revision of one console | a single paged ROM that writes each register at a swept dot and draws the boundary — one page per register, same reader | open |

Ordering, if only one sitting is available: **g1 then g6**. g1 is one `rgbasm`
invocation away and it is the newest and least independently supported constant
in the tree; g6 is already built and would delete two constants and reopen ~60
rows if the answer is "the read idiom never mattered".

### The open contradiction g1 has to resolve

Two instruments in this tree, both scored against the same oracle, disagree
about the shipped constant. Scored by BASE equivalence
(`tools/gbprobe/probe_f_base.sh --plain`, which sweeps the probe's write
position in dingbat and holds SameBoy at the shipping BASE 26):

| probe (e) anchor | `CGB_HALT_PPU_LEAD=0` | `=1` (shipping) |
|---|---|---|
| `-DANCHOR_LINE=0` | BASE 23 | BASE 23 (the gate suppresses it — as designed) |
| `-DANCHOR_LINE=16` | BASE **24** | BASE **23** |

A build that matches at a LOWER base needs its write EARLIER, i.e. is further
from "no compensation needed". So probe (e) says the lead moves dingbat AWAY
from SameBoy on a normal line — while daid's LYC sweep says SameBoy has the
lead at LYC = 1, 8, 40 and 100. Both are SameBoy comparisons. They cannot both
be right.

The shipped model follows daid and `cgb-acid-hell`: two published ROMs, both
rebuilt byte-exact, both understood line by line, one of which SameBoy
reproduces pixel-exactly — against probe (e), which is ours, has a frame loop
with joypad reads and in-VBlank header drawing around the measurement, and
carries an unexplained **2–3 M** baseline offset from the oracle that predates
this work entirely. An instrument whose zero is 2–3 M out is not a fit arbiter
of a 1 M effect, so it does not get a vote until that offset is explained.

**But it is not dismissed, and it is why g1 is the shot to take.** Either
probe (e) has a bug, in which case its BASE numbers have been misleading this
work for weeks and several earlier conclusions drawn from them need re-reading;
or it is right, and `CGB_HALT_PPU_LEAD` is fitted to two ROMs that happen to
agree. Hardware is the only thing that separates those.

### g1, ready to shoot: the ROM, the settings and all three predictions

`tools/gbprobe/mk.sh probe_e_objgrid -DSCX_DEFAULT=n -DOBJX_DEFAULT='$FF'` —
the shipping anchor (line 16), objects off. Read the band columns with
`tools/gbprobe/read_probe_e.py`, which measures each bar against the parameter
header inside the same frame, so a photograph needs no registration.

Two photographs, SCX 0 and SCX 4. The three candidates are **8 dots apart**,
which is a whole tile and unmistakable on a phone camera:

| SCX | `CGB_HALT_PPU_LEAD=0` | `=1` (shipping) | SameBoy |
|---|---|---|---|
| 0 | `32 40 40 48 48 56 …` | `40 40 48 48 56 56 …` | `24 32 32 40 40 48 …` |
| 4 | `28 36 36 44 44 52 …` | `36 36 44 44 52 52 …` | `20 28 28 36 36 44 …` |

Note what this shot actually covers: **neither dingbat build agrees with
SameBoy here even at lead 0** — that is the unexplained 2 M baseline offset, and
it is 8 dots wide in this reading. So the photograph answers two questions at
once, and the third outcome is the interesting one:

* lands on **24 / 20** — SameBoy is right, BOTH dingbat builds are wrong on this
  probe, and the thing to chase is probe (e)'s baseline offset, not the lead.
* lands on **32 / 28** — lead 0 is right on this instrument, which contradicts
  daid and puts `CGB_HALT_PPU_LEAD` back in question.
* lands on **40 / 36** — the shipping build is right and probe (e)'s
  disagreement with SameBoy is SameBoy's, which would be the first time in this
  work the oracle has been wrong about anything.

### g1 RESULT — 2026-08-18, GBA SP: hardware reads the SameBoy column

Both photographs, read with `tools/gbprobe/read_g1.sh` (find_panel + photowarp
+ read_probe_e):

| | silicon | SameBoy | lead 0 | lead 1 (ships) |
|---|---|---|---|---|
| SCX 0 | `24 32 32 40 40 48 48 56 56 64 64 71 71 79` | `24 32 32 40 40 48 48 56 56 64 64 72 72 80` | `32 40 …` | `40 40 …` |
| SCX 4 | `20 28 28 36 36 45 45 53 53 61 61 69 69 77` | `20 28 28 36 36 44 44 52 52 60 60 68 68 76` | `28 36 …` | `36 36 …` |

(the trailing +1s are the photograph's own perspective drift at the far end,
exactly as in the probe (e)/(f) sessions.) **The answer is the pre-registered
"most likely" one: hardware = SameBoy, and BOTH dingbat builds are wrong here.**
Lead 0 is 8 px (2 M) out; lead 1 is 16 px (4 M) out.

Three things follow, and the first is the big one:

1. **probe (e)'s 2-3 M baseline offset is a REAL dingbat defect, not an
   instrument artifact.** It has been treated as suspect since it appeared and
   that is now settled the other way: silicon agrees with SameBoy to the pixel,
   so dingbat is genuinely 2 M wrong on this ROM's path even with the lead off.
   That is a new, hardware-anchored bug with a photograph behind it.
2. **On this instrument the lead makes things worse**, by a further 1 M.
3. **It does not unship `CGB_HALT_PPU_LEAD`**, and that was decided before the
   photographs existed. `cgb-acid-hell`'s reference was verified
   hardware-correct on this same console (session 2, IMG_3803) and daid's is a
   silicon capture; both are pixel-exact only with the lead, and both are
   ordinary ROMs rather than an instrument with a known 2 M defect. A ROM that
   is 2 M wrong before the question is asked cannot arbitrate a 1 M answer.

So the open question is no longer "is the lead real" but **"what is probe (e)'s
2 M, and does fixing it leave the lead needed?"** If the 2 M turns out to live
in the same halt-wake path, the lead may be compensating for it in the wrong
place — which would be the third time in this investigation that a constant
landed next to the defect rather than on it (`CGB_TDSEL_LATENCY=5`,
`CGB_WIN_RESTART_COUNTER=1`, and possibly this).

**And it is a dingbat bug, not a probe bug — that distinction matters and the
first draft of this section got it wrong.** "probe (e) is ours, so it may be the
probe's fault" does not survive the photograph: hardware and SameBoy agree on
what this ROM does, to the pixel. Only dingbat disagrees. Whatever the ROM does,
dingbat emulates it 2 M wrong. That also makes it a pure emulator-debugging
task with a validated oracle and no further hardware needed.

**Measured straight after, and it redirects the hunt: it is NOT the halt.**
Building the same probe with `-DANCHOR_POLL`, which reaches the anchor line by
polling `rLY` and contains no `halt` in the measurement path at all, dingbat is
still **3 M** from SameBoy (BASE 23 against the shipping 26) with the lead off.
So the defect survives the removal of the very mechanism the whole
`CGB_HALT_PPU_LEAD` argument is about. Whatever the 2-3 M is, it lives in
something both the halted and polled builds share -- mode 3's own timing on this
ROM's settings, the LCDC.4 write path, or the free-running band loop -- and not
in the wake.

That is worth stating plainly because it cuts the other way too: if the halt is
not where probe (e)'s error lives, probe (e)'s dissent was never really evidence
about the halt constant in the first place.

#### Hunting the 2 M: three homes eliminated, all by the same argument

Scored with `probe_f_base.sh --plain -d:CGB_HALT_PPU_LEAD=0`, where the target
is the shipping BASE 26 and dingbat currently sits at 24:

| knob | 0 | 1 (ships) | 2 | 5 | 9 | 13 |
|---|---|---|---|---|---|---|
| `CGB_TDSEL_LATENCY` | — | **24** | — | 23 | 22 | 22 |
| `CGB_PIPE_MCYCLES` | none | **24** | 23 | — | — | — |

**Every one of them moves BASE DOWN as it increases, and the target is UP.**
dingbat's effect lands about 8 dots too far RIGHT for a given write time -- its
fetcher is further along than hardware's -- so the fix has to RETARD the PPU
against the CPU, and each of these knobs advances it. Reaching 26 would need
`CGB_TDSEL_LATENCY` around -8 or `CGB_PIPE_MCYCLES` at -1/-2: unphysical, and
`-1` is also pathological in practice (the PPU loop slows ~70x, so do not leave
that sweep running).

`CGB_PIPE_MCYCLES = 0` is the one non-monotone entry -- it produces NO common
BASE across the eight SCX values, i.e. it makes the model inconsistent with
itself rather than merely offset. That is its own small finding: the pipeline
advance is load-bearing for SCX consistency, which is presumably why daid pins
it so sharply.

So: not the halt, not the tile-select arrival, not the pipeline advance.

Then the machine axis, same probe, same harness (target 26 throughout):

| machine | BASE | dingbat is |
|---|---|---|
| DMG (DMG silicon) | 27 | 1 M **early** |
| CGB compatibility mode (DMG-flagged cart on a CGB) | 24 | 2 M **late** |
| CGB native (CGB-flagged cart) | 24 | 2 M **late** |

Two things fall out. **It is not a native/compat split** -- both CGB modes give
24, so the third machine is not the discriminator, which was the obvious guess
because daid's cart is DMG-flagged and this probe's is not. And **it is a clean
3 M DMG-vs-CGB split**: dingbat has the CGB pipeline 1 M ahead of the DMG
(`CGB_PIPE_MCYCLES = 1`) and this probe wants that relationship 3 M the other
way.

#### The leading hypothesis: emission versus the fetch grid

daid's `ppu_scanline_bgp` runs on CGB compatibility mode -- the same machine as
the middle row above -- and dingbat is pixel-exact on it. But daid's ruler is
**BGP**, i.e. EMISSION, while probe (e)'s is **LCDC.4**, i.e. the FETCH GRID. So
on one machine, at one time, dingbat's emission phase is right and its
fetch-grid phase is 2 M out. That is not two bugs; that is a 2 M separation
between emission and the fetch grid -- which is the oldest open axis in
`docs/gb-failure-triage.md`, the one described there as "acid-hell needs the
CPU's writes aligned to the BG fetch grid where they are; daid needs them four
dots later relative to pixel emission".

**And probe (c) is the instrument built to measure exactly that**, by putting
both rulers on one frame so the separation is internal to a single photograph.
Which is why the registration fix below is not a side quest: it is the next
step of this hunt.

The honest caveat: `cgb-acid-hell` is also a fetch-grid measurement and it is
pixel-exact, which this hypothesis does not yet explain. Its observable is which
FETCH gets split rather than which COLUMN changes, and those need not have the
same sensitivity -- but that is an assertion, not a result.

#### The revision mismatch: what it did and did not cost (2026-08-18)

`tools/gbfuzz/sameboy_runner.c` hardcodes `GB_MODEL_CGB_E`; dingbat defaults to
**CGB-C**. Every CGB comparison in this investigation ran C against E. All ten
SameBoy-comparison harnesses now force `--cgb-rev=E` (`SB_REV`, overridable).

Scope of the damage, measured rather than assumed:

| instrument | rev C vs rev E | verdict |
|---|---|---|
| probe (c) — BGP band edge (EMISSION) | band 6 vs **5** | **wrong conclusion drawn**; corrected |
| probe (c) — glitched column (FETCH) | identical | unaffected |
| probe (e)/(f) plain arm | identical (8/8, BASE 24 both) | unaffected |
| probe (f) windowed arm | identical (2/8, no common BASE both) | unaffected |
| g1 hardware columns | identical | unaffected |
| mealybug `*map_change*` rows (the 4 failing) | identical at C, D and E | unaffected |

The pattern is coherent rather than lucky: `CGB_MIXER_LATENCY` **is** the
CGB-C/CGB-D split, and it sits on the palette/mixer step. probe (c)'s emission
ruler is a BGP write, so it moves with the revision; everything else here
measures the LCDC.4 fetch-grid path, which does not. So exactly one conclusion
was wrong -- the one drawn from the one instrument that reads the mixer -- and
it is the one that has been corrected.

**It closes no open question and resolves no test row.** The four failing
mealybug `map_change` rows are byte-identical at C, D and E, and their shipped
`_cgb_c` and `_cgb_d` references are identical to each other, so they are
genuine model defects and not mis-scored silicon. Worth stating plainly rather
than hoping: finding a systematic methodology error is not the same as finding
rows it was hiding.

Fixed while proving that: `ppmdiff.py` rejected 1-bit greyscale PNGs outright
(`ctype=0 depth=1`), which is how several mealybug CGB references ship -- so
those rows were unscorable by every tool here except the runner itself.

#### The revision axis has a real defect in it: `m3_scy_change` (2026-08-18)

Prompted by the observation that Beaten Dying Moon, `cgb-acid-hell` and
mealybug all share one author (BDM is `mattcurrie.com`), so his emulator's
revision handling and his test ROMs' per-revision captures are the same
statement made twice. The captures are the stronger form, and they are on disk.

Seven mealybug ROMs ship `_cgb_c` and `_cgb_d` references that actually DIFFER
(the other thirteen pairs are byte-identical, so they carry no revision axis).
Scored with `tools/gbppu/mbrevcheck.sh`:

| ROM | refs differ | rev C vs `_cgb_c` | rev D vs `_cgb_d` | |
|---|---|---|---|---|
| `m3_bgp_change` | 864 px | 0 | 0 | ok |
| `m3_bgp_change_sprites` | 716 px | 0 | 0 | ok |
| `m3_lcdc_obj_en_change_variant` | 144 px | 0 | 0 | ok |
| `m3_obp0_change` | 42 px | 0 | 0 | ok |
| **`m3_scy_change`** | **6217 px** | **0** | **6217** | **MISMATCH** |
| `m3_window_timing` | 138 px | 0 | 0 | ok |
| `m3_window_timing_wx_0` | 144 px | 0 | 0 | ok |

dingbat switches correctly on six of seven. On `m3_scy_change` it produces the
CGB-C picture at **every** revision -- C, D and E -- and misses `_cgb_d` by the
entire 6217-pixel difference. There is no partial credit here: the revision
behaviour for a mid-line SCY write is simply not modelled.

**Nothing in the tree could see it.** The local runner wires the 27 `_cgb_c`
rows and no `_cgb_d` row at all; the shootout defines RevC/RevD mealybug
variants in `testroms/mealybug.py` but they are not in its active list -- its
recorded dingbat run contains zero of them. So `_cgb_d` is scored by no harness,
and a 6217-pixel revision defect sat behind that gap.

It also matters for how dingbat is scored today: the shootout runs it at
`--cgb-rev=E`, and for SCY that is currently the CGB-C machine.

Two things worth doing, neither of them large: wire the seven revision-carrying
`_cgb_d` rows into the runner so this class of defect is visible, and find out
what CGB-D changed about mid-line SCY. The `m3_scy_change` pair is a 6217-pixel
difference over 142 scanlines -- a whole-frame behavioural change, not a phase
nudge, so it should be tractable to characterise from the two references alone.

#### Refuted this pass

* **probe (e)'s 8 px is its VBlank header drawing.** Built with `-DNOHEADER`
  and compared by absolute bar-0 column: delta unchanged at every SCX. Not the
  header. What is left of the VBlank difference is the joypad read and
  `ApplyParams`' register writes.

#### Reading the ARCHIVED photos: blocked, and the fix is a ROM change

IMG_3803-3808 (session 2) are on disk in `hwphotos/`. IMG_3804-3806 are probe
(c), the acid-hell-vs-daid arbitration, and they **cannot currently be
registered**: probe (c) draws white bands on a BLACK background, so the 160x144
frame has no visible border and photowarp's whole model -- "find the lit
quadrilateral inside the letterbox" -- has nothing to lock onto. `find_panel.py`
locks onto the couch instead. Computing the frame from the GBA SP's own
240x160 panel geometry (the GB image sits at 40/240, 8/160) was tried and the
LCD's corners cannot be eyeballed accurately enough either -- the warp comes out
including the shell's "GAME BOY ADVANCE SP" legend.

**The fix is four registration marks in the ROM**, and it costs the measurement
nothing: put a white tile in each of the four map corners. The fetcher still
fetches exactly one tile per eight pixels whatever the tile contains, so no
timing changes at all -- only which bytes come back. probe (c)'s staircases live
in the middle of the frame and never reach the corners. With those, photowarp's
existing detector works on a black-background probe and every future session
photo of one becomes readable.

Until that lands, IMG_3804-3806 hold data we cannot extract, and the arbitration
they were shot for needs a re-shoot rather than more tooling.

### What a negative result would mean, stated in advance

Worth writing down before the photographs exist, because it is the only
protection against reading them the way we want to:

* **g1, column does not move between n = 0 and n > 0.** Then the snapback
  exemption is fitted, `daid` and `cgb-acid-hell` are being reconciled by a
  rule silicon does not have, and the honest response is to revert
  `CGB_HALT_PPU_LEAD` to 0 and take `cgb-acid-hell` back to 2 px. 261/261 is
  not worth a constant hardware refuses.
* **g1, column moves but by something other than 4 dots.** The quantity is real
  and the size is wrong, which points at the repayment path in `cpu_halt_tick`
  rather than at the gate.
* **g6, the two idioms read the same.** `STAT_M0_FIELD_TAIL` and
  `STAT_M0_TAIL_MAX_MC` both go, and the ~60 rows they currently buy have to be
  re-derived from something else.
