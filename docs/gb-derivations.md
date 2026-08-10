# Derivation archive — GB/GBC and GBA accuracy work, 2026-08

Commit messages from the agent branches of the 2026-08-01..04 accuracy effort.
That work was **squash-merged** into main, so these messages are not reachable
from any commit in `git log`, and the branches they lived on have been deleted.

**This is an archive, not the reference.** The *rules* live as comments beside
the constants they explain (`src/dingbat/gb/fifo_ppu.nim`, `ppu.nim`, `gb.nim`,
`memory.nim`, `src/dingbat/gba/bus.nim`), and several tables regenerate from the
ROMs (`tools/gbppu/objtab.py`). What is preserved here that is preserved nowhere
else is the **raw measurement**: the observation grids, the swept ranges with
their scores, and the falsified alternatives with the rows that refused them.

That matters most where a cluster is still open. The clearest example is the
first entry below: the `(elapsed, s)` grid that fixed the CPU half of the GBA
prefetch hand-off is the same evidence anyone will need for the DMA half, which
is still unsolved and needs the occupancy rewrite in
`docs/prefetch-model-rewrite.md`.

Re-baseline, revert and measurement-artifact commits are omitted.
See `docs/gb-failure-triage.md` for what remains to be done.

---

## gba/dma: latch the word count at enable, and close out the Timing DMA cluster

`d7c62f098` — Mon Aug 3 07:03:40 2026 -0700

```
gba/dma: latch the word count at enable, and close out the Timing DMA cluster

Two things, both about the mGBA suite's last 41 failing rows.

**DMA count latching.** `run_channel` read DMACNT_L live at transfer time,
so a write to it after the enable write retroactively resized a burst that
was already armed. GBATEK is explicit that the internal registers are copied
when the channel is enabled and that repeat reloads the count, so the count
now latches alongside `src`/`dst` and reloads at each repeat. Serialized at
GBA payload rev 5; pre-v5 states reconstruct it as the user register, which
is exactly the machine those builds ran.

The fixture is `mgba-emu/suite@fbe6156`/`@aac98dc`, a test that does not
exist in the pinned v1.0 ROM, so the committed baseline does not move. Built
against the fork's current master it takes Misc from 9/12 to 11/12.

**The 32 Timing rows are now a closed question, not an open one.**
docs/prefetch-model-rewrite.md carries the derivation. Instrumenting every
prefetch-enabled DMA in the Timing section reduces all 32 to eight distinct
(s, elapsed) points, and those points are unsatisfiable by any rule of the
form "stall iff (elapsed + k) mod s == r": at s=2, elapsed 2 must stall and
elapsed 4 must not, and 2 == 4 (mod 2) for every k. That excludes extending
the CPU hand-off rule, and both re-anchorings of it, without a sweep.

So the previous note's "reconcile the two clocks first" was not the missing
step. Reconciling them by *charging* the skew was measured and is decisively
wrong (Timing 1836); parking the prefetch buffer across the burst does
nothing to Timing at all. A requirement that is non-periodic in a variable
that is periodic by construction means the variable is wrong:
`rom_free_since` is derived from the last ROM access and only coincides with
the prefetch unit's real position while the CPU is the sole master. The
occupancy model this doc was written to propose is the only path left.

**Two documentation defects fixed while reading these rows.**

tests/README said the suite's Got/vs columns are swapped. Checked against
every `doResult` in the sources: `src/misc-edge.c` is the only caller that
inverts its arguments. `timing.c` prints `Got <measured> vs <expected>` and
always has. Reading Timing the swapped way turns "dingbat is one cycle
short" into "one cycle long" and aims any fix backwards.

The same section claimed 9/10 against a corrected build. It is 11/12 with
this change, and only with DINGBAT_NO_WAITLOOP=1: under the default
fast-forward six "H-blank bit start" rows report the skip's granularity
rather than the PPU's, and score 5/12. Bounding the skip by the spin loop's
own period is the real fix and is not started; `analyze_loop` does not
measure it.

A v1.1 release candidate is built and staged with its release steps, but
nothing is published, so `MgbaSuiteRelease` stays at v1.0 and the CI cache
key is only annotated. Both move in the same commit as the rebaseline.

Verification: full runner exit 0, unchanged — 934/672/262, gambatte
3534/5005, mGBA 6967/7008 HLE and 6964/7008 LLE (both arms identical under
the official BIOS). Link/rollback battery and all six nimble unit tasks
pass. Retired instructions on Pokemon Emerald +0.0013%, at the 0.002%
reproducibility floor.
```

## gb/ppu: the window starts on an equality, and the WY latch is a level

`41ac05718` — Mon Aug 3 07:15:26 2026 -0700

```
gb/ppu: the window starts on an equality, and the WY latch is a level

Three separate things the window model had wrong, each settled by a gambatte
family that brackets its boundary to the M-cycle (the instrument is the new
-d:gb_win_trace plus tools/gbppu/windot.py, which prints the dot each ROM's
register write lands on next to the filename's expected value):

* The WY condition was sampled once, at the mode 2 -> 3 edge, and then
  re-tested as `ly >= wy` at every use. Pan Docs makes it a level comparator
  behind a per-frame latch -- "WY == LY at any point in the frame" -- so it is
  now set at the top of every visible line and on any WY write that makes the
  two equal, and nothing re-reads WY afterwards. window/arg/late_wy_1 vs _2
  place the per-line sample at dot 0 rather than 80; late_wy_1toFF_* show the
  re-test retracting a window hardware keeps drawing.

* The window started on `lx + 7 >= wx`. A `>=` cannot be un-satisfied, so
  anything that armed the window late -- a mid-line WY write, LCDC.5 coming
  back up -- started it at whatever pixel the shifter had reached. It is an
  equality on the pixel about to be emitted. late_wy_FFto2_ly2_1..3 bracket
  that dot at `83 + WX + (SCX and 7)` across the family's WX and SCX variants,
  which is this comparison's own dot and no other.

* WX = 7 was lumped in with the WX < 7 hardware-bug corner and started the line
  as a window line, charging nothing for it. It is an ordinary window start at
  screen x = 0 and pays the ordinary fetch restart (m2int_wx07_m3stat_*).

gambatte window 272 -> 295 of 476 (suite 3534 -> 3561), enable_display +2,
m0enable +2, mealybug m3_lcdc_win_map_change 92.8% -> 98.7%,
m3_lcdc_tile_sel_win_change 92.9% -> 96.1%,
m3_lcdc_win_en_change_multiple_wx 74.0% -> 79.1%,
turtle-tests/window_y_trigger_wx_offscreen 96.0% -> green. results.md
Total/Pass 934/672 -> 934/673.

GBMicrotest stays at 400: win7_a goes green and win7_b goes red, the two ends
of the same bracket. Those pairs put the WX = 7 restart at 1..4 dots where the
fetch costs 5; nine of win7_b's siblings already sit on that side of the same
one-dot fetch-phase error, so this is the pair joining them rather than a new
disagreement. results.md is regenerated for it.
```

## gb/ppu: the SCX&3 split at the mode 3 end is one uniform dot pair, not eight

`8e15cd673` — Mon Aug 3 07:16:51 2026 -0700

```
gb/ppu: the SCX&3 split at the mode 3 end is one uniform dot pair, not eight

GBMicrotest's hblank_int_scx0..7 splits by SCX & 3, and the note at
STAT_MODE_HOLD read that as "a mode-3 LENGTH residual per SCX & 7". It is
not. The eight ROMs differ only in the SCX byte they write, so each exercises
one residue and one sweep of a uniform dot offset reads out all eight windows;
a per-residue table cannot carry more information than that, which is the tell.
Swept -4..+4, the windows are one single 4-dot window shifted by one dot per
residue, and `c + (SCX&7)` fits them at exactly one c -- 170, not 172. The
split is what a uniform 2-dot error looks like when eight lengths one dot apart
are sampled by a ROM that counts M-cycles.

Nothing here changes behaviour: every constant added ships at 0 and compiles
out, field and branches included, and the full runner is row-for-row identical
(934 / 672 / 262, gambatte 3534, GBMicrotest 400, mooneye 112, Blargg 23,
mGBA 6967). gbgate is IDENTICAL on all 26 real ROMs over 1800 frames, the
eleven blargg cpu_instrs frames are still pixel-identical to SameBoy at frame
1200, and retired instructions move +0.0004% (Zelda) / +0.0005% (Crystal),
against a 0.002% reproducibility floor.

What is added is the instrument and the measurement:

* M3_END_EARLY (fifo_ppu.nim) shortens mode 3 without moving the pipeline --
  the one knob that says "the length is wrong" rather than "the phase is
  wrong". At 2 it takes GBMicrotest 400 -> 420 and costs mooneye
  hblank_ly_scx_timing-GS, four wilbertpol intr_2_mode0_scx{1,2,5,6}_timing_nops,
  twelve GBMicrotest int_hblank_* rows and 150 gambatte rows. The rows it
  breaks are the same residues {1,2,5,6} it fixes, measuring the same edge from
  the other side.
* LCD_ON_LINE0_TRIM / LCD_ON_LINE1_TRIM (gb.nim) reach the same 2 dots through
  the LCD-on path instead. The write-up above them tabulates all three routes
  (those two plus LCD_ON_HEAD_START=7) against what each one loses, and sorts
  the ROMs by the one thing that decides which answer they give: which line
  after an LCD enable they time. Line 0 says 0 dots, line 1 says -2, the
  post-boot steady state says -2, later frames say 0. No constant of any of
  these shapes is all four.

The closest cell by a wide margin is line 0 short by 2 and line 1 long by 2 --
+33 rows for -5, with mooneye, Blargg, Mealybug, mGBA, scx_during_m3 and every
other gambatte subdirectory untouched. It is not shipped because nothing
derives it: a scanline is 456 dots and hardware has no mechanism that makes one
454 and the next 458, so as it stands it is a fit to which ROMs disagree. The
note says so, and says where to look for a mechanism.

Two claims in the existing notes are corrected because they are what sends the
next attempt down the wrong path: the per-residue reading above, and
"hblank_ly_scx_timing-GS fixes LCD_ON_HEAD_START at 1 mod 4" -- a full runner
at 7 leaves mooneye and mooneye-wilbertpol row-for-row unchanged, so that ROM
cannot tell 5 from 7. What actually pins 5 is gambatte enable_display and the
scx_during_m3 reference PNGs.

ppu.skip_boot now clears the LCD-on trim window the same way it already clears
`first_line`: the HLE hand-off writes LCDC = $91 through write_byte, so the
LCD-enable branch fires at boot too, and without the reset a trim silently
retimes the first two lines after the BOOT hand-off as well. That is inert at
the shipping values and it is what keeps the two routes above from being
measured as one.
```

## gb/ppu: precompute the window's trigger position instead of testing for it

`ac4baf87e` — Mon Aug 3 07:45:54 2026 -0700

```
gb/ppu: precompute the window's trigger position instead of testing for it

The window model in the previous commit put its two rules on either side of the
shifter's emit -- the start before it, the re-trigger edge after it -- because
they need different dots. That is a SECOND branch on the mode 3 dot loop, and
this path does not have room for one: +1.7% of retired instructions on blargg
01-special, +0.9% on Pokemon Blue (DINGBAT_BENCH_COUNTERS, cycles= equal on
both arms, and per-function sizes confirm only the three edited procs moved, so
it is not an inlining cliff).

Neither rule's inputs -- LCDC.5, WX, the WY latch, fetching_window -- can move
except on a register write or a fetch restart, so the whole conjunction folds
into one cached `lx` value on GbFifoPpu that the shifter compares against once
per dot. The re-trigger edge then rides the same compare: it wants WX - 8 where
the start wants WX - 7, which is the same dot one pixel earlier in the shifter,
so it moves ahead of the emit and inserts its colour-0 pixel BEHIND the FIFO's
head rather than in front of it. Same pixel displaced, same dot, one branch.

Byte-identical to the previous commit everywhere it was checked: all 5,005
gambatte rows, all 24 mealybug percentages, the 36 GBMicrotest window rows and
results.md. Retired instructions vs main (2400 frames, 300 warmup):
blargg 01-special -1.39%, Pokemon Blue -0.56%, Pokemon Crystal -0.23%,
Zelda LA DX -0.26% -- the cached compare is cheaper than the conjunction main
was already paying.
```

## tools/gbppu: document the counter A/B and the WIN_REACT_PHASE sweep

`cebe97d89` — Mon Aug 3 07:49:37 2026 -0700

```
tools/gbppu: document the counter A/B and the WIN_REACT_PHASE sweep

counters.sh wraps DINGBAT_BENCH_COUNTERS around a gbgate build pair, with the
trap that cost an hour here written down: nim c failing leaves the previous
binary in place, so a stale slot B reports the previous revision's numbers and
they look like a real result. reactsweep.sh re-pins WIN_REACT_PHASE against the
mealybug rows that see the re-trigger edge.
```

## gb/ppu: a mechanism for CGB per-register write latency, measured and shipped off

`58342f709` — Mon Aug 3 10:32:24 2026 -0700

```
gb/ppu: a mechanism for CGB per-register write latency, measured and shipped off

The CGB PPU does not take a CPU write to a pipeline register on the same dot
the DMG one does, and it is not a single phase offset between the models: two
gambatte families with the identical shape move in opposite directions.
window/late_disable_{0,1,2} expects out0,out3,out3 on DMG and out0,out0,out3 on
CGB (CGB flips one M-cycle LATER), while late_disable_early_scx03_wx12_{1,2,3}
expects out0,out0,out3 on DMG and out0,out3,out3 on CGB (one M-cycle EARLIER).
What can produce both is an independent latency per register.

dingbat commits a write's byte at the top of its M-cycle (mem_write) and the
DMG families agree with that, so what this adds is the CGB DELTA and nothing
else -- which makes it invariant to whatever constant offset this tree's dot
grid carries against anyone else's. The mechanism parks the store and runs the
M-cycle's dots in pieces around it (mem_tick_ppu_latched), so the effect is
scheduled at a known dot rather than polled: nothing new runs per dot, and the
write path keeps the single `write_deferred` test it already had, with the dots
inlined on the common side of it. Six intdefines, one per register, so each can
be swept and justified on its own.

**All six ship at 0, and that is the result, not a placeholder.** Pan Docs
documents none of this, so gambatte's LCD::wxChange/wyChange/scxChange/
scyChange/lcdcChange (libgambatte/src/video.cpp) and SameBoy's DMG-only extra
display step (Core/display.c) are legitimate evidence here -- but they are
evidence, not an oracle, and scored against the families every one of their six
values is refused by this tree. Whole gambatte suite, one build per cell,
baseline 3561/5005:

  all 0 (control)                     3561  row for row identical to main
  CGB_WX_LATENCY=1                    3560  window -1
  CGB_WY_LATENCY=1                    3561  nothing moves at all
  CGB_WY_LATCH_LATENCY=4              3560  window -1
  CGB_SCROLL_LATENCY=2                3551  scy -6, scx_during_m3 -3, ...
  CGB_SCROLL_LATENCY=2, CAP=1         3559  scx_during_m3 -1, scy -1, e_d +1 -1
  CGB_LCDC_LATENCY=2 (tdsel 1)        3553  window -5, sprites -2, bgtiledata -1
  all six at gambatte's values        3553
  a uniform 4 on all six              3539  (the phase model, for the record)

Every moved row is a [cgb] row; Mealybug and GBMicrotest are scored against DMG
references only here, so gambatte is the whole instrument. Three reasons the
values are refused, each its own mechanism rather than a wrong constant:

  * SCROLL. The one clean per-device row a scroll latency fixes is
    enable_display/ly0_late_scx7_m3stat_scx0_274 (DMG $87, CGB $84; 2 dots gets
    both right). The same family's _scx3_17 expects $87 on BOTH devices and 2
    dots takes it to $84. The family brackets the latency above 1 and below 2,
    i.e. it does not bracket it -- and its _scx1 rows are already red on both
    devices, which is where the residual actually deciding one of them lives.
  * LCDC. All five window rows it costs are late_disable / late_reenable rows --
    the family SameBoy gives a CGB-only fetcher-abort path, which moves them the
    other way. The latency is not separable from the abort; the abort has to
    land first.
  * WX / WY / the latch. Traced with -d:gb_win_trace, the window/arg late_wy_*
    rows this was expected to buy are not decided by the latch dot at all: in
    late_wy_FFto2_ly2_3 the WY write lands on dot 93 of line 2 and the window
    starts on dot 92 on BOTH devices -- the write is already past the sample.
    The two runs diverge a whole FRAME earlier, in how long the ROM's vblank
    wait takes. Until that is understood no register latency can show up there,
    and that is most of the 42 dual-expectation window ROMs.

Left alone deliberately: the `_ds_` rows and gambatte's lcd_offset family (the
CGB CPU-to-PPU phase really is variable across 0..3 dots through a KEY1 switch
-- a different quantity, and CGB_LATENCY_CAP is what keeps a register latency
from being scored against them), mode 3 starting on dot 84 on CGB, the WX=166
and WX-1 DMG rules, and GB_update_wx_glitch.

Instruments, all off by default: tools/gbppu/cgbsweep.sh scores any setting
against a baseline row file in ~40 s with a zero-control that must reproduce
main; tools/gbppu/famflip.py collapses a row file into per-family flip points
with the two devices side by side; -d:gb_win_trace gains a WYLATCH line for the
per-frame LY == WY level.

Full runner unchanged: exit 0, Total 934 / Pass 673 / Fail 261, gambatte
3561/5005, GBMicrotest 400/513, Mealybug row for row, Mooneye 112/115,
Blargg 23/28, mGBA 6967/7008.
```

## gb: a DMG cart on CGB hardware is a third device, not the DMG

`73fbe71bc` — Mon Aug 3 11:19:11 2026 -0700

```
gb: a DMG cart on CGB hardware is a third device, not the DMG

dingbat had one model bit, `cgb_enabled`, standing for two different
questions, and every place it was read got one of them wrong.

The console decides timing and the SoC's own quirks: the DMG STAT-write
glitch, the OAM bus release inside mode 2, the serial tap, the line-144 STAT
lead. The *mode* decides the picture and the register map: a DMG cart on CGB
hardware runs in DMG-compatibility mode, where the CGB half of the IO map is
gone, BG map attributes and the OBJ attribute's palette/bank nibble are not
decoded, LCDC.0 is DMG's "BG on/off" rather than the CGB's master priority,
objects are ordered by X again, and every pixel goes through BGP/OBP before it
indexes palette 0 — while the timing stays the CGB's. Mooneye's whole misc/
directory is DMG-header carts run on CGB/AGB, so that is the device those rows
have been measuring all along.

Two symptoms of collapsing those together:

  * With the boot ROM skipped, a compatibility cart rendered as native CGB and
    through an all-zero palette, i.e. a black screen. That is what gambatte's
    three m2int_m3stat/nobg/*_cgb04c rows (the only DMG-flagged carts in the
    suite with a cgb04c expectation) were reading back as an unrecognised
    glyph, and what left the whole CGB half of the Mealybug references
    unscoreable.
  * With a real CGB boot ROM, the FF50 handoff cleared cgb_enabled outright,
    which handed a compatibility CGB the DMG's timing and the DMG's
    STAT-write glitch as well as its picture.

So `cgb_enabled` now means the console and nothing else, `cgb_native` becomes
a cached field meaning the mode, and each of the ~40 branches was sorted into
one or the other. Skipping the boot ROM installs the compatibility palettes it
would otherwise have written through BCPD/OCPD on its way out; only the
fallback palette is here, the one the boot ROM uses for any cart without a
Nintendo licensee, which is every homebrew and every test ROM. Reproducing the
per-title table would mean lifting boot ROM data and would change nothing
measurable.

gambatte 3561 -> 3563 (m2int_m3stat 27 -> 29; the third nobg row wants the
mode-3 end an M-cycle later and is a separate question). Nothing else moves —
the DMG half of every suite is untouched by construction, since a DMG console
never reaches a changed branch.
```

## tests: score the Mealybug references on BOTH devices

`b23a58aa0` — Mon Aug 3 11:19:25 2026 -0700

```
tests: score the Mealybug references on BOTH devices

Mealybug ships a `_dmg_blob.png` and a `_cgb_c.png` for nearly every ROM, and
this tree only ever read the first. Its author's reason for shipping two is
exactly the thing that was unmeasurable here: "These tests examine very
specific PPU behaviour/timings, so produce different results on a DMG compared
to a CGB."

So the CGB half goes in as 27 rows of its own. Every one of these carts is
DMG-flagged, so the CGB reference is DMG-compatibility mode — CGB timing, a
DMG picture — which is what the previous commit made renderable. The two
reference sets deliberately do not cover the same ROMs: the seven `*2.gb`
variants have a CGB reference and no DMG one, and m3_wx_4/5/6_change have a
DMG one and no CGB one. That asymmetry is the suite pointing at where it
thinks the models diverge.

Baseline, and it is not a flat copy of the DMG column:

  m3_scy_change            DMG 92.6%   CGB 81.4%   (and scy_change2 100.0%)
  m3_scx_high_5_bits       DMG 99.7%   CGB 100.0%
  m3_lcdc_win_en_change_multiple      61.5% on both
  4 rows green: m2_win_en_toggle, m3_lcdc_win_map_change2,
                m3_scx_high_5_bits, m3_scx_low_3_bits

`_cgb_d.png` is not wired: CGB-D caches the bitplane row differently again and
dingbat models one CGB.

Two fixes fall out of running them. The screenshot comparison could collapse
an RGB reference for a greyscale row but not the reverse, and seven of the
`_cgb_c` references are 1-bit greyscale (their frames are black and white
only) — those came out as a size mismatch, which the results writer drops as
an unrecognised detail string, i.e. a blank row rather than a failure. And
`mbscore.py` takes a device argument so the same 27 rows can be scored without
a runner pass.

Total 934 -> 961, Pass 673 -> 677.
```

## gb/ppu: split the CGB scroll latency in two, and sweep it on the new instrument

`7e34d1785` — Mon Aug 3 11:33:44 2026 -0700

```
gb/ppu: split the CGB scroll latency in two, and sweep it on the new instrument

The write-up above these constants ended "Mealybug and GBMicrotest cannot
arbitrate at all, because both are scored against DMG references only in this
tree. gambatte is the whole instrument." That is no longer true, so the table
gets a second column and the SCROLL constant gets taken apart.

SCY and SCX were one knob. They are not one behaviour: Pan Docs' "Mid-frame
behavior" gives SCY a per-model sample point and describes SCX's split (high
5 bits re-read per tile fetch, low 3 latched at the start of the line) with no
model qualifier at all. The new Mealybug CGB rows see the difference directly —
SCX at 1 dot costs two rows that are otherwise pixel-perfect, SCY at 1 dot does
not touch them — so a single constant could never be set without trading one
register against the other.

Both still ship at 0, and the reason is again a measurement, now from two
instruments that disagree:

  * The Mealybug CGB references put SCY's latency at 1 dot and it is a big
    move — m3_scy_change 82.0% -> 95.9%, about 3300 pixels, the largest single
    accuracy gain available anywhere in this file.
  * The documented value is 2 T-cycles, and at 2 the same row only reaches
    84.6%.

A measured 1 against a documented 2 is not a value to ship. It is a one-dot
residual elsewhere in the CGB pipeline being absorbed into this constant, and
that is precisely what a mode 3 starting one dot early on CGB would look like:
that shift moves every register's sample point together, turning a documented
2 into a measured 1. Two smaller refusals agree — m3_scy_change's own CGB-only
sibling m3_scy_change2 moves the wrong way at every setting, and gambatte loses
scy/scy_during_m3_spx08_ds_4, a double-speed row, i.e. the CPU-to-PPU phase
axis reading a register latency, which is the confusion CGB_LATENCY_CAP exists
to prevent and cannot prevent at a width of one dot.

So the mode-3 start dot has to be settled first and this row becomes the check
on it rather than the knob. Everything here is inert: gambatte 3563 row for
row, Mealybug 1794023 CGB / 510167 DMG matching pixels, both unchanged.
```

## tests: audit against the gbdev shootout, and wire up what it scores that we did not

`a27b567ff` — Mon Aug 3 11:34:11 2026 -0700

```
tests: audit against the gbdev shootout, and wire up what it scores that we did not

Diffed gbdev/GBEmulatorShootout's nine suites against the runner. It scores
almost nothing we do not already cover — no gambatte, no GBMicrotest, no AGE,
no wilbertpol fork, no MagenTests, no GBA at all — but four of its suites are
ROMs published nowhere else, and two groups of the game-boy-test-roms bundle we
already download were never globbed. +17 rows, 934 -> 951.

Added, all with machine-readable verdicts:

  SameSuite dma/ppu/interrupt (6 rows, 2 pass) - same bundle as the APU half
  and the same mooneye LD B,B verdict; build_samesuite_apu_tests just globbed
  apu/ only. These need no audio path, so they go in the default run rather
  than behind --apu.

  rtc3test (3 rows, 1 pass) - previously documented here as blocked on input
  scripting, because upstream it is one ROM behind a three-way button menu.
  The shootout ships three builds with the menu resolved at build time, so no
  parser needs porting from dingbat_bench. First MBC3 RTC coverage in the
  runner, on native-CGB references.

  CasualPokePlayer MBC3 (3 rows, 1 pass) and daid (5 rows, 1 pass) - fetched
  file-by-file from raw.githubusercontent at ShootoutRev, as FuzzARM is; ~30
  files under a megabyte against a 32 MB testroms/ archive.

Two mechanism changes this needed. alt_pngs, because hardware itself is
non-deterministic for daid's mid-scanline BGP write and the suite accepts any
of three outcomes. And grey_tolerance, implementing the shootout's own
compareImage rule (luma, within 50): its references are screen captures of a
running emulator, not framebuffer dumps, so they carry that emulator's CGB
colour correction - rtc3test's green is #009100, which the raw (X<<3)|(X>>2)
expansion cannot produce. Under exact matching a correct frame failed; under
the suite's own rule rtc3test-2 passes at 100%. Everything else stays exact.

Deliberately NOT added, and the reason is the interesting part: mealybug's
_cgb_c and _cgb_d references. 47 unused images in a bundle we already download,
apparently the only way to arbitrate a CGB-side mid-scanline question. They are
CGB *compatibility mode* captures - every mealybug cart is DMG-flagged, and all
47 images across both revisions contain only the six compat-palette colours and
not one native-CGB colour. Wiring them up scores 0-48% for a reason unrelated
to the PPU: a DMG-flagged cart forced to CGB renders a black panel here.
The same trap takes three daid rows, one of which would have gone in green
while asserting nothing (its reference is an all-black frame).

Baseline is honest, not tuned: 5 new rows green and gating, 12 red. Costs 1.9 s
of emulation, absorbed into the parallel phase; no opt-in flag needed.
```

## gb/ppu: lock VBK outside CGB mode instead of gating the fetcher

`835ecd087` — Mon Aug 3 11:36:37 2026 -0700

```
gb/ppu: lock VBK outside CGB mode instead of gating the fetcher

Suppressing the BG map attributes with a branch in the fetcher put that branch
in the mode 3 dot loop, and it cost +0.8% of retired instructions on Pokemon
Crystal (168537600 emulated cycles both arms, 22.206e9 -> 22.387e9
instructions). The same suppression is free one level up: VBK leaves the
register map with the rest of the CGB set when the boot ROM sets KEY0, so
outside CGB mode nothing can write bank 1 and the attribute plane is all
zeroes by construction. The fetcher goes back to reading it unconditionally.

The FF4F READ stays on cgb_enabled deliberately -- with the bank pinned it
answers 0xFE either way, which is what mooneye misc/bits/unused_hwio-C reads
back and what AGE records for a CGB in non-CGB mode.

gambatte 3563 row for row, Mealybug 1794023 CGB / 510167 DMG, all unchanged.
```

## gb: write down the model splits this tree still gets wrong

`7b01407c2` — Mon Aug 3 11:44:21 2026 -0700

```
gb: write down the model splits this tree still gets wrong

An audit of every place dingbat branches on the model, and every place
hardware does and dingbat does not, against Pan Docs, the mealybug PPU
document, and the per-model expectations mooneye/AGE/gambatte carry in their
own filenames. It goes next to the two model bits because that is where the
next person will be standing when they need it.

Ordered by whether anything in the suite can see it. Measurable and unfixed:
the DMG-only OBJ fetch cancel on LCDC.1 (and the CGB's matching refusal to
skip the penalty), the CGB-only LCDC.4 mid-fetch glitch, the CGB-only window
Y-condition reset on LCDC.5, WX=166 and the WX+1 trigger as monochrome bugs,
OAM DMA above $DFFF, OPRI, and an
APU with no model branch anywhere despite three documented ones. Unmeasurable
here: HALT granularity, DI's contested CGB delay, joypad settling, the IR
port, STOP.

And the boundary: CGB-revision splits are out of scope, because this tree
models one CGB and every reference it is scored against is CPU CGB C.
```

**Superseded 2026-08-10 on both counts.** `$FEA0-$FEFF` no longer answers
`0x00` on every model (`GbUnusableRegion`), and CGB-revision splits are no
longer out of scope: `--cgb-rev=<0|A|B|C|D|E>` selects the machine at runtime
and three behaviours now hang off it. The last sentence survives as the reason
the *default* is what it is — the default CGB moved to `grCgbC` in the same
change, so "every reference it is scored against is CPU CGB C" is now what the
enum says rather than something only this paragraph knew. See
`docs/gb-failure-triage.md`, 2026-08-10, and `docs/gb-hardware-revisions.md`
§2.3.

## gb: HDMA1-4 are write-only; reads return $FF

`923437d9d` — Mon Aug 3 11:49:21 2026 -0700

```
gb: HDMA1-4 are write-only; reads return $FF

Pan Docs (CGB Registers) marks FF51/FF52 "VRAM DMA source (high, low)
[write-only]" and FF53/FF54 "VRAM DMA destination (high, low)
[write-only]". dingbat handed back the stored byte instead, so a CGB
title could read its own HDMA source/destination registers and see them.

Pan Docs does not say what a read of a write-only register returns, so
the value comes from the ROM family that measures exactly that:
gambatte's ff51_bits, ff52_bits, ff53_bits and ff54_bits each expect FF
on cgb04c -- not one bit of any of the four is readable. dingbat was
returning C0, 00, 80 and 80. The written bytes are still kept, because
ppu_start_hdma builds the transfer addresses out of them; they are just
not visible to the CPU.

gambatte 3561 -> 3565 (dma 112 -> 116/229); no other suite moves.

Also adds the harness this came out of, tools/gbdiff: a black-box
differential oracle against docboy (MIT), built to the same shape as
tools/gbfuzz and tools/gbgate and reusing gbfuzz's dingbat_gb_nav as the
dingbat side. No docboy code is copied and no behaviour here is
justified by what docboy does -- see tools/gbdiff/README.md, which also
records the two cases where docboy is the one that is wrong.

GDMA_SETUP_MCYCLES lands at 0, i.e. no behaviour change: gambatte's
gdma_cycles_* family says dingbat's general-purpose VRAM DMA is short of
the hardware, but tools/gbdiff/gdma_sweep.sh reads all nine pairs out at
every setting and no constant satisfies them -- the residual tracks SCX,
so the missing time is not a fixed setup cost. The knob and the measured
table are committed so the next attempt starts from the evidence rather
than from a guess.
```

## tools/gbdiff: read gambatte glyphs in-process, and decode its diagonal 7

`dd748a396` — Mon Aug 3 12:21:03 2026 -0700

```
tools/gbdiff: read gambatte glyphs in-process, and decode its diagonal 7

Two fixes to the result reader, both found by running it over the whole
1,532-ROM CGB priority set.

gambatte does not draw 7 as a seven-segment figure at all -- it is a top
bar and a diagonal stroke down to the left, so the only sample point it
lands on is the top bar. The reader called that shape unrecognised, which
turned every genuine 7 into '?' and mislabelled a real DOCBOY_ONLY
cluster (dma_oam_read, dma_vram_read, dma_hiram_read: expected 7,
dingbat 0, docboy 7) as BOTH_FAIL. No other hex glyph in this font leaves
just the top bar, so the signature is unambiguous.

The sweep also spawned readout.py four times per ROM, which dominated its
runtime -- 350 ROMs in 31 minutes. glyphs() is now importable and
gambatte_ab.py calls it directly.
```

## tools/gbdiff: record what the first CGB sweep found

`e1d0c9b0f` — Mon Aug 3 13:29:13 2026 -0700

```
tools/gbdiff: record what the first CGB sweep found

Scored against gambatte's own filenames over the 503 CGB rows dingbat
fails in the seven priority directories: 296 DOCBOY_ONLY, 191 BOTH_FAIL,
14 BOTH_PASS, 2 DINGBAT_ONLY. On 59% of the CGB rows dingbat gets wrong,
some emulator gets the right answer, so the behaviour is reachable and
the rows are worth chasing.

The per-directory split is the actionable part -- sprites 62/65,
speedchange 83/102, dma 71/117, window 63/103 -- and so is the outlier:
oamdma is only 17/114, because it is mostly BOTH_FAIL, with 92 rows where
the two emulators give different wrong answers (the
oamdma_src*_busypop/busypush bus-conflict family). Nothing there can be
adjudicated against docboy. scx_during_m3 and scy barely appear because
their failures are almost all on the DMG row.

Caveats recorded with the numbers: 10 of the 296 are rows where dingbat's
glyph did not decode, and the 14 BOTH_PASS rows are a framing difference
between this harness and the suite's own runner.
```

## gb: HDMA1-4 are the transfer's counters, and a halted CPU stalls it

`68aaed17d` — Mon Aug 3 14:10:29 2026 -0700

```
gb: HDMA1-4 are the transfer's counters, and a halted CPU stalls it

Four HDMA rows were red, and the four had three different causes. Only one of
them was the HBlank block firing when it should not have; the other two were
about what a transfer is made of. All three come out of Pan Docs' FF51-FF55
section and the ROMs that bracket it.

1. A halted CPU stalls an armed HBlank transfer.

   "Upon halting the CPU (using the halt instruction), the transfer will also
   be halted and will be resumed only when the CPU resumes execution." The
   block is transferred on the CPU's bus, and a halted CPU is not on it. So the
   mode-0 edge now only marks a block DUE when the CPU is halted, and cpu.tick
   pays it at the M-cycle the halt ends -- ahead of that wake's own interrupt
   dispatch, since the DMA has the bus first. A block stays owed only for as
   long as its HBlank lasts: halt across the end of mode 0 and that line's block
   is never transferred at all, which is what gambatte's hdma_m3halt_m1unhalt_
   hdma5 measures (it halts through the rest of a frame and finds the length
   untouched). The check sits inside the halted branch, so a running CPU pays
   nothing for it -- and inside that branch it is asked only on the M-cycle the
   halt ends, which is why cpu.tick now opens `handle_interrupts` up rather than
   calling it: asking on every halted M-cycle instead is a measured 0.3% of
   Pokemon Blue, whose main loop is halted.

   magen/hblank_vram_dma went from every pixel blue -- its documented "the
   HBlank operation executed even though the CPU is halted" -- to every pixel
   green.

2. HDMA1-4 are the transfer's address counters, not a template it is built
   from. A block advances them, and a write to FF55 does not reload them.

   same-suite dma/gbc_dma_cont runs two one-block GDMAs back to back and writes
   the address registers once; hardware copies two tiles, because the second
   transfer continues where the first stopped. It also means a write to one of
   FF51-FF54 part way through a transfer moves the blocks that follow it --
   what gambatte's hdma_late_destl pair measures, which stays where it was
   (one of its two rows green) because what separates those two is the M-cycle
   the write lands on, not whether it is seen at all.

   Making them counters is also what makes the destination's mask legible. The
   mask is on the address the counter DRIVES ("the upper 3 bits are ignored --
   destination is always in VRAM"), not on the counter: dma_dst_wrap's two ROMs
   set the same VRAM address from two different HDMA3 values ($DF, $FF) and get
   different results, the second stopping where the 16-bit counter would step
   off the top ("if the transfer's destination address overflows, the transfer
   stops prematurely"). The source wraps there instead of stopping
   (dma_src_wrap). The old code masked the counter and then added an unmasked
   offset to it, so a transfer running off the end of VRAM wrote into cartridge
   RAM.

3. FF55's bit 7 is "no transfer active", on every path into that state.

   "This works under any circumstances - after completion of General Purpose,
   or HBlank Transfer, and after manually terminating a HBlank Transfer." Only
   completion set it here, because completion happens to leave the length at
   $FF; a terminated transfer read back with bit 7 clear, i.e. as still running.
   That single byte is the whole of both hdma_lcd_off and hdma_mode0: each
   copies its block and decrements correctly, then reads $00 where hardware
   reads $80. (Both also pin that the write's own low bits land in the length
   register whether it starts or stops a transfer -- $00 written to stop a
   transfer with three blocks left reads back $80, not $82.)

Scores: same-suite/dma 1/4 -> 4/4, magen 6/7 -> 7/7, gambatte/dma 116 -> 120,
gambatte total 3567 -> 3571, results.md 681 -> 685 of 978. Nothing else moved
in any suite. Inside gambatte/dma, eight rows turn green and four turn red, and
all four are the "_2" sibling of a pair whose "_1" now passes: hdma_late_length,
hdma_late_m3halt_m2unhalt_scx1, and the two hdma_transition_*halt_late_unhalt_
scx1 pairs each bracket one M-cycle, and the boundary is now on the other side
of it. That is the CPU-vs-PPU phase cluster the rest of that family lives in,
not this change's model -- the block is now placed by the halt's end rather
than by the mode-0 edge, and where exactly inside that M-cycle it lands is the
open question there.

The save-state field sequence is unchanged: HDMA1-4 are written out of the
counters and read back into them, and the block index that used to be a
separate field is folded into the counters on load, so states from before this
resume where they left off. No payload-revision bump.

Verified: runner exit 0; tools/gbgate byte-identical on all 26 real GB/GBC ROMs
(1200 frames) and on the six CGB titles again over 4000 driven frames; the
eleven blargg cpu_instrs frames still pixel-identical to SameBoy at frame 1200;
gbhdmatest.gbc (the Crystal-boot re-entrancy guard) survives with a
byte-identical frame; savestate-compat and rewind suites pass. Retired
instructions (min of interleaved runs, identical emulated cycle counts):
Crystal +0.002%, Zelda LA DX -0.001%, Shantae -0.10%, Pokemon Blue +0.03%.
```

## gb: the SCY dot is in the OBJ fetch phase, not in the CGB latency

`67c0ed5f3` — Mon Aug 3 14:29:35 2026 -0700

```
gb: the SCY dot is in the OBJ fetch phase, not in the CGB latency

CGB_SCY_LATENCY measures 1 against a documented 2, and the residual absorbing
that dot is now located: it is the BG fetcher's phase across an object fetch,
it is device-independent, and it is the ruler both mealybug SCY ROMs measure
with.

mealybug m3_scy_change is eighteen measurements, not one. Its OAM table is
Y = 16 + 8k, X = k for k = 0..17, so each 8-line band carries one object whose
X marches down the screen -- and per Pan Docs' OBJ penalty algorithm that X is
what sets the wait term, hence the phase between the ROM's every-2-M-cycle SCY
write burst and the fetcher's three per-fetch SCY reads. m3_scy_change2 states
the design in its own header ("Sprites are positioned to cause the write to
occur on different T-cycles of the background tile fetch").

Scored per band rather than per frame, the two halves separate cleanly. In the
five bands whose object has no wait term -- exactly the bands where the DMG
reference says this tree's phase is already pixel-exact -- the CGB reference is
PIXEL-EXACT at CGB_SCY_LATENCY = 2 and wrong at 1. In every band with a wait
term, 0 and 1 tie and 2 collapses -- and those are exactly the bands where the
DMG reference already disagrees with this tree, with no CGB constant in play.
Decoding the reference against dingbat's own traced read dots puts hardware's
post-object fetch grid `wait` dots behind ours, which is the one line that
advances the fetcher during a penalty.

Nothing ships at a new value. Every one of the seven CGB write latencies was
re-swept alone against both instruments and the table is recorded: SCY is the
only register whose instruments move at all, so the shortfall is not the
systematic one-dot-per-register signature a late CGB mode 3 start would leave.
Deleting the fetcher tick outright is one dot short of what the band table
wants and costs gambatte 3567 -> 3542, so the exact rule is still open.

Also here: SCY writes join the -d:gb_m3_trace instrument, -d:GB_TRACE_LY=-1
traces every line (an 18-band ROM cannot be read one line at a time), the
object trigger prints its penalty terms, and mbscore.py takes $MBROOT so a
private ROM cache can be scored.

No behaviour change: every edit outside the comments is inside
`when defined(gb_m3_trace)`. Full runner unchanged, row for row.
```

## tools/gbppu: how to read an m3_* frame as eighteen measurements

`0d51e604d` — Mon Aug 3 14:33:31 2026 -0700

```
tools/gbppu: how to read an m3_* frame as eighteen measurements

The whole-frame percentage these ROMs are usually scored by averages one
measurement per 8-line object band together, which is how a constant gets
fitted to a residual belonging to a different band. Write down the per-band
method instead, plus the decode that makes a band quantitative with nothing
but the ROM itself: NOP out its writes for a glyph table, take the write and
read dots from -d:gb_m3_trace -d:GB_TRACE_LY=-1, and fit the dot offset.

Also documents $MBROOT next to the existing $GAMROOT.
```

## gb/ppu: the BG fetch restarts on the dot it pushes, and the pipeline leads by 2

`fe29292e6` — Mon Aug 3 17:40:04 2026 -0700

```
gb/ppu: the BG fetch restarts on the dot it pushes, and the pipeline leads by 2

The OBJ families read short -- mealybug m3_scy_change's per-object bands sat at
~960/1280 wherever the penalty had a wait term, and 79 of the 153 cells of
GBMicrotest's ppu_spritex_vs_scx penalty table were a dot over. Both were the BG
fetch cycle's own phase, and neither was the OBJ penalty algorithm.

A push taken at the Get-Tile-Data-High step fell through the Sleep and Push
steps it had already served instead of restarting the fetch. That puts the
cycle's two idle dots at the HEAD, where Pan Docs' fetcher has them at the tail
(step 4 is what waits for the FIFO), and leaves every VRAM read on the line two
dots late. The 172-dot line is the check: 6 dots of throw-away fetch plus 6 of
the real one plus 160 pixels only adds up if the first push is immediate.

(Amended 2026-08-09: the 12-dot head is right and the immediate push was the
right conclusion **for a six-dot throw-away**, but the split is 4 + 8, not
6 + 6 — the discarded fetch is a `B0` and the first real cycle runs to its own
push slot. mealybug m3_scy_change reads the split off directly; see
`M3_THROWAWAY_DOTS` at `tick_bg_fetcher` and `docs/gb-mealybug-sources.md` §3.4.
Nothing about the phase of the reads from the second tile on changes, which is
why the paragraph above still holds everywhere it is used.)

Those two dots were cancelling a real two-dot lead of the whole pipeline over
the CPU's register view, which is why neither error was visible on its own and
why fixing either alone is worse than main. M3_PIPE_DELAY carries the lead and
now ships at 2; mealybug m3_bgp_change pins it, being a row with no objects on
it at all (87.3% -> 93.5% DMG on the lead alone).

With the phase right, four things derived against the old one were re-derived
and three moved. A window start restarts at fetcher step 1, not the step 1 + 1
the old padding needed. WIN_REACT_PHASE re-swept from 5 to 7, where all three
m3_wx_*_change ROMs are pixel-exact for the first time. CGB_SCY_LATENCY and
CGB_SCX_LATENCY both ship at the documented 2: each was refused by a mealybug
CGB row that was reading this phase, and each now has gambatte and mealybug
agreeing on it. Pan Docs' X = 0 exception is spelled out rather than derived --
an object at OAM X 0 costs a flat 11 dots and the derived form ramped it 11..6
across the SCX residues.

tick_sprite_fetcher is deliberately unchanged. Re-measured on the fixed phase,
all four candidate rules for what the BG fetcher does during a penalty give the
penalty table 0/153 and land within a quarter of a percent of each other on
mealybug and one row on gambatte, so the one that stays is the one Pan Docs
writes down.

  tools/gbppu/objtab.py is the instrument that settled it: ppu_spritex_vs_scx
  never writes $FF82 and stops at its first failing assertion, so the runner
  cannot score it and the screen says only "something failed". This reads all
  153 cells back as dots, differenced against the same build's no-object line.

  results.md 685 -> 691 passing. gambatte 3571 -> 3614 (sprites +19, window
  +27, m0enable +2, bgtilemap -2, scx_during_m3 -3). Mealybug DMG 510167 ->
  517987 matching pixels and CGB 1794023 -> 1814452, with m3_wx_4_change,
  m3_wx_4_change_sprites (both devices) and m3_wx_5_change newly pixel-exact.
  GBMicrotest sprite4_4..7_b go green, win10_scx3_b goes red.

  The four regressions are named and separately caused. bgtilemap and
  scx_during_m3 lose five rows to M3_PIPE_DELAY's tail accounting, which decides
  the last two pixels of a line early; the fix for that is to move the WRITE
  rather than the pipeline and is a bus-layer change. mealybug-cgb
  m3_lcdc_win_map_change2 drops to 99.4% -- every DMG m3_lcdc_* row went UP and
  every CGB sibling went down, which is the CGB LCDC write latency the file
  already documents as blocked on the fetcher-abort path. win10_scx3_b is one
  M-cycle from its boundary in a family whose end-of-mode-3 dot is separately
  three dots late (ppu_sprite0_scx*, which have no object in OAM at all).

  A nonzero M3_PIPE_DELAY compiles the lead machinery into the mode 3 dot loop,
  which is +5.51% of retired instructions done naively -- mostly 52 opcode
  bodies crossing clang's inline threshold, not the branches. Three mitigations
  take that to +1.03%, and the whole change measures +1.22% on Pokemon Crystal,
  +1.49% on Zelda DX and +1.16% on Pokemon Blue against main. Each mitigation is
  marked at its site; the accounting is at M3_PIPE_DELAY.

  tools/gbgate over the 26 real ROMs: 21 identical, 3 titles diverge by 1-2
  pixels out of 23040 on one scanline each (Zelda x=98 y=48, Pokemon Blue
  x=95..96 y=8, Prehistorik Man x=19..20 y=0) -- a mid-line write landing a
  pixel over, which is what this change is. blargg cpu_instrs 11/11 still
  pixel-identical to SameBoy at frame 1200.
```

## gb/ppu: the mode 3 lead costs a quarter of what it did, and the rest is a floor

`a6bb3b850` — Mon Aug 3 18:45:03 2026 -0700

```
gb/ppu: the mode 3 lead costs a quarter of what it did, and the rest is a floor

151b952 turned the pipeline's two-dot lead on and paid for it. This makes the
same lead cheap, with every test result byte-identical: Total 978 / Pass 691 /
Fail 287, gambatte 3614/5005, all three results files differing from the
committed baselines only in the timestamp line, tools/gbgate 26/26 IDENTICAL
against main, and the blargg canary 11 of 11 pixel-identical to SameBoy at
frame 1200.

Retired instructions, 2400 frames after 300 of warm-up, minimum of four runs per
arm, both arms built by the same builder in the same session (see the
measurement note below for why every one of those qualifiers is load-bearing).
`cycles=` is identical across each row.

  against main, tools/gbgate slots -- the same two builds the 26-ROM gate ran:
                     151b952           here          delta    cycles=
  Link's Awakening 22,928,871,297  22,791,244,391   -0.600%  168,395,236
  Pokemon Crystal  22,445,942,361  22,299,897,652   -0.651%  168,537,600
  Pokemon Blue     22,617,754,920  22,465,551,148   -0.673%  168,515,104

  and against 93f7cc2, three trees built identically by hand:
                     93f7cc2         151b952          here
  Link's Awakening 22,668,618,548  22,878,541,833  22,732,843,193
                                       +0.926%        +0.283%
  Pokemon Crystal  22,173,924,299  22,384,973,644  22,244,013,187
                                       +0.952%        +0.316%

So roughly 69% of what 151b952 spent comes back, and what is left of it is a
third of a percent rather than one and a quarter.

Where the cost actually was. Building each tree with `-d:M3_PIPE_DELAY=0`
compiles the whole lead mechanism out and splits the bill in two:

                        lead machinery    everything else
  151b952, DMG            +0.83%              +0.10%
  151b952, CGB            +0.72%              +0.23%
  here,    DMG            +0.22%              +0.06%
  here,    CGB            +0.12%              +0.20%

The two halves are additive to within a hundredth of a point on both titles. So
it was all the lead, and the lead is arrangement rather than work -- the pipeline
runs the same 160 dots a line either way. Worth recording that CGB_SCX_LATENCY
and CGB_SCY_LATENCY going 0 -> 2 in the same commit, which turns on a whole
write-pipeline in memory.nim and four functions with it, is +0.01%: free.

Four edits, three of them one line.

  * the head-delay block loses its `continue` and falls into the dot loop
    instead. Same sequence of actions -- the loop's own `remaining > 0` exits
    when the head ate the whole tick, and fetcher_retired cannot have moved
    across dots on which nothing ran -- and it saves the outer loop a back edge.
  * fifo_burst_tail is {.inline.} again. It was {.noinline.} to keep a second
    copy of fifo_pipeline_dot out of fifo_tick_slow, which was the right call
    when the lead landed; with the mode 3 branch settled it costs +172 bytes
    there, changes the size of NOTHING else in the binary, and is worth -0.11%.
  * m3_delay is a uint8, so the once-per-mode-3-M-cycle "is the head spent?"
    test is `ldrb`+`cbz` rather than `ldr`+`cmp`+`b.le`. -0.08%.
  * the fourth is what the three do together, and it is not their sum: isolated
    they add to 0.22 points and the combination measures 0.64. The per-function
    size diff has three rows -- fifo_burst_tail gone, fifo_tick_slow -36,
    sprite_fetch_merge -24 from the field-offset shift -- and NO opcode body
    moves, so this is not the inline cliff docs/gb_oam_dma_cost.md describes. It
    is the mode 3 branch getting out of the dot loop's way.

Two hypotheses died. fetcher_retired's four extra terms are +0.04%, not the
cost, and splitting them into a {.noinline.} tail behind the first compare -- the
shape that should make it one instruction on the dot loop -- measures WORSE,
because clang already folds that compare into the dot loop's own `lx` test and
the split takes that away. And the head delay does not go below this: the four
spellings measured span 0.16 points against a build with the head removed
outright, this one is the cheapest of them at +0.162%, and the floor underneath
is +0.19% for the byte test alone. Spending the head dots where mode 3 begins is
the only way to delete that test and it does not work -- a double-speed M-cycle
is two dots and the mode 2 -> 3 transition is one of them, so a lead of 2 always
leaves a dot for the next tick to find.

Measurement. Two things invalidate a naive A/B here and both produced a wrong
answer in this work before they were understood, so they are written into the
file next to the numbers they explain:

  * proc_pid_rusage's ri_instructions includes kernel work charged to the
    process, so a contended run reads HIGH -- 0.5% high at load average 100, and
    correlated with the run's own fps. That is larger than every effect above.
    "Reproduces to 0.002%" holds on an idle machine and nowhere else. Take the
    minimum of four or more runs.
  * two builds of the SAME source in different directories differ by up to 0.25%
    (nimcache path length reaches the generated C, `_uNNNN` renumbering with
    it). Both arms have to be built the same way; the 93f7cc2 column above moves
    0.23% between two builders on its own.
```

## gb/hdma: a source outside cartridge or WRAM transfers $FF, not a read

`a7b635501` — Mon Aug 3 18:52:24 2026 -0700

```
gb/hdma: a source outside cartridge or WRAM transfers $FF, not a read

Pan Docs (FF51-FF52) gives the HDMA source as "$0000-$7FF0 or $A000-$DFF0" --
the cartridge and WRAM, and nothing else. dingbat read whatever the address
decoded to, so a transfer sourced from HRAM, OAM or VRAM copied that region
instead of the open bus.

The value is measured by the suite rather than chosen: gambatte's
dma_hiram_read_result GDMAs $FF80 -> $8000 and then does LD A,($8007) / SUB $FE
expecting 1, i.e. the byte that landed is $FF. Its three siblings
(dma_hiram_read, dma_oam_read, dma_vram_read) only assert that the destination
does not match the source, which is why they were not enough on their own.

Decided once per block rather than per byte: HDMA2 masks the low nibble away,
so a block is 16 aligned bytes and cannot straddle a region boundary. That
keeps it to one compare per 16 bytes, in a path that is already cold.

gambatte dma 120/229 -> 124/229, +4 rows and nothing down; full runner exit 0
with every other suite and subdirectory unmoved. dma/dma_src_wrap, which pins
the source wrapping past $FFF0, still passes.
```

## docs: rank the remaining GB test failures by leverage, and correct four stale notes

`54b7b7be3` — Mon Aug 3 19:05:39 2026 -0700

```
docs: rank the remaining GB test failures by leverage, and correct four stale notes

Assigns every remaining failing Game Boy row to a root-cause bucket and ranks
the buckets by rows recoverable per unit of work. docs/gb-failure-triage.md is
the deliverable; the source changes are corrections to notes it falsified.

The honest denominator is 1,674 individual failing sub-tests, not 287 -- 45 of
the 287 rows are aggregates standing for 1,432 sub-test failures. 37 of those
are not recoverable at all: 31 GBMicrotest ROMs never write $FF82, the byte
--mode=microtest scores, so the harness reads uninitialised HRAM forever (all
513 bundled ROMs scanned for E0 82 / EA 82 FF; the 31 without one are exactly
31 of the failing rows and none of them passes). The rest are AGE
revision-locked pairs, a boot-ROM dumper with no verdict, and two rows already
known to be unscoreable.

Two cross-cuts reframed the ranking. 208 ROMs pass on DMG and fail on CGB, 90
of them oamdma -- whose busypush/busypop shapes are 312/312 green on DMG. And
603 of the 982 famflip lines with a mismatch have dingbat's flip point entirely
OUTSIDE the family's window, bidirectionally, so the dominant shape is not the
one-M-cycle phase error it is usually treated as; only 133 lines are that shape.

The headline actionable finding is LY0-RESYNC: 125 rows across scy, bgtilemap,
bgtiledata, scx_during_m3 and bgen fail on scanline 0 ONLY, with lines 1-143
pixel-exact. They were all filed as mid-scanline pipeline failures; they are the
vblank -> LY=0 re-sync, and the fix is in cold code.

The mode-3-edge error and the mode-0 STAT lateness are shown to be ONE defect,
in the readback rather than the edge: of 65 ROMs, 30 of the 38 that want the
"2 dots" read $FF41 and 24 of the 27 that refuse them do not. Hardware samples
mode 0 at cc-2, bracketed from both sides; dingbat no earlier than cc-5, and one
of those dots is unexplained even at the shipping STAT_READ_LAG. The eight
wanters that do not read STAT are a genuinely separate LCD-enable line phase.

Four in-tree notes are corrected in place because this pass falsified them:

* gb.nim, CGB_*_LATENCY: late_wy_* is NOT "decided a whole frame earlier".
  13 of the 14 families have different EXPECTED values per device, all shifted
  one M-cycle the same way -- hardware differs, and dingbat models no device
  difference at all in 11 of the 14. CGB flips earlier, so every positive
  latency in that block moves it the wrong way.
* gb.nim, the LCDC bullet: re-measured, =1 is 3616 (+3/-5), and it shifts the
  whole late_disable family by one step rather than changing where it flips --
  the signature of the missing fetcher-abort, whose two mealybug rows are bad on
  BOTH devices, so it is not purely CGB.
* fifo_ppu.nim, M3_PIPE_DELAY: the tail does not cost scx_during_m3 anything
  (31/141 at both settings). 2 vs 0 is 3618 vs 3596 -- it buys window +19,
  scy +6, bgtiledata +1, m0enable +2 for bgtilemap -2 and sprites -4. The
  bus-layer change it points at has already landed.
* tools/gbppu/README.md: gambatte/sprites is NOT the STAT-read lag. It is a
  strict local maximum -- 393 at L=3, 354 at 2, 245 at 4 -- and the OBJ penalty
  is exactly Pan Docs' 11 dots per object, measured.

tools/gbppu/famflip.py stripped the _out tag with a single-character hex class
where the tag is 1-20 digits, so exactly the families containing a flip were
split into one family per step -- the case the instrument exists to show.
Recovers 276 rows into 74 families and removes the spurious +9/+29 deltas.

No scored row moves: 3618/5005 before and after, runner exit 0.
```

## gb: CGB raises the line-144 mode 2 STAT one M-cycle before vblank

`51a75a2c8` — Sat Aug 1 16:29:49 2026 -0700

```
gb: CGB raises the line-144 mode 2 STAT one M-cycle before vblank

mooneye's vblank_stat_intr pair times the extra OAM/mode-2 STAT interrupt
that fires when the PPU enters vblank on line 144. Both ROMs reset DIV a
fixed number of NOPs into line 143 and read it back in the handler, so the
NOP count that flips the DIV byte from 1 to 0 pins the interrupt to an
M-cycle. The vblank rounds bracket it at 54/55 NOPs on every model; the
STAT rounds bracket it at 54/55 on -GS (DMG/MGB/SGB) but at 53/54 on -C
(CGB/AGB/AGS), which places the CGB STAT exactly one M-cycle -- 4 dots --
ahead of the vblank interrupt. dingbat raised both together on every model,
so misc/ppu/vblank_stat_intr-C failed.

The source is now expressed as m2_line144(): high on line 144 in mode 1 as
before, and on CGB also for the last 4 dots of line 143, while the PPU is
still in mode 0. Nothing else happens on that dot, so the FIFO renderer's
idle-skip target for H-Blank stops there on line 143 (only) and runs the
STAT edge detector. That is the whole per-dot cost of the change: one
`ly == 143` compare, false on 153 of every 154 lines, in the skip target
select. Best-of-8 dmg-acid2/cgb-acid2 benchmarks are unchanged (new build
marginally ahead of old, inside the noise), and all 32 mealybug renders are
byte-identical.

mooneye: 150 -> 151 pass.
```

## gb/ppu: the window's re-trigger edge injects a colour-0 pixel

`456af3bc7` — Sat Aug 1 16:30:30 2026 -0700

```
gb/ppu: the window's re-trigger edge injects a colour-0 pixel

Re-reaching WX while the window is ALREADY the active fetch source is not
a no-op, which is what the FIFO renderer assumed: tick_shifter's window
check was guarded on `not fetching_window` and simply dropped the edge.

What hardware does there is narrow. The window does not restart -- the
window tile position and current_window_line both carry on, and every
pixel after the edge is the pixel it would otherwise have been. The edge
injects ONE pixel of colour 0 at the lowest priority in front of the BG
FIFO, displacing the rest of the line one pixel right. That is exactly
what mealybug m3_wx_4_change's reference image is: our previous output
with a single colour-0 pixel spliced in at WX-7 and everything from there
shifted by one. Colour 0 rather than a shade is what lets an OBJ-behind-BG
sprite show through the injected pixel, which is the extra thing
m3_wx_4_change_sprites checks -- its reference has the sprite's grey at
that pixel, not the palette-0 shade, and both now agree.

The edge is swallowed on seven fetcher steps in eight. mealybug drives WX
from LY so the re-trigger walks one pixel per line, and the artifact shows
up on one line in eight; the ROM's own comment names the surviving step as
the window tile-map (nametable) read. Which of this renderer's eight
fetch_counter positions that read corresponds to is a property of our
phase, not of hardware -- the discarded first fetch and the extra
Get-Tile-Data-High push both shift it -- so it was settled by sweeping all
eight positions against the three ROMs at once. Position 5 is the unique
best on all three (intdefine'd so the sweep can be re-run).

  m3_wx_4_change_sprites   10 ->   4 mismatching pixels
  m3_wx_4_change          229 ->  53
  m3_wx_5_change          638 -> 142

m3_lcdc_win_en_change_multiple moves 63.9% -> 61.5%. That ROM toggles
LCDC.5 mid-line, which this renderer does not model at all (the fetcher
never stops reading window tiles), so its output is already unrelated to
the reference; the reactivation edge lands somewhere else inside that
noise. Nothing else in the suite moves: 182/150/32 before and after, no
pass->fail flips.

The hot path is untouched. The added compare sits in the `elif` of the
existing `not fetching_window` early-out, so a dot with no active window
-- every dot of every line in a game with no window, and every dot left of
WX in one that has -- runs exactly the instructions it ran before.
```

## tests: score DenSinH/FuzzARM, 50 000 randomized ARM/Thumb tests

`d9b2d6882` — Sat Aug 1 16:31:31 2026 -0700

```
tests: score DenSinH/FuzzARM, 50 000 randomized ARM/Thumb tests

Adds the last cheap GBA suite dingbat was not running. Five prebuilt ROMs
(GPL-3.0, downloaded and cached like every other external suite — nothing
vendored), pinned to commit a675329 because the repo has no release tag.

New --mode=fuzzarm. The ROM reports a failure, waits for a button, and
continues, so the mode drives that gate (hold A one frame, release the next)
and reports EVERY failing test rather than the first — the point of a
randomized suite. The verdict comes from the ROM's own 16-word dump at the
base of eWRAM (state, opcode+shift, inputs, got vs expected r3/r4/CPSR), so
no BIOS, PPU or pinned frame hash sits between the CPU and the score, and a
failure says *what* broke, not just *that* something did.

"Done" is the unique `b .` self-branch located by scanning the image. The
obvious "PC unchanged across two frame boundaries" signal that the jsmolka
mode uses is wrong here: this ROM never waits on vblank, so a repeated
boundary PC is common — it scored ARM_Any 10000/10000 while executing a few
hundred tests. Verified by bit-flipping expected values at chosen test
indices in local ROM copies: all 17 planted failures are found, including
test 9999 in every ROM.

Result: 50 000/50 000 pass. results.md 182/150 -> 187/155, all five rows
baselined green so a future regression fails CI. Full runner 7.7s -> 10.5s,
cheap enough to stay in the default run. ROM cache key bumped.

Note: FuzzARM's tests are randomly generated at build time, so this baseline
is only meaningful for the pinned SHA — a bump is a re-baseline, not a
regression.
```

## tests: score the gambatte suite (5,005 rows, 2632 passing)

`250ad9e4f` — Sat Aug 1 16:36:33 2026 -0700

```
tests: score the gambatte suite (5,005 rows, 2632 passing)

The game-boy-test-roms bundle we already download carries sinamas' gambatte
suite — 3,524 ROMs, one of the strongest GB/GBC accuracy oracles there is —
and the runner had never looked at it. Zero download cost; wire it up.

Scoring follows the bundle's own gambatte/game-boy-test-roms-howto.md,
cross-read against gambatte-core's test/testrunner.cpp: 15 LCD frames from
the post-boot state, then read the frame. The device (`dmg08`/`cgb04c`) and
the expected value (`_out<hex>`, per device) are both in the filename, and
the ROM draws the hex result as 8x8 glyphs across the top-left of the screen.
Some ROMs ship a reference PNG instead and are scored on the whole frame.
3,524 ROMs expand to 5,005 scored rows (a ROM tagged for both devices is two
tests, and its DMG/CGB expectations often differ).

New `--mode=gambatte` is BATCHED: it takes a list file and runs every entry
in one process with a fresh GB per row. One fork/exec per ROM would have cost
more than the emulation — each row is 15 frames. The runner shards the list
round-robin across cores, which takes the suite from ~34 s in one process to
~7 s and the whole runner from 8 s to 15 s, so it is default-on. Rows are
independent: a shuffled list reproduces every verdict and every detail string
exactly, and the sharded totals match the single-process run.

results.md gets one row per gambatte subdirectory (5,005 individual rows would
make it unreviewable); tests/results_gambatte.md carries the per-test detail.
Those aggregated rows gate on the pass COUNT, not just the pass/fail bit, so
223/811 -> 222/811 is a regression even though the row was already red.

Three supporting changes:
  * new_gb gains force_dmg. Gambatte picks the device from its loader flag,
    not the cart header, and nearly every ROM ships a CGB header even for its
    DMG half — without this the DMG column is unreachable.
  * png_reader learns 8-bit truecolor+alpha; all 331 reference images are RGBA.
  * TestResult.always_detail keeps the pass count in results.md for rows that
    pass, which is what the count-based gate reads back.

Not scored, and why: the 220 `_outaudio0/1` rows (gambatte decides them over a
2 MHz sample stream and several ROMs turn on a difference lasting a handful of
clocks; dingbat's APU emits at 32,768 Hz, 64x coarser, so a faithful verdict
isn't available from the sample path) and gambatte's AGB column (its own runner
marks it "FIXME: Actual AGB results" and feeds it the CGB expectations).

The glyph table is HARVESTED from the ROMs' own rendered output via the new
--dump-tiles, not copied from gambatte-core: that project is GPL-2.0 and this
tree is MIT.

Baseline is 2,632/5,005 (results.md Total 182->230, Pass 150->155). This is
measurement only — no emulator behaviour was changed, and the honest result is
committed as the new baseline so CI stays green while any of it going backwards
fails.
```

## tests: score alloncm/MagenTests CGB corners by screen colour

`e1566f7b0` — Sat Aug 1 16:38:00 2026 -0700

```
tests: score alloncm/MagenTests CGB corners by screen colour

Seven ROMs from release 0.5.0 (MIT), downloaded and cached like every other
external suite. Covers ground nothing else dingbat runs touches: HBlank VRAM
DMA (including that it must stop while the CPU is halted), the KEY0 lock
after boot, STAT's reported mode while the PPU is off, and MBC1/3/5
out-of-bounds SRAM addressing.

Not a screenshot comparison, despite the runner already having that path:
the repo ships no 160x144 reference frame — images/ is a 641x574 upscale, a
318x295 SameBoy window grab, two 15x17 swatches and a photo of real hardware
— and a pinned frame hash would be a golden of dingbat's own output with
nothing behind it. Instead the gate is the ROM's own documented contract:
src/common.asm fixes WHITE/RED/GREEN/BLUE and each README entry says what
they mean. --mode=magen-green requires every pixel green; --mode=magen-nored
requires zero red, which is bg_oam_priority's stated criterion and is the
weaker of the two by design. Both print the full colour histogram, so a
failure names its own cause. oam_internal_priority is left out: its only
stated criterion is prose and red is legitimate in it.

Verdicts are stable from frame 60 through 1200; the timeout is slack.

6 pass, 1 fails and is baselined failing: hblank_vram_dma renders all blue,
which the ROM defines as "the HDMA HBlank operation executed even though the
CPU is halted". Recorded, not fixed. results.md 187/155 -> 194/161. Full
runner 10.5s -> 11.7s. ROM cache key bumped.
```

## tests: score 11 more suites out of the game-boy-test-roms bundle

`14fe0d8b2` — Sat Aug 1 16:39:35 2026 -0700

```
tests: score 11 more suites out of the game-boy-test-roms bundle

The v7.0 bundle the runner already downloads ships 21 suites; we scored 5 of
them and left ~4,200 ROMs on disk unread. This wires up the ones whose verdict
mechanism the harness already had, or nearly had:

- Blargg was only partially wired — `oam_bug` (8 ROMs, and we had ZERO OAM-bug
  coverage), `mem_timing-2` (3), `halt_bug` and the CGB-only `interrupt_time`
  all report through the same $A000/DEB061 SRAM protocol tmSram already reads.
- GBMicrotest, 513 ROMs, via a new `--mode=microtest`: no completion signal at
  all, so the harness runs a fixed 2 frames and reads the verdict out of HRAM
  $FF82. Per the suite's howto only $FF82 is scored — several of its tests
  leave $FF80 == $FF81 on a failure, so the actual/expected pair is reported
  for triage and never used as the verdict.
- AGE, via the existing mooneye Fibonacci-register verdict plus screenshots.
  Its failure signal is "any registers other than the Fibonacci ones", with no
  dedicated failure signature, so LD B,B has to end the run unconditionally —
  hence the opt-in --bb-breakpoint. Without it a failing AGE ROM never stops
  and burns its whole 1800-frame timeout, which alone was ~20 s of wall clock.
- bully, strikethrough, scribbltests, turtle-tests, cgb-acid-hell,
  little-things-gb/firstwhite and mbc3-tester, all through the screenshot path
  that mealybug and acid2 already use.

Three things had to be fixed for the measurements to mean anything:

png_reader only understood greyscale, RGB and indexed PNGs. Four of the new
reference images are RGBA, and those fell through to the greyscale branch and
"compared" at 0.0% — a silently wrong answer, not an error. One unfilter loop
now covers all the 8-bit sample formats, and an unsupported one raises.

The regression gate keyed on the LAST path segment while results.md wrote
everything after the FIRST slash, so any multi-segment name (all 115 mooneye
rows) looked up a key that was never in the table and was silently ungated.
Rows are now the full test name and the lookup matches, which also keeps the
new suites from colliding with the old ones.

--nosave keeps battery-backed suite ROMs (mbc3-tester) from dropping a .sav
into the shared ROM cache, where the next run — or in CI the next
actions/cache restore — would load it back as power-on state.

results.md is the honest new baseline: 182/150 -> 757/399. The added suites
are overwhelmingly red and that is the point; they measure mid-scanline PPU
timing, which is where dingbat is weakest. Newly-recorded failures cannot fail
CI, but every newly-recorded pass now gates.

Runner wall clock: 8.6 s -> 12 s, so everything stays in the default run.
```

## tests: score the wilbertpol fork of the Mooneye suite (0xED breakpoint)

`e22285991` — Sat Aug 1 16:40:56 2026 -0700

```
tests: score the wilbertpol fork of the Mooneye suite (0xED breakpoint)

117 more ROMs already on disk. Same Fibonacci-register verdict as Gekkio's
suite, but the fork is built against mooneye-gb as it stood in 2016, when the
magic breakpoint was the undefined opcode 0xED rather than LD B,B — so it needs
a hook in the SM83 dispatch, not just runner wiring. Kept as its own commit for
that reason: it is the only part of this batch that touches the core.

The hook is inside the existing `when defined(test_harness)` block and behind
an opt-in TestOutput flag, so it is absent from release builds and inert in
every other suite scored on the same binary. Unlike the LD B,B hook it fires on
any register values, which is safe precisely because 0xED is undefined and
locks up real hardware: nothing but a test ROM's breakpoint can execute it.

utils/ (a dump tool, not a test) and logic-analysis/ (meant to be observed on a
logic analyzer, no pass/fail signal) are skipped; the two screenshot ROMs go
through the PNG path, one of them pinned to the MGB boot model its reference
was captured on.

61/117 pass. Roughly 80% of the content overlaps Gekkio's suite, so the
marginal signal is modest — but 52 of the 56 failures are in acceptance/gpu/,
which is exactly the fork's added content: LY/STAT/mode timing around
lines 0, 144 and 153. That is the same cluster GBMicrotest and AGE point at.

Total 757/399 -> 874/460. Runner wall clock 12 s -> 16 s.
```

## tests: don't drop (or deadlock on) FuzzARM's failure triage

`ca8c2efb4` — Sat Aug 1 16:42:48 2026 -0700

```
tests: don't drop (or deadlock on) FuzzARM's failure triage

Two bugs in the runner's handling of the new suite, both invisible while
every ROM passes and both fatal to the first real failure.

execCmdEx reads the child's stdout pipe only. The per-failure triage went to
stderr, so via the runner it was silently discarded — and, unread, that pipe
also deadlocks the run once the triage outgrows its buffer (the 500-failure
cap is ~100 KB). Merge stderr in, and replay it into the runner's own log
when a ROM fails, so a CI failure can actually be diagnosed.

Picking the verdict as "the last line" was wrong twice over: the loop
reassigned the very string it was iterating (so it latched the FIRST line,
which is the storage layer's "Backup type could not be identified"), and
even fixed it would be unsound — stdout is block-buffered when piped while
stderr is not, so the early stdout warning can flush after the whole triage
once the streams are merged. The verdict line now carries a "FUZZARM: "
marker and is matched by content.

Verified by swapping the cached ARM_DataProcessing ROM for a copy with three
expected values bit-flipped: exit 1, "REGRESSIONS DETECTED
fuzzarm/ARM_DataProcessing", the three failing instructions in the log, and
"9997/10000 passed (3 failed)" in results.md.
```

## GB PPU: fix LCD-on line 0, the LY=LYC read window, and CPU VRAM/OAM locks

`944cd30d3` — Sat Aug 1 16:49:15 2026 -0700

```
GB PPU: fix LCD-on line 0, the LY=LYC read window, and CPU VRAM/OAM locks

Four mooneye acceptance/ppu tests were failing. Three of them now pass
(150 -> 153 on the full suite); the fourth gets a partial, measured fix.

acceptance/ppu/lcdon_timing-GS, lcdon_write_timing-GS
  Three separate things were wrong on the first line after the LCD is
  switched on:

  * The PPU started that line at the instant the LCDC write retired.
    lcdon_timing-GS pins all three of line 0's boundaries against the
    write and they are all earlier than that; hblank_ly_scx_timing-GS
    then pins the answer mod 4. The seed is 5 dots -- derivation in the
    comment at the LCDC-enable write.
  * A STAT read in the M-cycle where LY advances reads the coincidence
    bit CLEAR whatever LYC holds, for a comparison that has just become
    true AND one that has just become false. Modelled as a suppression
    window carried in bit 7 of the existing read_mode latch, so it costs
    no extra per-M-cycle store.
  * VRAM was never taken away from the CPU at all, and OAM was taken
    away on the wrong edge. Both locks now close on the live mode and
    open with the STAT bits, and a write sees the latched mode where a
    read sees the live one -- which is what lets an OAM write land on
    the last M-cycle of mode 2 while a read in that same M-cycle is
    refused. See cpu_vram_open / cpu_oam_open.

  The locks are checked on the CPU bus (mem_read/mem_write), not in
  ppu_read/ppu_write, so the OAM DMA unit -- which drives the bus itself
  -- keeps its access to both regions.

acceptance/ppu/hblank_ly_scx_timing-GS
  Fixed by the dot-phase half of the seed above: mode-3 length was
  already 172 + (SCX&7), but the M-cycle boundary the mode-0 STAT
  interrupt was quantised to sat three dots too late, so the gap to the
  LY advance changed at SCX&7 = 4 instead of 1.

acceptance/ppu/intr_2_mode0_timing_sprites -- still FAILS
  A second object at the same X was charged 2 dots instead of the 6 an
  object fetch costs. Fixed (phase 7), which takes the test from its
  2nd case to its 12th: the whole X=0 group and the X=1 group now match.
  The rest needs the per-object alignment penalty from (OBJ.x + SCX) mod
  8, which this fetcher cannot express because the shifter starts at
  lx = -(SCX and 7) rather than -8, so every object with X <= 8 collapses
  onto one trigger point. That is a rewrite of the start-of-line fetcher
  model, not a tweak -- left alone.

Performance: nothing added to the mode-3 per-dot path. The new cost is
one predictable compare+branch per CPU bus access; interleaved A/B over
dmg-acid2 (best of 6, 3000 frames) is 1.465s before / 1.444s after, i.e.
inside the noise on this machine.

No regressions: no test that passed before fails now, and every mealybug
percentage that moved went UP (m3_bgp_change 65.4 -> 74.8,
m3_lcdc_bg_map_change 91.4 -> 97.5, m3_scx_high_5_bits 98.5 -> 99.6,
m3_window_timing 88.6 -> 92.1, and six others).
```

## gb: hoist the OAM-DMA hot-path test into a maintained flag

`4fbbbe800` — Sat Aug 1 16:54:58 2026 -0700

```
gb: hoist the OAM-DMA hot-path test into a maintained flag

Every CPU read and write ran

    if (dma_position > 0 and dma_position <= 0xA0) and
       (idx >= 0xFE00 and idx <= 0xFE9F)

before touching memory — two integer compares on the single hottest path
in the GB core, to answer a question that changes at most twice per OAM
DMA. dma_position is written in exactly one place (mem_dma_tick), so the
predicate can be cached there instead: `dma_busy` is set alongside every
mutation of dma_position and is true for exactly `dma_position in
1 .. 0xA0`, which is the old expression verbatim.

The hot path becomes one bool load and a not-taken branch; the OAM-range
test moves into a {.noinline.} cold callee that only runs during the ~160
M-cycles a DMA is actually in flight. That cold path is where the bus
conflict model lands next, so it can be added without the "is a DMA
running?" question reaching the fast path at all.

Behaviour-preserving by construction. dma_busy is a cache of existing
state, not new state: load_mem_state re-derives it from the already
serialized dma_position, so the save-state payload is byte-for-byte
unchanged and no payload revision moves. Verified with the gambatte
oamdma directory (223/811, per-row detail strings identical) and the full
runner (Total 242, Pass 166, gambatte 2632/5005 — unchanged).
```

## gba: charge the committed prefetch halfword on a CPU data access to ROM

`1d6a623d3` — Sat Aug 1 16:57:06 2026 -0700

```
gba: charge the committed prefetch halfword on a CPU data access to ROM

All 46 remaining mGBA-suite "Timing tests" failures were actual = expected - 1
and every one touched the gamepak with the prefetch buffer on. 14 of them (the
2 `ldr r2,[#0x08000000]` rows and all 12 `ldmia [#0x07FFFFF*]` region-crossing
rows) share one cause: the hand-off of the ROM bus from the prefetcher to a CPU
*data* access.

Derivation (spec/hardware, not ported)
--------------------------------------
GBATEK: the prefetch unit streams opcode halfwords sequentially whenever the CPU
is executing from the gamepak and does not need the bus. A halfword takes S16+1
cycles (dingbat's `wait16_s`, call it s). When the CPU issues a data access to
the gamepak the prefetcher must surrender the bus; the question the suite's
hardware table answers is what happens to the halfword that is in flight.

dingbat already tracks `rom_free_since` = the cycle the ROM bus went idle, so
the in-flight halfword started `(now - rom_free_since) mod s` cycles ago. The
suite pins the answer directly. Instrumenting `rom_access_cycles` over the six
failing/passing column pairs of the three `ldmia [#0x07FFFFF*]` tests plus the
`ldr/ldr` test gives (elapsed, s) -> extra cycles hardware charges:

    (0,3) -> 0    ldr/ldr P..            passes today
    (1,2) -> 1    ldr/ldr P.S, FFFC P.S  -1 today
    (1,3) -> 0    FFFC P..               passes today
    (2,2) -> 0    FFF8 P.S               passes today
    (2,3) -> 1    FFF8 P..               -1 today
    (3,2) -> 1    FFF4 P.S               -1 today
    (3,3) -> 0    FFF4 P..               passes today

That is exactly `elapsed mod s == s-1`: the access stalls one cycle iff the
in-flight halfword is in its **final** cycle. Physically, the last cycle of a
gamepak access is the data phase — once the ROM has been addressed and the data
is on its way in it cannot be recalled, so the new bus master waits it out;
during the earlier address/wait cycles the fetch is simply abandoned. Note this
is NOT "wait for the whole remaining fetch" (that model predicts 2 for (1,3) and
breaks `ldmia [#0x07FFFFFC] P..`, which passes), and it is not the blanket
whole-halfword credit floor that a previous pass measured at Timing 1758.

Once the buffer is full (8 halfwords = 8*s cycles) the prefetcher is idle and
nothing is in flight, so the stall is bounded by that. It only applies while the
CPU is executing from the gamepak (`fetch_page`), since the prefetcher does not
run otherwise, and only to non-fetch accesses (a fetch *is* the prefetcher).

Implementation / perf
---------------------
`rom_access_cycles` is the hottest bus function, so the per-page `elapsed ->
stall` predicate is precomputed into a `uint64` bitmap in `update_waitcnt`
(`Bus.pf_commit`): the hot path is a shift and a test, no division. The
condition is ordered to exit on `not contiguous` first, and the `fetch` term is
a compile-time constant at every call site. `pf_commit` is derived from WAITCNT,
which save states already restore through `update_waitcnt`, so no new serialized
state and no STATE_VERSION bump.

Native benchmark, `dingbat_bench <rom> 600 90` with `DINGBAT_NO_WAITLOOP=1`,
user CPU time, builds run back to back and interleaved, median of the settled
samples: Pokemon Emerald 1.23s -> 1.22s, Kirby 1.53s -> 1.51s, FireRed 1.35s ->
1.36s. Within noise on a contended machine; no measurable cost. `DINGBAT_BENCH_HASH=1`
over 360 frames of Emerald is byte-identical.

Results
-------
mGBA suite (HLE): Total 7008, Pass 6910 -> 6918, Fail 98 -> 90.
  Timing tests 1974/2020 -> 1988/2020 (+14, zero Timing rows regressed)
  DMA tests    1256/1256 -> 1250/1256 (see below)
Everything else byte-identical per `tests/mgba_rowdiff.py`.

The six `HBl W ±SRAM/=IWRAM|EWRAM` DMA-suite rows that flip are the known
log-length artifact, not a timing regression: those tests DMA out of SRAM, and
SRAM is the suite's own `savprintf` log (suite src/main.c:167). Once the log
passes 0x8000 the terminator write wraps onto SRAM[0], so what the DMA reads
depends on how many lines were printed, i.e. on how many tests failed. Traced
both builds: the bursts are parameter-identical (src 0x0E00000C, len 4, fixed
dest) and only the SRAM byte changes (0x47 'G' -> 0x00) once the wrap point
moves. `docs/prefetch-model-rewrite.md` Phase 4 anticipated exactly this
"log-length-luck -SRAM reshuffle"; the committed baselines are updated to match.

The remaining 32 Timing failures are all DMA rows. The same hand-off exists
there but is not a function of `(elapsed mod s)` at the DMA's first ROM access
(`Trivial DMA (16/ROM)` ARM P.S needs it at elapsed 2/s 2, Thumb P.S must not at
elapsed 4/s 2), because dingbat runs a DMA on the scheduled event clock while
`rom_free_since` is on the CPU's bus clock and the two skew by up to a fetch.
Left open and written up in the doc.
```

## gb: the eleven undefined opcodes lock the CPU up, as hardware does

`76901cd93` — Sat Aug 1 16:57:52 2026 -0700

```
gb: the eleven undefined opcodes lock the CPU up, as hardware does

Pan Docs ("CPU Instruction Set", and the STOP chart's sibling note) is
explicit that D3/DB/DD/E3/E4/EB/EC/ED/F4/FC/FD are not no-ops: the SM83's
decoder enters a state it never leaves, and the CPU hangs until reset.
dingbat treated all eleven as 4-cycle no-ops, so gambatte's undef_ops
directory was 0/20 — every one of those ROMs prints 01, arms the VBlank
IRQ, executes the undefined opcode, and prints 02 if it ever gets to the
next instruction (03 if the IRQ is serviced). dingbat printed 02.

Modelled as `halted` plus a new sticky `locked`:

  * `halted` is what already stops the fetch/dispatch while leaving
    mem_tick_extra running the machine 4 T-cycles at a time, so the PPU,
    timer, OAM DMA and the scheduler go on ticking exactly as they do in
    HALT. That is what the test observes (the frame keeps being drawn),
    and it is why a locked ROM cannot spin the host or stall the frame
    loop — vblank still arrives and step_frame still returns.
  * `locked` is what stops handle_interrupts from clearing `halted`
    again, since no interrupt gets a real SM83 out of this. Nothing
    clears it; reset and load-ROM both build a fresh GB (and so a fresh
    GbCpu), so the application cannot be wedged by it.

Cost on the running CPU: none. `tick` already branched on `cpu.halted`,
so the halted case is split out of the `cycles_taken` expression and the
`locked` test lives entirely inside it — the fetch/execute path is
byte-for-byte the same work it was. PC is left pointing at the opcode
that locked, which is the truthful place for it.

Save states: GB_PAYLOAD_VERSION 3 -> 4 with the usual `if rev >= 4`
migration, so every older GB state still loads (a state from before this
commit cannot have been locked).

gambatte undef_ops 0/20 -> 20/20; gambatte total 2632 -> 2652/5005.
No other row in tests/results.md moves.
```

## gba: split the IRQ entry/return cost the way hardware does (count-up 936/936)

`8fd095da7` — Sat Aug 1 17:02:53 2026 -0700

```
gba: split the IRQ entry/return cost the way hardware does (count-up 936/936)

The mGBA suite's "Timer count-up tests" scored 893/936. Despite the name the
suite never sets a count-up (cascade) bit: every one of its 25 configurations
writes one 32-bit word to 0x4000100, so it is timer 0 on the prescaler alone.
What each row measures is a poll loop racing the timer IRQ - how many loop
iterations run before the handler writes TM0CNT_H = 0, and what counter value
that write latches. Both are pure IRQ phase.

Cycle-exact traces of the 0b block (39 of the 43 failures) show why. The
latched value is right for the FIRST interrupt (the disable store lands 92
cycles after the overflow, matching hardware) and drifts afterwards, because
each interrupt shifts the poll loop's alignment by the round trip
entry + handler + return. Ours was 122 cycles; the hardware values are only
reproducible at 121 or 125 (the loop is 8 cycles, so the shift matters mod 8),
and 125 scores far worse. So the round trip was one cycle too long while its
entry half was exactly right.

GBATEK defers to the ARM7TDMI data sheet here, which costs an exception entry
at 2S+1N and the matching return - a data-processing write to r15 with the S
bit - at 2S+1N: six cycles of overhead around the handler body, four of which
are the two pipeline refills the model already charges. The remaining two are
what we mis-split. The entry side is pinned by measurement (the handler's
first instruction runs four cycles after the interrupted instruction's
boundary; forcing three fails 21 of the 90 Timer IRQ rows and moves the
latched value to 91), so the return side gets one, not two.

Charge it that way: entry is now an unconditional 2, and the IRQ exception
return gives one back. That also retires both ad-hoc discounts the old
lopsided split needed - halt-wake -2 and back-to-back-exception-return -1 -
which only ever fired on the paths where the surplus cycle showed up. The pair
totals the same in every case they covered, so the chains they were protecting
(the 5-cycle-period rows, where interrupts re-enter immediately) are
unaffected; only an interrupt taken out of straight-line code moves, by the
one cycle it was always owed. Dropping them also drops two per-instruction
flag stores from cpu.tick.

HALT_RETURN_COST goes 21 -> 20 for the same reason: it is a deferral, not a
cost - it moves part of the BIOS Halt routine past the wake boundary so
post-wake measurements see the real execution order - and the boundary moved
by the cycle the return no longer charges. The SWI entry/return pair is
measured separately (BIOS timing tests) and still splits evenly, so the
adjustment is scoped to returns from IRQ mode.

mGBA suite (HLE): 6910/7008 -> 6953/7008.
  Timer count-up  893/936 -> 936/936  (all four "second sub-bug" 8b/10b rows
                                       included; they were the same phase
                                       error landing on a 16x loop boundary)
  Timer IRQ         90/90 -> 90/90    (unchanged, still green)
  every other section unchanged; the Misc/DMA rows whose *expected* values
  move are the documented log-length-coupled ones (tests/golden/README.md) -
  their pass counts do not change.
Full runner: Pass 150 -> 151, no regressions. Link/rollback acceptance and
save-state compatibility unchanged.

Perf: no cost. FireRed, 900 frames after 200 warmup, ABBA-interleaved on one
machine, seven quartets whose four samples agree within 6%: median fix/base
1.009 (mean 1.005); with DINGBAT_NO_WAITLOOP=1, 1.007. Within noise, biased
slightly positive by the two removed hot-loop stores.

Known residual: under the official BIOS the four SIO timing rows now read one
cycle high, because HALT_RETURN_COST is an HLE-side constant and the real
BIOS's Halt path has no equivalent knob. LLE still improves overall
(6909 -> 6949); the residual says one instruction in that BIOS routine is
modelled a cycle long, which is a separate bug this change only exposed.
```

## gba: raise the H-blank IRQ with its DISPSTAT flag, not at dot 240

`77548b9f6` — Sat Aug 1 17:04:08 2026 -0700

```
gba: raise the H-blank IRQ with its DISPSTAT flag, not at dot 240

The H-blank signal is one signal. GBATEK pins it: "Although the drawing time
is only 960 cycles (240*4), the H-Blank flag is '0' for a total of 1006
cycles" -- DISPSTAT bit 1 rises 46 cycles into the 272-cycle gap, and bit 4
enables an interrupt on that same bit-1 condition. dingbat had them split:
the IRQ fired at 960 while the flag waited until 1004, so H-blank handlers
got a 272-cycle window instead of hardware's 226. vblank/vcounter already
raise flag and IRQ together in end_hblank; H-blank was the odd one out.

Derivation of the 52-cycle move (46 flag + 6 recognition), all under a
suite ROM rebuilt with the two upstream fixture fixes applied (see
tests/README.md -- the pinned v1.0 ROM cannot score these rows):

- "H-blank bit start / Flip 1" times the H-blank IRQ's halt-wake against the
  end of the same scanline. It was 0xB7 (183) against hardware's 0x87 (135),
  a flat 48 cycles, invariant under every flag-offset perturbation -- so the
  error is in the IRQ edge, not the flag.
- The other candidate, an under-modelled halt-wake path, is falsified: a
  blanket +48 there does fix Flip 1 (Misc 9/10) but collapses Timer count-up
  893 -> 689 and SIO timing 4 -> 0, which pin that path independently.
- Flip 1 then admits IRQ recognition anywhere in 1010..1014 (the poll loop
  samples every 8 cycles); 1012 is the middle of that plateau, i.e. flag at
  1006 plus a 6-cycle recognition delay. The timers' IRQ_SYNC_DELAY of 3 was
  calibrated against the Timer IRQ rows only -- peripherals do not share one
  path to the interrupt controller, and this is the one row that measures the
  video controller's.

Also confirmed, not changed: the DMA-prefetch open-bus model is already
correct. "DMA Prefetch Read" fails only because gcc dead-store-eliminates the
test's source array; rebuild the ROM with upstream's `vu32` and dingbat
returns 0xDEAD0000 and passes. H-blank DMA is left at 960 -- nothing in the
suite distinguishes it and DMA is 1256/1256.

Verification
- mGBA suite (pinned v1.0 ROM): 7008/6910/98, every PASS/FAIL row byte-
  identical to the previous baseline. Only the Misc value columns move.
- mGBA suite (ROM rebuilt with 8c97f2c9 + a58437f3, devkitARM 15.2.0):
  Misc 8/10 -> 9/10; every other section identical (Memory 1552, I/O 130,
  Timing 1974/2020, count-up 893/936, Timer IRQ 90, Shifter 140, Carry 93,
  Multiply long 72, BIOS math 615, DMA 1256, SIO R/W 90, SIO timing 4/4).
  The one remaining row, "DMA Prefetch Break", is a loop iteration count
  that depends on ROM code layout and is not comparable across builds.
- ./dingbat_test_runner: exit 0, Total 182 / Pass 150 / Fail 32 (unchanged).
  test_savestate_compat and test_ppucomposite pass.
- Perf, instructions retired, median of 3, DINGBAT_NO_WAITLOOP=1, 1800
  frames after 300 warmup, ROM symlinked into a scratch dir so no .sav
  crosses builds: Emerald 65.4134e9 -> 65.4124e9 (-0.002%), Kirby: Nightmare
  in Dream Land 60.9073e9 -> 60.9037e9 (-0.006%). Both inside noise; the hot
  path only moves one branch from start_hblank into set_hblank_flag.
- DINGBAT_BENCH_HASH=1 over 1200 frames: framebuffers byte-identical to the
  previous build on both games.

tests/dingbat_test.nim gains dingbat_bench's DINGBAT_NO_WAITLOOP knob -- it is
what separates a real timing error from fast-forward sampling resolution on
the rows that spin on a register.
```

## gb: the CGB speed switch resets DIV and stalls the CPU, per Pan Docs

`820dac45c` — Sat Aug 1 17:21:57 2026 -0700

```
gb: the CGB speed switch resets DIV and stalls the CPU, per Pan Docs

gambatte's speedchange_div_* / speedchange2_div_* (8 rows) read DIV
immediately after a KEY1 speed switch and expect 00 (or 01 one step
later). dingbat returned 1F: `stop_instr` flipped the speed bit, rescaled
the scheduler and returned, doing nothing to the divider and charging the
switch nothing but STOP's own 4 T-cycles.

Two things from Pan Docs, neither of which dingbat did:

  * The STOP chart (Reducing Power Consumption) has STOP resetting DIV.
    Done here through the FF04 write path rather than by zeroing tdiv, so
    the divider's consumers see this reset the way they see any other:
    the APU frame sequencer steps early if its tap was high, a shifting
    serial byte sees its tap fall, TIMA gets its edge check. It runs
    before the speed flip so those taps are read at the speed the reset
    happened at, and `speed_mode=` then rescales the re-aimed
    frame-sequencer event with everything else.

  * FF4D/KEY1: "The CPU stops for 2050 M-cycles (= 8200 T-cycles) after
    the `stop` instruction is executed... `DIV` does not tick." Which
    parts of the machine stop with it is decided by the same page's two
    lists: the CPU, the timer/divider, the serial port and OAM DMA are
    the things that run at the CPU clock (they are exactly what doubles
    in double speed), while the LCD, HDMA and the sound timings run at
    real time regardless. So mem_tick_stalled advances the scheduler and
    the PPU for the stall and leaves the timer and OAM DMA alone; the one
    scheduler event that is not real-time, the DIV-APU frame sequencer,
    is lifted over the stall and re-aimed from the (reset, still zero)
    divider afterwards — Pan Docs' "so *some* audio events are not
    processed", stated exactly.

8200 is real-time T-cycles: the CPU clock is what is stopped, so it
cannot be the unit of its own stall. In the scheduler's (CPU-clock)
domain that is `8200 shl current_speed`, which mem_tick_stalled shifts
back down for the PPU.

All 8 div rows pass. gambatte speedchange 76 -> 107/208, total
2652 -> 2682/5005 (DIV reset alone is worth +8, the stall the other +22).

One row moves the other way: dma/hdma_late_m3speedchange_tima_scx1_ds_4
was a coincidental pass in a 6-row TIMA-across-the-switch series dingbat
gets wrong in 5 of 6 either way (expected F3 F4 F6 F7 F8 F9, we return
F5 F6 F6 F6 F6 F7 before and after — the DIV reset only shifts which of
the six happens to line up). Baseline updated; the cluster is untouched
work, not a regression this introduced.

Not fixed, and written up on SPEED_SWITCH_STALL_T: three gambatte LY rows
say the PPU should advance 143 scanlines across the switch, eight times
what 8200 T-cycles allows. Sweeping the constant has no clean optimum
(2682 at 8200, 2692 near 65664, 2691 at 131072, jagged between), so
Pan Docs' figure stands until the stall is timed on hardware.

Perf: stop_instr is cold (a handful of executions per session) and the
hot loop is untouched. Pokemon Crystal 3600f: -0.05% top-3 / -0.34% max;
Link's Awakening (DMG) -0.11% top-3 / -0.04% max, both inside the noise
floor. DMG output is byte-identical (the path cannot be reached); Crystal
is byte-identical over 3000 frames driven through the title screen;
Link's Awakening DX shifts by a fraction of a frame and renders the same
intro.
```

## gb: model OAM DMA bus conflicts

`28ae07e06` — Sat Aug 1 17:55:33 2026 -0700

```
gb: model OAM DMA bus conflicts

dingbat treated an OAM DMA as invisible to the CPU: a read during a
transfer returned the plain memory byte and a write went where it was
addressed. Real hardware has genuine bus conflicts, and gambatte's
oamdma directory is 811 rows of them — 588 of which failed.

The model, derived from Pan Docs' "OAM DMA bus conflicts" (the CGB
"cartridge and WRAM are on separate buses" carve-out, generalized by the
memory map and the PPU's own video bus) and cross-checked row by row
against the gambatte test ROMs' own .asm sources, never against another
emulator's implementation:

  The unit takes one bus for the whole 160 M-cycle transfer:
    external   cart ROM $0000-$7FFF + cart SRAM $A000-$BFFF, plus WRAM
               $C000-$FDFF on DMG (one external bus for cart and RAM)
    video      VRAM $8000-$9FFF
    WRAM       $C000-$FDFF, CGB only
  A CPU access on that same bus does not reach memory. A read returns
  the byte the DMA has in flight; a write is lost, and the CPU instead
  becomes a driver of the lines the DMA is latching, so its value ends
  up in OAM at this M-cycle's position. Accesses on any other bus, and
  on none at all (IO, HRAM, IE), are untouched.

What actually lands in OAM on a write depends on what the *source*
memory is doing to those lines, which is why the source region matters
and not only the bus:

  cartridge source   the cart sees /WR and stops driving -> OAM gets the
                     CPU's byte  (gambatte src0000/7F00/A000/BF00 push*)
  DMG WRAM source    WRAM keeps driving its read data -> wired-AND of the
                     two  (srcC000/DF00 push*, expect $55&$65=$45)
  CGB WRAM source    separately arbitrated: the CPU's access is lost but
                     the DMA's own read still completes, OAM unaffected
  CGB video source   also arbitrated, and the DMA loses the cycle
                     outright: OAM takes $00 — for a colliding *read*
                     too, which is the one case where a CPU read damages
                     the transfer  (src8000/9F00 pop7FFF/9FFF)

Two more differences fall out of the same tests:

  * On CGB a source at or above $E000 is driven onto the external bus,
    where neither cart nor WRAM answers, so every byte transferred is
    $FF open bus. The echo remap stays DMG-only (mooneye sources-GS).
  * The whole OAM page $FE00-$FEFF reads $FF while the unit owns it, not
    just the $FE00-$FE9F object area.

Also fixed here because the stack tests are what exposed it: word
accesses did not wrap the 16-bit address bus, so `push`/`pop` with SP at
$0001/$FFFF sent their high byte to $10000 and dropped it. That is a
plain addressing bug, independent of DMA.

Cost: none. The conflict logic lives entirely inside the {.noinline.}
mem_read_busy/mem_write_busy added in the previous commit, so the
no-DMA path is untouched — still the single bool test that replaced two
range compares. Paired-sample benchmark (host is contended, so per-pair
ratios, 21 pairs, DINGBAT_NO_WAITLOOP=1, order alternated):

  Zelda: Oracle of Seasons   +0.94%   Pokemon Crystal   +0.52%
  Super Mario Land           +0.74%   (all vs pre-refactor baseline)

i.e. the pair of commits is a small net *win*, not a cost. The cold path
is genuinely exercised: instrumented, Zelda runs 8181 OAM DMAs over 8300
frames and takes 989,901 CPU accesses through mem_read_busy — and hits
exactly 0 conflicts, because real games busy-wait in HRAM, which is on
no bus. Per-frame FNV framebuffer hashes are byte-identical over 3000
frames on all three ROMs.

gambatte oamdma 223/811 -> 681/811; gambatte total 2632/5005 ->
3090/5005. results.md Total 242, Pass 166, Fail 76 unchanged, and no
other gambatte subdirectory moved by a single row.
```

## gb/ppu: lead the window re-trigger test with the fetcher position

`50466af62` — Sat Aug 1 18:04:41 2026 -0700

```
gb/ppu: lead the window re-trigger test with the fetcher position

Pure reordering of a conjunction — same dots, same pixels, byte-identical
output — but the WX comparison was the first term and it is the least
selective one. The fetcher-position test is true on one dot in eight and
reads a field the fetcher wrote on this same dot, so leading with it keeps
seven eighths of the dots of an active window off the WX compare.

Measured on dmg-acid2, whose window covers most of the screen on every
scanline and which therefore runs this branch about as often as a GB ever
can: 12000 frames, minimum user CPU over 14 interleaved runs, against a
byte-identical copy of the baseline binary as the noise floor (0.00%).
Whole branch 5.420s -> 5.390s against a 5.270s baseline, i.e. this rule's
share of the stack drops from ~1.3% to ~0.8% on that worst case. On a real
DMG game (Super Mario Land, 12000 frames, same method) it was already at
the noise floor before this change and still is.

tests/results.md is unchanged: 182/154/28.
```

## gb/ppu: record the 8-dot mode-3 phase residual, measured but not fixed

`bc4fbfe81` — Sat Aug 1 18:33:55 2026 -0700

```
gb/ppu: record the 8-dot mode-3 phase residual, measured but not fixed

Comment only; no code change, output byte-identical.

The mealybug m3_* ROMs all write a PPU register at a known dot of a known
line and photograph where the change lands. Tracing those writes against
lx says this pipeline is a constant 8 dots ahead of hardware relative to
the CPU clock -- one number, not a per-register effect: BGP, LCDC.3/.4/.6,
SCY and WX are all early by the same 8. (It was 11 before the LCD-on line 0
head start landed; that fix accounts for three of them.)

Worth writing down because it is the single largest remaining lever on the
GB PPU and because the obvious fix is a trap. Injecting 8 idle dots at the
head of mode 3 was measured against the whole suite: it takes m3_bgp_change
74.8 -> 97.8, m3_scy_change 51.4 -> 90.4, m3_lcdc_bg_en_change 84.3 -> 94.7
and four more rows by 3-6 points each -- and turns four currently-passing
rows red, because deferring the pixels that way also defers the mode 0 flag
by 8 dots, which mooneye pins to the dot.

The note in the mode 3 loop carries the numbers, why the crude fix fails,
what a shippable one would have to separate, and that the 2613-title
byte-identical sweep is the gate for attempting it.
```

## gb: point the dma_busy note at where the flag is actually re-derived

`fb85fad58` — Sat Aug 1 21:16:21 2026 -0700

```
gb: point the dma_busy note at where the flag is actually re-derived

4fbbbe8's comment referred to a gb_recompute_dma_derived that never existed;
the re-derivation lives in load_mem_state. Comment only.
```

## tests: drop the unused exit code from the mGBA suite runner

`b6fc91d7a` — Sat Aug 1 22:20:25 2026 -0700

```
tests: drop the unused exit code from the mGBA suite runner

execCmdEx's status is not the verdict for this suite -- the ROM prints
per-section pass counts and the harness exits 0 either way, so scoring reads
stdout. Binding it produced the tree's only XDeclaredButNotUsed hint, which
would have been a new hint on main.
```

## gb: pin the CPU bus hot path's inlining, and measure what OAM DMA really costs

`139978de7` — Sun Aug 2 08:06:44 2026 -0700

```
gb: pin the CPU bus hot path's inlining, and measure what OAM DMA really costs

The OAM-DMA bus-conflict model (28ae07e) was reported at -2.0% on Link's
Awakening and -1.5% on Crystal, measured by wall-clock fps. Its real marginal
cost is +0.37% of retired instructions, and the companion refactor 4fbbbe8
makes the DMA half of this path cheaper than what main does. The -2.0% was a
measurement artifact, and this commit fixes the thing that produced it.

Wall clock cannot resolve an effect this size here: two builds differing only
in code the benchmark never executes measure ~1.3% apart from layout alone,
and layout error is systematic, so it does not average out. dingbat_bench now
reports retired instructions and CPU cycles under DINGBAT_BENCH_COUNTERS=1,
via proc_pid_rusage(RUSAGE_INFO_V4) around the measured window -- no root and
no Xcode, which xctrace would need. Those reproduce to 0.002% against fps's
1.3%, and the existing emulated `cycles=` line is the control that both arms
did the same work.

With that, the actual finding. mem_read/mem_write sit exactly on clang's
inline-cost threshold with ~160 generated opcode bodies calling them, so
adding or removing ONE compare on their hot path flips the inlining decision
for a large arbitrary subset of those call sites -- 123-162 functions changed
size between builds that were supposed to differ by three instructions
(colonanonymous 108 -> 324 bytes, cb_set 156 -> 320). That coin flip is worth
~0.9% of all retired instructions, more than twice the cost of everything the
DMA model and the PPU's CPU lock put on this path combined. It is re-tossed by
every future edit here, which is how a 3-instruction change comes to measure
as a 2% regression.

So the decision is made here rather than inherited, always_inline rather than
an `inline` hint the heuristic is free to ignore. It is also the faster side:
-0.84% retired instructions on DMG and -0.93% on CGB, for +568 bytes of
__text. Scoped to clang because GCC makes a failed always_inline a hard error
rather than a dropped hint, and the gcc/mingw CI builds cannot be compiled
here to prove a proc with 160 call sites always takes it; those keep a plain
`inline`, which cannot fail to build. macOS, iOS and the web build are clang.

With the inlining pinned instead, the costs are additive and there is no
interaction between the two features -- the leading hypothesis for the -2.0%
is dead. Against a no-checks build, Link's Awakening over 2400 frames:

  PPU CPU VRAM/OAM lock (944cd30)      +81.8M   +0.353%
  OAM-DMA cached flag (4fbbbe8+28ae07e) +85.7M   +0.370%
  both (HEAD)                         +167.4M   +0.722%    (81.8+85.7 = 167.5)
  main's old inline OAM predicate     +103.6M   +0.447%

so 4fbbbe8 is a +0.077% win, not the +1.55% first reported, and HEAD retires
FEWER instructions than main's shape overall (-28.0M DMG, -12.8M CGB) despite
adding the lock. Predicted 3 instructions x 30,028,939 bus accesses = 90.1M
against 85.7M measured.

Behaviour is untouched: this changes an inlining attribute and nothing else.
Framebuffers byte-identical over 1560 frames on both ROMs, gambatte oamdma
681/811 and total 3248/5005 unchanged, runner exits 0 at Total 934 / Pass 615.
The CGB three-bus separation is unchanged, which matters beyond the test score
-- the GBC Wizardry ports DMA from WRAM while executing from ROM and depend on
no conflict being raised there.

docs/gb_oam_dma_cost.md has the full method, why a merged "slow path needed"
flag was evaluated and rejected (VRAM is locked ~40% of every scanline, while
Link's Awakening issues zero CPU VRAM reads in 28.9M), and the rules for
benchmarking this path.
```

## tools: a two-build GB framebuffer gate for machines without the ROM library

`ba05f6df4` — Sun Aug 2 08:47:11 2026 -0700

```
tools: a two-build GB framebuffer gate for machines without the ROM library

The established rule for a GB rendering or memory change is a byte-identical
screenshot sweep across the library, via tools/gbfuzz. That library is not on
every machine, and without it the rule quietly becomes "no gate at all".

gbgate is the reduced version: build two revisions of dingbat_bench side by
side, run both over whatever real ROMs the machine does have, and diff the
per-frame framebuffer hash streams. It cannot replace a 2,613-title sweep and
does not pretend to -- but it turns "untested" into "tested on 26 ROMs", and
it found a real one on its first run.

The hard part is not the sweep, it is reading the result. A differing hash is
not a bug: the bench hash is *rolling*, so a single frame landing one frame
early poisons every later hash whether or not the picture is ever wrong again.
So the classification tools are the point:

  classify.sh  dumps both builds at a spread of frames and reports pixel
               equality, which separates a transient phase difference (diffs
               that heal) from a real one (diffs that persist)
  phase.sh     asks the question directly -- does B@N equal A at some nearby
               frame? -- which is what "benign animation phase" actually means
  diffmap.py   prints the divergence as an 8x8 tile map, so "the sprite moved"
               and "a row of tiles is missing" are distinguishable at a glance

Hygiene that has cost this project time before is built in rather than left to
the caller: ROMs are symlinked (not copied) into a per-build directory so each
build's .sav stays its own, the list is read with read -r so a ROM name with a
space cannot silently truncate the sweep, each build gets its own TMPDIR, and
the watchdog never shares stdout with the child it may have to kill.
```

## gb: the KEY1 speed switch stalls the CPU for 2^16 dots, not 8200

`7566f32ff` — Sun Aug 2 09:40:11 2026 -0700

```
gb: the KEY1 speed switch stalls the CPU for 2^16 dots, not 8200

The reported regression was blargg cpu_instrs rendering "  ssed" / "Passe"
instead of "Passed" on 03, 06 and 11 after 944cd30 added the CPU VRAM/OAM
locks. The write lock is not the bug. Instrumenting the refused writes says
so directly: they are spread across the whole of mode 3 (line dots 83-249,
one write every 22 dots), so no phase correction of the mode-3 window --
including the 8-dot residual bc4fbfe documents -- can make them land.

What is really happening, traced out of the ROM's own code:

  * Blargg's runtime switches the CGB to double speed during init (init_crc
    at $C4AC calls set_double_speed and never calls set_normal_speed), so
    everything it prints afterwards is printed at double speed.
  * Its console waits for VBlank with a BOUNDED poll -- ld bc,$FB1E / inc bc
    / ldh a,($44) / cp $90, 1250 iterations of 14 M-cycles. At single speed
    that is 70 000 T-cycles against a 70 224-dot frame, i.e. "wait up to one
    frame" and it effectively always succeeds. At double speed the same 1250
    iterations are 35 000 dots -- half a frame -- so it times out whenever the
    print is entered in the wrong half, and the console then blits its 20-byte
    row into the tile map with the LCD on, straddling mode 3.
  * Those cells are then correctly dropped. SameBoy drops them too: 28 of 160
    on 06-ld r,r, and on 03-op sp,hl it loses the P, a and s of "Passed", so
    that ROM's result line never reaches SameBoy's screen at any frame count.

So the screen is a phase probe, not an oracle -- and it pointed at a real
divergence. The STOP that performs the switch happens at LY=140 in both
emulators, so everything up to it agrees; what follows does not, because
dingbat held the CPU for 8200 dots where SameBoy holds it for 65540.

SPEED_SWITCH_STALL_T becomes 65540 (= 2^16 + 4), which is SameBoy's
speed_switch_halt_countdown of 0x20008 converted out of its half-dot unit.
That is the same number gambatte's speedchange_ly44_m3_ly / speedchange_ly97_ly
have been asking for all along (the old comment here recorded them wanting 143
scanlines and left it as an open question); both now pass. Pan Docs' 2050
M-cycles is the outlier, and it is eight times short.

Suite effect, all of it inside the speed-switch family:

  gambatte total  3248 -> 3253
    speedchange   108 -> 111   (incl. both LY rows named above)
    dma           105 -> 108   (three hdma_late_m3speedchange_ly rows)
    oamdma        681 -> 680   (oamdma_late_speedchange_stat_1, same family)

results.md is re-baselined for those three counts; nothing else moved
(Total 934 / Pass 615 either way). The residual speedchange churn is
sub-M-cycle alignment -- SameBoy additionally models a 6-cycle switch
countdown and a PPU re-alignment freeze that this does not.

Independent confirmation: with the real CGB boot ROM on both sides, dingbat's
frame is now pixel-identical to SameBoy's on all eleven cpu_instrs ROMs at
frame 1200. At 8200 three of them differ. Swept, the eleven-of-eleven region
sits around 2^16 and 0x20008 is inside it (8200 -> 8/11, 32768 -> 6/11,
65208 -> 8/11, 65536/65540/65544 -> 11/11, 131072 -> 8/11).

No hot-path code changed: the constant is read once, in stop_instr.

Also closes the blind spot that let this reach a merge queue green. The
eleven cpu_instrs rows were the runner's only GB rows that ran a whole ROM to
a verdict with nothing looking at the screen. They now run with a new
--screen-check, which asserts the two things that stay true however the ROM's
console races the PPU: the panel settles (10 identical frames within 240 of
the verdict) and is not one flat colour. It deliberately does NOT compare
glyphs -- a glyph assertion fails on correct emulation, as the SameBoy
measurement above shows -- and tests/README.md now carries that measurement
in full so the next person does not add one.
```

## gb: measure the mode-3 fetch phase, and why bgtiledata/bgtilemap are 0/74

`c373385c7` — Sun Aug 2 11:31:58 2026 -0700

```
gb: measure the mode-3 fetch phase, and why bgtiledata/bgtilemap are 0/74

gambatte/bgtiledata (0/34) and gambatte/bgtilemap (0/40) are ONE bug, and it
is not a bug in LCDC.3/.4 decoding: it is the mode-3 pipeline phase already
recorded as a KNOWN RESIDUAL in fifo_ppu.nim. No emulator change ships here --
what ships is the measurement, the instruments that produced it, and three
corrections to what that note claims.

Both families are four ROMs whose only difference is that a mid-line LCDC
write moves by one M-cycle, each with a reference PNG. That makes the picture
they draw a staircase -- first affected tile = 8*ceil((write_dot - c)/8) --
whose one unknown c is the dot at which the BG fetcher samples LCDC. Reading
the write dot out of the emulator (-d:gb_m3_trace) and the boundary out of
the frame (DINGBAT_GAM_DUMP) and solving both directions of the write, on
both devices, single and double speed:

                      this renderer     hardware
  LCDC.3 tile map       lx + 88         lx + 89 .. 92
  LCDC.4 data low       lx + 90         lx + 93 .. 96
  LCDC.4 data high      lx + 92         low + 2

The 2-dot gap between the map read and the data read is already right, and
the whole low/high split is already right -- the double-speed ROMs draw
mixed-shade tiles when a write lands between the two bytes and this renderer
draws them in the same places. Only the fetch's phase against the CPU clock
is wrong, by one constant, which is why the two families fail identically.

Pan Docs fixes the fetcher's step order and that LCDC.4 selects $8000
unsigned vs $8800 signed; it does not fix this phase, and nothing here is
fitted to a test's expected value -- c is read off a staircase that four
independent write times and two write directions all agree on.

Three corrections to the KNOWN RESIDUAL note:

* The constant for the fetcher is 3-4 dots, not the 8 read off mealybug.
  M3_PIPE_DELAY (new, default 0, compiled out) makes rows 16..143 of every
  single-speed ROM in both families pixel-exact at N=3 and N=4 and at no
  other N: 1400 mismatching pixels -> 240. 3 and 4 cannot be told apart
  because a single-speed CPU can only place a write on a 4-dot grid.
* "One constant, not a per-register effect" is not supported. BGP is applied
  at the shifter and the fetch selects are applied at the fetcher; this
  measurement only covers the fetcher.
* The crude head-delay is worse than the note says: at any N > 0 it puts ~40
  mooneye + GBMicrotest hblank-timing rows red, not four.

And two bugs that only become visible once the phase is corrected, neither
fixed here: the CGB double-speed rows want N in {1,2} where single speed
wants {3,4} (a 2-dot write-to-PPU alignment difference between the speeds,
so no single phase passes all 74), and one object at screen x=0 shifts this
pipeline's fetch phase by 6 dots where the references need 11-13.

There is no local fix. Hardware samples LCDC.4 for the tile displayed at
lx..lx+7 at a dot AFTER the dot on which this renderer has already pushed and
begun displaying it, so the sample cannot be moved without moving the pixel
pipeline -- which is the flag-vs-pipeline restructure the note describes and
which another change is already carrying. Deliberately not doing it here
rather than doing it twice.

Instruments kept, all compiled out or off by default:
  -d:gb_m3_trace -d:GB_TRACE_LY=n   per-dot mode-3 trace + LCDC writes
  -d:M3_PIPE_DELAY=n                sweep the pipeline phase
  DINGBAT_GAM_DUMP=<dir>            gambatte frames as PPM, in the
                                    comparison's colour space

Verification: ./dingbat_test_runner exits 0 at Total 934 / Pass 615 /
Fail 319, gambatte 3253/5005 -- identical to main in every suite, as it must
be for a change that adds no shipping code path.
```

## gb/ppu: split the mode 0 flag from the pixel pipeline

`332a6ab6b` — Sun Aug 2 12:22:26 2026 -0700

```
gb/ppu: split the mode 0 flag from the pixel pipeline

The mode-3 phase residual recorded in fifo_ppu.nim has a fix that has never
been shippable: move the fetch/shift pipeline later against the CPU clock. It
is not shippable because moving the pipeline also moves the mode 0 flag, and
mode 3's LENGTH is pinned to the dot by mooneye. Measured end to end, the naive
version costs more than it buys -- ~40 mooneye + GBMicrotest hblank-timing rows
red, results.md Pass 615 -> 548, for gambatte 3253 -> 3288.

This is that decoupling. No shipped behaviour changes: M3_PIPE_DELAY still
defaults to 0 and results.md is byte-identical to main. What changes is that
turning it up is now a question about the PHASE alone.

WHAT THE FLAG ACTUALLY MEANS. Mode 3 no longer ends when the shifter emits
pixel 159; it ends when the BG FETCHER retires, which is M3_PIPE_DELAY pixels
earlier. The pixels still in the FIFO come out during the first dots of
H-Blank with the fetcher parked. The head delay and the early flag are the same
n and cancel, so mode 3 stays 172 + SCX&7 + object penalties exactly.

Two things inside it that are choices, not details:

* The CPU VRAM/OAM locks keep reading the LIVE mode. They open with the flag,
  on the dot they always did. That is right because the pixels shifted out
  afterwards never touch VRAM again -- which is enforced (fifo_pipeline_dot's
  `drained` freezes the fetcher) rather than assumed. Letting the fetcher run
  on into H-Blank re-reads SCX and the LCDC selects for a tile the CPU is now
  free to move under it, and mealybug m3_scx_low_3_bits catches that within one
  line. All eleven blargg cpu_instrs frames are still pixel-identical to
  SameBoy at frame 1200, which is the canary for that boundary.
* An object overlapping the last columns (X 160..167 is partly on screen, so it
  is a real fetch) holds mode 3 open exactly as an object anywhere else does;
  the flag waits for it. Without that the object penalty would silently vanish
  for the right-hand edge of the screen.

EVIDENCE THAT THE DECOUPLING WORKS. Sweeping n = 0..8: blargg 23/28, mooneye
112/115, mooneye-wilbertpol 79/117, GBMicrotest 347/513, MagenTests 6/7 and the
mGBA suite 6967/7008 do not move at ANY n. That is the whole blocker gone.

WHY THE PHASE STILL SHIPS AT 0. n = 3 (what the bgtiledata/bgtilemap staircase
measurement asks for) puts gambatte exactly level at 3253 and the mealybug
percentages well up -- m3_scy_change 51.4 -> 83.5, m3_bgp_change 74.8 -> 84.2,
m3_window_timing 92.1 -> 95.7, bgtilemap 0/40 -> 4/40, bgtiledata 0/34 -> 1/34
-- but it turns m3_scx_low_3_bits from green into 98.6%, and the two families
it is aimed at still cannot pass while the double-speed write alignment is
unfixed. One real regression for a partial win is not a trade worth making, so
the structure lands and the phase waits. The per-value cost table is at the
M3_PIPE_DELAY declaration.

Also here: an early attempt to model the residual as a LATENCY on the CPU's
write instead (a p_* shadow register file, so no mode boundary would move at
all) is written up at the same declaration as falsified rather than untried. A
write that lands later can only push its effect further right, and hardware's
is further left; built and swept anyway, it takes m3_bgp_change 74.8 -> 62.3
and m3_scy_change 51.4 -> 43.9.

Cost: +0.001% to +0.005% retired instructions over five GB/GBC titles
(DINGBAT_BENCH_COUNTERS, identical emulated cycle counts), i.e. at the 0.002%
reproducibility floor. The `when M3_PIPE_DELAY == 0` guards are what keeps it
there -- without them the dead m3_draining tests cost a real +0.24%.

tools/gbgate/build.sh: use `nim c` directly rather than `nimble bench_build`
(nimble reads the file list through `git ls-files` and the extracted tree is
not a repo), and add GBGATE_FLAGS_A/B so one arm can carry a -d: knob.
```

## gb: the mode-3 pipeline lead is a CPU M-cycle, not a dot count

`5567bd19f` — Sun Aug 2 13:28:40 2026 -0700

```
gb: the mode-3 pipeline lead is a CPU M-cycle, not a dot count

Two gambatte families of mid-scanline LCDC writes (bgtiledata, bgtilemap)
each ship four ROMs whose only difference is that the write moves one
M-cycle, plus a reference PNG, so the boundary they draw is a staircase you
can solve for the fetcher's phase against the CPU. Sweeping the pipeline
lead in dots over 0..8 and scoring rows 16..143 of all 74 rows:

  lead (dots)   0      1      2      3      4      5..8
  single speed  61440  28672  28672  0      0      61440
  double speed  11264  0      0      11264  11264  17408+

Two disjoint windows, so no constant number of dots passes both. That is
the shape of a quantity one M-cycle long: 4 dots at normal speed and 2 in
double speed (Pan Docs, "Dots"). Solving {3,4} - k = {1,2} - k/2 gives
k = 4 and only 4, and at one M-cycle both windows collapse onto the same
{-1, 0} -- i.e. the residual dot term is zero and the two speeds agree.

That constant is not a fit: it is where dingbat already puts a CPU write
for the purposes of the VRAM/OAM locks. mem_write runs the M-cycle's PPU
dots before handing the byte to write_byte, so the DATA commits at the end
of the M-cycle, while cpu_vram_open/cpu_oam_open admit the same write on
the LATCHED mode -- the mode at its START. Hardware has one event, not
two; the pipeline is one M-cycle behind what this renderer assumed, and it
is a factor of two behind in double speed for the same reason.

So M3_PIPE_DELAY (dots, speed-independent) gains M3_PIPE_MCYCLES
(M-cycles, latched per line off current_speed), the lead becomes the
runtime m3_lead, and the pipeline machinery still compiles out entirely
when both are 0. Two fixes fall out of making the lead real:

  * fetcher_retired now also holds mode 3 open for a window that has not
    started yet (WX <= 166 still reaches lx 159 and restarts the BG
    fetch), not just for a pending object;
  * the tail the lead pushes past the end of the line is emitted in one
    burst on the dot the fetcher retires, instead of draining into the
    first dots of H-Blank. "The fetcher retired" means the line is already
    decided, so nothing the CPU does in H-Blank may reach it -- and the
    fetcher no longer runs during H-Blank at all, which is what the old
    `drained` flag was there to approximate.

Shipping default stays 0, i.e. this build is byte-for-byte identical to
the previous one on the whole runner (results.md, results_gambatte.md and
results_mgba_suite.md all diff clean; retired instructions within 0.03%).
At -d:M3_PIPE_MCYCLES=1 the double-speed bug is gone and the accuracy is
much better -- gambatte 3253 -> 3256, age/m3-bg-lcdc-ds-cgbBCE goes green,
mealybug m3_scy_change 51.4% -> 83.5%, m3_bgp_change 74.8% -> 87.3%,
m3_bgp_change_sprites 75.9% -> 89.1%, m3_window_timing 92.1% -> 96.9% and
eight more rows up -- but it costs mealybug m3_scx_low_3_bits (100% ->
98.6%, a green row) and two gambatte group counts the runner gates on
(sprites 257 -> 255, window 258 -> 256), and ~5% retired instructions.
Every one of those costs is a WX=166 / OBJ X=166 / SCX-at-H-Blank row:
the head-delay accounting's tail, not the M-cycle constant. Landing it for
real means committing the write at the start of its M-cycle in mem_write
so the pipeline never moves and there is no tail to account for.
```

## gb: the CGB boot handoff was half an M-cycle out of phase with the CPU

`78cd7251b` — Sun Aug 2 13:43:41 2026 -0700

```
gb: the CGB boot handoff was half an M-cycle out of phase with the CPU

The CPU and the PPU run off one clock and every SM83 instruction is a whole
number of M-cycles, so the offset between the PPU's dot grid and the CPU's
M-cycle grid is a fixed property of the machine. It does not depend on which
boot ROM ran: the handoff decides WHERE in the frame the machine restarts, not
where inside an M-cycle. DMG and CGB must therefore agree on it mod 4.

They did not. On DMG the phase falls out of the LCDC-enable head start of 5
dots (mooneye lcdon_timing-GS pins it to 5..8, hblank_ly_scx_timing-GS pins it
to 1 mod 4): from there the line ends 457 - 5 = 452 dots later, exactly 113
M-cycles, so every line boundary lands on an M-cycle boundary. The CGB
handoff seed was 160, which puts the first line boundary 457 - 160 = 297 dots
out — one dot past the grid — and every CGB line boundary after it a dot early
against the CPU. 457 - phase = 0 (mod 4) wants phase = 1 (mod 4), and 161 is
the only such value inside 159..162, the window gambatte
display_startstate/stat_1 + stat_2 leave open. Sweeping confirms the period:
157, 161 and 165 all score the same, 158/159/162/163 all score 29 rows lower,
160 lowest of all.

The symptom was clean: in the gambatte m2int_* families, where each ROM has a
DMG twin and a CGB twin that expect the SAME value, every CGB row missed by
exactly one M-cycle while its DMG twin passed.

gambatte 3253 -> 3304 / 5005. halt 110 -> 124, m0enable 143 -> 149, window
258 -> 268, lcd_offset 36 -> 40, sprites 257 -> 263, dma 108 -> 112,
oam_access 49 -> 52, vram_m3 32 -> 35, m2int_m3stat 24 -> 27, and eight
smaller groups. Nothing outside gambatte moves: Blargg 23/28, Mooneye 112/115,
mooneye-wilbertpol 79/117, GBMicrotest 347/513, Mealybug and MagenTests
unchanged, mGBA suite 6967/7008, results.md still 934/615/319.

One group goes the other way — speedchange 111 -> 106 — and it is the same
five-row shape at the mode 3 -> 0 STAT edge that STAT_MODE_HOLD (below)
describes: with the CGB phase corrected, those rows now read one M-cycle early
like the rest of the cluster instead of being masked by the phase error. It is
106 at 157, 161 and 165 alike, i.e. it is a property of the correct alignment,
not of 161.

Also lands the instrument the rest of that cluster was measured with
(-d:gb_stat_read_trace, compiled out of every shipping build), the
STAT_MODE_HOLD knob and its write-up of what the m2int_* families actually
pin, and LCD_ON_HEAD_START / CGB_BOOT_PHASE so both phases can be re-swept
when the STAT read model moves. STAT_MODE_HOLD ships off and compiles out
whole; see its comment for why the model it implements is not the right one.
```

## gb: the CGB boot handoff was half an M-cycle out of phase with the CPU

`abd106f5e` — Sun Aug 2 13:43:41 2026 -0700

```
gb: the CGB boot handoff was half an M-cycle out of phase with the CPU

The CPU and the PPU run off one clock and every SM83 instruction is a whole
number of M-cycles, so the offset between the PPU's dot grid and the CPU's
M-cycle grid is a fixed property of the machine. It does not depend on which
boot ROM ran: the handoff decides WHERE in the frame the machine restarts, not
where inside an M-cycle. DMG and CGB must therefore agree on it mod 4.

They did not. On DMG the phase falls out of the LCDC-enable head start of 5
dots (mooneye lcdon_timing-GS pins it to 5..8, hblank_ly_scx_timing-GS pins it
to 1 mod 4): from there the line ends 457 - 5 = 452 dots later, exactly 113
M-cycles, so every line boundary lands on an M-cycle boundary. The CGB
handoff seed was 160, which puts the first line boundary 457 - 160 = 297 dots
out — one dot past the grid — and every CGB line boundary after it a dot early
against the CPU. 457 - phase = 0 (mod 4) wants phase = 1 (mod 4), and 161 is
the only such value inside 159..162, the window gambatte
display_startstate/stat_1 + stat_2 leave open. Sweeping confirms the period:
157, 161 and 165 all score the same, 158/159/162/163 all score 29 rows lower,
160 lowest of all.

The symptom was clean: in the gambatte m2int_* families, where each ROM has a
DMG twin and a CGB twin that expect the SAME value, every CGB row missed by
exactly one M-cycle while its DMG twin passed.

gambatte 3253 -> 3304 / 5005. halt 110 -> 124, m0enable 143 -> 149, window
258 -> 268, lcd_offset 36 -> 40, sprites 257 -> 263, dma 108 -> 112,
oam_access 49 -> 52, vram_m3 32 -> 35, m2int_m3stat 24 -> 27, and eight
smaller groups. Nothing outside gambatte moves: Blargg 23/28, Mooneye 112/115,
mooneye-wilbertpol 79/117, GBMicrotest 347/513, Mealybug and MagenTests
unchanged, mGBA suite 6967/7008, results.md still 934/615/319.

One group goes the other way — speedchange 111 -> 106 — and it is the same
five-row shape at the mode 3 -> 0 STAT edge that STAT_MODE_HOLD (below)
describes: with the CGB phase corrected, those rows now read one M-cycle early
like the rest of the cluster instead of being masked by the phase error. It is
106 at 157, 161 and 165 alike, i.e. it is a property of the correct alignment,
not of 161.

Also lands the instrument the rest of that cluster was measured with
(-d:gb_stat_read_trace, compiled out of every shipping build), the
STAT_MODE_HOLD knob and its write-up of what the m2int_* families actually
pin, and LCD_ON_HEAD_START / CGB_BOOT_PHASE so both phases can be re-swept
when the STAT read model moves. STAT_MODE_HOLD ships off and compiles out
whole; see its comment for why the model it implements is not the right one.
```

## gb/ppu: keep the STAT_MODE_HOLD scratch out of the shipping GbPpu

`4d663b025` — Sun Aug 2 13:52:08 2026 -0700

```
gb/ppu: keep the STAT_MODE_HOLD scratch out of the shipping GbPpu

Guarding only the code left three fields (two u8 + an i32) in GbPpu that the
shipping build never reads or writes, and moving the object's layout is not
free: with them in, retired instructions were +0.02..+0.05% across Crystal,
Blue and Shantae, including on a DMG ROM the CGB change cannot touch. The
fields now sit inside the same `when` as the latch, so the knob costs the
default build nothing at all.
```

## gb/ppu: keep the STAT_MODE_HOLD scratch out of the shipping GbPpu

`894c8f332` — Sun Aug 2 13:52:08 2026 -0700

```
gb/ppu: keep the STAT_MODE_HOLD scratch out of the shipping GbPpu

Guarding only the code left three fields (two u8 + an i32) in GbPpu that the
shipping build never reads or writes, and moving the object's layout is not
free: with them in, retired instructions were +0.02..+0.05% across Crystal,
Blue and Shantae, including on a DMG ROM the CGB change cannot touch. The
fields now sit inside the same `when` as the latch, so the knob costs the
default build nothing at all.
```

## gb: a CPU write commits at the start of its M-cycle, not the end

`c5fe70139` — Sun Aug 2 14:28:56 2026 -0700

```
gb: a CPU write commits at the start of its M-cycle, not the end

dingbat decided a write's VRAM/OAM lock on the mode at the START of its
M-cycle and then landed the byte at the END of it, because mem_write ran
the M-cycle's PPU dots before write_byte. On hardware the lock and the
data are one event, and that one-M-cycle skew was the whole of the mode-3
fetch-phase residual -- the reason the BG fetcher sampled LCDC too early
relative to the CPU, and the reason M3_PIPE_MCYCLES existed.

mem_write now splits the M-cycle: mem_tick_bus (scheduler, timer, OAM DMA
-- the DMA first because dma_busy picks the write path) runs, then the
byte lands, then mem_tick_ppu runs the dots. Reads are untouched; they
have no data to commit and their sample point is already the read_mode
latch. Moving the PPU to the end of mem_tick_components for every caller
is a verified no-op on its own (all 934 rows, gambatte's 5,005 included).

Four things follow from the reorder, each measured:

* The locks are asked at the write's own commit point. cpu_vram_open's
  write rule reads the live mode where it used to read read_mode -- the
  same value, one M-cycle earlier in the code. cpu_oam_open's needs the
  one fact the start of an M-cycle cannot supply, whether mode 2 ends
  inside it; mode 2 always ends at dot 80, so the M-cycle's own dot span
  answers it. Dropping that term (Pan Docs' unmodified "OAM is the PPU's
  for all of modes 2 and 3") costs lcdon_write_timing-GS, so it stays.
* The LCD-on head start is measured from an M-cycle boundary by both
  ROMs that pin it, and this is the write whose effect is a restart of
  the PPU's own clock, so the seed backs the M-cycle out. Flat 5 restarts
  a double-speed PPU an M-cycle late (enable_display/*_ds_*).
* The fine-scroll discard is the fetcher's, not the shifter's: SCX is
  latched when the throw-away first fetch completes, not a dozen dots
  later when the shifter first finds a pixel. m3_scx_low_3_bits brackets
  that latch with two SCX writes one M-cycle apart.
* Re-driving the STAT interrupt line from an LCDC/STAT/LYC write is a
  mode-machinery event, and the mode machinery was never out of phase
  with the CPU -- so that half of the write stays on the M-cycle
  boundary (mem_flush_deferred). IF was tried there too and does not
  belong: it costs 18 gambatte rows to buy one back.

  gambatte      3253 -> 3311   (18 subdirectories up, none down)
  results.md    615  -> 619    Total 934
  mealybug      m3_scy_change 51.4 -> 83.5, m3_bgp_change 74.8 -> 87.3,
                m3_bgp_change_sprites 75.9 -> 89.1, m3_window_timing
                92.1 -> 96.9, +9 more up; m3_lcdc_bg_map_change
                97.5 -> 97.3 and m3_lcdc_obj_size_change 99.6 -> 99.5
  age           m3-bg-lcdc-ds-cgbBCE GREEN, cgbBCE 88.9 -> 98.9,
                dmgC 83.3 -> 94.4, m3-bg-bgp-dmgC 96.2 -> 98.4
  GBMicrotest   347 -> 349     wilbertpol 79 -> 80
  mooneye 112/115, blargg 23/28, mGBA 6967/7008, jsmolka, FuzzARM,
  MagenTests, acid2 all unchanged

One row regresses: gbmicrotest/oam_int_if_edge_d, one of sixteen
IF-edge-race rows that go 10/16 -> 12/16 overall. Its M-cycle has the
CPU clearing IF and the PPU raising the mode-2 STAT source, and which
wins is sub-M-cycle -- dingbat lumps the four dots, so it cannot split
them. The two mealybug rows that lose a tenth of a percent are the
line's first two tiles, the known fetch-phase gap at a line start.

M3_PIPE_MCYCLES stays 0 and is now a diagnostic: turning it up counts
the same M-cycle twice.
```

## gb/cpu: keep the interrupt check a leaf

`d3791b2a3` — Sun Aug 2 14:52:53 2026 -0700

```
gb/cpu: keep the interrupt check a leaf

handle_interrupts runs after every instruction and almost never takes the
branch, but the two mem_writes in its taken half are always_inline, and
that is enough register pressure to give the whole proc a real prologue --
paid on every one of the tens of millions of calls a second that do
nothing. Splitting the taken half into a noinline dispatch_interrupt is
worth ~1% of all retired instructions against main on both a DMG and a
CGB title, and no test moves (pure refactor: 934 rows byte-identical).

It shows up now because the write path grew a little in the M-cycle
commit change, which pushed handle_interrupts over the threshold; the
cost was always latent.
```

## gb/ppu: charge an object what Pan Docs' OBJ penalty algorithm says

`8beda495f` — Sun Aug 2 22:28:47 2026 -0700

```
gb/ppu: charge an object what Pan Docs' OBJ penalty algorithm says

The FIFO renderer charged a flat 8 dots for every object on a line. Pan Docs
(Rendering, "OBJ penalty algorithm") charges 6 for the object's own tile fetch
plus a wait for the BG fetch that object interrupted -- 6 to 11 dots depending
on where the object's leftmost pixel sits inside its BG tile, and the wait is
paid once per TILE, not once per object.

Both halves come straight out of this renderer's own state. The BG FIFO holds
exactly the not-yet-emitted pixels of the tile on screen, so its occupancy at
the trigger dot IS "how many of that tile's pixels are strictly to the right of
The Pixel"; fetcher_x is the tile identity to charge the wait against. An
object hanging off the left edge belongs to the tile BEFORE the first on-screen
one, which is what makes Pan Docs' X=0 exception ("always 11 dots, regardless
of SCX") fall out of the general rule instead of needing a special case -- and
what leaves the leftmost on-screen tile unconsidered for the next object, which
gambatte's 10spritesPrLine_1xpos0 measures against 10spritesPrLine.

The eight-phase sprite state machine collapses to a dot countdown, so this is
also two fewer fields on GbFifoPpu and less work per object.

Measured, not fitted. Sweeping the flat term over 4..8 and the wait's offset
over 1..5 against all 476 gambatte/sprites rows has a unique optimum at Pan
Docs' own (6, minus 2) -- 391 rows against 312 for the next best, with the old
flat 8 sitting in that table's bottom-right corner. With the algorithm in, all
38 NspritesPrLine/1spritesPrLine m3stat brackets are satisfied by ONE
consistent STAT-read model, so what is left of that family is the read lag
STAT_MODE_HOLD already documents rather than anything the object does.

The BG fetcher now runs for the wait and stops for the object's own six dots
(one address bus). Running it through the object fetch as well was measured,
not assumed: it costs no dots either but moves every later BG VRAM read on the
line, and eleven mealybug m3_* rows say that is wrong (m3_scy_change
92.6% -> 78.3%).

  gambatte/sprites   266 -> 374     gambatte total 3378 -> 3490
  gambatte/scy         6 -> 9       scx_during_m3 30 -> 31, bgtiledata 1 -> 2
  gambatte/m0enable  150 -> 149     (enable_wxA6_2x_spxA7_ds_4, an OBJ at X=167
                                     one M-cycle from its boundary in double
                                     speed; the 6-dot penalty it wants is the
                                     one 1spritesPrLine_offset7 confirms)
  gbmicrotest        393 -> 394     (sprite4_{0,1,2}_a gained, sprite_{0,1}_b
                                     lost, both to the same STAT read lag)
  mealybug           11 m3_* rows up, none down
  results.md         Total 934, Pass 665 -> 666
  Mooneye 112/115, Blargg 23/28, mGBA 6967/7008, wilbertpol 82/117 unchanged

Retired instructions (DINGBAT_BENCH_COUNTERS, 1800 frames, equal emulated
cycles): Link's Awakening -0.18%, Pokemon Crystal -0.12%, Shantae -0.33%.
tools/gbgate over 26 real ROMs: 24 identical, and the two that are not are the
same DMG Link's Awakening twice, three pixels on one scanline of one frame of
the title-screen wave animation. blargg cpu_instrs 11/11 pixel-identical to
SameBoy at frame 1200.
```
