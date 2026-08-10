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
| 6 | Speed-switch stall: 65540 is SameBoy's ripple counter + 8 unexplained dots; the sweep is "jagged … not one stall length" — the 6-cycle countdown + PPU re-alignment freeze is unmodelled | `memory.nim:672` `SPEED_SWITCH_STALL_T`; bucket 13 (55 rows) + 31 of bucket 12 | **[built p14 SPEED]** coarse; **open**: a post-STOP LY/STAT *burst* variant (daid `speed_switch_timing_ly` shape) would decompose it | 55-86 rows |
| 7 | `STAT_READ_SAMPLE` at both speeds — the cc-2 constant, and the double-speed "+1" that is admittedly a parked half-dot phase error | `gb.nim:49/52`, `ppu.nim:729-800`; bucket 15's residue | **[built p08 STATSEQ + p13 DSTAT]** | closes the half-dot question; ~13 SCX-residue rows |

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
