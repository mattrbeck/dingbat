# GB test failures: a ranked triage

**Date:** 2026-08-03
**Tree:** `main` @ `151b952` ("gb/ppu: the BG fetch restarts on the dot it pushes,
and the pipeline leads by 2")
**Purpose:** assign every remaining failing Game Boy row to a root-cause bucket and
rank the buckets by rows recoverable per unit of work, so the next round is chosen
by leverage rather than by guess. This is a triage, not a fix list.

Reproduced with an isolated `TMPDIR`, a private `DINGBAT_ROM_CACHE` and a private
nimcache. All three are shared across worktrees and have produced wrong results
here; the run below matches the committed `tests/results.md` row for row.

## Rows that pass on one revision and fail on another — swept 2026-08-19

Every currently-failing self-checking row (mooneye, wilbertpol, AGE — 113 of
them, all boolean via the Fibonacci protocol) re-run on all eleven revisions
dingbat models: dmg0, dmgABC, mgb, sgb, sgb2, cgb0, cgbab, cgbc, cgbd, cgbe,
agb. Script: `tools/gbppu/revsweep.py`.

**Exactly six pass on at least one revision, and they are one family:**

    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx4_timing_nops
    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_scx8_timing_nops
    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_nops
    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx2_nops
    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx3_nops
    mooneye-wilbertpol/acceptance/gpu/intr_2_mode0_timing_sprites_scx4_nops

All six are green on **every CGB revision AND on AGB**, and red on **every**
DMG-family one (dmg0/dmgABC/mgb/sgb/sgb2). They are scored as DMG. So the
behaviour is implemented and correct — it is the DMG side of it that is wrong,
which is a far smaller problem than a row that is red everywhere.

**The residue pattern names the mechanism.** Among the plain SCX variants on
DMG, `scx1`, `scx2`, `scx3`, `scx5`, `scx6` and `scx7` all PASS; only **`scx4`
and `scx8`** fail — and 8 mod 8 = 0. With sprites, every `_nops` variant fails
(`scx1` fails on all eleven revisions, the rest recover on CGB). The plain
non-`_nops` rows — `intr_2_mode0_timing` and `intr_2_mode0_timing_sprites`, in
both forks — pass, so this is only visible at the ONE-NOP granularity the
`_nops` builds measure.

That is mode-3 LENGTH as a function of `SCX mod 8` and of object presence, on
DMG, at single-nop resolution: the same grid-alignment quantity as
`cgb-acid-hell`, the 31 halt-lead rows and probe (e)'s column table, seen from
the DMG side for once. Two useful consequences:

* it is a **DMG** instrument for a question that has otherwise only been
  asked on CGB, and dingbat's DMG and CGB paths clearly disagree here;
* it is **cheap to iterate** — six boolean rows, each a sub-second run, versus
  probe (e)'s 136-cell fit.

Worth trying before the structural work: whatever separates dingbat's DMG
mode-3 length from its CGB one at `SCX mod 8 in {0, 4}` and under objects.

**Everything else is red on all eleven revisions**, so there is no other
cheap revision-gating win hiding in the self-checking suites. That is the
useful negative: the remaining 107 failures are real behaviour gaps, not
mis-assigned machines.

## The last mooneye row: `madness/mgb_oam_dma_halt_sprites` — 18 pixels

**Corrected 2026-08-19.** An earlier note here read the diff as a
"phase-inverted checkerboard" from the tile grid. That was wrong. The colour
histograms say what is actually going on:

    dingbat     11520 white + 11520 grey(170,170,170)          no sprite
    reference   11517 white + 11505 grey(176,176,176) + 18 px dark(104)

The checkerboard PHASE matches exactly. The tile diff lit up alternate columns
because only the GREY tiles differ, and in a checkerboard the grey tiles ARE
alternate columns. And they differ only in SHADE: this reference uses a
255/176/104 ramp where every other mooneye reference — `sprite_priority-dmg.png`
included, which dingbat matches exactly — uses 255/170/0. That is an encoding
difference in the PNG, not an emulator difference, so both rows now carry
`grey_tolerance: 8`, which absorbs the 6-level ramp gap and nothing else. The
row went from a misleading **50.0%** to **99.9% (23022/23040)**.

**The entire real defect is 18 pixels: one sprite dingbat does not draw.**

### What has to be modelled

The ROM's own header states the behaviour is per-machine, which is why this is
an MGB row:

    MGB:      as visualised by *_expected.png
    DMG:      a different sprite
    CGB:      checkerboard WITHOUT sprites
    AGB/AGS:  a different sprite

**dingbat currently produces the CGB answer on an MGB.**

The mechanism, from `madness/mgb_oam_dma_halt_sprites.s`: OAM DMA is started
from HRAM and the CPU halts while it is still running, which stalls the transfer
mid-OAM-write with no interrupt enabled to end it. The PPU keeps drawing and
sees a bus conflict, rendering ONE phantom sprite whose four bytes come from two
existing OAM bytes and the one incoming DMA byte:

    Y = (existing | incoming) & $FC        X = (next_existing | incoming)
    C = (existing | incoming) & $FC        F = (next_existing | incoming)

With this ROM's `$30`/`$40` existing and `$1A` incoming that is Y=$38 (56),
X=$5A (90), tile $38, flags $5A — above BG, H-flipped, OBP1. The `& $FC` is
unexplained upstream ("Why & $FC? I have no idea").

It is additionally GATED: no sprite appears at all unless OAM contains at least
one properly aligned four-byte group inside these ranges — `$98-$9F`,
`$00-$A7`, `$09-$9F`, `$00-$A7`. Position does not matter and more than one is
fine. Upstream flags two of those bounds as not understood either.

### 2026-08-20: the ROM's own data says dingbat is running the DMA to COMPLETION

Reading the source rather than the picture moves this a long way. Two facts pin
the mechanism:

**1. Where the transfer stops is not a guess.** `common/macros.s` expands
`start_oam_dma` to `wait_vblank / ld a,addr / ldh (DMA),a`, and the ROM follows
it with exactly `nop` then `halt`. So the CPU halts about two M-cycles into the
transfer — and the ROM's own comment names the bytes involved as OAM[2] = `$30`
(the byte "supposed to be replaced"), OAM[3] = `$40` (the next one), and `$1A`
(the incoming byte, which is `$2000 + 2` in the source page). **The unit is
frozen mid-write to OAM index 2**, which is exactly where two M-cycles of DMA
would put it. Nothing here needs inventing.

**2. The CGB row of the header explains dingbat's picture completely.** The
source page is `$FF $FF $1A $FF` followed by 156 more `$FF`, so a transfer that
RUNS TO COMPLETION leaves `Y = $FF` in all forty sprites, every one off-screen,
giving a checkerboard with no sprites — the ROM's stated CGB answer. dingbat
draws precisely that on an MGB. **So the primary defect is not a missing
phantom-sprite rule: dingbat lets the OAM DMA finish during `halt`, where a
DMG-family machine freezes it.** That is a claim about the DMA unit's clock —
HALT gates the CPU clock on a DMG, and if the DMA unit rides that clock it
stops with it, while the CGB's evidently does not.

**Tested, and it does not change the picture — for a knowable reason.** Freezing
the transfer while `cpu.halted` on DMG-family renders byte-identically. With the
unit stopped at index 2, OAM still reads `FF FF 30 40 9F A7 9F A7` then zeroes,
and the only on-screen sprite that leaves is entry 1 at Y=`$9F` (159), X=`$A7`
(167) — using **tile `$9F`, which this ROM never draws into**. It is invisible.
So the freeze is necessary but cannot be OBSERVED through this ROM, and the
expected sprite can only come from the bus conflict on top of it.

**And the conflict now has a shape that explains the exact expected sprite.**
If, while frozen, the OAM address bus is stuck at the DMA's current index and
the data bus carries `stored | driven`, then every PPU OAM read returns the same
two bytes — `($30|$1A) = $3A` and `($40|$1A) = $5A` — so all forty sprites
resolve to the same Y, X, tile and flags and draw on top of each other, which
looks like ONE sprite. With the `& $FC` the ROM records on the Y/tile byte that
is Y=`$38` (56), X=`$5A` (90), tile `$38`, flags `$5A`: **the reference sprite,
exactly.** The unexplained parts are the mask itself and the four-byte range
gate, and upstream marks both as not understood either.

### Why it is not implemented yet

Scope is small (one phantom sprite, gated on `dma_active and cpu.halted`) but
the details are invented rather than derived: which OAM index the stall lands
on, whether the phantom suppresses real sprites or merely wins, and what the
range gate physically is. Getting those wrong risks the 40-row `oamdma` family
for one row. The instrument is now honest — 18 pixels, not half a screen — so
this can be picked up cold.

**If it gets a hardware session**, the first question is far simpler than the
sprite and does not involve the PPU at all: **does OAM DMA keep running while
the CPU is halted?** Probe design, which is worth building properly:

* pre-fill OAM with `$11` and a DMA source page with `$22`, so "transferred" is
  distinguishable from "not";
* the LAST byte a transfer writes is OAM `$FE9F`, and a CPU read of OAM while
  the DMA holds the bus answers `$FF` — so polling `$FE9F` until it turns `$22`
  measures the part of the transfer still outstanding;
* start the DMA, `halt` with a timer set to wake ~160 M-cycles later (one whole
  transfer), and on waking count poll iterations. Run the same thing again with
  a busy-wait of the same length as a control.
* **DMA keeps running while halted** -> it has finished by the wake, so the two
  counts MATCH. **DMA freezes** -> it resumes with ~158 bytes to go and the
  halt count is far larger. The two answers are ~30 poll iterations apart, not
  a couple.

A Game Boy Pocket is the ideal machine; running it on a CGB too is worth it,
since the two should DISAGREE if the per-machine split the mooneye ROM records
really is about this clock.

**Two attempts at this probe have failed to render, and the bisect is worth
having before a third.** Every component works ALONE, verified separately:
the draw path (182 px), the `fillSrc` loop (188 px), a timer waking a `halt`
with IME=0 (172 px), a `halt` with an OAM DMA already in flight (80 px), and
the entire halt-run path end to end including the capped poll (153 px). But:

* adding a SECOND measurement to the same image blanks the screen;
* and replacing the `halt` with a 40-iteration `nop` busy-wait — nothing else
  changed — also blanks it.

So the fault is structural in the ROM rather than in any measurement, and it is
NOT the halt, the DMA, the poll or the drawing. Suspect the section layout or a
label/register collision introduced when the pieces are combined; disassemble
the linked image rather than re-reading the source, which is what two passes of
source-reading failed to catch.

**Also re-derive the interpretation before running it.** The working row-0-only
build reads `00C0` (192 poll iterations) in dingbat, where dingbat completes the
transfer during the halt and the model therefore predicts ~1. Either the poll is
far slower per iteration than assumed (it is ~17 M, not ~6), or the timer wake
is not the 160 M intended. Until that number is understood, a hardware reading
cannot be interpreted — so the probe is not merely unfinished, its scale is
unvalidated.

After that, the sweep ROM: vary `initial_data`'s two bytes and the DMA source
byte across a grid so the OR-and-mask rule and the range gate are measured
rather than taken from a comment.

## RESOLVED 2026-08-19: `rtc3test-1` and `-3` were a HARNESS bug, not an RTC one

Both rows now pass and the Shootout section is **13/13**. There was never
anything wrong with dingbat's RTC.

The investigation below was right about every fact and wrong about whose fault
it was. dingbat reaches `rtc3test-1`'s reference at frame **720** and the
harness sampled at **570**, so the "missing" pixels were lines the ROM had not
drawn yet. I took 570 from the shootout's `testroms/ax6.py` (`runtime=9.5`) and
concluded that lengthening it would be scoring gbdev's images by a looser rule
than they publish. **That was the error: `runtime` is not the budget.**
`emulator.py` polls until

    test.runtime / speed + self.startup_time + 5.0

seconds have elapsed, and `emulators/dingbat.py` converts that to frames as
`(runtime + startup_time + 5.0) * 59.7275` with `startup_time = 1.0`. The real
budget for `rtc3test-1` is **925 frames**, not 570 — so using 570 was the
TIGHTER rule, exactly the mistake the ShootoutTolerance comment warns about
from the other direction.

This also reconciles a discrepancy that had been sitting unexplained: the
shootout scores dingbat **261/261 including these rows**, while this tree
scored them red. One harness was wrong, and it was ours.

### What the investigation did establish, and it still stands

* **Every sub-test PASSES**, and dingbat's frame is a **100.0% pixel match** to
  the reference — zero differing pixels, not merely within tolerance.
* **The tick rate is exact:** 570 frames x 70224 T = 9.54 RTC seconds against
  the 9.5 s allotted; `RTC_SECOND_CYCLES = 4194304` and `schedule_gb` scales it
  by `current_speed`.
* **The sub-second reset rule is right**, and `tools/gbprobe/roms/rtcrate.asm`
  measures it directly: 60 frames after a SECONDS write (divider reset), 30
  after a MINUTES write and after halt/resume (remainder kept). That matches
  rtc3test's own `tests.md` (RTCS/500 and RTCS/900 expect 1000 ms; RTCM/50
  expects 50 ms).
* **The green is a red herring:** rgb(0,206,0) vs the reference's rgb(0,145,0)
  is ~35 luma, inside the shootout's tolerance of 50, and contributes zero
  differing pixels.
* RTC behaviour is corroborated green by `mealybug/mbc/mbc3_rtc`,
  `mbc3-tester`, `latch-rtc-test`, `rtc-invalid-banks-test`, `ramg-mbc3-test`.

**Harness trap worth keeping:** these carts are battery-backed, so a bare
`dingbat_test` run leaves a `.sav` and the next run starts from the previous
run's clock — the battery appears to finish sooner every time. The runner
passes `no_save: true`; manual repros need `--nosave` and a stale-save sweep.

**Hardware note (2026-08-19):** `rtcrate.gb` was run on Matt's GBA SP and the
cart's MBC3 turned out to have no RTC behind it — every tick wait timed out,
and plain cart RAM read open bus. Settling this on silicon would need a cart
with genuine MBC3 RTC support. It is no longer needed for these rows.

## CORRECTED 2026-08-19: the CGB halt lead is net +45 on gambatte, not -31

Earlier notes in this tree describe `CGB_HALT_PPU_LEAD=1` as *costing* ~31
gambatte rows. **That was the breakage list, not the net, and it is no longer
even that.** Measured by building the control into `dingbat_test` (which is what
the runner shells out to -- rebuilding the runner changes nothing):

    CGB_HALT_PPU_LEAD      0            1 (ship)
    gambatte            4213/5005     4258/5005
    runner Pass          1008          1012

Per ROM the lead **breaks 31 and fixes 76**. It also closes `cgb-acid-hell`,
the 261st shootout row. The balance moved because `HDMA_VISIBLE_DOTS` and
`CGB_HALT_LEAD_SKIP_LYC0` were added after those notes were written. Turning
the lead off to recover the 31 would surrender 45 others and the shootout row.
Do not treat the 31 as a block to be "recovered" by reverting.

### The 31 are structured, and the structure is SCX

* **9 `halt/*_m0stat_*`**, every one `[cgb]`, every one at **SCX 2 or SCX 5**.
  The rows the lead FIXES in the same family are SCX 3, SCX 4 and the
  double-speed SCX 2/3 variants. So a uniform lead is being applied where the
  correct amount depends on where mode 3 ends -- the same SCX grid-alignment
  question `cgb-acid-hell` ran into, not an independent bug.
* **10 `dma/hdma_*`**, seven of them `hdma_late_disable`.
* **8 `lcd_offset/offset1|2_lyc9Xint_*`**, plus 4 `*lcdoffset1*` rows over in
  `window` and `lycEnable`.

### Refuted 2026-08-19: HDMA_VISIBLE_DOTS is not the lever

`HDMA_VISIBLE_DOTS` is *defined* as `4 + 4 * CGB_HALT_PPU_LEAD`, so the obvious
hypothesis was that the coupling constant is wrong and the seven
`hdma_late_disable` rows would come back at some other value. Swept whole-suite:

    HDMA_VISIBLE_DOTS     4      6      8 (ship)   10     12
    gambatte dma        116    121      121      118    116
    gambatte total     4253   4258     4258     4255   4253

The shipping value is already at the maximum, **not one of the seven rows
returns at any value**, and the runner total is 1012 in every arm. Incidentally
6 ties 8 exactly, so the `4 *` term is over-specified -- `2 *` would score the
same. Not worth changing, but do not read the 4 as measured.

### Refuted 2026-08-19: STAT_M0_FIELD_TAIL_CGB is not the lever either

The nine broken `halt` rows are all `[cgb]` and all `*_m0stat_*`, reading STAT
and getting 2 where the ROM wants 0, so the named knob for how long CGB's
mode-0 STAT field is visible was the obvious next lever. Swept whole-suite:

    STAT_M0_FIELD_TAIL_CGB    0 (ship)    1       2       3
    gambatte total             4258     4232    4213    4203
    gambatte halt               136      136     136     136
    gambatte dma                121      121     121     121
    gambatte lcd_offset          35       35      35      35

The three groups that hold all 31 rows are **byte-identical in every arm** --
the knob does not reach them at all -- while the suite total falls
monotonically, so the shipping 0 is already optimal and every nonzero value is
pure damage elsewhere. Two named, plausible, directly-aimed constants now both
answer "not here", which is the same verdict earlier rounds reached about
`OBJ_WAIT_SUB` and `CGB_TDSEL_LATENCY`: **these rows do not have a knob.**

### What the 31 rows actually need

The SCX split is the whole tell: broken at SCX 2 and 5, fixed at SCX 3 and 4.
A single scalar lead cannot be right at every SCX because the quantity it is
standing in for depends on where mode 3 ends, which moves with `SCX & 7`. That
is the same grid-alignment model gap `cgb-acid-hell` needed and that
docs/probe-e-plan.md concluded "needs a structural path, not a knob" -- the
fetcher's displacement and the mode-3 length are two quantities on silicon and
one field here. Until that is separated, expect every scalar sweep aimed at
these 31 to return what these two did.

Do NOT spend another round on constants here. The next real move is the
structural one, and it is the same one probe (e) is blocked on.

## NEW 2026-08-19: `mooneye/misc/boot_hwio-C` fails on AGB and passes on CGB

The per-machine fan-out (`mooneye_machines_for`, added 2026-08-19) runs every
machine a mooneye filename claims. `-C` is the suite's group token for
**cgb+agb+ags**, so that ROM now scores on CGB-C and on AGB rather than only on
whatever the default was — and the two arms disagree:

    mooneye/misc/boot_hwio-C@cgbc   PASS
    mooneye/misc/boot_hwio-C@agb    FAIL   (Mooneye: FAIL)

This is the ONLY disagreement among 77 multi-arm tests, so it is a real, narrow
defect rather than a class of them: dingbat's **AGB boot HWIO state** does not
match what the ROM asserts, while its CGB state does. Note the ROM is the same
bytes in both arms — only `--model` differs — so this is purely the boot table
in `gb_set_revision`, not PPU or timing behaviour.

Not to be confused with the wilbertpol `@agb` failures next to it in
`tests/results.md`: those rows fail on their `@cgbc` arm too (that fork's
`gpu/ly_lyc*` family is a known pre-existing bucket, below), so they carry no
AGB-specific signal.

Worth doing before anything else in this file that costs a hardware session:
it is one boot table, the expected values are in the ROM, and it is currently
the only row in the tree that says AGB and CGB differ where dingbat says they
do not.

## The denominator

`dingbat_test_runner` reports **Total 978 / Pass 691 / Fail 287**, but 45 of those
287 failing rows are *aggregates* standing for many sub-tests:

| | rows |
|---|---|
| failing top-level rows that are aggregates | 45 |
| ...the sub-test failures behind them | 1,432 |
| failing top-level rows that are individual tests | 242 |
| **individual failing sub-tests** | **1,674** |

The aggregates are the 42 gambatte subdirectories (1,391 of 5,005 rows failing) and
3 mGBA-suite sections (41 of 6,998). Ranking on the 287 would weight
`gambatte/window` — 154 failing ROMs — the same as one Blargg row, so everything
below counts individual sub-tests.

## First, shrink the denominator: 37 rows are not recoverable at all

These fail because the oracle is invalid for this tree, not because the emulator
is wrong. They must come out before anything is ranked.

| rows | what | evidence |
|---|---|---|
| **31** GBMicrotest | The ROM **never writes `$FF82`**, the byte `--mode=microtest` scores, so the harness reads uninitialised HRAM forever | Scanned all 513 bundled ROMs for `E0 82` (`ldh ($82),a`) and `EA 82 FF`. 482 contain one; **31 do not — and those 31 are exactly 31 of the failing rows, with none of them passing.** Verified independently of the agent that found it. **Shipped 2026-08-13**: `build_gbmicrotest_tests` skips them through the named `MicrotestNoVerdict` list (re-derived by a fresh scan, cross-checked row by row against `results.md`), so the suite now reports out of 482 and the 31 red rows are gone; listed in `NotScored` |
| 3 | AGE revision-locked pairs | `lcd-align-ly-cgbBC`/`-cgbE`, `spsw-tima-cgbBC`/`-cgbE`, `spsw-interrupts-cgbBC`/`-cgbE` are CGB-only pairs differing only in SoC revision. dingbat has one CGB boot model (`bmCgbABCDE`), so at most one of each pair can ever be green. **2026-08-13**: `build_age_tests` now passes each row's own token through as `--model=`, so the two halves are at least scored on the revisions they name (`grCgbC` vs `grCgbE`); measured, all six still fail, i.e. nothing modelled yet distinguishes C from E here |
| 1 | `mooneye/utils/bootrom_dumper` | A tool, not a test — dumps the boot ROM over serial and has no verdict. `build_wilbertpol_tests` already skips `utils/`; the Gekkio path does not. **Fixed 2026-08-13**: `build_mooneye_tests` now skips `utils/` too, which also drops `dump_boot_hwio` — a green row that could not fail, since `quit_dump_mem` sets the success byte unconditionally. Both are listed in `NotScored` |
| 1 | mGBA `DMA Prefetch Break` | Expects `0x10000000 + 4 × iterations` where the count depends on where gcc put the loop; already documented as unscoreable |
| 1 | `bully/bully` at 0.6% | A whole-machine torture test whose single reference is a CGB capture the author's own DMG-C fails. One row standing for dozens of independent checks; not triageable as a bucket |

`ppu_spritex_vs_scx` was already known to be in the first group; **the other 30
were not**, and GBMicrotest's headline therefore read 403/513 when the honest
figure is 403/482. The recoverable total is **1,674 − 37 = 1,637**.

**2026-08-13**: the 31 are now out of the denominator for real — the runner
skips them by name, so the suite reports `n/482` and 31 rows that could never
go green no longer sit in `results.md`.

## Two cross-cuts that reframe the problem

These are properties of the whole failure set, computed before any bucket was
opened. Both changed how the buckets below are ranked.

### 1. The failures are overwhelmingly CGB, and one family carries most of it

1,709 gambatte ROMs are scored on **both** devices. Pairing them:

| | ROMs |
|---|---|
| both pass | 1,169 |
| both fail | 277 |
| **DMG passes, CGB fails** | **208** |
| CGB passes, DMG fails | 55 |

Suite-wide the DMG fail rate is 20.5% (366/1,784) and the CGB rate 31.8%
(1,025/3,221). **90 of the 208 DMG-ok/CGB-bad ROMs are `oamdma`** — the next
family down is `window` at 39. Narrowing further, the `busypush` and `busypop`
shapes are **312/312 green on DMG and 90/312 failing on CGB**. A perfect DMG
column says the general OAM-DMA conflict machinery is right and only the CGB bus
topology is wrong, which makes this the most sharply isolated large bucket in the
suite.

Double speed, by contrast, is **not** a bucket: `_ds` rows fail at 30.4%
(291/956) against 27.2% (1,100/4,049) for single speed. Where a family's failures
cluster in its `_ds` rows that is a fact about the family, not a global
double-speed phase error.

### 2. The dominant failure shape is not a one-M-cycle phase error

A gambatte `_1/_2/_3…` family is one ROM with one write moved by one CPU M-cycle
per step, so the step at which the expected value changes *is* the measurement.
**1,250 of the 1,391 failing rows (90%) sit in such a family**, against 269 (19%)
that have a reference PNG. `tools/gbppu/famflip.py` is therefore the instrument
with by far the widest reach, and it was under-used — see the tool fix below.

Classifying all 982 family/device lines that contain a mismatch:

| shape | lines |
|---|---|
| expected value constant across the family (not a bracketing family) | 219 |
| **EARLY** — dingbat already at the family's *final* value at step 1 | 339 |
| **LATE** — dingbat still at the family's *initial* value at the last step | 264 |
| flips inside the window, at the right step but with wrong values | 53 |
| flips one step early | 39 |
| flips one step late | 41 |
| flips ±2/±3, or values outside the expected sequence | 27 |

**603 of 982 have dingbat's flip point entirely outside the family's window** —
the error is larger than the family can measure — and it is bidirectional. Only
133 lines are the ±1 M-cycle shape that a constant nudge would fix. Per family
the direction is strikingly clean, and it splits along a fault line:

| cluster | families | EARLY | LATE |
|---|---|---|---|
| STAT read anchored on a mode-2 interrupt | `m2int_m0irq`, `m2int_m3stat`, `m2int_m2stat`, `m2int_m0stat`, `lycm2int`, `lyc0int_m0irq`, `lycint_lycirq`, `m0int_m0irq`, `m0int_m0stat`, `vram_m3` | **64** | **2** |
| mode 3 → 0 edge on a line carrying ten objects | `sprites/10spritesPrLine_*`, `oam_access/10spritesprline_postread`, `vram_m3/10spritesprline_postread` | 14 | **60+** |

Those two are opposite signs and both are supported by dozens of rows.
Reconciling them was the central open question going in; it is answered below
("Is the mode-3-edge error the same quantity as the mode-0 STAT lateness?") — the
STAT-read cluster and the mode-0 edge turn out to be **one** defect in the
readback, and what looked like a second quantity is a separate LCD-enable line
phase carried by only eight ROMs.

`oamdma` is the exception that proves the instrument's limits: 88 of its 110
famflip lines have a **constant** expected value across the family. It is a
*value* suite (which byte lands in OAM), not a *timing* suite, and must be
triaged with byte-level readouts rather than flip points.

## A fix to the instrument itself

`tools/gbppu/famflip.py` stripped the filename's expectation tag with
`_out[0-9a-fA-F]` — a **single** hex character, where `tests/README.md` documents
the tag as 1 to 20 hex digits. For any family whose expected value has more than
one digit the remainder stayed glued to the family name, and because siblings
differ *precisely* in that value, exactly the families containing a flip were
split into one family per step — the case the instrument exists to show.

Changing the class to `+` recovers **276 rows into 74 additional multi-step
families**, and the spurious `+9/+10/+12/+29` flip deltas it used to report
disappear (they were mis-groupings); every delta now lands in −3..+3. It also
makes `oamdma` readable per byte, e.g.

```
oamdma/oamdma_src0000_busypopDFFF
  dmg  exp=65766576  got=65766576  .
  cgb  exp=657655AA  got=657600AA  X
```

which is a whole diagnosis in one line. This and the HDMA source fix recorded at
the end are the only two code changes in this otherwise investigation-only pass.

### A calibration against over-reading the STAT signal

The `m2int_*` cluster is vivid — 64 famflip lines, 100% EARLY, device-independent —
and it is tempting to conclude the STAT read model is the dominant defect. It is
not, suite-wide: ROMs whose name mentions `stat`/`irq`/`if` are 34% of all gambatte
failures (467/1,391) but fail at a **lower** rate than the rest (24.0% against
30.2%). The STAT concentration is real inside specific families and should not be
extrapolated to the suite.

## The perf-risk taxonomy used below

From `docs/gb_oam_dma_cost.md`, which is the authority and whose rules apply to
any A/B on these paths (retired instructions via `DINGBAT_BENCH_COUNTERS=1`, never
wall clock; `cycles=` must match between arms; diff per-function sizes before
believing a result):

| site | measured sensitivity | flag |
|---|---|---|
| mode-3 dot loop (`tick_shifter`, `fetcher_retired`) | `tick_shifter` alone is 28% of a profile; one extra branch measured **+1.7%** | **hot** |
| CPU bus path (`mem_read`/`mem_write`) | 3 instructions = +0.37%; and a one-compare edit flips an inlining cliff worth ~0.9% | **hot, and hard to measure** |
| `mem_tick_components` | 15% of a profile | **hot** |
| OAM-DMA cold handler, HDMA setup, MBC registers, boot phase | `mem_read_busy` is 5 samples in ~10,300 | cold |

## The sharpest single measurement found: `NspritesPrLine_m3stat`

`sprites/NspritesPrLine_m3stat` is one ROM per N objects on the line, N = 1..10,
each a two-step bracket of the mode 3 → 0 edge. Verdicts are identical on DMG and
CGB:

| N | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| single speed | ✗ | ✗ | ✗ | **✓** | ✗ | ✗ | ✗ | **✓** | ✗ | ✗ |
| double speed | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

(✗ = we answer `3,3`, i.e. we never reach mode 0 inside the family's window.)

Two independent constraints fall out:

1. **Single speed fails at every N except N ≡ 0 (mod 4).** One family step is one
   M-cycle = 4 dots, so this is the signature of a per-object cost that is off by
   a fraction of an M-cycle and re-aligns every fourth object. A base-offset-only
   explanation is dead, because that would be N-independent.
2. **Every double-speed sibling passes.** Mode 3's length in *dots* does not depend
   on CPU speed, and at double speed the M-cycle is 2 dots — a *finer* sampling
   grid. A genuine mode-3-length error should therefore be more visible at double
   speed, not invisible. **This is a falsification of "mode 3's length is wrong"
   for these rows**, and it points instead at the phase between the mode-0 flag
   and the M-cycle the STAT read samples in.

The controlled A/B that makes it stick is inside one directory:
`vram_m3/postread` and `vram_m3/10spritesprline_postread` are the same ROM shape
differing only in whether objects are on the line, and they fail in **opposite
directions** (`exp=3,0 got=0,0` versus `exp=3,0 got=3,3`). The OBJ penalty does
not cause the error; it moves the edge, and therefore decides which M-cycle the
edge lands in and whether a given row can see the error at all.

### …and why the obvious reading of it is wrong

The N ≡ 0 (mod 4) pattern looks like a per-object cost that is off by a fraction
of an M-cycle. **It is not.** Measured here with `-d:gb_m3_len` on the family's
own ROMs:

```
10spritesPrLine_m3stat_2   objx=8,16,24,32,40,48,56,64,72,80   len=282
 4spritesPrLine_m3stat_2   objx=8,16,24,32                     len=216
 (an object-free line)     objx=                               len=172
```

282 − 172 = 110 = **11 × 10**, and 216 − 172 = 44 = **11 × 4**. Every object sits
at a multiple of 8 with SCX = 0, so each costs Pan Docs' full penalty
`6 + max(0, 5 − ((X + SCX) mod 8))` = 6 + 5 = **11 dots**, and dingbat charges
exactly that. The per-object cost is right.

The mode-3 end therefore lands at `172 + 11N`, and since 172 ≡ 0 (mod 4), its
offset within the ROM's 4-dot sampling grid is `11N mod 4 = 3N mod 4`, which is
zero **iff N ≡ 0 (mod 4)** — precisely the observed `{4, 8}` pass set. So a single
**constant** error in the mode-0 edge, smaller than one M-cycle, is invisible only
when the edge happens to land on an M-cycle boundary, and the objects are doing
nothing but sliding the edge across that grid. No N-dependent term exists.

This also disposes of the coverage-gap worry about `objtab.py`: all ten objects are
in distinct tiles at the same residue, so the family is ten independent
single-object measurements and objtab's one-object differencing is representative
of it.

**The consequence for ranking is large.** These rows are not an OBJ bucket and not
a STAT-read bucket — they are another instrument reading the same sub-M-cycle
error at the mode 3 → 0 edge that `LCD_ON_LINE0_TRIM`, `M3_END_EARLY` and
`LCD_ON_HEAD_START` have each been refused for. That makes "the dots at the
mode 3 → 0 edge" the single most over-subscribed unknown in the tree, and this
family is a new and unusually clean way to measure it, because the object count
lets you sweep the edge across the sampling grid on demand.

## The mode-0 STAT latch, bracketed on both sides to the dot

> **CLOSED 2026-08-09 — bucket 15's readback half is solved and shipped**
> (`9ff4bd7`, `965aa1d`; derivation at `stat_read_mode` in `gb/ppu.nim`).
> The whole model is one threshold, `T`: a read whose M-cycle leaves the PPU dot
> counter at `cc` returns mode 0 iff `cc - m0 >= T`. dingbat's `T` was **5** at
> normal speed and **3** in double, because `read_mode` is latched at the top of
> `fifo_tick` — one dot *before* the M-cycle's first dot — so what it carried was
> the M-cycle's length plus one and not a sample point at all. **That is the
> "one dot unaccounted for independently of `L`" below**: `STAT_READ_LAG`'s
> documented meaning (`cc - 1 - L`) and its implementation (`cc - 2 - L`)
> differed by one, so the `4D + L = 4` equation was solved a dot out and every
> cell of that grid is off by the same dot.
>
> `T = 2` at normal speed and `3` in double, each bracketed on **both** sides by
> ROMs that take **no interrupt** — which is the methodological point, because
> every `m2int_*` row's read dot is only as good as its dispatch dot:
>
> | speed | ROM | `cc − m0` | wants | pins |
> |---|---|---|---|---|
> | 1x | GBMicrotest `ppu_sprite0_scx0_a` | 1 | mode 3 | `T ≥ 2` |
> | 1x | gambatte `sprites/1spritesPrLine_m3stat_2` | 2 | mode 0 | `T ≤ 2` |
> | 2x | gambatte `sprites/1spritesPrLine_m3stat_ds_1` | 2 | mode 3 | `T ≥ 3` |
> | 2x | gambatte `sprites/10spritesPrLine_m3stat_ds_2` | 3 | mode 0 | `T ≤ 3` |
>
> `NspritesPrLine` confirms the *size* of the old error independently: each
> object moves `m0` by 11 dots across the CPU's 4-dot read grid, so an error of
> `e` dots leaves `(4 − e)/4` of the object counts agreeing with hardware.
> Exactly one `N` in four passed, which is `e = 3` and nothing else — and 3 is
> what `T` going 5 → 2 is.
>
> Measured: runner **743 → 765**, GBMicrotest **404 → 430** (all 26 of the
> `0x83`-against-`0x80` rows and *nothing else in that suite moves*), mooneye
> **112 → 113** with `acceptance/ppu/intr_2_mode0_timing_sprites` taking
> acceptance to 66/66, `NspritesPrLine` single-speed **54 → 86 of 88** with the
> `_ds` column unchanged, and not one row or pixel of mealybug, acid2, blargg,
> daid or the mGBA suite. gambatte **3856 → 3818** (+64 / −102) — see the note
> on bucket 14 below, which now owns every one of those 102 rows.
>
> Two things falsified on the way. **The double-speed dot is not a readback
> term**: nothing measured in CPU T-cycles can grow when the CPU clock doubles,
> so the extra dot is the half-dot the CPU's M-cycle boundary sits at against
> the PPU's dot grid once the M-cycle is 2 dots, which `cycles shr
> current_speed` rounds to zero. **And it is not the speed switch's phase
> either**: moving `SPEED_SWITCH_STALL_T` by the one dot that separates the CPU
> and the PPU takes the double-speed rows the *other* way (−110 / +18).
>
> **What this unblocks is bucket 14, and it also promotes it.** 98 of the 102
> gambatte rows traded are `m2int_*`-anchored and are arithmetically exactly one
> CPU M-cycle of mode-2 STAT dispatch away from correct (4 dots at normal speed,
> 2 in double; the other 4 are `lcd_offset` rows whose read is on a line with no
> mode 3). GBMicrotest says the same from ROMs that never read STAT —
> `int_oam_nops` `0x94` vs `0x93`, `int_oam_incs` `0x70` vs `0x6F`,
> `oam_int_inc_sled`, `oam_int_nops_a`, `lcdon_to_oam_int_l0..2`,
> `line_144_oam_int_c`, each exactly one M-cycle over, while the hblank, LYC and
> vblank equivalents are exact. **The old `T = 5` was three dots of readback
> error cancelling four dots of dispatch error**, which is why moving either
> alone looks like a regression and why bucket 14 could never be scored before
> this landed. The six `mooneye-wilbertpol/intr_2_mode0_scx*_timing_nops` rows
> are the same story from the other side: 6 of 8 passed on the cancellation, and
> all 8 now fail *uniformly* — one M-cycle, where a residue-split failure was
> two errors of different sizes.
>
> Still open in this bucket: the ~13 SCX-residue rows and the 20 `halt` rows,
> neither of which moved, and the half-dot itself, which an integer-dot PPU
> cannot represent anywhere but here.


Exactly **21** GBMicrotest rows report `$FF80 = 0x83` against `$FF81 = 0x80`:
`ppu_sprite0_scx{1,2,3,5,6,7}_b`, `sprite_0_b`, `sprite_1_b`,
`win{0,1,2,7,8,9,10,11,12,13,14,15}_b`, `win10_scx3_b`. Every `_a` sibling passes,
so each pair brackets the edge. Traced all 21 plus four `_a` siblings with
`-d:gb_stat_read_trace` and `-d:gb_m3_len` (`cc` is the dot being *entered*; mode 0
begins at dot `80 + len`):

| ROM | m3 len | mode-0 start | read `cc` | `cc − m0` | we read | live mode |
|---|---|---|---|---|---|---|
| `win0_a` | 179 | 259 | 257 | −2 | 3 | 3 |
| `ppu_sprite0_scx1_a` | 173 | 253 | 253 | 0 | 3 | 3 |
| `ppu_sprite0_scx0_a` | 172 | 252 | 253 | **1** | 3 | **0** |
| `sprite_0_b`, `win0_b`, `ppu_sprite0_scx{3,7}_b` | | | | **2** | **3** | **0** |
| `win{1,7..15}_b`, `sprite_1_b`, `ppu_sprite0_scx{2,6}_b` | | | | 3 | 3 | 0 |
| `win2_b`, `win10_scx3_b`, `ppu_sprite0_scx{1,5}_b` | | | | **4** | **3** | **0** |

Two results, of different strength:

- **Hardware samples at exactly `cc − 2`, and this is tight on both sides.**
  `ppu_sprite0_scx0_a` at `cc − m0 = 1` expects mode **3**, while `sprite_0_b` and
  `win0_b` at `cc − m0 = 2` expect mode **0**. Different ROMs pin each side, so
  this is bracketed, not fitted.
- **dingbat samples no earlier than `cc − 5` — a lower bound, not an exact
  figure.** Every one of the 21 reads mode 3, and the largest `cc − m0` the family
  offers is 4. Nothing here contains a case at `cc − m0 = 5`, so "a uniform 3 dots"
  is **not** established by this family; what is established is **at least 3**.

The actionable part is smaller and firmer than the headline. At the shipping
`STAT_READ_LAG = 3` the nominal sample dot is `cc − 4`, so at `cc − m0 = 4`
the model says we should already read mode 0 — **and we read 3**. One dot is
therefore unaccounted for between `stat_read_mode`'s nominal sample point and the
mode-0 latch, independently of whatever `L` is set to. That stray dot is a
separate defect from the documented `L ≤ 2` vs `L = 3` trade, and it is the piece
worth chasing first, because it does not have to pay that trade's cost.

Note also that **`live` is already 0 in every failing row**: the PPU's own mode-0
transition happens on the right dot and only the CPU-visible latch is late. That
is independent confirmation, from a second direction, that this bucket is not a
mode-3-length bug — the same conclusion `M3_END_EARLY`'s table reached.

## The ranked table

Effort is rough calendar effort for someone who knows the file. Perf follows the
taxonomy above. "Net" is the measured whole-suite delta of the *naive*
implementation where one was built — several buckets are large but currently
net-negative, and that distinction is the whole point of the ranking.

### Tier 1 — cheap, unblocked, measured

| # | bucket | rows | instrument | effort | perf | net if built |
|---|---|---|---|---|---|---|
| **0** | **`LY0-RESYNC` — line 0's pixel pipeline runs one M-cycle ahead.** 125 png rows fail on **scanline 0 only**, with lines 1–143 pixel-exact | **125** (`scy` 55, `bgtilemap` 28, `bgtiledata` 24, `scx_during_m3` 17, `bgen` 1) | **boundary column, and an unusually sharp one**: a per-scanline PNG differ | small | **cold** — not in the dot loop | **+119 / −7**, shipped as `LY0_PIPE_MCYCLES` (gambatte 3658 → 3770) |
| **1** | **`$FEA0-$FEFF` is real RAM on CGB** — dingbat answers `$00` for every model; the ROMs seed the region with a `PUSH` and read it back | **26** (`oamdma` `busypushFEA1`/`busypushFF01`) | the ROM itself | ~5 lines + a savestate field (payload revision bump) | cold | **+26 / −0**, shipped 2026-08-10 (see that section; the savestate field is deferred to the batched bump, not taken) |
| **2** | **HDMA source outside cartridge/WRAM moves `$FF`** | **4** (`dma`) | `dma_hiram_read_result` reports the *value* | done | cold | **+4 / −0**, shipped as `a7b6355` |
| **3** | ~~**STAT edge-detector re-trigger**~~ **— not the edge detector; the interrupt DISPATCH's IF clear.** The level-OR and its rising-edge detector were already right. What was wrong is that the dispatch cleared IF at T = 0 and then charged all 20 T-cycles, so any source that rose inside the 5 M-cycles survived. The clear belongs at **T = 16**, the start of the fifth M-cycle | **28** (`irq_precedence` 6, `m1` 6, `ly0` 6, `m2int_m2irq` 3, `lyc153int_m2irq` 3, `tima` 4) | pairs, ±1 M-cycle | small | cold | **built** as `IRQ_SAMPLE_T` in `gb/cpu.nim`: **+16 / −1**, a strict local maximum (12 → +1/−0, 20 → +27/−14). Recovers `m2int_m2irq`, `tima`, `irq_precedence`, `serial` and the `_ds` arms of `ly0`/`lyc153int_m2irq`/`m1`. **Does NOT recover the nine single-speed `ly0` rows** — see below |
| **4** | ~~**STAT source enabled by an `$FF41` write while already high**~~ **— not the write; the LY=LYC comparator's blind window on the SOURCE.** A line boundary moves LY and the mode at once, and one evaluation cannot see a source hand the line to another. The comparator drops before LY moves and answers again after the mode has — the read path's own `LY_JUST_CHANGED` rule, which the interrupt line never had | **8** (`lcdirq_precedence`, the whole family) | pass/fail only | small | cold | **built** as `ly_advance_close` / `GbPpu.ly_changing`: **+20 / −1** on top of bucket 3 (6 of the 8 `lcdirq_precedence` rows, plus 12 `miscmstatirq` and 3 `lycEnable`). The other 2 need the window at the line-144 entry, which is blocked on bucket 18 |
| **5** | **DMG CH3 wave-RAM access rule** — CGB already correct; the documented "wave RAM is only accessible on the dot CH3 reads it" gap | **8** (`sound`, DMG only) | famflip: `exp=FF,FF,FF,FF got=10,32,32,54` | small | cold (APU) | not built |

Tier 1 is **199 rows** for work that is individually small, individually
self-contained, and blocked on nothing.

**Buckets 3 and 4 were built together, 2026-08-09, and both were misnamed.**
Neither is what its row above originally said, and the correction is the useful
part.

Bucket 3 is not the STAT edge detector. `*_late_retrigger` appears under five
STAT sources *and* under the timer, and the timer has no edge detector at all,
so the quantity has to be in the part they share: the dispatch. Each ROM's
handler re-requests its own interrupt with an `LDH ($0F),A` that moves by one
M-cycle per family member, `EI`s, and reads IF back inside the second dispatch.
`m2int_m2irq_late_retrigger_{1,2}` reads the answer out directly — the STAT
source rises on the same dot either way, only the dispatch moves, and hardware
keeps the bit when the dispatch starts 19 T before the rise and loses it at 15 —
so the clear is at T = 16, the fifth M-cycle. Pan Docs' "Interrupt Handling"
describes that M-cycle as the one that sets PC to the handler.

Bucket 4 is not "an `$FF41` write while the condition is already high". The
failing ROMs' `$FF41` write is ~200 M-cycles ahead of the IF read it is scored
on, and the edge hardware produces is at the LY advance in between. The whole
`lcdirq_precedence` family is a bracket on the ORDER of the line boundary's two
input changes, and four of its ROMs pin it against each other:
`lycirq_ly44_lcdstat48` (LYC + mode 0) wants a dip, its `_lcdstat68` twin (the
same, plus mode 2) wants none, `m1irq_lcdstat50_lyc8f` (LYC + mode 1) wants one
and `m1irq_lcdstat18` (mode 1 + mode 0, no LYC) wants none. One rule fits all
four and no other does: **the LY=LYC comparator answers nothing while LY is
changing** — it lets go before LY moves and comes back only after the mode has
moved with it. That is the read path's rule (`LY_JUST_CHANGED` in `ppu_read`,
mooneye `lcdon_timing-GS`) applied to the interrupt SOURCE, which never had it,
and it is the same sentence `LYC_SETTLE_DOTS` already writes for the 153 → 0
snapback: "an LY change like any other".

Two riders came out of the same measurement and are worth keeping:

* **The OAM source rises with the LINE, not with the mode.** `m2enable/
  enable_after_lycint_1` hands a LYC match over to the next line's OAM pulse and
  wants NO interrupt, while `m1irq_lcdstat50_lyc8f` hands the same match over to
  mode 1 and wants one. So mode 2's arrival is inside the blind window and mode
  1's is after it — which is the reading `m2_source` in `gb/ppu.nim` already
  argues on independent grounds ("tied to a line starting, not to a mode").
* **A CPU write parked for this M-cycle takes the window's place.** gambatte's
  `lycEnable/ff45_enable_weirdpoint` is named for the notch it measures: writing
  LYC = LY+1 one M-cycle apart across the advance gives an interrupt on either
  side and none at the step that lands on the boundary. `stat_write_pending`
  already gives that write its own instant at the M-cycle boundary; running the
  comparator's glitch as well counts one input change twice.

**What is still open, and it is the correction that matters most.** The ten
gambatte rows `ab0d7d6` traded for the snapback are recorded there as "the known
STAT edge-detector re-trigger bucket, which used to cancel against this dot".
That attribution is now measured and is **wrong for nine of the ten**. Bucket 3
at its pinned T = 16 recovers exactly one of them
(`lycint152_lyc153irq_late_retrigger_ds_2`). The remaining nine are all `ly0`
`lyc0irq_ifw` / `lyc0irq_late_retrigger` / `lyc153irq_late_retrigger`, and they
need the LYC = 0 relatch to land *before* a CPU store that commits in the same
M-cycle. `daid/ppu_scanline_bgp` independently pins that relatch INTO M-cycle
[9..12] of line 153 (it is pixel-exact at `LYC_SETTLE_DOTS` = 4 and 6 and wrong
at 2 and 8, i.e. the pin is at M-cycle granularity), and `mem_write` commits a
CPU byte at the top of its M-cycle. So the third quantity these rows are waiting
on is the IF store's commit point against a PPU edge inside the same M-cycle —
already measured and refused as a whole-register move (`mem_flush_deferred`:
deferring IF costs 18 rows to buy 1), which means it needs a rule finer than
"early or late", not a knob. **They are not bucket 3, and no setting of
`IRQ_SAMPLE_T` reaches them**: at 20 the `_1` arm of every other retrigger
family goes red.

**Bucket 0 deserves its own paragraph**, because it is the largest actionable
finding in this triage and it was hiding behind a whole-frame percentage. Every
one of these rows was being read as a mid-scanline pipeline failure; a
per-scanline differ shows lines 1–143 are **pixel-exact** and only LY=0 differs —
55 of the 58 `scy` failures are exactly **8 differing pixels at y=0**. Verified
here independently on the whole `scy` family: 55 rows LY=0-only, 3 rows all-lines.
The verdict is identical at 14, 15 and 16 frames, so it is not a frame-latch
artefact. `-d:gb_m3_trace` shows the ROM writing SCY at dots 85 and 241 of *every*
line including LY=0, at exact 456-dot cadence, and the reference puts hardware's
LY=0 sample **one CPU M-cycle earlier than ours** while every later line agrees.
So this is not a mode-3 bug at all — it is the vblank → LY=0 re-sync — and the
fix is in cold code.

**Built and shipped, 2026-08-09, as `LY0_PIPE_MCYCLES` in `gb/fifo_ppu.nim`.**
The falsifier held exactly: one change takes all five families
(`bgen` 1/1, `bgtiledata` 24/24, `bgtilemap` 26/28, `scy` 52/55,
`scx_during_m3` +13/−7) and, over all 5,005 rows dumped as frames and compared
scanline by scanline against the same tree with the term at 0, **the only
scanline that moves anywhere is y = 0**. gambatte 3658 → 3770, runner 704 → 712,
mealybug DMG +110 pixels with `m3_window_timing_wx_0` going 4 → **0** exactly as
this bucket's framing predicted, CGB +520 with five more rows pixel-exact. Cost:
7 `scx_during_m3` rows whose SCX write lands inside the four dots at the head of
mode 3 that this moves. Retired instructions −0.04% with `cycles=` identical.

Two readings of the same 4 dots were built first and **both are falsified**, and
that is the useful part of the result — every STAT-visible edge on line 0 is
already where hardware puts it:

* **"Line 0's mode 2 STAT interrupt is one M-cycle late."** Scores the same five
  families (gambatte 3658 → 3762) and is refused from three directions.
  mooneye `acceptance/ppu/intr_1_2_timing-GS` (and wilbertpol's copy) counts
  `inc b` from the line-144 mode 1 STAT interrupt to the line-0 mode 2 one and
  wants 20 then 21; moving the pulse makes it 21/22, and that ROM is verified on
  DMG/MGB/SGB/SGB2. gambatte `m2enable/late_enable_ly0_{1,2}` and eight siblings
  enable the source one M-cycle apart across the top of line 0 and bracket the
  pulse's own window where it already is; `lcdirq_precedence/m2irq_ly00_lcdstat30`
  and `lyc153int_m2irq_ifw_2` bracket the same edge from the vblank side. A
  variant that skews the pulse by ONE DOT rather than one M-cycle survives the
  m2enable bracket and scores +111, but `intr_1_2_timing-GS` refuses it too.
* **"Line 0's mode 2 is four dots short."** Mode 3's flag and the pipeline both
  start at dot 76 (gambatte 3658 → 3714), which drags the mode 3 → 0 flag with
  them: `m0enable` −18, `vramw_m3end` −8, `lcd_offset` −7, `enable_display` −7,
  `m0int_m3stat` −2. `ly0/lycint152_m2stat_1` separately refuses the mode 2 → 3
  edge moving on its own, and mooneye-wilbertpol's `ly00_mode2_3` /
  `ly00_mode3_0` are green today.

So the residual is not in any flag or any source: it is the phase at which the
pipeline samples the registers, which is the per-line version of
`M3_PIPE_MCYCLES` and is spelled in the same units. gambatte's `_ds` rows are
what pin the units — the same five families want 2 dots in double speed, not 4,
and a fixed 4 costs 14 `_ds` rows that one M-cycle keeps.

The open question this leaves is the 7 traded rows. `scx_during_m3_spx0/1/2` and
four siblings write SCX from the first instruction of the mode 2 handler, so
their write lands in the four dots between the mode 3 flag and where the
pipeline's first fetch used to sample the fine scroll. They say line 0's
fine-scroll latch does NOT move with the pipeline; 13 rows in the same family
say the rest of it does. Whether the latch is a flag-time event is the next
thing to settle here, and `tools/gbppu` has no instrument for it yet.

### The mode-3 pipeline pool, by bucket

Beyond bucket 0, the pipeline pool's 555 rows resolve as: `M3-EDGE-BANDS` 72 (all
144 lines but only `x ≤ 31` / `x ≥ 133`, hot), `WY-LATCH device delta` 51 (cold),
`OBJ-MODE0-EDGE` 45, `LOCK-EDGES` 46, `FINE-SCROLL-MIDLINE` 42 (hot), `WX166-TAIL`
37 (blocked on STAT), `WIN-FETCH-ABORT` 29 (hot, blocked), ~~`OBJ-LATE-SIZECHANGE`
24~~ (**SHIPPED 2026-08-13, all 24; and it was never a mode-3 row at all — see
item 5 of the ranked remainder**), `top ≤16 lines` 22, `window/on_screen` 18, `CGBPAL-M3END` 18 (a missing
mechanism, not a phase), `BGP-SHIFTER-PHASE` 15 + mealybug (hot — **and it must
not be fixed by raising the pipeline lead**), `OBJ-LATE-DISABLE` 11
(unimplemented), `m0enable` 14, the SCX-residue rows 12, and `WIN-REACT-WX6` 1 ROM
(`m3_wx_6_change` at 40.1% with two siblings at 100%, and `reactsweep.sh` already
exists for it).

### Tier 2 — one constant or one rule, with a sweep harness already written

| # | bucket | rows | instrument | effort | perf | blocked on |
|---|---|---|---|---|---|---|
| 6 | **GDMA/HDMA block duration one M-cycle short** — famflip is *uniform* `exp=3,0 got=3,3` across every SCX and both speeds, which is what says it is the DMA's duration and not the mode-3 edge | **21** (`gdma_cycles*` 14, `gdma_weird` 1, `hdma_cycles*` 6) | famflip, uniform | 1 constant + sweep (`tools/gbdiff/gdma_sweep.sh` exists) | cold | — |
| 7 | **Serial transfer-complete IF one M-cycle early** | **28** (`serial`) | famflip `exp=E0,E8 got=E8,E8`, both devices, both speeds | small | cold | — |
| 8 | **CGB APU frame-sequencer/DIV-APU tap one step early** — every row is `dmg PASS / cgb FAIL` | **39** (`sound` 25, `speedchange` `ch2_nr52` 14) | famflip, per-device | small | cold | — |
| | *(the `ch2_nr52` half, 2026-08-13: **not** the stall length and **not** the PPU phase. Swept `SPEED_SWITCH_STALL_CPU`, every `_1a`/`_2a` wants ≤ 131075 and every `_2b` wants ≥ 131076 — two-sided and empty. It is the tap's phase across the switch)* | | | | | |
| 9 | ~~**HDMA start one M-cycle early**~~ — **done 2026-08-13, +6 / −0.** Not the block's start (that reading scores −5) and not an M-cycle: the transferred BYTES appear 4 dots late, `HDMA_VISIBLE_DOTS`. The 7th row is the SCX residual, bucket 15 | **7** (`hdma_start*`) | famflip `exp=0,1 got=1,1`, then `-d:gb_dma_trace` VRAMRD-vs-HDMABLOCK dots | small | cold (+0.13%) | — |
| 10 | **`FF55` / HDMA1-4 latch phase** — `ppu_write_machinery`'s M-cycle boundary rule | **11** (`hdma_late_enable/disable` 8, `destl`/`length`/`wrambank` 3) | famflip | small | cold | — |
| 11 | **Serial restart / `trigger_int8` ordering** — different shape from #7, do not fold | **6** | famflip, opposite direction | small | cold | #7 |

### Tier 3 — real mechanism, needs a model rather than a number

| # | bucket | rows | why it is not cheap |
|---|---|---|---|
| 12 | **HDMA block owed to a CPU that is off the bus** (halted, or stalled by a speed switch) | **61** (`dma` 30 + speed-switch 31) | The rule — a CPU off the bus stalls the block — is already in the tree for HALT (`eb75393`) and is right *in kind*. Built for the speed-switch half: **+11 / −10**. It fixes every `_1` family member and breaks every `_2`/`_3`, because hardware still delivers the **one block already owed** at the instant of the STOP. That last block's phase is set by the mode-0 edge, i.e. bucket 15. **Retry this after bucket 13's pair lands** (2026-08-13, second section): the owed block's phase is measured against a PPU that was 4 to 13 dots out of place across every switch in these ROMs' preambles |
| 13 | ~~**PPU dot phase coming out of a speed switch**~~ | **55** (`speedchange*_ly44_m3_*m3stat*`), all 55 green in the derived build | **DERIVED 2026-08-13, and it ships OFF** — see the 2026-08-13 (second) section. It is **two** constants, not one: the PPU comes out of a switch **8** dots ahead of the CPU clock into double speed and **3** back into single, and the shipped 12 is the 8 with `CGB_HALT_PPU_LEAD`'s halt-exit M-cycle folded in. The instrument is the family read as a **ladder in switch count** (rung N measures A, A+B, 2A+B, 2A+2B, 3A+2B; measured 8, 11, 19, 22, 30, differences +3/+8/+3/+8). `SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE` in `gb/memory.nim`; both defaults are tied to `CGB_HALT_PPU_LEAD`, so the bucket lands the day bucket 22 does, with no further edit |
| 14 | ~~**OAM STAT source rises one M-cycle late**~~ — and *only* that source | **+228 / −114 gambatte, +8 / −4 GBMicrotest, runner 765 → 773** | **MEASURED AND DERIVED 2026-08-09, and it ships OFF** — `STAT_M2_LEAD` + `M3_PIPE_AHEAD`, both `intdefine`s at 0, derivation at `STAT_M2_LEAD` in `gb/ppu.nim`. The source rises **one CPU M-cycle** (not a fixed dot count: the 75-row `_ds_`-only delta is the proof) before the line whose OAM scan it belongs to, on every line except line 0, whose predecessor is vblank. The cancellation this bucket named is real and is resolved: moving the dispatch alone costs `scy` 67/67 → 0/67, and one M-cycle of `M3_PIPE_AHEAD` gives **every** one of those pixel rows back, `scx_during_m3` and `bgtiledata` and `bgtilemap` included, with `LY0_PIPE_MCYCLES` going to 0 because line 0's four dots ARE this lead. Two-sided on both axes; GBMicrotest pins the lead alone (429 / 433 / 425 at 0 / 1 / 2). **What blocks it is a different bucket:** all 17 rows it costs are ROMs that wait with `EI; HALT`, and the twelve wilbertpol `*_timing_nops` rows — the same measurements with the halt replaced by a sled — are among the rows it *wins*. See bucket 15's halt rows. **The halt quantity is measured 2026-08-09** — `HALT_IF_SAMPLE_T` in `gb/cpu.nim`, the T-cycle of the M-cycle a halted CPU latches the interrupt line on, which is the MIDPOINT where a running CPU's is the end. With it, this bucket lands: runner **765 → 786**, gambatte 3972, GBMicrotest 439, fifteen of the seventeen back including all five mooneye `intr_2_*` and their wilbertpol copies. The pair is still off, on ONE row the latch costs by itself — `mooneye acceptance/ppu/hblank_ly_scx_timing-GS`, bucket 24 below |
| 15 | ~~**The sub-M-cycle error at the mode 3 → 0 edge**~~ | **≥ 21 GBMicrotest + the `NspritesPrLine` family + 20 `halt` + ~13 SCX-residue rows** | **The readback half is CLOSED 2026-08-09** — see the section above. The unexplained dot was the `read_mode` latch being taken one dot before the M-cycle's first, so `STAT_READ_LAG`'s documented meaning and its implementation disagreed by a dot and the `4D + L = 4` grid was solved a dot out. The sample point is `cc − 2` at normal speed and `cc − 3` in double, bracketed both sides at both speeds by ROMs that take no interrupt. Runner 743 → 765, GBMicrotest 404 → 430, mooneye acceptance 66/66, gambatte 3856 → 3818 with all 102 traded rows owned by bucket 14. Still open here: the SCX-residue rows. **The 20 `halt` rows are CLOSED 2026-08-09** by `HALT_IF_SAMPLE_T` (bucket 14): gambatte `halt` 124 → 136 in the composed build, and GBMicrotest's `int_hblank_halt_scx0/3/4/7` — the four SCX steps whose mode-0 edge lands in the M-cycle's second half — go green with the latch alone |
| 16 | **CGB `$D000` window aliases `$C000`** | **64** (`oamdma`) | Forcing `$D000-$DFFF → wram[0]` measures **+64 / −2**, and the −2 are exactly the two ROMs that pin banking. But the ROMs' shared prologue writes `SVBK = 2`, so the 64 expectations assert that bank 2 *is* bank 0 — which contradicts the two banking ROMs. **Declined pending hardware**: dump WRAM on a real CGB-C after `LDH ($70),$02`; if `$CFFF ≠ $DFFF` these rows are permanently unreachable |
| 17 | **LCD-on / boot dot phase** | **75** (`enable_display` 49, `lcd_offset` 22, `display_startstate` 4) | Already written up at `LCD_ON_HEAD_START` / `CGB_BOOT_PHASE`; `lcd_offset` is 100% CGB-only |
| 18 | **Mode-1 / vblank STAT source values** | **42** (`m1`) | A *value* question (`exp=0,3 got=1,1`), not a phase one: whether the mode-1 STAT source asserts at all on entering vblank, and how it overlaps the vblank IF bit. Untouched by every STAT phase experiment run |
| 19 | ~~**OAM-DMA start off-by-one whose sign flips with speed**~~ — it is not the DMA's start at all, it is the **mode-2 OAM scan against the transfer**, and the clock crossing is real | **27** | **DERIVED 2026-08-13, +16 / −0 gambatte, and it ships OFF** (`OAM_SCAN_DMA_LOCK` in `gb/fifo_ppu.nim`). The start-latency reading is **falsified**: sweeping `CGB_OAM_DMA_START_T` from 4 T to 40 T moves the whole `late_sp*` set by exactly **zero** rows while moving the rest of `oamdma` by hundreds (771 → 426 / 408 / 174). What the families actually measure is the scan reading OAM entry `n` on dot `2n` of mode 2 while an OAM DMA holds OAM — the `x` half steps the transfer's START across that entry's dot, the `y` half steps its END across the same dot, and both halves land on `2n` to two dots. The single thing still wrong is the lock's DURATION: `strikethrough` (23040 → 23033 on both devices) draws entry 39 on a line whose whole mode 2 is inside a transfer. Full account in the 2026-08-13 section |
| 20 | ~~**Line-153 LY vs the LYC comparator**~~ | **21** (`ly0`) | ~~Readable LY and the comparator's copy need separate line-153 phases.~~ **Closed 2026-08-09** — and the reading above was right in kind and wrong in scale. The comparator's copy of LY did not need a *phase*: the snapback ran no edge detector at all, so the LYC=0 STAT interrupt fired at the top of line 0 (451 dots late) and a LYC=153 match was never taken back down. Restoring the edge plus the read path's own one-M-cycle blind window (`LYC_SETTLE_DOTS` in `gb/ppu.nim`) takes `ly0` 66 → 74, `lycEnable` 172 → 179, `lycm2int` 8 → 10, the whole GBMicrotest `line_153_*` set to 23/24, and `daid/ppu_scanline_bgp-dmg` from 68.8% to **pixel-exact**. Still **not** the snapback dot, which stays where it was |
| 21 | `lycEnable` residual (49), `m2enable` CGB-vs-DMG window (12), misc `oamdma` singletons (14) | **75** | Not one quantity each; need their own pass |

### Contested / handed between pools

`halt`'s 34 rows split: **14** are the CGB-only halt-exit M-cycle (bucket 22
below), **15** are claimed by bucket 14, **20** by bucket 15 — the sum exceeds 34
because the buckets overlap on the same rows and cannot be separated until one of
them lands. `m0enable`'s 14 rows are **not** a STAT bucket (0 rows moved by any
STAT experiment) and belong to `ppu_write_machinery`'s mem-write boundary.

**Bucket 22 — HALT exit costs one M-cycle more, on CGB only (14 rows).** DMG halt
exit is *correct*: 13 GBMicrotest ROMs pin it (`int_lyc_halt`, `int_oam_halt`,
`int_timer_halt`, `int_vblank1_halt`, `lyc_int_halt_a`, …) and famflip's DMG
column matches exactly on `halt/m1int_ly`, `lycirq_m2stat` and
`m0int_m0stat_scx3/scx4`. CGB is one M-cycle short — the already-documented "CGB
termination M-cycle". Blocked on bucket 23.

**Re-read that "DMG halt exit is correct" against `HALT_IF_SAMPLE_T`
(2026-08-09).** It is correct only in the sense those 13 ROMs can express: every
one of them waits on a source that rises in the FIRST half of its M-cycle (LYC,
vblank, the timer), where a halted CPU and a running one do agree. The eight
`int_hblank_*_scx*` pairs walk the mode-0 edge across the other half and say the
DMG halt is one M-cycle later than the DMG sled on four of the eight — so the
DMG exit is not "correct", it is *unmeasured by those 13*, and the CGB delta
this bucket is about has to be re-derived on top of the latch rather than
against a DMG zero that four other ROMs refuse.

**Bucket 24 — the mode-0 edge to LY-advance distance, as a halt-woken handler
sees it (2 mooneye acceptance rows, and it is what blocks 14).** `mooneye
acceptance/ppu/hblank_ly_scx_timing-GS` and wilbertpol's copy are the only rows
`HALT_IF_SAMPLE_T = 2` costs on its own, and they are a direct contradiction
with `gbmicrotest/int_hblank_halt_scx0`: same source, same SCX, same device.
GBMicrotest reads TIMA out of the handler and so times the dispatch against the
timer, and says halt is one M-cycle after sled. mooneye reads LY out of the
handler twice, one M-cycle apart, and so times it against the LY advance — and
puts the halt-woken read on the near side of a boundary that the extra M-cycle
crosses. Both endpoints of mooneye's span are separately pinned against TIMA and
both are green (`int_hblank_nops_scx0`; `poweron_ly_*`, `lcdon_to_ly*`,
`line_153_ly_*`), so the arithmetic says they should agree. The family already
shows the error from the other side: the sled sibling
`hblank_ly_scx_timing_nops` is **red on main**, at either latch. A read-side lag
is FALSIFIED — giving `$FF44` the sample point `STAT_READ_LAG` gives the mode
bits does not fix the mooneye row and takes seven GBMicrotest LY rows with it.

**Bucket 23 — timer IRQ visibility (16 `tima` rows, and it gates 22).** This is
the bucket whose received description is most wrong, so it is worth stating
precisely what survives.

## Six things proved *not* to be what they were thought to be

These are the most valuable results here, because each one closes a line of work.

1. **"HALT exit costs one M-cycle more, worth ~+25 gambatte plus GBMicrotest
   `int_hblank_halt_*`" — not reproducible on this tree.** Built and scored: the
   universal version is gambatte **net −102** (`halt` −16, `tima` −84) and
   GBMicrotest **403 → 390**, including **13 ROMs that currently pin the DMG
   halt-exit cost as correct** going PASS → FAIL. The CGB-only version is net −40.
   And `int_hblank_halt_scx0..7` is **not a halt row at all** — it is a pure SCX
   parity swap, 4/8 green either way, i.e. bucket 15.
2. **The "84 `tima` rows" compensating error is real but is not a timer-IRQ
   offset.** The 84 (and 42 CGB-only) reproduce exactly, but *both* directions
   were built and both are worse: IRQ one M-cycle later gives `tima` −92; IRQ at
   the overflow instant gives −38. **There is no pair of (halt-exit cost,
   timer-IRQ time) that recovers them**, so the joint fix is not derivable as
   stated. The untested third term is when `mem_tick_components` runs relative to
   the CPU's bus action, which `e823f9e` moved to the start of the M-cycle.
   **2026-08-09: that third term is the whole of the 84, and it is now measured.**
   The timer IRQ lands on T 3 of its M-cycle in this tree, and with
   `HALT_IF_SAMPLE_T = 2` and nothing else, `tima` goes 218 → **134** — the same
   84 rows, produced on demand. Running the M-cycle's bus half whole in front of
   the latch (i.e. treating the timer IRQ as a HEAD source, which is what
   `int_timer_halt`, `int_timer_halt_div_a` and `int_timer_halt_div_b` say)
   gives all 84 back. The 84 are not a timer-IRQ *offset* and not a halt cost;
   they are which half of the M-cycle the timer IRQ is in.
3. **The 90 CGB `oamdma` `busypush`/`busypop` failures are not an OAM-DMA
   arbitration bug, not `DriveZero`, and not the SVBK 0→1 rule.** They are 26
   `$FEA0` rows plus 64 WRAM-window rows. The decisive evidence is a ROM
   byte-patch: changing the seed `LD ($CFFF),A` to `LD ($DFFF),A` and nothing else
   makes stock `dingbat_test` print the expected `657655AA` and **pass**. The `00`
   that looked like `DriveZero` is simply an unwritten WRAM cell. The perfect DMG
   column (312/312) says the same from the other side.
4. **`gambatte/sprites` is not the STAT-read lag.** `tools/gbppu/README.md` says
   its residual failures are `STAT_READ_LAG`; measured, `sprites` sits at a strict
   local maximum at the shipping value — **393 at L=3, 354 at L=2, 245 at L=4** —
   so no value of L helps any of its 83 rows. `vram_m3` (35→35) and `oam_access`
   (52→52) do not move by a single row under L either. That file is worth
   correcting.
5. **`dma_hiram_read` and friends were not an unknowable "Pan Docs says garbage"
   fit.** The suite ships a fourth ROM that reports the *value*. Fixed.
6. **Double speed is not a bucket** (30.4% vs 27.2% fail rate), and **the mode-3
   *length* is not the error behind the `NspritesPrLine` family** — the per-object
   cost is exactly Pan Docs' 11 dots, measured.

Two smaller ones: **`ly0` is not the line-153 snapback dot** (parameterised and
built: 3614 → 3606), and **`m0enable` is not a STAT bucket** (0 rows moved by any
STAT experiment; 7 CGB-ok/DMG-bad against 4 DMG-ok/CGB-bad with zero both-fail).
`m0enable` is in fact **two quantities**: every single-speed failure is a
one-M-cycle DMG/CGB split where dingbat models **zero** split, with some rows
landing on the CGB side, some on the DMG side and one between. That is why every
`CGB_*_LATENCY` sweep nets ≤ 0 on it — a uniform CGB latency reaches only the
four `ff45` rows. It retires a whole class of attempted fix.

7. **`window/arg/late_wy_*` is not "decided a whole frame earlier".** The note at
   `CGB_*_LATENCY` said the two devices diverge a frame back, in how long the
   ROM's vblank wait takes. Measured: **13 of the 14 late_wy families scored on
   both devices have *different expected values per device*, all shifted the same
   way by one M-cycle** (`late_wy_FFto2_ly2` is `dmg exp=3,3,0` against
   `cgb exp=3,0,0`). Hardware genuinely differs; there is no frame-level mystery
   to explain first. dingbat answers the **same** value on both devices in 11 of
   the 14 — it models no device difference at all — which is the actual defect,
   worth ~26 rows. Note the sign before reaching for a constant: CGB flips
   *earlier*, so CGB samples WY **sooner**, and every constant in that block is a
   positive delay that moves CGB the wrong way. That, not a missing instrument, is
   why "WY / WY latch: nothing at all" appears against every setting in the sweep
   table. Corrected in place.

8. **`M3_PIPE_DELAY`'s documented cost was overstated.** The note claimed the
   shipping value of 2 costs `scx_during_m3` 34 → 31 and `bgtilemap` 4 → 2, and
   that the real fix is a bus-layer change. Re-measured, 2 vs 0 is **3618 vs
   3596**: it *buys* `window` +19, `scy` +6, `bgtiledata` +1, `m0enable` +2 and
   costs only `bgtilemap` −2 and `sprites` −4. **`scx_during_m3` does not move by
   a single row** (31/141 at both settings), and the write-side half of the
   bus-layer fix already landed, so there is no such change left to make.
   Corrected in place.

## Is the mode-3-edge error the same quantity as the mode-0 STAT lateness?

This was the explicit question, because the two keep surfacing under unrelated
investigations. **Answer: mostly yes — and the part that is not is a different
axis that has been miscategorised for a long time.**

With `STAT_READ_LAG` excluded (a strict local maximum) and the OBJ penalty
excluded (exactly Pan Docs' 11 dots per object, measured), the residual behind
`NspritesPrLine` is a constant sub-M-cycle error in the mode 3 → 0 edge **as the
CPU reads it back**. That is the same thing the 21 `0x83`-vs-`0x80` rows measure,
and my dot-level trace says the PPU's own edge is on the right dot (`live` is
already 0 in every one) — so there is only one defect, in the readback, not two.

The decisive test is which ROMs demand the 2 dots. I scanned every ROM in both
groups for a `$FF41` read (`F0 41` / `FA 41 FF`):

| group | reads `$FF41` | does not |
|---|---|---|
| **wants** the 2 dots (`ppu_sprite0_scx*_b`, `win*_b`, `sprite_{0,1}_b`, `sprite4_*_b`, `hblank_int_scx*`) | **30** | 8 |
| **refuses** them (`int_hblank_{nops,incs,halt}_scx*`, `win{0_scx3,5,6}_a`) | 3 | **24** |

54 of 65 fall exactly where the "it is a STAT-readback error" hypothesis predicts.
And the 11 exceptions are not noise — they split cleanly, and each side explains
itself:

- The **3 refusers that do read STAT** are all `_a` siblings. They are the *upper*
  bracket: `_a` and `_b` differ by one NOP, hardware reads 3 then 0, and we read 3
  for both. They refuse a 2-dot *edge* move because an edge move shifts both
  members together. That is precisely why the lever has to be the **sample point**,
  not the edge — and it is consistent, not contradictory.
- The **8 wanters that do not read STAT** are `hblank_int_scx0..7`, and they are
  the real second quantity. They differ from the 24 refusers (`int_hblank_*`) in
  exactly one way, already documented at `LCD_ON_LINE0_TRIM`: they enable the LCD
  and then burn 114 NOPs before enabling the STAT source, so they time **line 1
  after an LCD enable**, where `int_hblank_*` time the steady state from the boot
  hand-off.

**So the "2 dots at the mode 3 → 0 edge" is two quantities, and they should stop
being chased as one:**

1. **A STAT-readback lateness of at least 3 dots** — hardware samples mode 0 at
   `cc − 2` (bracketed both sides), we sample no earlier than `cc − 5`, and one of
   those dots is unexplained even at the shipping `L = 3`. This is the one that
   `M3_END_EARLY` and `LCD_ON_HEAD_START` were wrongly asked to supply, which is
   why both were refused by ROMs that never read STAT.
2. **A line-0/line-1 phase error after an LCD enable**, carried by 8 ROMs and
   refused by 24 — which is exactly the axis `LCD_ON_LINE0_TRIM=2` +
   `LCD_ON_LINE1_TRIM=-2` fits at +33/−5. That fit is still not derivable and
   should still not be shipped, but it is now clear it is answering a *real and
   separate* question rather than being an artefact of the first one.

That separation is the most useful structural result in this document: it says
the next attempt should move the **STAT sample point** and leave every mode-3
length and boot-phase constant alone, and it predicts that doing so will not
disturb the non-STAT-reading families that have refused every previous attempt.

## Top three recommendations

### 1. `LY0-RESYNC` first — 125 rows, cold path, nothing blocked

It is the largest actionable bucket in the triage by a factor of four, it is not
where anyone was looking (every one of these rows was filed as a mid-scanline
pipeline failure), and its instrument is the sharpest available: a per-scanline
differ over rows that ship reference PNGs, showing lines 1–143 pixel-exact and
only LY=0 wrong. The fix is in the vblank → LY=0 re-sync, which is cold code, so
it cannot cost performance. Do this before touching anything in the dot loop.

The falsifier is cheap and should be run first: if the LY=0 sample really is one
M-cycle late, then a build that moves it must take all five families together
(`scy`, `bgtilemap`, `bgtiledata`, `scx_during_m3`, `bgen`) and must leave lines
1–143 byte-identical. If it moves only some of them, the 125 rows are not one
bucket.

### 2. Take the rest of Tier 1 — 74 more rows, five independent changes

Every one is small, cold-path, self-contained, and either already measured
(`$FEA0`: **+26/−0**, shipped 2026-08-10; HDMA source: **+4/−0**, shipped) or backed by a rule the
suite states uniformly (the `*_late_retrigger` family fails on *every* STAT source
*and* the timer, which is one rule rather than five). None touches the mode-3 dot
loop or the CPU dispatch, so none of them can cost performance, and none has to
wait for the two hard unknowns to be settled. This is the only tier where "rows
recoverable per unit of work" is unambiguously high, and it should be done before
anything in Tier 3 is attempted.

### 3. Move the STAT sample point — and nothing else — for bucket 15

It is the most over-subscribed unknown in the tree: `M3_END_EARLY`,
`LCD_ON_LINE0_TRIM`, `LCD_ON_HEAD_START` and `GDMA_SETUP_MCYCLES` have each been
proposed for it and each refused, and it now also blocks buckets 12, 13, 14 and
22. Two new instruments make it more tractable than at any previous attempt:

- **The dot-level bracket.** Hardware samples mode 0 at exactly `cc − 2`, pinned
  from *both* sides by different ROMs; dingbat samples no earlier than `cc − 5`.
  Crucially, at `cc − m0 = 4` the shipping model predicts we read mode 0 and **we
  read 3** — so at least one dot is unaccounted for independently of `L`. That
  stray dot is the piece to chase first, because unlike the `L ≤ 2` vs `L = 3`
  trade it does not have to pay a known cost.
- **`NspritesPrLine` as a variable-phase ruler.** Each object costs exactly 11
  dots (measured: `len = 172 + 11N`), so the object count *sweeps the mode-0 edge
  across the CPU's 4-dot sampling grid on demand*. No other family in the suite
  lets you move the edge continuously while holding everything else fixed.

The deliverable here is a number with a mechanism behind it, not a constant that
scores well. Four previous agents declined fits at this exact spot and every one
of those calls was later vindicated.

### Bucket 14 is decided, and it hands off to the halt rows

**Done 2026-08-09.** The cancellation came apart exactly as this section predicted
and the OAM dispatch is measured: the source rises **one CPU M-cycle** before the
line whose OAM scan it belongs to. The derivation, both sweeps and the whole
row-by-row account live at `STAT_M2_LEAD` in `gb/ppu.nim`; `M3_PIPE_AHEAD` in
`gb/fifo_ppu.nim` is its second axis. Both are `intdefine`s and **both ship at 0**,
where the mechanism compiles out — the control build reproduces this tree row for
row on all 5,005 gambatte rows and all 513 GBMicrotest ones, and costs 0.00% of
retired instructions on three ROMs.

Three things came out of it that were not known before:

* **It is a CPU M-cycle, not a PPU dot.** A rise at a fixed dot 452 is one
  M-cycle early at normal speed and two in double. Scaling it is worth 75
  gambatte rows against the fixed dot, and **every one of those 75 is a `_ds_`
  row**. Nothing at normal speed can tell the two spellings apart.
* **Line 0 is not in it**, and that is what `LY0_PIPE_MCYCLES` was really
  measuring. Line 0's predecessor is vblank, which scans no OAM; mealybug's
  "line 0 timing is different by 4 cycles" is the same fact read from the other
  end, and it needs no per-line pipeline once the other 143 lines lead.
* **The pipeline's phase is not independently pinned.** Every ROM that measures
  it — gambatte `scy` / `bgtiledata` / `bgtilemap` / `scx_during_m3`, mealybug
  `m3_*` — writes its register out of the mode 2 handler, so what those ~180
  rows measure is the dispatch and the pipeline as ONE quantity. Moving both
  together keeps every one of them.

**What stops it landing is the halt/sled split, which belongs to bucket 15's halt
rows.** All 17 rows the change costs are ROMs that wait for their interrupt with
`EI; HALT` — the five mooneye `intr_2_*` (twice, with wilbertpol's copies), daid
`ppu_scanline_bgp`, both `strikethrough`s, and GBMicrotest's `int_oam_halt` /
`oam_int_halt_b`. Twelve of the rows it *wins* are wilbertpol's
`intr_2_mode0_scx1..8_timing_nops` and `intr_2_mode0_timing_sprites*_nops`: the
same measurements with the halt replaced by a NOP sled. GBMicrotest says why, in
four pairs that differ in nothing else:

| source | `_nops` | `_halt` | where it rises |
|---|---|---|---|
| OAM | `$93` | `$94` | one M-cycle before a line boundary |
| hblank | `$61` | `$62` | at the mode 3 → 0 edge, mid-M-cycle |
| LYC | `$99` | `$99` | on a line boundary |
| vblank | `$42` | `$42` | on a line boundary |

Hardware puts the halt one M-cycle after the sled for exactly the two sources
that do not rise on a line boundary. dingbat ticks the PPU over a whole M-cycle
and then asks for IF, so its halt and its sled agree for all four — which means
**both the old model and the new one are one M-cycle wrong, and they differ only
in which instrument reads them wrong.** The next quantity to derive is where
inside an M-cycle a halted CPU samples IF against where an executing one does;
those four pairs bracket it on both sides, and `int_lyc_halt` / `int_vblank*_halt`
/ `int_timer_halt*` refuse a uniform "halt costs one more M-cycle" outright.

**What I would not do:** re-run the `(D, L)` grid (both solutions are falsified,
and `L = 4` is now refuted by *both* instruments rather than one), re-open the 32
mGBA Timing DMA rows (closed by proof; needs `docs/prefetch-model-rewrite.md`), or
ship `LCD_ON_LINE0_TRIM=2` + `LCD_ON_LINE1_TRIM=-2` on its +33/−5 — nothing
derives it, and a line is 456 dots.

</content>

## The one fix landed in this pass

`a7b6355` — *gb/hdma: a source outside cartridge or WRAM transfers `$FF`, not a
read* (bucket 7 of the original brief; bucket 2 of Tier 1 above).

Pan Docs FF51–FF52 gives the HDMA source as `$0000-$7FF0 or $A000-$DFF0`. Outside
that the block reads nothing and moves the open bus. The **value is measured by
the suite rather than chosen**: `dma_hiram_read_result` GDMAs `$FF80 → $8000`,
then does `LD A,($8007) / SUB $FE` and expects `1`, i.e. the byte that landed is
`$FF`. Its three siblings only assert "destination ≠ source", which is why they
were not sufficient alone. Decided once per block, not per byte — HDMA2 masks the
low nibble, so a block is 16 aligned bytes and cannot straddle a region boundary.

| gate | result |
|---|---|
| gambatte `dma` | **120/229 → 124/229**, +4 / −0 |
| whole gambatte suite | 3614 → **3618**, no other subdirectory moved |
| full runner | **exit 0**; `tests/results.md` diff is one line (`gambatte/dma`), no suite or subdirectory down |
| `tools/gbgate` 26 real ROMs, 400 frames | **26/26 IDENTICAL**, zero divergences to classify |
| blargg canary | all eleven `cpu_instrs` ROMs are in that sweep and are byte-identical to `151b952`, which is itself pixel-identical to SameBoy at frame 1200; `sameboy_runner` is not built on this machine, so the canary holds transitively rather than directly |
| retired instructions (`DINGBAT_BENCH_COUNTERS=1`, Pokemon Crystal, a heavy-HDMA title) | `cycles=` identical in both arms (168,537,600); 22,474,786,524 → 22,468,346,617 = **−0.029%** |

The four rows recovered are `dma_hiram_read`, `dma_hiram_read_result`,
`dma_oam_read` and `dma_vram_read`, all `[cgb]`.

## The mid-mode-3 near-miss frames (2026-08-07)

Eight shootout rows were within ~100 wrong pixels of the reference, two of them
within 2. The brief that opened this pass proposed one cause for four of them
— *a mid-mode-3 write to LCDC bits 1 and 2 latching at the wrong point, so one
fix to when the FIFO latches those two bits takes `m3_lcdc_obj_size_change`,
`m3_lcdc_obj_size_change_scx`, `m3_lcdc_obj_en_change` and
`m3_wx_4_change_sprites` together*.

**That hypothesis is false as stated, and the diff images say so plainly.** The
four rows do not share a cause: `m3_wx_4_change_sprites` does not involve LCDC
at all (it writes LCDC exactly once, at init, and drives WX from LY thereafter), and the
two `obj_size_change` rows are untouched by everything that fixed
`obj_en_change`. What the diffs did show is two *other* shared mechanisms, both
now landed, which between them took four runner rows and moved ten more.

### What LCDC bit 1 actually measures: the mixer is a two-stage tail

`m3_lcdc_obj_en_change` is the sharpest instrument in the mealybug suite and
had not been read as one. Nineteen objects, one per 8-line band, at OAM X =
1..18 — so each band is a separate measurement — and a single LCDC write
clearing OBJ enable a few dots into mode 3, at a dot the ROM itself moves by an
M-cycle at LY 64. Every band therefore answers "which is the last object pixel
this write does NOT suppress".

All 60 of the frame's wrong pixels were one answer, at both write dots and
across all nineteen bands: **the pixel emitted on the dot immediately before
the write's own dot survived here and does not on hardware.** Not a latch, and
not bit 1's own: the mixer stage reads its registers a dot after the pixel it
colours leaves the FIFO. `m3_obp0_change` — the same nineteen objects against
two OBP0 writes — then separates a second stage: with one dot the pixel emitted
on dot 108 comes right and the one on 107 does not, uniformly, in every band.
So the tail is

    +1  LCDC's priority bits (the BG-vs-OBJ decision)
    +2  BGP / OBP0 / OBP1 (the shade lookup, one stage after it)

and the CGB's write to any of them arrives one dot later than the DMG's, which
is the shape `CGB_SCY_LATENCY` next door already has. The derivation, the
measurement and why `M3_PIPE_DELAY = 3` is not the same fix are at
`fifo_recompose_last` in `gb/fifo_ppu.nim`.

### The window's re-trigger survives on a dot, not on a fetcher state

`WIN_REACT_PHASE` named a fetcher position, and `fsPushPixel` is the one
position this fetcher can sit at for more than a dot — it parks there while the
BG FIFO drains. On an object-free line the park is one dot and the two readings
agree; with objects it stretches to three and the artifact smears over three
lines. `m3_wx_4_change_sprites`' reference settles it: every zero pixel is on
one lattice, `x mod 8 == 5`, running straight through two 8-line bands carrying
ten objects each, so objects do not move the surviving phase by a dot. Anchor
the proxy to the END of the park (the fetch restart) and the row goes exact.

### What each of the eight rows is now, and what is left in it

Two more landed after that, both against the mealybug suite's own written
documentation rather than against a diff image, and between them they are worth
more than either of the above: **`WIN_LINE_START_WX`** (a line starts as a
window line below WX **6**, not below 7 — gambatte brackets WX 0 and 7 and has
nothing between, so mealybug's three `m3_wx_{4,5,6}_change` ROMs are the only
oracle, and only 6 satisfies all three) and **`WIN_EN_ABORT`** (clearing LCDC.5
mid-mode-3 returns the fetcher to background tiles at the next tile-map read —
documented in mealybug's PPU notes, filed in this tree as SameBoy's *CGB-only*
fetcher abort, and measured by two ROMs whose scored references are
`_dmg_blob`). Derivations at their constants in `gb/gb.nim`.

### Where the whole scored DMG set stands

**Only the 24 DMG mealybug rows are scored by the shootout** (`mealybug.py`
ends `all = dmgs`), so the 13 CGB rows in `tests/results.md` carry no shootout
weight even though they moved a long way here. Wrong pixels of 23040, `main` at
`6d81502` against this branch:

| row | before | after | what is left in it |
|---|---|---|---|
| `m3_lcdc_win_en_change_multiple` | 8874 | **0** | `WIN_EN_ABORT` |
| `m3_obp0_change` | 74 | **0** | the mixer's second stage |
| `m3_wx_4_change_sprites` | 2 | **0** | the park |
| `m3_wx_6_change` | 13810 | **0** | `WIN_LINE_START_WX`, then `WIN_START_PRE_PIXEL` (2026-08-07, off the hardware photographs) |
| `m3_lcdc_win_en_change_multiple_wx` | 4215 | 343 | as above — **0 as of 2026-08-09**, and with it the whole scored DMG set (`WIN_WX0_PHASE` + `WIN_PRE_PX_PHASE`, at the end of this file) |
| `m3_lcdc_obj_en_change` | 60 | 2 | see below |
| `m3_lcdc_obj_en_change_variant` | 380 | 102 | the mixer |
| `m3_window_timing` | 299 | 29 | **0 as of 2026-08-09** — 12 px `MIXER_TAIL_DOTS`, 21 px `WIN_HEAD_ABSORB` + `WIN_LINE_START_LATCH` |
| `m3_bgp_change` | 1508 | 820 | second mechanism, see below |
| `m3_bgp_change_sprites` | 1044 | 536 | as above |
| `m3_window_timing_wx_0` | 902 | **4** | the SCX discard on a window-start line (2026-08-07); the 4 left were all LY = 0, i.e. bucket 0, and are **0 as of 2026-08-09** |
| `acid/cgb-acid-hell` (CGB) | 2 | 2 | **MEASURED 2026-08-18, not closed.** The 2 px are one CPU-vs-PPU M-cycle, proven frame-wide off the ROM's own source. `CGB_HALT_PPU_LEAD = 1` spends it and takes this row to 0 — and takes `daid/ppu_scanline_bgp` (GBC) from 0 to 2304, so it is the wrong home and ships at 0. See the 2026-08-18 sections |
| `m3_lcdc_obj_size_change_scx` | 30 | 30 | LCDC.2 is read once per BITPLANE — **0 as of 2026-08-09**, see below |
| `m3_lcdc_win_map_change` | 34 | 34 | see below — **0 as of 2026-08-09** (`obj_yields_to_window`) |
| `m3_lcdc_obj_size_change` | 57 | 57 | as above — **0 as of 2026-08-09** |
| `m3_lcdc_tile_sel_win_change` | 106 | 106 | the same WX = 7 tie as `m3_lcdc_win_map_change` — **0 as of 2026-08-09** (`obj_yields_to_window`). Its CGB twin is a different row and moved 830 → 474 on 2026-08-10 (`CGB_TDSEL_LATENCY` + `CGB_TDSEL_GLITCH`), then **474 → 0 on 2026-08-11** (the SET rule's address latch survives H-Blank, see below); the CGB `m3_lcdc_tile_sel_change` went with it, 116 → 0 |
| `m3_lcdc_bg_map_change` | 192 | 192 | not diagnosed — **0 as of 2026-08-09** |
| `m3_scy_change` | 417 | 417 | **0 as of 2026-08-09** — 83 for free with `OBJ_BG_RUN`, 29 with `LY0_PIPE_MCYCLES`, and the last 29 were the length of the discarded fetch at the head of mode 3 (`M3_THROWAWAY_DOTS`) |
| `m3_lcdc_tile_sel_change` | 776 | 776 | the CGB `TILE_SEL` glitch's DMG sibling — **8 as of 2026-08-09** |
| `m3_lcdc_bg_en_change` | 2193 | 2193 | LCDC.0 is read at the PUSH here, not at the mixer |

### 2026-08-08: three of those came off the ROMs' own source code

`docs/gb-mealybug-sources.md` is the suite read from its `.asm` sources rather
than from its pixels. Two of the rows above are closed by it and one is
diagnosed exactly. Wrong pixels of 23040, against the table above:

| row | was | now | why |
|---|---|---|---|
| `m3_lcdc_bg_en_change` | 2193 | **67** | the ROM clears LCDC.0 for exactly 12 dots and then 8, and the reference's white runs are 12 and 8 pixels wide at x = −1 and 19 — neither on a tile boundary. LCDC.0 is a MIXER read, once per pixel (`BG_EN_AT_MIX`). CGB: 1824 → 11, and `m3_lcdc_bg_en_change2` 364 → 6 |
| `m3_bgp_change` | 820 | **403** | a DMG palette write puts one pixel of `old or new` at the far end of the mixer tail (`MIXER_PALETTE_OR`). Zero free parameters: 720 cells over 144 different old/new pairs go exact together |
| `m3_bgp_change_sprites` | 536 | **124** | as above |
| `m3_lcdc_tile_sel_change` | 776 | 776 | **diagnosed, not fixed**: hardware never puts an object fetch between a background tile's two bitplane reads; we do on 13 of 18 bands. Not curable by any of the four `OBJ_BG_RUN` rules — **fixed 2026-08-09 by a fifth, see below** |
| `m3_lcdc_bg_map_change` | 192 | 192 | the same defect on a coarser instrument — **0 as of 2026-08-09** |

Cost, named: gambatte `dmgpalette_during_m3_{4,5,scx1_4}` and `scx3/_5` go
8 → 150 wrong pixels and `lycint_dmgpalette_during_m3_4` goes 1284 → 1140. All
five were already red, none is a pass/fail row, and the mealybug photograph
sides with the OR pixel on all six of its columns (65–93%, table in
`gb-mealybug-sources.md` §3.2). Suite totals do not move: 978 / 702, gambatte
3658 / 5005.

A fourth thing the sources say and this pass did **not** act on: `inc/utils.asm`'s
`line_0_fix` macro burns 4 T-cycles *fewer* on LY 0 than on any other line,
which asserts that hardware's line-0 mode 2 STAT interrupt arrives 4 T-cycles
later relative to the start of drawing. dingbat's does not (dot 101 against dot
105, measured), so every mealybug ROM's line 0 is 4 dots early — 100–150 pixels
across the set, and the cheapest well-evidenced item left here. It reaches the
STAT model that mooneye `intr_2_*` and eight gambatte families pin, so it needs
its own measured trade.

### `acid/cgb-acid-hell` is a real failure, not a scoring artefact

*(It was. The row is 0 as of 2026-08-12 — `CGB_TDSEL_IDX_DOTS`, further down.
This section is kept because it is the calibration that stopped the row being
written off, and the same question comes back for every near-miss frame.)*

Worth stating because the shootout's rule is a **±50 luma tolerance**, not an
exact match, and dingbat's own runner applies exact comparison to the bundled
acid ROMs. Run through `util.compareImage` verbatim, the two pixels are
`(80, 68)` and `(80, 69)`, black against yellow, **luma delta 226** — four
times the tolerance, in both directions. `compareImage()` returns `False`. The
row is genuinely 2 pixels short and the framing holds.

**`m3_lcdc_obj_en_change`, the last 2 pixels.** One object, OAM X = 2, at LY 17
and 22 — the only two rows of its band where its column 6 is opaque and its
column 7 is not. Every other band in the frame is explained by "the write
suppresses from the dot before its own": for OAM X = 1..5 the object's last
on-screen pixel lands on dot 104 and the write is live at 105, and for X = 6, 7
the pixel at dot 103 is KEPT (LY 51 has an opaque one and the reference draws
it). X = 2's pixel at dot 103 is suppressed. No uniform number of stages fits
both. What is special about it is that dot 103 is the FIRST dot after that
band's object fetch ends (its penalty is 9 dots from a trigger at 94), where
X = 6's dot 103 is the fourth. So the residual is about what the mixer holds
across an object stall, not about the register — which is a model, not a
number, and it is worth one row.

**`acid/cgb-acid-hell`, the 2 pixels — mechanism identified, and landed on
2026-08-12 as `CGB_TDSEL_IDX_DOTS`. The row is 23040/23040.** Everything from
here to that entry is the derivation in the order it happened, and it is kept
because three of the four routes through it were refuted and the refutations are
the reusable part. The
whole frame is explained by a single anomaly, and `-d:gb_px_trace` reads it out
exactly. The ROM's tile DATA is a constant per scanline (both `$8000` and
`$8800` hold the same bytes, so `TILE_SEL` has no data effect at all) and the
picture is drawn by the tile-attribute palettes; on line 68 every tile's
bitplane bytes are `lo = $7F, hi = $5D`. The two wrong pixels are one tile on
each of lines 68 and 69 whose bitplane-1 byte hardware read as **the tile
index** — `$55` where the tile number is `$55`, and `$49` where it is `$49`.
Two byte-exact coincidences, and both bytes are pinned to all eight bits by the
eight pixels of the tile, not inferred from the one that differs.

That is the CGB `TILE_SEL` glitch the mealybug PPU notes describe verbatim:
"resetting `TILE_SEL` on the same T-cycle as a bitplane data read will cause
the tile index to be instead used as the data for that bitplane". The notes'
other branch is measurably refuted here — the alternatives it lists for a
*setting* are "bitplane 1 data from the most recently drawn sprite" (`$41` and
`$22` on those lines, traced) and "from the most recently drawn tile when
`TILE_SEL` was last reset" (`$5D`), and neither is `$55`/`$49`.

Two things stopped it being landed, and **the second ROM the note asked for was
found on 2026-08-10.** It settles the timing and the *reset* rule outright and
leaves the two pixels themselves unexplained. See `CGB_TDSEL_LATENCY` and
`CGB_TDSEL_GLITCH` in `gb/gb.nim` for the full decode; the short version:

* **The coincidence really does need one more dot, and the dot is measured.**
  `m3_lcdc_tile_sel_change2`'s CGB reference reads out the bytes hardware used
  for every tile of the frame, and its eight bands step the LCDC write by
  exactly one dot each through the fetch cycle. Hardware glitches the bands
  where dingbat's write is one dot *earlier* than a bitplane read, in both
  directions — so LCDC.4 reaches the fetcher one dot late on CGB. Its DMG twin
  is 23040/23040 with the same eighteen-band ruler, so the dot is a CGB delta
  and not a phase error being absorbed. It is `CGB_TDSEL_LATENCY`, and it also
  spends itself inside a double-speed M-cycle: gambatte's `bgtiledata` gains 8
  `[cgb]` rows at 1 dot and loses 4 `_ds_` ones unless the value is scaled.
* **The polarity is still inverted against the notes, and now against a second
  ROM as well.** The same reference names, unambiguously, what each direction
  substitutes: a **reset** on the read dot gives the tile index, and a **set**
  gives the byte at the last `$8000`-region address (the object's bitplane 1
  first, then the last reset-glitched tile's). Both rules are landed and both
  `*_change2` rows are pixel-exact under them. `cgb-acid-hell`'s glitched read
  is a **set** — `$E3 → $F3` at dot 177, live at 178, which is the bitplane-1
  read of the tile at `x = 76..83` — and the set rule delivers `$5D` there, the
  unglitched byte, because every tile-data byte on that line is `$5D`. Hardware
  delivers `$55`. **The only thing in the machine that holds `$55` on that dot
  is the tile-map read**, so the two pixels demand the index at a set, which
  every set cell of `change2` refuses.

That is where it stands: the timing and the reset rule are landed off a
23040-pixel readout, and the two pixels are a documented non-landing. The frame
cannot arbitrate on its own — 2731 of 2736 pushed tiles match, and BG palette 1
in this ROM is four shades of white, so **the only observable tile per line is
the single `attr = 00` one**, and on both lines 68 and 69 that tile is a *set*.
Every reset-glitched tile on those lines is invisible. What is left to try is a
CGB revision question (the notes split the reset branch by revision already, and
`cgb-acid-hell` ships one reference with no revision named) or a fourth
substitution source nobody has written down.

#### 2026-08-11: the SET rule was incomplete, and closing it closed two rows

Re-derived from all four CGB `tile_sel` references at once rather than from
`*_change2` alone. Every glitched bitplane read of the four frames whose eight
pixels the reference pins is one cell — 188 RESET cells and 161 SET cells — and
the whole set is scored against a candidate substitution source at a time. Two
results, and neither is about `cgb-acid-hell`:

* **RESET is the tile index on 188/188 cells.** Nothing moved here.
* **The SET rule's address latch is a bus register, and H-Blank does not clear
  it.** The two plain rows (`m3_lcdc_tile_sel_change`, `..._win_change`, CGB)
  put their first glitched read of a line *before* anything on that line has
  driven an `$8000`-region address, and hardware substitutes anyway — with what
  the line above left there. Dropping the per-line clear takes the SET cells
  from 133/161 to 158/161; also letting a plain unglitched `LCDC.4 = 1` read
  leave its address there takes it to 159/161. Both rows go **22924/23040 and
  22566/23040 → 23040/23040**, i.e. from the pair's whole residual to pass.
  Full arithmetic at `CGB_TDSEL_GLITCH` in `gb/gb.nim`.

A plain DATA latch — the last `$8000`-region *byte* rather than its address,
which is the cheaper thing to build and what the notes' wording suggests — is
refuted by a whole band and not a cell (89/161): `*_change2`'s two bands glitch
on different PLANES and hardware answers with the same tile at the plane the
glitch is on, which only an address can do.

**`cgb-acid-hell` is unchanged at 2, and it is now the only thing in the tree
that refuses the rule** (as of this entry — the 2026-08-12 one below closes it).
Its observable cells were undercounted here: there are
**seven**, not two — lines 64..70, all at `x = 76..83`, all bitplane-1 SET
glitches, all eight bits of each pinned. All seven want the tile index; five of
them are cells where the latch happens to hold the same byte, and the two the
frame can tell apart are lines 68 and 69. So the ROM votes 7/7 for the index
and 5/7 for the latch, against 96 cells of `*_change2` / `*_win_change2` that
vote 48/48 for the latch and 0/48 for the index.

Two things are now settled that were guesses before:

* **No address-latch rule of any shape can produce those two bytes.** A VRAM
  search of the frame is decisive: on line 68 the only tile-data byte equal to
  `$55` at row 4 plane 1 is `$8699` (tile `$69`, which the line never fetches),
  and on line 69 the only one equal to `$49` at row 5 plane 1 is `$869B`, the
  same absent tile. The only other addresses holding those bytes are tile-MAP
  entries, and one of them on each line is the current tile's own map address
  (`$98A0` and `$98C0`). The byte is the tile index, arrived at as an index and
  not as a tile-data address.
* **The two ROMs' cells are structurally identical**, which is what kills the
  remaining "our bookkeeping diverges" hypotheses. `cgb-acid-hell` line 68:
  map read at dot 174, plane 0 at 176 (signed), LCDC `$E3 → $F3` at 177, plane
  1 at 178. `m3_lcdc_tile_sel_change2` line 43: map at 142, plane 0 at 144
  (signed), LCDC `$C3 → $D3` at 145, plane 1 at 146. Same plane, same direction,
  same offsets, same `< $80` tile index — and different answers.

The one thing that does separate them, measured over all 161 SET cells: in
`cgb-acid-hell` the latch was written **8 dots and one intervening read** ago
(its LCDC.4 toggles every 8 dots, so the RESET-glitched read is in the
immediately preceding tile fetch), and **every other cell in the tree is at
least three reads or a whole scanline stale**. That bucket is populated by this
ROM alone, so "back-to-back glitched fetches substitute the index" is a rule
fitted to two pixels with no independent confirmation, and is not landed.

The revision question is now *narrower but still open*. mealybug ships a
`_cgb_d` reference for `m3_lcdc_tile_sel_change` and `..._win_change` and they
are **pixel-identical to the `_cgb_c` ones** — but those are exactly the two
rows where the index and the latch agree, so they cannot arbitrate either. The
two ROMs that can (`*_change2`) ship `_cgb_c` only. So: every reference this
rule is derived from is a CGB-C capture, `cgb-acid-hell`'s names no revision,
and the one experiment that would settle it — a `_cgb_d` capture of
`m3_lcdc_tile_sel_change2` — does not exist. Landing it as a revision split
would mean `CGB_TDSEL_GLITCH` growing a second SET branch selected by the
behaviour-flag mechanism in `docs/gb-hardware-revisions.md` §2.1, on the
evidence of two pixels and no reference that names its device. Not worth it
yet; worth it the day a second acid-hell-shaped ROM appears.

#### 2026-08-10: the revision question is CLOSED, and the ROM closes it

`cgb-acid-hell` does name its device — not in the filename, in the code. The
disassembly carries a **`$FEA0` readback gate** at `$1AB6`, run once during
setup on the CGB path (`cp $11 / jp nz` selects the non-CGB one above it):

    ld hl, $fea0 / ld b, $55      ; wait for STAT bit 1 clear, then
    ld [hl], b                    ;   write $55 to $FEA0
    ld hl, $feb8 / ld b, $44      ; wait again, then
    ld [hl], b                    ;   write $44 to $FEB8
    ld hl, $fea0 / ld a, [hl]     ; wait again, then read $FEA0 back
    cp $55 / ret nz               ; NOT $55  -> return, caller loads $1F64
                                  ; IS  $55  -> fall through, load $2044

The two branches load **different tile data** — `$1F64` on the fall-out and
`$2044` on the fall-through — so the ROM draws a different picture on the two
sides of the `$FEA0` behaviour, which is a CGB revision split. dingbat takes the
`$1F64` branch, the bundled reference is the `$1F64` picture (that is what
23038 of 23040 pixels agreeing means), and the author's photo is of the same
branch. The repo's issue tracker carries a photo of a device that takes the
other one — a real CGB showing the ROM's `SORRY YOU CAN'T GET TO PLAY` screen —
so both branches exist in the wild and the author shipped one reference.

Two consequences, and the second is a live hazard:

* **The reference is a CGB-C capture, like every `*_change2` one**, so the
  `CGB_TDSEL_GLITCH` rule and this ROM are scoring the same device after all.
  A revision split for the SET branch is therefore not merely unsupported, it
  is *excluded*: the two pixels and the 48 `*_change2` SET cells that refuse
  them are the same silicon. What is left is `H1` — "a SET glitch whose latch
  was written by the immediately preceding fetch substitutes the index" — which
  is one rule, scoreable over the 349-cell corpus, and still the only live
  candidate.
* **dingbat passes that gate by accident.** `memory.nim`'s read path answers
  `of 0xFEA0..0xFEFF: 0x00'u8` for every model, so the compare fails and the
  `$1F64` branch is taken because the region is not modelled at all. The day
  anything models `$FEA0..$FEFF` per revision — and the OAM-corruption work is
  the obvious way in — **this row silently changes which picture it is drawing
  and stops being comparable to its reference.** Whoever touches that range
  should re-score `cgb-acid-hell` in the same commit. The 2026-08-13 entry has
  the per-revision table this gate was written against, and the number to aim
  for: a CGB-C must read `$44` back from `$FEA0` here, and only CGB-D reads
  `$55` and takes the SORRY branch.

Two smaller corrections to what is written above:

* **The two pixels are hardware-photo-verified.** The repo ships
  `img/photo.jpg`, a capture of the ROM on a real device, and the 8x8 cell at
  `x = 76..83, y = 64..71` is a legible yellow face on white in it. Both
  disputed pixels are inside that face and both agree with `cgb-acid-hell.png`
  pixel for pixel: `(80, 68)` is yellow and `(80, 69)` is black. The reference
  PNG is not the only witness and the pair is not a PNG-generation artefact.
* **"the notes split the reset branch by revision" is only half of it, and the
  SET branch has a third alternative this file never listed.** Quoting the
  mealybug PPU document's `TILE_SEL` section in full, a SET on a bitplane read
  gives *either* the sprite's bitplane 1, *or* the last reset-`TILE_SEL` tile's
  bitplane 1, *or* "bitplane 0 or 1 data from the read in progress during pixel
  159/160 (?) on the previous row when the tile fetcher is interrupted — **the
  timing of which bitplane is selected differs between CGB revisions**". So the
  revision language is inside the SET branch too, on the previous-row case's
  plane selection. It does not rescue a revision split here (the `$FEA0` bullet
  above kills that), and it is not the two pixels either — that third source is
  a previous-row *fetch*, and the byte hardware delivers is the current tile's
  index — but the earlier sentence in this file understated what the notes say,
  and the reset branch's own CGB-D arm is a wholly different rule ("read the
  bitplane data from the address for bitplane 0", not the index) that this tree
  has never needed.

#### 2026-08-10: the write-to-fetch phase is not the answer either, and why

The other live hypothesis was that the write burst is in the wrong place rather
than the rule being wrong, because dingbat's CGB halt-wake is measurably early.
It is early — by exactly one M-cycle — and the ROM needs two. That is now
bracketed from both sides rather than argued, so this route is closed:

* **What the ROM needs is 8 dots, not 4, and the lattice says why.** The
  handler is `ld a,N / ldh [rLYC],a / xor a / ldh [rIF],a / halt`, then
  `ld a,$xx / ldh [rSCY],a / 17 nop / 16x ld [hl],r`, and the sixteen bytes it
  writes to LCDC are `$80 $E1 $80 $E3 $F3 $80 $E1 $80 $F3 $E3 $F3 $80 $E1 $80
  $F3 $E3` (`de = $80E1`, `bc = $E3F3`). Traced with `-d:gb_halt_trace
  -d:gb_m3_trace`: the wake is at dot 1 of every line, write *i* lands on dot
  `97 + 8i`, and the fetch of the one observable tile reads its map at 174, its
  plane 0 at 176 and its plane 1 at 178. Write 10 is at 177, is live at 178
  through `CGB_TDSEL_LATENCY`, and is the `$E3 -> $F3` SET. Both grids have an
  8-dot pitch, so moving the CPU by 4 dots does not change which *write* is on
  the read, it moves the write off the bitplane read and onto the tile-map read,
  where nothing glitches at all — the frame comes out **bit-identical** to
  `main`. Only a whole 8 dots advances the write index by one, and it does so in
  either direction: at +8 the read is hit by write 9 (`$F3 -> $E3`) and at -8 by
  write 11 (`$F3 -> $80`), both RESETs, both delivering the index, both making
  the two pixels correct. Measured: `CGB_HALT_PPU_LEAD=2` is 23040/23040.
* **The halt is worth exactly one M-cycle, and 2 is refused by ROMs that are
  not this one.** gambatte `halt/lycirq_m2stat_{1,2,3}` and `halt/m1int_ly_
  {1,2,3}` are three ROMs each differing by one NOP, with a CGB-specific
  expected value on the middle member. At 1 both `_2` members flip green and
  `_1`/`_3` stay green; at 2 the `_1` members go red. `lycirq_*` is the
  IME-clear path — exactly `cgb-acid-hell`'s — and neither family carries an
  SCX, so neither is in the `scx_during_m3` bucket. The full derivation, the
  phase-versus-charge separation the 42 `tima/*` rows force, and the two
  independent witnesses for the same M-cycle (daid `ppu_scanline_bgp` on CGB,
  and `SPEED_SWITCH_STALL_T` which was absorbing it) are at `CGB_HALT_PPU_LEAD`
  in `gb/gb.nim`.
* **The non-halt half of the phase is pinned to one dot by the four CGB
  `tile_sel` rows**, which are 23040/23040 and whose ROMs sync on a mode-2 STAT
  interrupt in a NOP slide with no `halt` anywhere (`inc/lcdc_stat_int_base.asm`).
  So an 8-dot CPU-to-PPU error that this ROM has and they do not would have to
  live entirely in the halt, and the halt is worth 4.

So the 8 dots do **not** decompose: 4 are derived and bracketed, and the other 4
have no source. `cgb-acid-hell` stays at 2 pixels, `CGB_HALT_PPU_LEAD` ships at
0 for an unrelated reason (one `strikethrough` row), and `H1` — the
back-to-back-glitch SET rule scored over the 349-cell corpus — remains the only
live candidate for the row.

#### 2026-08-18: the 2 pixels are not a glitch-rule question at all

H1 ships and `cgb-acid-hell` is 2, which on its own reads as "the rule regressed".
It did not. Traced with `-d:gb_m3_trace -d:GB_TRACE_LY=68` on the SETTLED frame
(the first traced frame is still filling and its tiles are all `$00` — reading
that one is how this was mis-diagnosed once already), line 68 now looks like:

    DOT 176 fsPushPixel        lx=76 fx=10 lcdc=E3
    LCDC ly=68 dot=177 old=E3 new=F3   fc=0  lx=77 fx=11
    DOT 178 fsGetTile          lx=78 fx=11 lcdc=F3
    DOT 180 fsGetTileDataLow   lx=80 fx=11 lcdc=F3
    DOT 182 fsGetTileDataHigh  lx=82 fx=11 lcdc=F3

The write lands at **`fc = 0`, on the fetch BOUNDARY**: the whole of fetch 11 —
map, plane 0 and plane 1 — happens with LCDC.4 already set. Nothing is
mixed-tileset, so no glitch arms, so no glitch rule can reach these pixels.
That is why seventeen knobs across the tile-select, window, object and (new
here) WY, mixer and `CGB_TDSEL_IDX_DOTS` families all leave the residual at
exactly 2 px: they are all rules about a split fetch, and there is no split
fetch to apply them to.

`m3_lcdc_tile_sel_change2` line 43, traced the same way, still splits:

    DOT 140 fsGetTileDataLow   lx=36 fx=5 lcdc=C3
    LCDC ly=43 dot=141 old=C3 new=D3   fc=4  lx=37 fx=5
    DOT 142 fsGetTileDataHigh  lx=38 fx=5 lcdc=D3

**`fc = 4`, between the two bitplane reads** — the split the row needs, which is
why it passes. Both ROMs write LCDC at fixed CPU dots, and the 2026-08-10 entry
above records acid-hell's line 68 splitting the same way (plane 0 at 176, write
at 177, plane 1 at 178) back when it scored 0. So acid-hell's line has drifted
**4 dots** against its own CPU and mealybug's has not.

This is finally a complete account of `CGB_TDSEL_LATENCY=5`, which the entries
above could only describe as "four dots parked in the wrong path". It delays
every LCDC.4 arrival by 4 dots, which puts acid-hell's write back inside the
fetch (`fc 0 → 4`) and takes the row to 0 — and by the same 4 dots takes
mealybug's write *out* of its fetch (`fc 4 → 0`), which is exactly the four
`tile_sel` rows it costs. One shift, both signs, and the reason the trade has
never been winnable by that knob.

So the open question is no longer "which glitch rule" but **where those 4 dots
are**. Ruled out so far, by trace rather than by score: it is not the window
start re-anchoring the grid (`-d:CGB_WIN_RESTART_COUNTER=1` perturbs the window
by a dot and leaves the write at `fc = 0`), and not the object penalty
(`OBJ_FETCH_DOTS` 5/7, `OBJ_WAIT_SUB` 2/4/6, `OBJ_BG_RUN=0` all leave it at
2 px). The fetcher re-locks to the shifter, so `fc` is a function of `lx`: it is
0 at `lx ≡ 5 (mod 8)` on acid-hell's line and 4 at the same residue on
mealybug's. Line 68 carries `SCX = 180` (`&7 = 4`), one object at X = 1, and a
window from `lx = 26`; mealybug's line carries none of those. The 4 dots are in
one of them, and the next step is to find which by trace, not by sweep.

Note for whoever runs this: `-d:gb_px_trace` on its own did not compile until
2026-08-18 (`gb_traced` was guarded on `gb_m3_trace` alone).

#### 2026-08-18, same day: the 4 dots are `CGB_HALT_PPU_LEAD`, and it is 0 px

The answer came from the ROM's own source rather than from another sweep.
`cgb-acid-hell` is an mgbdis disassembly on GitHub, and it rebuilds byte-exact
(md5 `cdf25d29ff8504d28a87bb8d20f7f698`) once four pre-0.6 rgbds spellings are
fixed -- the fourth being **a `nop` after each of its 136 `halt`s**, which old
rgbasm inserted for you. Miss that one and the ROM is a byte short per line,
which on this ROM is 4 dots of phase: the quantity under study, introduced by
the build. See `tools/gbppu/hellsrc.py` for the recipe.

What the source shows is that the ROM is **fully unrolled, one block per
scanline**, each block anchored by its own `halt` on the STAT LYC interrupt and
then writing LCDC 16 times, two M-cycles apart, via `ld [hl], r` with `hl` =
$ff40. Lines 67..70 are byte-identical apart from `rSCY` ($e0/$e8/$f0/$f8,
stepping one tile row) -- so the LCDC write timing is not what distinguishes the
failing lines from their neighbours, and `d,e,b,c` = `$80,$E1,$E3,$F3`
reproduces the traced write sequence exactly.

Because every line re-anchors on its own halt, one line can be perturbed with
the other 143 as controls. ROM0 is exactly full and the disassembly carries 29
raw-address jumps, so the perturbation has to preserve byte offsets: rewrite k
of a block's 17 idle `nop`s ($00, 1 byte, 1 M) as `ld a, [hl]` ($7E, 1 byte,
**2** M), which buys k M-cycles at identical size. Then (`tools/gbppu/hellall.py`):

| | dingbat | oracle |
|---|---|---|
| every line delayed 0 M | — | 2 px on lines 68, 69 |
| **every line delayed 1 M** | **0 px, all 23040** | — |

**Delaying every line's writes by exactly one M-cycle makes dingbat reproduce
SameBoy's undelayed frame pixel-perfectly on all 144 lines.** So the residual
was one uniform CPU-vs-PPU M-cycle all along -- not a glitch rule, not the
window, not the object -- invisible on 142 lines only because the ROM's writes
sit on an 8-dot lattice and the phase is 4 dots. (Delaying the whole post-halt
block including `rSCY` gives the same result, so this ROM cannot say whether the
M-cycle is in the wake or in the write path; `strikethrough` can, and does.)

That constant already existed: **`CGB_HALT_PPU_LEAD`**. It shipped at 0 because
`strikethrough-cgb` went 7 px wrong under it and nothing measured it from the
other side. Both halves are now resolved:

* `cgb-acid-hell` measures it, above, and any lead ≥ **1 dot** takes it to 0 --
  it is not a 4-dot threshold, the pixel flips immediately.
* `strikethrough` was never refuting it. `OBJ_DMA_BUS_LEAD`'s own derivation in
  `fifo_ppu.nim` says that frame witnesses the **SUM** of the pipeline's advance
  and the object fetch's lead over the OAM DMA unit's bus. The advance is now
  summed into that lead, CGB-only, exactly as `CGB_PIPE_MCYCLES` already was --
  and both strikethrough frames are byte-identical across the change. Setting
  `OBJ_DMA_BUS_LEAD=2` globally instead does fix the CGB arm and breaks the DMG
  one by the same 7 px, which is the two-sided bracket the constant claims.

Ledger: **884 → 886 rows, gambatte 4201 → 4241 (+40), no regressions**; objtab
held 0/153, probe (e) 68 → 113/136, `cgb-acid-hell` **23040/23040**. The +40 is
not this constant alone -- bucket 13's speed-switch model has its defaults tied
to this knob, so turning it on lands that model with it, which is what it was
parked waiting for. Refused on the way: `CGB_HALT_EXIT_MCYCLES=1` (882, gambatte
4160), `STAT_LYC_LEAD=1` (866, gambatte 3905 -- it moves the LYC interrupt
itself, which GBMicrotest and mooneye pin directly), and
`CGB_OAM_DMA_START_T=4` as the compensator (recovers strikethrough but costs 117
`oamdma` rows, confirming the 8 T start).

#### 2026-08-18, third pass: the lead is REVERTED, and why

The section above shipped `CGB_HALT_PPU_LEAD = 1` on a full runner pass with no
regressions. **That pass was blind.** `daid/ppu_scanline_bgp` "(GBC)" is a
silicon reference the shootout scores and the local runner did not: the lead
takes it from **0 px to 2304**, at every one of the six CGB revisions. The knob
is back at 0 and the row is now wired (`daid/ppu_scanline_bgp-gbc`,
`--cgb --model=cgbe`, which is exactly what the shootout adapter passes), so
the gap cannot reopen.

That makes three instruments, all STAT-LYC `halt` anchors on CGB, and they do
not agree:

| instrument | halts per frame | wants the advance? |
|---|---|---|
| `cgb-acid-hell` | 144 (one per line, LYC = the line) | **yes** |
| `daid ppu_scanline_bgp` (GBC) | 1 (LYC = 0, the 153→0 snapback) | no |
| probe (e)/(f), plain arm | 1 (LYC = 16) | no |

and **SameBoy reproduces all three** — including acid-hell pixel-exactly — while
carrying no halt-wake PPU lead at all. So the M-cycle acid-hell measures is
real, and the halt is not where it lives: this is the same category as
`CGB_TDSEL_LATENCY = 5`, a compensation that happens to land on one ROM.

The obvious discriminator is **refuted**: it is not IME / whether a vector is
taken. acid-hell's per-line blocks continue inline after `halt`, so IME is 0 and
no vector is dispatched — the same as the probe, which disagrees with it — while
daid's handler *is* entered (it "pops its return address and never returns").
So IME cannot separate the yes from the nos.

What is left to try, in order: the count and spacing of halts (acid-hell is the
only one of the three that re-halts every line, so anything that decays within a
line or accumulates per halt would separate it); the LYC value itself (0 on the
snapback vs a normal line); and the possibility that the M-cycle is not at the
wake at all but in a per-line quantity acid-hell alone rewrites every line
(`rSCY`, `rLYC`, `rIF`). The `hellsrc.py` harness can test the first two
directly, since the ROM's anchor is source-editable — that is the next move,
not another knob sweep.

The regressions the lead also caused are worth recording as the same signal
rather than as separate problems: gambatte `dma` −12 and `lcd_offset` −6 are
both measured across a halt wake, and they line up with daid, not with
acid-hell. Its gains — `speedchange` +50 and `age/spsw-mode0-cgbBCE` — are
bucket 13's speed-switch model, whose defaults are tied to this knob; they are
real and they are still waiting on the same one row.

#### 2026-08-12: H1 holds, and `cgb-acid-hell` is 0

The corpus was rebuilt from scratch (the previous pass's scorer was never
committed; this one is, as `tools/gbppu/tdselcells.py`, and its self-check
column is what says the rebuild is sound — all five frames reconstruct their
own bytes from their references with 0 mismatches once the row is passing).
The census came out **192 RESET cells and 223 SET cells**, not 188 and 161: the
pinning convention behind the older numbers was not written down, and this one
counts a cell whenever the reference pins at least one of its eight bits and
scores per pinned bit, which is a superset either way.

**H1 scores 223/223 SET and 192/192 RESET, and `cgb-acid-hell` is 23040/23040.**
The whole 981-row runner moves by exactly one row (768 → 769 pass) and every
other file the runner writes is byte-identical.

The trigger has **two halves and the corpus forces both**, each by a whole band
rather than a cell — which is the part worth carrying forward, because it is the
only thing here that is not fitted to two pixels:

| SET-branch trigger for "deliver the index" | SET cells |
|---|---|
| never (the address latch alone — what shipped) | 221 / 223 |
| always | 125 / 223 |
| the latch was written by a RESET glitch, any age | 158 / 223 |
| **the immediately preceding read was RESET-glitched** | **221 / 223** |
| the latch is ≤ 8 dots old, whatever wrote it | 215 / 223 |
| a RESET glitch landed ≤ 8 dots ago | 223 / 223 |
| **the latch is ≤ 8 dots old AND a RESET glitch wrote it** (shipped) | **223 / 223** |

* Recency alone fails on 8 cells: `*_change2`'s first glitch of a line has an
  *object* fetch 8 dots behind it and wants the latch, so the window is armed by
  a RESET glitch specifically and not by the last `$8000`-region read.
* Provenance alone fails on 64: `*_change2`'s columns 5 and 8 are SET glitches
  whose latch a RESET glitch wrote two tile columns back, and they want the
  latch. So the window is short.
* **The task's own first spelling — "the immediately preceding read was
  glitched" — is refuted, and by the two pixels it was written for.**
  `cgb-acid-hell` toggles LCDC.4 on an 8-dot lattice, so its RESET glitch is the
  *previous fetch's* read of the same plane and an unglitched signed read sits
  between the two. It scores 221/223, i.e. exactly what shipping already did.

The window is bracketed to **8..15 dots** with a clean gap on both sides (7
loses acid-hell, 16 breaks 64 `*_change2` cells), and 8 is the fetch cycle's own
pitch. It is measured in dots rather than reads because the two spellings score
223/223 identically and dots need no counter.

The two 223/223 rows differ only in whether an intervening write of the address
latch disarms the window, and no cell in the tree separates them. **The
narrower one ships because it is what the implementation gives for free**: a
field of its own costs 8 bytes of `GbFifoPpu` and moves the whole fetch path's
offsets, which measured +0.22% of retired instructions on Pokemon Crystal *with
the rule compiled out* — more than the rule itself. Packed above the bank in
`tdsel_addr` it is the same single store the RESET branch already did, and any
write of the latch clears it.

**What this does not establish, and the honesty is load-bearing:** at every
setting in 8..15 the trigger fires on exactly seven cells and all seven are
`cgb-acid-hell`'s. The other 216 SET cells prove the rule is consistent with
everything else measured; none of them is in the distinguishing bucket, so they
do not vote on the trigger's shape. Five of the seven are cells where the index
and the latch hold the same byte, so the arbitrating evidence is still two
pixels — hardware-photo-verified, on a device the `$FEA0` gate above pins to the
same CGB-C the `*_change2` references are, but two pixels. The settling
experiment is unchanged and still does not exist: a hardware capture of
`m3_lcdc_tile_sel_change2` (or any second ROM) with a SET glitch one fetch
behind a RESET one. Full arithmetic at `CGB_TDSEL_IDX_DOTS` in `gb/gb.nim`.
*(Read the 2026-08-13 entry below with this one: a commented disassembly of the
ROM turned up, it confirms the mechanism, it disagrees about which of two
adjacent writes glitches the read, and it makes the corpus's silence here
sharper than "the bucket is one ROM's".)*

#### 2026-08-13: the ROM has a documented disassembly, and it agrees about everything except which write

[CelestialAmber/cgb-acid-hell](https://github.com/CelestialAmber/cgb-acid-hell)
is a commented disassembly of mattcurrie's ROM — five commits of documentation,
including one called *"Finally figured out the pattern for scroll y"* — and it
is the only second reading of this test that exists. It is a fellow
reverse-engineer's account and not a hardware capture, so every claim below was
scored against this tree's traces before it was believed. Four of the five
things it says are independently confirmed here, and the fifth is refuted **by
its own arithmetic**.

**Confirmed: the picture is drawn out of TILE INDICES, and the ROM says so.**
`gfx/tilemap.asm`'s header: *"The LCDC bit 4 bug the test relies on uses the
tile index currently used as the high byte for the tile data, and since the
tiles used end up being the top 7 after the first tile in the first column, they
(including the 9th tile in the column) get set to the 8 values of the upper
bitplane of the smiley face tile data."* Its de-obfuscated tilemap makes that
literal — column 0 of map rows 0..8 is `01 1C 22 55 41 55 49 22 1C`, i.e. the
happy face's eight bitplane-1 bytes as tile numbers. The SCY pattern
(`macros/scanline_hell.asm`) is `tilemapYPos = 8 + (9·LY mod 64)` on lines
64..71 and `129 + (30·LY mod 128)` / `129 + (10·LY mod 128)` elsewhere, so face
line `64 + k` fetches map row `k + 1` at tile row 4-ish and the *index* it reads
is the face's row-`k` upper bitplane. dingbat's trace is that, to the byte: line
68 reads map `$98A0`, `num = $55`, `row = 4`, and hardware's byte is `$55`.
Everything below `$8000` in the "which address holds `$55`" search of the
2026-08-11 entry was therefore looking for something that was never there.

**Confirmed: the red herring, named as one.** `HappyFaceGraphicsData` is copied
to tile `$69` *"merely a red herring to trip up people, as we render the smiley
face in another, much more indirect way"*, and OAM entry 0 uses that tile
off-screen to the right *"just there to likely confuse people more"*. That is
`$8699`/`$869B` from the 2026-08-11 VRAM search — the only two addresses holding
the disputed bytes, in the one tile the frame never fetches.

**Confirmed: the CGB-D gate, with the semantics spelled out.**
`CheckIfNotOnCGBD` is our `$FEA0` readback, and the fork gives the table it was
written against (SameBoy `GB_read_oam`/`write_oam`): CGB 0/A/B/C mask `addr &
~0x18` so the `$FEB8` write lands on `$FEA0` and the readback is `$44`; CGB-D
keeps them apart so the readback is `$55`; CGB-E/AGB/GBP ignore the writes and
return `$AA`. Only `$55` falls through to the SORRY screen — **so the branch
this ROM refuses is CGB-D alone**, not "later revisions", and the reason is
stated outright: *"the bugs in the PPU this test relies on work differently on
CGB-D"*. Two consequences for the hazard note above: the device in the issue
tracker's SORRY photo is a CGB-D, and whoever models `$FEA0..$FEFF` per revision
keeps this row comparable as long as CGB-C answers `$44` — the readback dingbat
must produce is `$44`, not the `$00` it produces today by not modelling the
region at all.

**Confirmed, and this is the part the analysis here had missed: the sprite is a
clock.** The tilemap deliberately doubles as OAM, and one entry is load-bearing
— `4F 01 B9 01`, *"timing sprite for scanlines 63-71"*, at OAM `(1, 79)` =
screen `(-7, 63)`. The fork's account: it triggers a sprite fetch that
*"succeeds, but due to the first write on dot 96, the sprite isn't drawn"*, and
the *"extra delay of 6 cycles"* is what aligns the write burst with the face's
bitplane-1 fetch. All of it is in dingbat's trace and none of it was fitted:

| | lines 60..62 | lines 63..70 | lines 71..72 |
|---|---|---|---|
| object at the left edge | none | `X = 1` (`OBJTRIG dot 94`) | `X = 0` |
| fetch delay it costs | — | **6 dots** | **11 dots** |
| the observable tile's plane-1 read | dot **172** | dot **178** | dot **183** |
| LCDC.4 change on that dot | none | **yes** | none |

The 6 and the 11 are not this tree's numbers: `tools/gbppu/objtab.py` reads the
whole OBJ-penalty table out of `ppu_spritex_vs_scx.gb` and dingbat matches
hardware on **153/153 cells**, with `X = 1` at `SCX mod 8 = 4` (this ROM's
`SCX = 180`) costing exactly 6 and `X = 0` costing 11. So the sprite lines are
the only ones whose fetches land on the write lattice at all, which is why the
glitch exists on 63..70 and nowhere else — and why line 71, whose object is a
different one, renders the face's last row straight out of the SCY trick with no
glitch. The fork says both of those in prose (*"on scanline 63 the bug still
happens; however … nothing ends up looking different"*, and *"the last line of
the smiley face is rendered as normal from the indirect SCY method"*) and the
trace shows both: line 63 glitches at dot 178 and delivers index `$07` into a
palette of four whites; line 71 has no glitched read anywhere.

**Refuted: which write is on that read.** The fork's `scanline_hell.asm` says
the glitching write is `ld [hl], b` — `$F3 → $E3`, a **RESET**, the tenth of the
sixteen — and therefore that the whole test is the mealybug notes' plain reset
rule with no new mechanism at all. dingbat has the *next* write, `ld [hl], c`
(`$E3 → $F3`, a SET), on that read. One 8-dot write slot apart, which is the
same `±8` the 2026-08-10 entry above bracketed. The fork's own numbers decide it
against the fork:

* It puts the face tile's top-bitplane fetch at **dot 172**. dingbat measures
  dot 172 for that fetch — **on the lines with no timing sprite**. The two
  models of the fetcher agree to the dot.
* The same sentence invokes the sprite's 6-dot delay and then quotes the
  coincidence at the *undelayed* dot. Carried through its own arithmetic, 172 +
  6 = 178, which is `ld [hl], c` and a SET: dingbat's answer.
* Its CPU accounting (`halt` = 4 cycles for wakeup, then 28 cycles to the SCY
  write, then 68 to the burst) puts write *i* live at `100 + 8i`; dingbat's
  lands at `97 + 8i` and is live at `98 + 8i`. Two dots apart, i.e. inside the
  slop of which T-cycle of `ld [hl], r` the store lands on — not eight.
* Both grids have an 8-dot pitch, so **only a whole slot can change the
  answer**, and a shift that is not a multiple of 8 destroys every coincidence
  on this ROM and renders no face at all. The frame rules out the intermediate
  values on its own.

**What the fork does change here: the corpus is now known not to arbitrate.**
The `±8` world was measured again, as `-d:CGB_TDSEL_IDX_DOTS=0
-d:CGB_HALT_PPU_LEAD=2`, and it is not merely "also passes the frame"
(23040/23040, as 2026-08-10 recorded) — it is **clean over the whole 415-cell
corpus with no `IDX_DOTS` rule at all**: the seven `cgb-acid-hell` cells move
from the SET column to the RESET one, the census becomes 216 SET / 199 RESET,
and the plain rules score **216/216 and 199/199**. So the corpus cannot tell
"H1 at this phase" from "no H1, one M-cycle later"; it says only that whichever
phase is right, the rules are consistent with every other cell measured. The
table in the entry above is a statement about one world, not a discriminator
between the two.

**What still decides it is the halt bracket, re-measured today.** Whole
gambatte suite, `tools/gbppu/gamall.sh`, one build per setting:

| build | gambatte | `cgb-acid-hell` |
|---|---|---|
| shipping (`IDX_DOTS=8`, `HALT_PPU_LEAD=0`) | 3850 / 5005 | 23040 |
| `IDX_DOTS=0, LEAD=1` | 3850 / 5005 | 23038 |
| `IDX_DOTS=0, LEAD=2` (the fork's world) | 3852 / 5005 | 23040 |

The +2 at `LEAD=2` is `scx_during_m3`/`dma` churn and not evidence; the two
clean families are. At `LEAD=1`, `halt/lycirq_m2stat_2` and `halt/m1int_ly_2`
flip green and their `_1` members stay green. At `LEAD=2`, `halt/lycirq_m2stat_1`
and `halt/m1int_ly_1` go red. Three ROMs one NOP apart per family bracket the
wake to **exactly one M-cycle**, and `lycirq_*` is `cgb-acid-hell`'s own
IME-clear path. The fork's world needs two. On the PPU side the same door is
shut by `objtab.py`'s 153 cells, which pin the 6 dots the fork itself quotes.

So the verdict is: **the fork corroborates the mechanism and refutes its own
assignment of it**, and `CGB_TDSEL_IDX_DOTS` stays. The caveat at the constant
gets *sharper*, not weaker — it is no longer "seven cells and all seven are this
ROM's" but "an independent reader of the source expected the reset rule here,
and the only thing standing between that reading and this one is one M-cycle of
CGB halt phase, measured against two gambatte families and nothing else". The
settling experiment is unchanged and still does not exist.

#### 2026-08-14: the `LEAD=1` world has no TILE_SEL rule, and the tile-MAP slot is what refuses it

The entry above leaves one obvious move open: `CGB_HALT_PPU_LEAD=1` is the
value the halt bracket wants, it closes daid `ppu_scanline_bgp` on CGB, and the
only thing it costs on this side is `cgb-acid-hell`. So ask the question
directly — **what must the CGB TILE_SEL glitch rule be in the `LEAD=1` world,
such that the 415-cell corpus, the four mealybug `tile_sel` rows and
`cgb-acid-hell` are all right in one build?**

The answer is that there is no such rule, and the refusal is not a near miss.
It is measured over 23984 pinned bitplane reads with a two-sided bracket on the
last free parameter. What follows is the derivation; `tools/gbppu/tdselphase.py`
is the instrument and it is committed with this entry.

**First, the premise: the corpus really is `LEAD`-invariant, and this is
verified rather than argued.** The four mealybug ROMs sync on a mode-2 STAT
interrupt in a NOP slide and never execute `halt`, so the halt phase cannot
reach them. Checked by building the pipeline trace twice and comparing:

| ROM | pipeline events | `LEAD=0` vs `LEAD=1` |
|---|---|---|
| `m3_lcdc_tile_sel_change` | 1796441 | byte-identical |
| `m3_lcdc_tile_sel_change2` | 1607480 | byte-identical |
| `m3_lcdc_tile_sel_win_change` | 1842377 | byte-identical |
| `m3_lcdc_tile_sel_win_change2` | 1648664 | byte-identical |

Every dot, every address, every byte, 6.9M events. So the corpus constrains the
rule *identically* in both worlds, and only `cgb-acid-hell` moves.

**Where its write burst lands at `LEAD=1`.** The wake is one M-cycle later in
PPU time, so the whole 8-dot write lattice shifts +4 dots — from the plane-1
read dots onto the tile-MAP read dots. Line 68, the observable tile
(`attr = 00`, `num = $55`), traced both ways:

| | `LEAD=0` | `LEAD=1` |
|---|---|---|
| LCDC.4 change dots on the line | 154, 162, 170, **178**, 186 | 158, 166, **174**, 182, 190 |
| tile-map read | 174 | 174 |
| plane 0 read | 176 (signed) | 176 (signed) |
| plane 1 read | **178** (unsigned, glitch SET) | 178 (signed, **no glitch**) |
| which of the 16 written bytes is on it | #10, `$E3 → $F3`, a SET | #9, `$F3 → $E3`, a RESET, in the MAP slot |

At `LEAD=1` **not one bitplane read of the frame has an LCDC.4 change on its
dot**: the corpus census drops from 415 cells to 408 (216 SET / 192 RESET,
scoring 216/216 and 192/192 under the shipping rules), `CGB_TDSEL_IDX_DOTS`
fires on nothing at any window in 0..19, and the row is 23038/23040 at every
setting of it. The two pixels are not mis-substituted there; nothing is
substituted at all.

**So the rule would have to fire in the map slot — and that is a bucket the
mealybug references populate.** `tdselphase.py` keeps every background bitplane
read whose eight bits a reference pins (not only the glitched ones, which is
what `tdselcells.py` scores) and buckets it by `delta = read dot - the dot the
last LCDC.4 change went live`. The four mealybug frames give 23680 pinned reads,
6352 of them with a change on the same line within -8..+40 dots:

| offset of the change from the read | pinned mealybug reads | disturbed by hardware |
|---|---|---|
| `delta = 0` (the change is ON the read) | 408 | all of them — the SET/RESET rules |
| `delta = 1..40` | 5720 | **0** |
| `delta = -8..-1` | 224 | **0** |

**Hardware disturbs a read on exactly one offset, and it is zero.** That single
table is the whole refutation: at `LEAD=1` `cgb-acid-hell`'s seven observable
reads sit at `delta = 4`, and 160 mealybug reads at `delta = 4` say a change
there does nothing.

**The bucket is shared right down to the previous change, and then bracketed
from both sides.** Sliced by the fetch cycle's own origin — `mapoff = 0` is a
change on the tile-map read dot, `read+4` is the plane-1 read of that fetch,
RESET direction, which is `cgb-acid-hell`'s exact situation:

| context | reads | hardware = the plain byte | hardware = the tile index |
|---|---|---|---|
| previous change: SET at -8, and one at **-32** | **7** (all `cgb-acid-hell`) | 5 (coincidences) | **7** |
| previous change: SET at -8, and one at **-24** | 32 (`*_change2`) | **32** | 0 |
| previous change: SET at -8, **none before it** | 24 (`*_change2`) | **24** | 8 (coincidences) |
| **no** previous change on the line | 8 | **8** | 8 (coincidences) |

Read the last free parameter off that table. Every candidate rule that fires on
acid-hell and not on the mealybug reads has to be keyed on the age of the
change *before last*, and the two neighbours of acid-hell's -32 bracket it from
both sides: at -24 hardware is quiet, and with no earlier change at all —
i.e. infinitely stale — hardware is quiet. A predicate true only at exactly -32,
with quiet on both sides of it, is not a rule. **`H_toggle`, "the bit was
already toggling one fetch back", dies here too**: 56 mealybug reads have
exactly that history (SET at -8, RESET at 0) and refuse the index, 48 of them
with the index pinned wrong.

**The two neighbouring-constant escapes are refuted by rows, not cells.** The
missing 4 dots cannot be borrowed from the LCDC.4 delivery path, because that
path is shared with the ROMs that pin it:

| build | `cgb-acid-hell` | the four mealybug `tile_sel` rows (CGB) |
|---|---|---|
| `LEAD=1` (shipping rules) | 23038 | 23040 / 23040 / 23040 / 23040 |
| `LEAD=1`, `CGB_TDSEL_IDX_DOTS=0` | 23038 | 23040 / 23040 / 23040 / 23040 |
| `LEAD=1`, `CGB_TDSEL_LATENCY=5` (the +4-dot escape) | **23040** | 21572 / 21515 / 22174 / 21499 |

The escape works exactly as advertised and costs 1468, 1525, 866 and 1541
pixels on the four rows it is derived from. `CGB_LCDC_TDSEL_LATENCY` is the same
shift applied at the write instead of the read and is refused the same way, with
three `window` rows on top (the table at that constant).

**The verdict.** At `LEAD=1` the missing thing is not a substitution rule; it is
4 dots, and every instrument that could supply them is already pinned:

* the fetch grid is pinned by `objtab.py`'s 153/153 OBJ-penalty cells, which
  fix the 6 dots this ROM's timing sprite costs;
* the change-to-read phase is pinned by the four mealybug rows through
  `CGB_TDSEL_LATENCY`, bracketed to one dot from both sides;
* the wake-to-write phase is pinned by `halt/lycirq_m2stat_{1,2,3}` — three
  ROMs one NOP apart, on `cgb-acid-hell`'s own IME-clear LYC path — to one
  M-cycle, which is `LEAD=1` itself.

The only door left open is a phase that separates an **LYC**-sourced STAT wake
from the **mode-2** STAT sync the mealybug ROMs use, since that would move this
ROM and not them. It is not free either: `halt/lycirq_m2stat` measures the same
composite (LYC raise → wake → read) and brackets it, so anything found there has
to re-explain that family in the same commit. Worth stating because it is the
one shape that is not yet excluded, and it is a halt/STAT question rather than
a PPU one.

So the ledger for whoever integrates `LEAD=1` is: it buys `halt/lycirq_m2stat_2`
and `halt/m1int_ly_2`, it closes daid `ppu_scanline_bgp` on CGB, and it costs
`cgb-acid-hell` two hardware-photo-verified pixels **with no rule available to
buy them back**. `CGB_TDSEL_IDX_DOTS` is not what stands in the way and turning
it off does not help; it is the 4 dots.

**The whole-runner `LEAD=1` baseline, for the integration that has to price
this.** One full `dingbat_test_runner` pass per build, same tree, same day; the
`LEAD=0` column is `main`'s `tests/results.md` reproduced row for row:

| row | `LEAD=0` | `LEAD=1` |
|---|---|---|
| local runner total | **769** / 981 | **765** / 981 |
| gambatte total | 3850 / 5005 | 3850 / 5005 |
| `gambatte/halt` | 124 / 158 | **128** / 158 |
| `gambatte/dma` | 124 / 229 | 120 / 229 |
| `acid/cgb-acid-hell` | 23040 | 23038 |
| `strikethrough/strikethrough-cgb` | 23040 | 23033 |
| `daid/speed_switch_timing_ly` | 23040 | 22915 |
| `daid/speed_switch_timing_stat` | 23040 | 22807 |

Nothing else in the tree moves. The two `daid/speed_switch_*` rows are not a
cost of the phase, they are the phase being double-counted: `SPEED_SWITCH_STALL_T`
absorbed this same M-cycle and its window moves 65548 → 65544 with it (see that
constant in `memory.nim`), which is worth 4 net gambatte `speedchange` rows on
its own. So the real standing cost of `LEAD=1` is `strikethrough-cgb`'s 7 pixels
and `cgb-acid-hell`'s 2, against +4 `halt` rows, -4 `dma`, and daid
`ppu_scanline_bgp`.

#### 2026-08-14: the ROM's wake source is LYC, and the axis is DISPLACEMENT, not any one knob

The entry above ends "it is not the glitch rule that is missing, it is 4 dots",
and leaves one door open: a phase that separates an **LYC**-sourced STAT wake
from a **mode-2**-sourced one would move `cgb-acid-hell` without moving the four
mealybug `tile_sel` ROMs. That door is now measured shut, and measuring it
turned the whole question into a better-posed one. Read this entry with the
`f243151`/`d8ef3b1` pair, which refutes a uniform halt phase at every value: the
spelling below is deliberately knob-independent because of that.

**The ROM's wake source, from the ROM.** `-d:gb_stat_src_trace` (new, at
`ppu_handle_stat_interrupt`) names which of the four terms takes the STAT line
high on each rising edge, which `if=` cannot — all four share one IF bit. Over a
whole `cgb-acid-hell` run:

* **15233 STAT rising edges, every one of them LYC-sourced**
  (`lyc=1 m2=0 m2v=0 m0=0 m1=0`). Not a majority — all of them.
* STAT reads `$C6` on 15121 of them and `$C5` on the other 112, i.e. bit 6 (LYC)
  enabled and **bit 5 (OAM/mode 2) clear for the entire frame**. The mode-2
  source is not merely unused, it is disabled in the register.
* Every halt exit is `ly=N dot=1 mode=2 ime=0`, off the LYC=N edge at `cc=0`,
  with the handler rewriting LYC to the next line each time. That is
  `halt/lycirq_m2stat`'s shape exactly, which is why that family is the one
  that brackets this ROM's wake.

So a mode-2-source phase cannot reach this ROM, and the measurement agrees with
the reasoning to the pixel: `STAT_M2_LEAD=1` **alone** leaves `cgb-acid-hell`
bit-identical at 23038 and takes the four mealybug rows to 21972 / 21591 /
21706 / 21609 — because *they* are the mode-2-sourced ones. The two sides of
this corpus sync on different STAT sources, and that asymmetry is the whole
reason bucket 14 moves one and not the other.

**What actually moves this ROM is DISPLACEMENT, and it is worth stating in those
terms because no single knob owns it.** Write `D` for how far the CPU's write
burst sits from the BG fetch lattice, in dots, and the entire axis collapses to
three cases — measured, and each reached by more than one spelling:

| `D` | where the LCDC.4 change lands | what hardware needs | `cgb-acid-hell` |
|---|---|---|---|
| **0** | ON the plane-1 read, a **SET** | `CGB_TDSEL_IDX_DOTS=8` | 23040 |
| **±4** | in the tile-**MAP** slot, on no read at all | *nothing exists* | **23038** |
| **±8** | ON the plane-1 read, a **RESET** | the plain mealybug rule, `IDX_DOTS=0` | 23040 |

The middle row is the entry above: 4 dots is the dead zone, and it is dead
whatever supplies the 4 dots. Confirmed from the other side today — in the
parked bundle (`STAT_M2_LEAD=1 M3_PIPE_AHEAD=1 LY0_PIPE_MCYCLES=0
HALT_IF_SAMPLE_T=2`) with **no halt phase at all**, line 68's fetch grid moves 4
dots *earlier* (map read 174 → 170) while the write lattice stays put, the
change lands at `mapoff = 0` again, `glitch=0` on both reads, the census is the
same 408 cells (216 SET / 192 RESET, acid-hell contributing none), and the row
is 23038 at `IDX_DOTS=8` and 23038 at `IDX_DOTS=0`. Same dead zone, opposite
mechanism: there the halted CPU moved, here the pipeline did.

**The algebra of the two-sided constraint.** With `N = M3_PIPE_AHEAD` (the fetch
pipeline against the whole CPU timeline) and `M = STAT_M2_LEAD` (the mode-2
dispatch the corpus ROMs sync on), and `cgb-acid-hell` syncing on LYC, which
neither moves:

* the four mealybug rows are unmoved **iff `N = M`** — their writes and their
  fetch lattice shift together;
* `cgb-acid-hell` sees `D = N` M-cycles, and it needs **`N = 2`**.

So the bundle's `N = M = 1` is exactly one M-cycle short of what this ROM wants,
which is why it lands in the dead zone rather than near it. Both halves verified
rather than assumed:

| build | `cgb-acid-hell` | the four mealybug `tile_sel` rows |
|---|---|---|
| bundle as parked (`N = M = 1`) | 23038 | 23040 × 4 |
| `N = 2`, `M = 1` | **23040** | 21572 / 21515 / 22174 / 21499 |
| `N = M = 2` | **23040** | 23024 / 23011 / 23024 / 23040 |

`N = M = 2` is the only spelling on the whole axis that gives this ROM its 8
dots while nearly holding the corpus (61 pixels residual, the same
line-0 shape `LY0_PIPE_MCYCLES` fixes at `N = M = 1`) — **and it is refused by
bucket 14's own bracket**, which pins `STAT_M2_LEAD` to one M-cycle from both
sides. Re-measured here on the sled that is the bucket's own evidence, so the
bracket is two-sided in one column rather than quoted:

| `STAT_M2_LEAD` | `int_oam_nops` | `int_oam_incs` |
|---|---|---|
| 0 | `$94` vs `$93` — one M-cycle **over** | `$70` vs `$6F` — over |
| **1** | **exact** | **exact** |
| 2 | `$92` vs `$93` — one M-cycle **under** | `$6E` vs `$6F` — under |

And the whole runner prices what `N = M = 2` costs to buy those two pixels:
**726 / 981 and gambatte 3653 / 5005**, against 769 / 3850 shipping. The door is
shut by the same measurement that opened the bucket.

**The per-source LYC lead, built and refuted.** To ask the door's question
cleanly rather than through `STAT_IRQ_LEAD` — which moves LYC, mode 0 and mode 1
together while the OAM pulse rides the flag clock and stays put — this entry
lands `STAT_LYC_LEAD` (gb.nim), the LYC-source-only twin of `STAT_M2_LEAD`. It
ships at 0 and compiles out with the rest of the split domain. At 1 it does
everything this axis could want and is refused anyway:

* all five reference frames go green at once (`cgb-acid-hell` 23040 and the four
  mealybug rows 23040) — the only single knob in the tree that does;
* and **six GBMicrotest LYC sleds go exactly one M-cycle early**: `int_lyc_nops`
  `$99 → $98`, `int_lyc_incs` `$70 → $6F`, `int_lyc_halt` `$99 → $98`,
  `lcdon_to_lyc1/2/3_int` `$70 → $6F`, `$E2 → $E1`, `$54 → $53`. Every one is
  exact at 0.
* Whole runner 765 → 752, gambatte 3876 → 3599 (`sprites` 436 → 240, `ly0`
  75 → 51, `lycEnable` 181 → 170, `m2enable` 94 → 76).

Those six sleds are **rulers, not thresholds** — they count M-cycles from the
source's rise to a fixed point — so they refuse a move in either direction, and
the instrument's sensitivity to sign is itself demonstrated next door: the same
family's OAM members read one M-cycle *over* (`int_oam_nops` `$94` vs `$93`),
which is the evidence bucket 14 is built on. The LYC source reads exact where
the OAM source reads over. That is the two-sided bracket, and it is why the LYC
half of the wake has no M-cycle to give.

**Where this leaves the axis.** `cgb-acid-hell` wants `D = ±8`; every
independently-derived quantity in the tree supplies at most 4, and the two
sources of a second 4 are each refused by their own ROMs — the halt phase by
`hdma_late_disable` versus `lycirq_m2stat` (`d8ef3b1`), and `STAT_M2_LEAD=2` by
GBMicrotest. The `D = ±4` world in between needs a substitution rule that the
415-cell corpus proves does not exist. So `CGB_TDSEL_IDX_DOTS` is not merely
still standing, it is *load-bearing for the bundle*: whoever lands
`M3_PIPE_AHEAD=1` should know it moves this row to 23038 and that turning the
constant off does not help, because at `D = 4` nothing fires either way.

#### 2026-08-10: the pipeline phase is ONE quantity, and two CGB rows bracket it to different values

The bundle measurement (`docs/gb-bundle-measurement-2026-08-10.md`) leaves four
rows broken and one fixed, and the obvious hope is that they are four different
mechanisms that can be unpicked. **They are not. They are one number**, and this
entry is the proof plus the minimal contradiction it forces. Call that number
`P`: how far the mode-3 pipeline runs ahead of machine time, in CPU M-cycles.
`P = 0` on `main`, `P = 1` under the bundle.

**Every disputed row moves with `M3_PIPE_AHEAD` and nothing else.** The full
2x2x2 grid over the trio, one build per cell, all five CGB frames plus both
daid devices plus both strikethrough devices:

| knob | `cgb-acid-hell` | daid-GBC revD | daid-DMG | strikethrough dmg / cgb | mealybug `tile_sel` x4 |
|---|---|---|---|---|---|
| `STAT_M2_LEAD` | — | — | — | — | **breaks** (21972…) |
| `LY0_PIPE_MCYCLES=0` | — | — | — | — | breaks by 8..32 px |
| **`M3_PIPE_AHEAD`** | **23040→23038** | **20736→23040** | **exact→20848** | **23040→23033 both** | breaks (21572…) |

So `STAT_M2_LEAD` and `LY0_PIPE_MCYCLES` are *only* the corpus's compensation
pair — they exist to keep the M2-synced mealybug frames still while `P` moves,
and they touch nothing else in this set. The coordinating hypothesis that
daid-GBC's +4 might come from the line-0-scoped `LY0_PIPE_MCYCLES` (which would
have dropped the global term out of the algebra) is **refuted**: that knob moves
daid by 0 pixels at either setting.

**The fetch grid and pixel emission are the same axis, so there is no depth
degree of freedom.** The proposed escape was a world with the grid 8 dots early
and emission only 4 — one extra fetch-cycle of lead, a deeper FIFO — which would
put `cgb-acid-hell` at `D = 8` (plain reset rule) while leaving daid at +4. It
is not expressible and the renderer says why: `m3_lead` delays fetch and shift
*together*, and `M3_PIPE_AHEAD` advances them together, so the two knobs are one
quantity with opposite signs. Measured rather than read off the source —
`M3_PIPE_AHEAD=1` with `M3_PIPE_DELAY=6` (advance 4 dots, delay 4 dots) returns
**every witness to its `main` value**: acid-hell 23040, daid-GBC 20736, daid-DMG
exact, strikethrough 23040/23040. They cancel exactly, which is what "one axis"
means. (It is also what the hardware says: the BG FIFO drains one pixel per dot
and fills eight per fetch, so the fetcher cannot sit a whole extra fetch ahead
in steady state.)

**daid-DMG did not move to another accepted variant — it broke.** The shootout
accepts any of `ppu_scanline_bgp_{0,1,2}.dmg.png` and the runner already scores
the best of the three, but scored separately the row reads:

| build | vs `_0` | vs `_1` | vs `_2` |
|---|---|---|---|
| `main` | 22576 | **23040** | 22576 |
| `P = 1` | 20848 | 20384 | 20272 |

Further from all three, not nearer a different one.

**The witness table, and the two-sided bracket.** `P` swept with everything else
held (the `P = 2` column carries `STAT_M2_LEAD=2` so the corpus stays scoreable;
`P = -1` is `M3_PIPE_DELAY=6`, the pipeline four dots LATE):

| row | `P = -1` | `P = 0` | `P = 1` | `P = 2` |
|---|---|---|---|---|
| `strikethrough-cgb` | 23033 | **23040** | 23033 | 23033 |
| `strikethrough-dmg` | 23033 | **23040** | 23040\* | 23040\* |
| `cgb-acid-hell` | 23038 | **23040** | 23038 | **23040** |
| daid-GBC `revD` | 18432 | 20736 | **23040** | 20736 |
| daid-DMG (best of 3) | 20848 | **23040** | 20848\* | 20848\* |
| mealybug `tile_sel` x4 | — | **23040** | 23040 | 23024/23011/23024/23040 |

(\* the DMG rows are shown under the device-gated build below, which is the only
way they and daid-GBC can be read in one column at all.)

Read the first four rows: **`strikethrough-cgb` is right only at `P = 0` and
daid-GBC `revD` only at `P = 1`, and both are bracketed from both sides.** That
is the contradiction, it is two rows, and they are the same device measuring the
same quantity — so no device split, no glitch rule, no halt phase and no
revision flag can reconcile them. `cgb-acid-hell` is a third witness on
`strikethrough`'s side of it (right at 0, and again at 2 where daid-GBC is
equally wrong), which is the `D = ±4` dead zone of the entry above seen from
the pipeline end instead of the halt end.

**The device split is real, is worth having, and does not help here.** daid's
two devices want different values of the same number — DMG `P = 0`, CGB `P = 1`,
one ROM — which is exactly the shape this tree already models per device
(`WIN_TAIL`), so it is built rather than argued about: `M3_PIPE_AHEAD_CGB` in
`fifo_ppu.nim`, CGB-only, added to the device-independent term. At 1, alone:

* **the whole DMG side is rescued** — daid-DMG exact against `_1` again,
  `strikethrough-dmg` 23040;
* daid-GBC `revD` is 23040;
* and `strikethrough-cgb` (23033) and `cgb-acid-hell` (23038) are still wrong,
  because they are CGB rows and the CGB side is where the contradiction lives.

It ships at 0 for that reason. The corpus needs `STAT_M2_LEAD` gated the same
way to be scored beside it; with the lead left device-independent the DMG
mode-2-synced families (`scy`, `scx_during_m3`, `m2enable`) pay for it and the
runner reads 752, which is a property of the half-applied gate and not of the
split.

**So the minimal contradiction, stated to be permanent:**

> `strikethrough-cgb` and daid `ppu_scanline_bgp` on CGB are both pixel-exact
> witnesses of the mode-3 pipeline's phase against machine time, on the same
> device, and they are two-sided at `P = 0` and `P = 1` respectively. No
> assignment of one number satisfies both, and `cgb-acid-hell` sides with
> `strikethrough` at 0.

What that rules out is a *global* pipeline phase, which is what every knob in
this family currently is. What it leaves open is finer structure inside the
consumers: `strikethrough` reads `P` through an OAM-DMA race (mode 2's scan
against the DMA unit's bus, which runs on machine time) and daid reads it
through pixel emission, so a world where the OAM scan keeps machine time while
pixel emission moves would satisfy both. That is not a knob today and this entry
does not claim it is derivable — it is the named place to look, and the ROM to
look with is `strikethrough`, whose 7 pixels are identical at `P = 1` and
`P = 2` (a boundary crossed, not a ruler) where daid's bands step linearly.

#### 2026-08-10: the LY 153 snapback edge is NOT device-split, and that closes the last door

The entry above rules out a global pipeline phase and leaves one narrow door,
because daid `ppu_scanline_bgp`'s phase-setting event is structurally unlike
every other witness's: it syncs on the **LYC = 0 STAT edge of the LY 153 -> 0
snapback** (the `LYC_SETTLE_DOTS` window in `ppu.nim`), and nothing else in the
bracket observes that edge at all. `strikethrough` syncs on LYC = 67,
`lycirq_m2stat` and `hdma_late_disable` on LYC = 1, `cgb-acid-hell` on LYC = N
of a normal line (measured, `-d:gb_stat_src_trace`), the corpus on mode 2, the
sleds on normal-line LYC. So "on CGB the snapback edge rises one M-cycle later
than on DMG" would hand daid-GBC its +4 in TODAY's shipping world and, by
construction, move nothing else. **It is refuted, from both sides, by CGB rows.**

**The +4 is exactly expressible at that edge, and both devices are two-sided on
it.** `LYC_SETTLE_DOTS` moves precisely this edge, so no new code is needed to
ask: the relatch dot is `LY153_SNAP_DOT + LYC_SETTLE_DOTS`, 5 + 4 = **9** today.

| relatch dot | daid-GBC `revD` | daid-DMG (best of 3) |
|---|---|---|
| 5 | 18432 | 20848 |
| **9** (ships) | 20736 | **23040 exact** |
| **13** | **23040 exact** | 20848 |

One M-cycle apart, each pixel-exact at its own value and wrong at its
neighbour's — the cleanest possible statement of what the hypothesis wanted.

**And the witness sweep kills it.** Because `LYC_SETTLE_DOTS` is
device-independent, moving it moves BOTH devices, so every `[cgb]` row that
breaks is a row pinning the CGB edge. Whole gambatte suite, one build per dot:

| relatch dot | CGB rows that break |
|---|---|
| 5 | `ly0/lycint152_lyc0flag_1 [cgb]`, `ly0/lycint152_lyc0irq_1 [cgb]`, `..._flag_ds_1 [cgb]`, `..._irq_ds_1 [cgb]` (+ `ifw_ds_1`, `late_retrigger_ds_1`, `lycEnable/lyc0_ff4{1,5}_disable_ds_1 [cgb]`) |
| **9** | **none** |
| 13 | `ly0/lycint152_lyc0flag_2 [cgb]`, `ly0/lycint152_lyc0irq_2 [cgb]`, `..._flag_ds_2 [cgb]`, `..._irq_ds_2 [cgb]` (+ `lycEnable/lyc0_ff41_disable_ds_2 [cgb]`) |

The `_1` members refuse dot 5 and the `_2` members refuse dot 13, so **dot 9 is
bracketed from both sides on CGB alone** — the DMG arms of the same ROMs are not
needed for the argument and agree anyway. The `_ds_` members are CGB
double-speed and bracket it there too, which independently re-confirms this is a
fixed PPU-dot count rather than an M-cycle.

**The filenames make the silence informative rather than merely absent.**
gambatte encodes per-device expectations in the name, and these ROMs carry ONE
value for both: `lycint152_lyc0flag_2_dmg08_cgb04c_outC5`,
`lycint152_lyc0irq_2_dmg08_cgb04c_outE2`. The convention is perfectly capable of
splitting — `lycEnable/lyc0_m1disable_2_dmg08_outE2_cgb04c_outE0` splits, in the
same suite, on the same edge family — so "DMG and CGB expect the same value
here" is a positive statement of hardware behaviour, not a gap in coverage.

So: **daid-GBC demands the CGB snapback relatch at dot 13; four CGB gambatte
rows demand dot 9 and pass there today.** Same device, same edge, two-sided.
The door is shut and nothing was built, because there was nothing left to build.

*(Item 4, for the record: at dot 13 daid-GBC is 23040 at `--cgb-rev=D` and 22464
at `revC` — 576 pixels, one pixel at each of 8 band boundaries, which is the
CGB-C -> CGB-D palette step. The revision knob really is the remaining -1, so
the composition the hypothesis proposed was arithmetically right. Only the
device split it needed is false.)*

#### Where the acid-hell / daid / strikethrough axis now stands, and the one alternative left

Three doors have been opened and shut, each with a two-sided bracket:

| candidate | refuted by |
|---|---|
| a uniform CGB halt phase (`CGB_HALT_PPU_LEAD`) | `hdma_late_disable` vs `lycirq_m2stat` sharing a wake (`d8ef3b1`) |
| a global pipeline phase (`M3_PIPE_AHEAD`, device-gated or not) | `strikethrough-cgb` (P=0) vs daid-GBC (P=1), both CGB |
| a device-split snapback edge (`LYC_SETTLE_DOTS`) | `ly0/lycint152_lyc0{flag,irq}_{1,2} [cgb]`, dot 9 both sides |

And a per-source wake phase (`STAT_LYC_LEAD`) is refuted by six GBMicrotest LYC
sleds, and a second M-cycle of OAM lead (`STAT_M2_LEAD=2`) by that bucket's own
sled. What survives all of it is the **one documented alternative**, restated
here so the record carries it in one place:

> **The consumers may not share one phase.** `strikethrough` reads the pipeline's
> position through an OAM-DMA race — mode 2's OAM scan against the DMA unit's
> bus, which runs on machine time — and daid reads it through pixel emission.
> A world in which the OAM scan keeps machine time while pixel emission moves
> one M-cycle satisfies both, and it is not expressible today: `M3_PIPE_AHEAD`
> and `m3_lead` both move the whole pipeline, and they cancel exactly
> (measured: `M3_PIPE_AHEAD=1` with `M3_PIPE_DELAY=6` returns every witness to
> its `main` value).

Two things about that alternative are already known and worth keeping with it.
It has a **signature**: `strikethrough`'s 7 pixels are identical at `P = 1` and
`P = 2` — a boundary crossed, not a ruler — where daid's bands step linearly
with `P`, which is what "these two rows are reading different things" looks like
from the outside. And it has a **cost of entry**: separating the OAM scan from
the pixel pipeline is a structural change to the renderer, not a constant, so it
should not be attempted until some ROM other than `strikethrough` measures the
same separation. Until then `cgb-acid-hell`, `strikethrough-dmg` and
`strikethrough-cgb` are pixel-exact on `main` and daid-GBC is the one row this
axis owes, at 20736/23040 with `--cgb-rev=D`.

#### 2026-08-10 (addendum): the bracket was real and the CONCLUSION was wrong — three of these constants were reading the phase

**Everything above is left standing, because every measurement in it
reproduces. What was wrong is the inference.** The bracket was two-sided
because the sweep that drew it moved `M3_PIPE_AHEAD` while holding fixed three
other constants that are each `f(pipeline phase) + a hardware delta`. Move the
phase and they go stale, and their witnesses go red for a reason that has
nothing to do with the phase being wrong. Shipped as `CGB_PIPE_MCYCLES = 1`
with its three dependants moved with it; runner 769 -> **770**, gambatte
3876 -> **3940 (+64)**.

| constant | why it moves with the phase | new value |
|---|---|---|
| `OBJ_DMA_BUS_LEAD` | it IS "the phase between the pipeline and the bus", by its own note — the DMA unit is on machine time, so an earlier fetch must look an M-cycle further ahead | 1 (+1 on CGB) |
| `LY0_PIPE_MCYCLES` | it is a DIFFERENCE between line 0 and its neighbours, so it must not STACK with a term every line now has | `max`, not `+` |
| `STAT_M2_LEAD` | not a compensation — the mode-2 anchor's own M-cycle, which the whole mealybug corpus anchors on | 0 (+1 on CGB) |

**Which of the five refutations survive.** Three do, one is an artifact, one is
newly narrowed:

| candidate | status now |
|---|---|
| a uniform CGB halt phase (`CGB_HALT_PPU_LEAD`) | **stands.** Refuted on its own witnesses (`hdma_late_disable` vs `lycirq_m2stat`), which this touches at all — that family is byte-for-byte unmoved here. daid did not need it |
| a device-split snapback edge (`LYC_SETTLE_DOTS`) | **stands.** Refuted on its own CGB witnesses, dot 9 bracketed from both sides. Unmoved |
| `STAT_LYC_LEAD` (six GBMicrotest LYC sleds) | **stands**, untouched |
| `STAT_M2_LEAD = 2` (that bucket's own sled) | **stands**, untouched — the value taken is 1 |
| a global pipeline phase, refuted by `strikethrough-cgb` vs daid-GBC | **ARTIFACT.** `strikethrough` was never a witness of the phase; it is a witness of `phase + OBJ_DMA_BUS_LEAD`. With the sum held it is byte-identical to its pre-advance frame, all 23040 px |

**And the documented alternative — "the OAM scan may not share a phase with
pixel emission" — is refuted, twice.** (1) The mealybug corpus anchors on mode 2
and contains both a family measuring emission (`m3_bgp_change`) and a family
measuring the fetch grid (`m3_lcdc_tile_sel_change`), both exact; one anchor
cannot move for one and not the other. (2) Neither SameBoy nor DocBoy has an
output stage — both run fetch and emission off one counter and one dot, and
DocBoy indexes the object trigger by `lx` itself. Nothing was restructured and
nothing needed to be.

**The signature was misread.** `strikethrough`'s 7 pixels being identical at
`P = 1` and `P = 2` was recorded as evidence that it reads a different quantity
from daid. It is the signature of a **saturated boundary crossing in a
stale compensation**: once the fetch's OAM read leaves the ROM's 4-dot window it
reads `$01` at any further offset, so the picture stops changing.

**What did NOT resolve, stated as the one open contradiction.**
`CGB_TDSEL_LATENCY` has two CGB witnesses that do not share an anchor —
mealybug `tile_sel` on mode 2 (wants 1) and `cgb-acid-hell` on LYC (wants 5) —
and one constant cannot be both. 1 ships: it costs `cgb-acid-hell` **2 pixels**
where 5 costs the four mealybug frames **3859**. See the next section, which
chased this to the bottom.

#### 2026-08-10: acid-hell's last chapter — the D=4 "no rule" proof, its real scope, and why the 2 pixels stay

This closes the narrative that ran from the `CGB_HALT_PPU_LEAD` work through
`CGB_TDSEL_IDX_DOTS` to the pipeline advance. Three findings, in the order they
matter.

**1. There is no SET-rule gap, and the claim that there was one is retracted.**
The previous entry read `tdselcells.py`'s trigger table wrong. On the
pre-advance tree the SHIPPING SET rule scores **223/223**. The 221/223 row is
`never` — the rule with `CGB_TDSEL_IDX_DOTS` deleted — and its two misses are
exactly the cells that *prove* that constant. The corpus JSON confirms it per
cell: acid-hell's `ly = 68` and `ly = 69` cells have `mine == hw` (85 and 73,
the tile index) against a latch of 93 and 65. dingbat was right about them all
along. Nothing needed refining.

**2. The two ROMs share an anchor, which is why the phase moves one and not the
other.** Both sources say so outright: `cgb-acid-hell.asm` sets `rSTAT = $40`
(LYC), `rLYC = 0`, `rIE = $02` and **halts**, then writes LCDC down a nop slide;
`ppu_scanline_bgp.asm` takes the same LYC=0 STAT out of `halt` and free-runs.
So `CGB_PIPE_MCYCLES = 1` moves the fetch grid under both ROMs' writes, and the
FDATA trace shows precisely that — on `ly = 68`, control has the LCDC.4 change
landing ON the plane-1 read dot (130/130, 138/138, 162/162, 170/170, 178/178,
186/186, `glitch = ±1`), and the advanced world has every read 4 dots earlier
with the changes unmoved, so `glitch = 0` everywhere and the substitution never
fires.

**This world is not new.** It reproduces the 2026-08-14 `CGB_HALT_PPU_LEAD=1`
census *exactly* — 408 cells, 216 SET / 192 RESET, 216/216 and 192/192,
`cgb-acid-hell` at 23038 whatever `CGB_TDSEL_IDX_DOTS` is set to. Two different
knobs, one displacement.

**3. The old "no rule exists at D=4" proof was narrower than it claimed, and the
wider question now has an answer too — the same one.** The wider question is
what `tools/gbppu/tdselphase.py` asks: for a change *d* dots from a read, does
hardware disturb it? Run in the advanced world it splits the one bucket that
could fix the row — `mapoff = 0`, read offset +4, RESET, 71 reads — by the
change *before* the previous one:

| `prev2off` | reads | hw wants INDEX | hw wants SGN | ROM |
|---|---|---|---|---|
| −32 | 7 | **7** | 5 | `cgb-acid-hell` |
| −24 | 32 | 0 | **32** | mealybug |
| None | 24 | 8 | **24** | mealybug |
| (prevdir −1) | 8 | 8 | **8** | mealybug |

Firing on the bucket buys acid-hell's 2 pixels and costs **64 mealybug reads**.
The only feature separating acid-hell's seven from the 32 hard refusers is
`prev2off = −32` against `−24` — one ROM's own fingerprint, on a context no
second ROM populates. **So no restatement reaches 223/223, and the minimal
contradiction is: any rule that fires where acid-hell needs it also fires on 32
mealybug reads that measure the opposite.**

**A cost the trade carries that is worth naming.** With acid-hell's seven cells
gone, `CGB_TDSEL_IDX_DOTS` has **no discriminating evidence left in the shipping
world** — `never` scores the same 216/216 as the shipping rule. The rule is
still believed, on the 223/223 world and the unchanged offset sweep, but nothing
in the tree can now falsify it. That is a real loss of coverage, and it is the
second half of the 2-pixel trade.

**`m3_lcdc_win_map_change`'s 34 pixels and `m3_lcdc_tile_sel_win_change`'s 98
are one mechanism, and both are 0 as of 2026-08-09.** Both are one 8x8 block at
`x = 0..7`, `y = 64..71` (tile_sel adds `x = 8..15`), which is band 8 — the one
band where the object's trigger pixel (`X - 8 = 0`) IS the window's start pixel,
because the ROMs run WY = 0 / WX = 7. It was read here as "the ® object drawn
where hardware loses it"; that is wrong, and the reference says so. Ours was a
solid BLACK 8x8 there and hardware's is the ® glyph over a WHITE window tile —
the object is drawn on both sides, and what differed was the window tile under
it. `tick_shifter` asked the object question first, so the window's first
tile-map read landed inside the ROM's 8-dot LCDC pulse (dots 105..112) instead
of before it.

**The rule is that the two triggers are ordered by COORDINATE**, and only the
tie changes hands: an object at `X - 8 < WX - 7` is fetched first (that is
every left-hanging object, `X` = 1..7 here, and it is what the current order
already did), one at `X - 8 == WX - 7` waits for the window's first tile to be
pushed. See `obj_yields_to_window` in `gb/fifo_ppu.nim` for the derivation off
both ROMs' `.asm` and both references, and for the two neighbouring spellings
the tile_sel reference refuses. Resolving the tie the other way for ALL objects
is still refused, and is still the measurement quoted below.

**Simply resolving the tie the other way is refused, and was measured out.**
Asking the window's start before the object trigger takes this row 34 → 318 and
the mealybug totals DMG 520109 → 519201 and CGB 1819207 → 1818393, so the
window start does NOT preempt an object fetch at the same pixel in general.

**What the tie rule cost was one open item, and it is closed (2026-08-09).**
The corner is `WX = 166` — the window's start pixel is the LAST pixel of the
line — and the tie rule alone gave it 190 dots on both devices, which took
`gambatte/m0enable` 153 → 147. Two constants close it, `WIN_TAIL_FETCH` and
`CGB_WIN_TAIL_LAST` in `gb/gb.nim`, and the whole derivation is written at the
second one. In short:

* a window START inside the tail holds mode 3 open for the fetch it restarts —
  it used to be absorbed by the pipeline's tail burst and cost nothing, which
  `window/m2int_wxA5_m3stat_1` catches on both devices;
* the DMG's mode 3 ends with the last PIXEL and the CGB's with the last FETCH,
  so only at `WX = 166` do the two part: DMG 174 dots, CGB 180. The four
  `m2int_wxA6_*_m3stat` families bracket that difference to **5..7 dots** and a
  BG fetch is six;
* an object whose trigger pixel is also `x = 159` is the same fetch slot, not a
  second one: both devices come out at 180 (174 + the object's own six), which
  is what the four `spxA7` mode-0 interrupt rows want.

gambatte 3793 → 3809, +17/−1 (see below), and the mealybug tie-rule wins are
untouched.

**The one row it costs, named.** `window/m2int_wxA6_scx5_m3stat_3` goes red on
CGB and its own family's `_ds_1` goes green. Same device, same WX, same SCX,
same measured mode 3 (185 dots) — only the sampling grid differs (4 dots single
speed, 2 in double), and the two want the CGB's extra to be ≤ 5 and ≥ 6
respectively. Six ships because six is a fetch; five is a fit at the same net
score and is refused. The residual is one dot on the double-speed sampling
grid, not on this constant.

**The two `obj_size_change` rows were not diagnosed** in this pass and did not
move (`m3_lcdc_tile_sel_win_change` was in this sentence too and is closed
above). `obj_size_change_scx`'s 30 pixels are
two 6-row bands at the very top and bottom of the frame (`y = 2..7` and
`y = 130..135`, `x = 27..31`) with the diff going both ways within a row, which
is the signature of a 16-pixel-tall object's row selection rather than of a
write dot; `m3_lcdc_obj_size_change` has the same shape plus a left-edge
component at `x = 0..2`.

### 2026-08-09: both `obj_size_change` rows are 0, on both devices

That reading of the shape was right and it is worth saying what it turned into.
An object fetch reads **LCDC.2 once per bitplane**, not once, and the two reads
are 2 dots apart — so a write between them gives the low plane one tile row and
the high plane another, which is exactly a diff that goes both ways inside a
row and only ever in the LOWER tile of an 8x16 object (the two heights agree on
rows 0..7 of an even tile index).

Both ROMs decode cleanly because BGP = `$00` makes the background white and
every object is tile `$4C` with `OBP0 = $E4`: each 16-line band is one object
read out as raw bitplane, so the reference names the pair *(height the low plane
used, height the high plane used)* per band outright. Against dingbat's own
merge dot `M` that gives, uniquely, **low plane on `M`, high plane on `M + 2`**
for an ordinary object — and something else for one hanging off the left edge,
where the fetch sits at the HEAD of the penalty instead of at its tail and both
reads land `t + 6` dots after the trigger whatever the wait is. The split
between the two is `idx < 0`, the same split `OBJ_BG_RUN = 4` derived from
`m3_lcdc_tile_sel_change`, and it is measured here rather than assumed: OAM
X = 7 refuses the tail arm's dots and X = 8 refuses the head arm's.

The `_cgb_c` references are the complement of the DMG ones band for band, and
solving them the same way gives one constant three dots in the same direction on
all six bands that separate the devices (`CGB_OBJ_SIZE_LATENCY`, the same shape
as `CGB_MIXER_LATENCY`). All four rows — two ROMs, two devices — are now
pixel-exact, the runner goes 719 → **723**, and nothing else moves: mealybug
goes 552101 → 552188 on DMG and 1856081 → **1856315** on CGB with only these
rows changing, gambatte is 3793/5005 row for row, `objtab.py` stays 0/153, and
`-d:gb_m3_len` over 1,216 ROM/device runs (both mealybug devices first, then
`sprites`, `window`, `scx_during_m3`, `m0enable`, `vram_m3`, `oam_access`) is
byte-identical for its whole 1,000,000-line budget — so mode 3 does not move by
a dot. The derivation, the sweep tables and what these ROMs cannot say are at
`OBJ_PLANE1_LAG` in `gb/fifo_ppu.nim`.

| | before | after |
|---|---|---|
| mealybug `m3_lcdc_obj_size_change` DMG | 57 wrong px | **0** |
| mealybug `m3_lcdc_obj_size_change` CGB | 114 wrong subpx | **0** |
| mealybug `m3_lcdc_obj_size_change_scx` DMG | 30 wrong px | **0** |
| mealybug `m3_lcdc_obj_size_change_scx` CGB | 120 wrong subpx | **0** |
| runner total | 719/981 | **723/981** |

The cost is one compare on the object-fetch path and nothing at all on the dot
loop: the redo hangs off `ppu_store_lcdc`, not off `tick_shifter`. Retired
instructions against `main`, min of several runs each: **−0.04%** on dmg-acid2
(the fast arm in `sprite_fetch_merge` more than pays for the extra state) and
**+0.07%** on blargg `cpu_instrs`, which never puts an object on screen at all,
so that figure is struct-layout drift and nothing else. Both are inside this
machine's ±0.1% spread on a loaded run and far under the 0.3% this file flags.

Two `GbFifoPpu` micro-optimisations reached for on the way here are **refused**
at this revision and are not shipped, which is worth recording because both look
obviously free: latching the CGB's share of the read dot in a new `int32` field
— to turn the object trigger's `if gb.cgb_enabled` into an add — costs
**+0.24%** on dmg-acid2, and moving the new field block to the end of the object
to win that back is a wash (−0.005%). The trigger is not on the dot loop; the
field is. Layout beats the branch, both times.

### Two more mid-mode-3 rules, and the ones next to them

**`m3_wx_6_change`'s remaining 4611 pixels** were read as the same sentence of
mealybug's PPU notes as `m3_lcdc_win_en_change_multiple_wx`'s 343 — *"If WX has
been updated correctly and WIN_EN is set again then the PPU stops drawing the
background, and will activate the window again, but it will start drawing the
**next row** of the window, on the same scanline"* — with the open question
being whether a bare WX re-trigger advances the row or only a full
re-activation through WIN_EN does.

**That reading was wrong, and the hardware photographs say what is.** It is not
a re-trigger at all: `m3_wx_6_change` re-triggers on no line of the frame (the
WX = 80 write lands at dot 189 and the shifter passed lx = 72 at dot ~157). The
whole 4611 was one extra increment of `current_window_line` at the TOP of the
frame, on LY 6, which hardware performs and we did not — after which every
window row we drew was the row above hardware's, for 90 scanlines. Fixed at
`WIN_START_PRE_PIXEL` (see below); the row is **0**, and
`m3_lcdc_win_en_change_multiple_wx` did not move, so the two were never the same
mechanism.

## The hardware photographs: what they say, and how much they can say

**The primary source nobody had read.** mealybug's `expected/` PNGs are Beaten
Dying Moon's *output* — the suite README says "screenshots from my Game Boy
emulator (which I believe to be correct)" — and the only hardware evidence it
ships is `photos/<device>/*.jpg`, "blurry photos of the ROMs running on real
devices".

**The 21-of-24 claim holds exactly.** At `mattcurrie/mealybug-tearoom-tests`
`70e88fb`, `photos/DMG-blob` has 21 JPEGs against 24 PNGs in
`expected/DMG-blob`; the three missing are `m2_win_en_toggle`,
`m3_scx_high_5_bits` and `m3_scy_change`. `photos/DMG-CPU B` adds three more but
of rows already covered, and `DMG-CPU B` is not the device the shootout scores.
Of the 16 DMG rows that were red, **15 have a photo** — only `m3_scy_change`
does not.

`tools/gbphoto` recovers a 160×144 grid of shade indices from one of these; its
README has the pipeline, the three validation tests and the limits. The two
numbers to keep: **adjudication power 87–100% per row, median ≈ 95%** (the
accuracy of the actual decision procedure on a manufactured one-pixel scanline
slide, which is the shape of every failure here), and read-back error **0.03–2.6%
on flat-content rows, 9–22% on the three that are a full page of
one-pixel-stroke glyphs**.

### Every failing DMG row: hardware agrees with the reference

Disputed cells only — the cells where dingbat and the `_dmg_blob` reference
differ — with the model's own residual as the noise unit:

| row | disputed | hardware ≈ reference | at > 2σ | strongest region |
|---|---|---|---|---|
| `m3_wx_6_change` | 4611 | 79.4% | 79.4% | 4514 of 4611 cells by region, ratios 1.5–230× |
| `m3_lcdc_bg_en_change` | 2193 | 89.8% | 94.5% | 161 cells, ratio 50× |
| `m3_bgp_change` | 820 | 81.2% | 83.8% | 387 cells `x = 153..159` |
| `m3_lcdc_tile_sel_change` | 776 | 75.0% | 75.7% | 332 cells, ratio 65× |
| `m3_window_timing_wx_0` | 652 | 94.2% | 95.4% | all 652 one region, ratio 7.6× |
| `m3_bgp_change_sprites` | 536 | 90.1% | 94.6% | 64 cells, ratio 85× |
| `m3_lcdc_win_en_change_multiple_wx` | 343 | 93.6% | 96.8% | 244 cells, ratio 19× |
| `m3_lcdc_bg_map_change` | 192 | 75.5% | 87.7% | all 192 one region |
| `m3_lcdc_tile_sel_win_change` | 106 | 92.5% | 92.5% | 98 cells, ratio 51× |
| `m3_lcdc_obj_en_change_variant` | 102 | 95.1% | 96.0% | 96 cells, ratio 25× |
| `m3_lcdc_obj_size_change` | 57 | 98.2% | 98.2% | every region, ratios 4.6–203× |
| `m3_lcdc_win_map_change` | 34 | **100%** | 100% | one region, ratio 77× |
| `m3_lcdc_obj_size_change_scx` | 30 | 96.7% | 96.7% | both regions, 6.6× and 38× |
| `m3_window_timing` | 29 | 86.2% | **100%** | 15 cells, ratio 63× |
| `m3_lcdc_obj_en_change` | 2 | **100%** | 100% | ratios 610× and 2930× |

**There is no row where hardware sides with dingbat.** The per-cell percentages
never reach 100% because a photograph cannot read an isolated pixel, but every
one of the 44 connected disputed regions larger than 15 cells lands on the
reference except one, and that one is explained below. So the long-open question
is closed: **the references are sound and the residuals are ours.**

### The one region that did not, and why it is not a conflict

`m3_lcdc_tile_sel_change` has three disputed regions of nearly the same size and
shape. Two land on the reference at ratios of 65× and 7.3×; the third — 320
cells at `y = 0..39`, `x = 8..15` — lands on dingbat at 1.2×, split 131/189.
That region is the only one of the three where the two hypotheses differ by
**shade 3 against shade 2**, and on this panel those are the closest pair by
some way (fitted levels 0.740 / 0.662 / 0.563 / 0.518 — the 2↔3 gap is 0.046
where 0↔1 is 0.078). Its discriminating power is **2.15σ** against 7.98σ for the
`0`-vs-`2` region next to it. A near-even split at 2σ on the pair the panel reads
worst is the pipeline's floor, not a disagreement with the reference, and it
should not be reported as one.

### `WIN_START_PRE_PIXEL`: the window comparator has a slot left of pixel 0

The row the photos made actionable. `m3_wx_6_change` writes WX = 6 in mode 2
(dot 49), WX = LY at dot 93 and WX = 80 at dot 189, with WY = 4 and SCX = 0; the
shifter's first dot is 94, so the value the comparator sees at its first slot is
LY. Decoding the frame's tiles against the ROM's own font:

| LY | WX at dot 94 | WX − 7 | hardware |
|---|---|---|---|
| 4 | 4 | −3 | background, no window |
| 5 | 5 | −2 | background, no window |
| 6 | 6 | **−1** | **window, whole line** (W row 0) |
| 7 | 7 | 0 | window, whole line (W row 1) |

`−1` fires and `−2` does not, on adjacent scanlines of one frame with everything
else equal — a two-sided bracket on a single slot. The comparator's counter runs
one lower than the emitted-pixel index, which is what "the window's first pixel
is at screen x = −1" means physically. It is **not** a `>=`: a `>=` would fire at
WX = 4 and 5 too, and the table says hardware does not. Shipped as a clamp in
`fifo_arm_window`, which runs on register writes only, so the mode 3 dot loop is
untouched (retired instructions 0.24% *lower* on blargg cpu_instrs, `cycles=`
identical).

It also disposes of the standing worry that `WIN_LINE_START_WX = 7` might be the
real answer: it cannot be, because this ROM's mode-2 write puts WX = 6 at the
mode 2 → 3 edge of **every** line ≥ 4 and the reference draws no window on LY 4
or 5. The line-head rule reads WX at the edge and stays at 6; this one reads it
at the shifter's first dot.

### The two rows this pass traded, and why neither refutes its change

`WIN_START_PRE_PIXEL` costs GBMicrotest **`win6_b`** and the SCX discard above
costs **`win0_scx3_b`**. Runner 978/703 → 978/702; gambatte 3656 → 3658, so the
ROM count is +1 and the row count is −1 (gambatte is one aggregate row).

Both are the same story, and in both cases the row's own `_a` sibling is what
says the new mode-3 length is right:

| ROM | `_a` reads at | `_b` reads at | hardware's mode 0 must start in | so mode 3 is | was | is |
|---|---|---|---|---|---|---|
| `win6` | cc 257, wants 3 | cc 261, wants 0 | [256, 259] | 176..179 | 174 ✗ | **178 ✓** |
| `win0_scx3` | cc 261, wants 3 | cc 265, wants 0 | [260, 263] | 180..183 | 178 ✗ | **183 ✓** |

(Hardware samples the mode bits at `cc − 2`, bracketed both sides — see the
mode-0 latch section above.) In each case the old length sat **outside** the
bracket and the new one sits inside it. What reddens the `_b` half is bucket 15:
we sample no earlier than `cc − 5`, so at `cc − m0` of 2..4 we answer `0x83`
where hardware answers `0x80`. That is the same signature and the same twenty
siblings as the `win{0,1,2,7..15}_b` rows already in that bucket, and both of
these come back for free when it lands. Neither should be read as evidence
against the change that exposed it.

**`win6_b` in detail — the row's own sibling says the trade is right.**
GBMicrotest `win6_b` goes red. mode 3 at WX = 6 moves 174 → 178, and the `_a`/`_b`
pair brackets it: `win6_a` reads STAT at `cc = 257` expecting mode 3, `win6_b` at
`cc = 261` expecting mode 0, so hardware's mode-0 start is in `(255, 259]`, i.e.
a length of 176..179. **178 satisfies both siblings and 174 satisfies neither** —
at 174 the `_a` read sits 3 dots past the mode-0 edge and would have to read 0,
and the ROM expects 3. The new length also puts `win6` exactly on `win7`: same
178, same PASS/FAIL pair. What reddens `win6_b` is bucket 15's readback lag, the
same `0x83` vs `0x80` signature as the twenty other `win*_b` rows, surfacing on
one more row because the mode-3 end moved into the window where it shows. Fix
bucket 15 and it comes back on its own.

### What the photos say about the rows still open

* **`m3_window_timing_wx_0`: fixed, 652 → 4.** A line that starts as a window
  line was discarding `7 - WX` for the window's own fine scroll and **nothing at
  all for SCX**, so mode 3 was independent of `SCX & 7` on exactly those lines.
  That ROM is a ruler for it — WX = 0, `SCX = LY`, BGP driven black at a fixed
  dot — and the reference's stair (11, 9, 8, 7, 6, 5, 4, 3 against our flat 11)
  reads the missing dots off directly. Derivation, the ROM's own header sentence
  that supplies both terms, and the three independent cross-checks at
  `fifo_sample_smooth_scroll`. **All four remaining pixels are on LY = 0**, the
  `line_0_fix` line — i.e. bucket 0 (`LY0-RESYNC`), which is an unusually clean
  confirmation of that bucket's framing from a row that was never counted in it.
* **`m3_window_timing`: fixed, 33 → 0 on both devices** (2026-08-09), in two
  halves that turned out to be independent. Hardware backs the reference
  throughout (86.2%, and 100% of the cells above 2σ). The reference is *pinned*
  at black-start x = 3 for LY 0..10, ramps 4..9 for LY 11..16 and is pinned at 9
  thereafter; ours ramped 3..8 across LY 1..6 where hardware is flat, and its own
  ramp ran two lines late. The **ramp's two-line lag** was the mixer tail counted
  in emitted pixels instead of dots (`MIXER_TAIL_DOTS`, 12 px, and the section
  at the end of this file). The **flat part** was the sharp claim it looked
  like: for WX = 1..6 the window's own fine-scroll discard costs no dots of its
  own, because it is paid out of the window's six-dot startup fetch
  (`WIN_HEAD_ABSORB`). It could not simply be deleted — `m3_wx_4_change` and
  `m3_wx_5_change` need the discard for their pixel *alignment* — so what moved
  is where the dots are spent, not the discard. LY 0 needed a third thing: WX is
  read at the end of the head's throw-away fetch, not at the mode 2 → 3 edge
  (`WIN_LINE_START_LATCH`), because this ROM writes WX *inside* mode 3 and the
  edge was still reading the previous line's 144.
* **`m3_bgp_change`'s ~800 is real.** Hardware backs the reference on 81.2% of
  its disputed cells and on 736 of 820 by region, and on `m3_bgp_change_sprites`
  at 90.1% — so the residual that makes those two "not a reliable vote" on
  `MIXER_PALETTE_BACK` is a defect of ours, not an artefact of the reference.
  The vote can be re-taken once it is found; it cannot be dismissed.
* **`m3_lcdc_win_map_change`'s 34 pixels are 100% hardware-confirmed at a 77×
  ratio.** The object really is absent on hardware. The `wx < 7` mode-2 special
  case named above is still where to look.
* **`m3_scy_change` (417) has no photograph** and is the only red DMG row that
  cannot be adjudicated this way. Its mechanism is written down in mealybug's own
  PPU notes instead ("SCY is read during the background tile fetch B, 0 and 1
  stages" on DMG and CGB ≤ C, B only on CGB D and AGB), which is a better source
  than a photo would have been — and the ROM turned out not to need a verdict at
  all, because its reference **inverts** into the (B, 0, 1) triple the fetch saw.
  That is how the row closed; see `docs/gb-mealybug-sources.md` §3.4 and
  `M3_THROWAWAY_DOTS`.

### What the mixer tail does not explain, and what it costs

`m3_bgp_change` is BGP written across the whole of mode 3 with **no objects on
the screen at all**, which is why the `M3_PIPE_DELAY` write-up uses it as the
pipeline's phase instrument. It went 1508 → 820 wrong pixels and is still the
largest mid-mode-3 residual in the DMG set, and it is the one row that argues
against the second mixer stage: it and `m3_bgp_change_sprites` prefer ONE stage
for the BG palette by 22 and 136 pixels, where `m3_window_timing` prefers two by
130 and `m3_lcdc_obj_en_change_variant` by 110. Two ships because the structure
says one palette read is one stage whichever palette it is, and because it is
+190 DMG pixels and free on CGB — but **until that ~800-pixel residual has a
name, `m3_bgp_change` is not a reliable vote on this dot**, and it is the next
thing to look at in this area.

`daid/ppu_scanline_bgp-dmg` moved the wrong way with it, 73.2% → 68.4%, red
either way. It shares exactly that mechanism (mid-mode-3 BGP), so it is the
same open question rather than a second one, and it should be re-scored
whenever the residual is understood.

**Resolved 2026-08-08, and the vote is re-taken.** The residual had two names,
both read off the ROM's source rather than off its pixels (see
`docs/gb-mealybug-sources.md` §3.2):

1. **The transition pixel.** A DMG palette write puts one pixel of `old or new`
   at the far end of the mixer tail. `m3_bgp_change` has all-zero VRAM, so its
   frame is BGP bits 1:0 sampled once per dot, and run-lengthing it gives a
   three-valued edge at every one of the six writes on every one of the 144
   lines. `MIXER_PALETTE_OR` ships it: 820 → 403 and `_sprites` 536 → 124,
   `age/m3-bg-bgp-dmgC` 62 → 2, `daid/ppu_scanline_bgp-dmg` 68.4% → 68.8%.
2. **The line end.** All 403 that remain are `x = 157..159`. The handler's last
   BGP write lands on dot 253, the first dot of mode 0, and
   `fifo_recompose_last` was guarded on mode 3 — but hardware clocks the line's
   last pixels out of the mixer during H-Blank and that write reaches all three.
   **Closed 2026-08-09 by `MIXER_TAIL_HBLANK`; 403 → 21, and all 21 left are
   LY 0.** See below.

### 2026-08-09: the line end, and what it took

Relaxing the mode-3 guard is not the fix on its own, and the reason is worth
stating because it is the whole of the change. Two facts about dingbat's own
timing, both off `-d:gb_m3_trace` on `m3_bgp_change`:

* the shifter emits pixel `x` on dot `x + 94`, so `lx = dot − 94` through the
  whole of mode 3 — which is what makes the reference's `dot − 96` edge come
  out as `lx − MIXER_PALETTE_BACK`, i.e. why `lx` can stand in for the dot;
* mode 3 ends on dot **252**, and `fifo_burst_tail` emits the last `m3_lead`
  pixels (158 and 159) *on that one dot*. It is the only dot of the line where
  the shifter is not one pixel per dot, and after it `lx` is 160 and says
  nothing about where the shifter would be.

So the seventh write, on dot 253, has to be answered with a shifter position of
**159**: 157 is the far end of the tail (the `old or new` pixel), 158 is inside
it, and 159 has not been emitted at all yet on hardware — it takes the new
palette because it is emitted *after* the write. That is exactly the
reference's three-valued edge at `x = 157`, and it needs two things a countdown
from `lx` cannot give: a position that keeps counting after `lx` stops
(`tail_dot0 = cycle_counter − lx`, latched at the burst), and a repaint that
reaches **forward** to the pixels the burst decided early. The held-pair ring
goes from 2 entries to 4 to cover columns 156..159.

Nothing about the mode 3 → 0 edge moves — no dot, no lock, no STAT source —
which is why this is not a `M3_END_EARLY` after all: bucket 15's dozens of rows
do not see it. Measured, full runner, against `-d:MIXER_TAIL_HBLANK=0`:

| row | before | after |
|---|---|---|
| mealybug `m3_bgp_change` | 403 | **21** (all LY 0) |
| mealybug-cgb `m3_bgp_change` | 790 | **60** (= 20 px × 3 ch) |
| gambatte `dmgpalette_during_m3_2` | 429 | **3** |
| gambatte `scx3/dmgpalette_during_m3_1` | 286 | **2** |
| gambatte `dmgpalette_during_m3_scx2_1` | 143 | **1** |

and **nothing else in the tree moves at all**: gambatte 3658/5005 row for row,
the mealybug DMG and CGB sets pixel for pixel on all their other rows, the whole
runner 704/980 with two rows improved and none regressed. The three gambatte
rows are the independent confirmation — a different suite, different references,
a BGP write that happens to land at the top of H-Blank, and the same fix takes
two of them to within 3 pixels of green.

The 21 that remain on `m3_bgp_change` are **all on LY 0**, four pixels wide at
every edge — the `line_0_fix` item named a section above ("A fourth thing the
sources say and this pass did not act on"), i.e. bucket 0. That is a second row
confirming it, after `m3_window_timing_wx_0`'s last 4. `m3_bgp_change_sprites` does not move (124, its left-edge mechanism),
and `daid/ppu_scanline_bgp-dmg` does not either: **it never writes BGP in mode 0
at all** (41760 mode-3 writes, 83 in vblank, 3 in mode 2, traced), so the
prediction that it shares this mechanism is falsified. Its residual is 12-wide
blocks with 4-wide gaps running the full width of the line — an M-cycle-grain
error in a tight write loop, and a separate question.

**Closed 2026-08-09, and it was not a mixer question at all.** Decoding the ROM
is the whole of it: its handler is ten `ld [c],a` at four M-cycles apart
followed by 70 `nop`s and a `jp`, which is **exactly 114 M-cycles = one
scanline**, so the frame is a picture of where the handler *started* and every
pixel of it inherits that one phase. The phase is re-pinned once a frame by the
LYC=0 STAT interrupt, and that interrupt was 456 − 12 dots late — see bucket 20
and `LYC_SETTLE_DOTS` in `gb/ppu.nim`. The 12-and-4 pattern was a whole line of
error, not an M-cycle of it: the picture was one line up and twelve pixels left,
which run-lengths alone cannot tell apart from a 12-dot slip. The row is now
**pixel-exact** against `ppu_scanline_bgp_1.dmg.png`, the OR-variant reference,
which is the one this tree's `MIXER_PALETTE_OR` predicts it should match.

With (1) fixed, **the two rows that argued against the second mixer stage now
argue for it**, and the vote across the palette rows is unanimous. One build per
setting, wrong pixels of 23040:

| row | `MIXER_PALETTE_BACK=1` | `=2` (shipping) |
|---|---|---|
| `m3_bgp_change` | 1209 | **403** |
| `m3_bgp_change_sprites` | 748 | **124** |
| `m3_obp0_change` | 42 | **0** |
| `m3_lcdc_obj_en_change_variant` | 212 | **102** |
| `m3_window_timing` | 159 | **29** |
| `m3_window_timing_wx_0` | 146 | **4** |

Before the OR pixel, the first two preferred **one** stage by 22 and 136. The
"second mechanism" was what inverted them, and the constant never needed to
move.

### The same cart on CGB: 3 pixels, and they are two different things

`daid/ppu_scanline_bgp.gb` run `--cgb --color` against the shootout's
`ppu_scanline_bgp.gbc.png` is **92.50% (1728/23040 wrong)**, and the error is
the cleanest shape in this document: every band boundary of every line sits at
`16k − 2` where the reference puts it at `16k + 1`. A uniform **3 dots early**,
144 lines, no exceptions. The row is not wired up (see `build_shootout_tests`);
this is what it would score.

The ROM is decoded above — one free-running 456-dot handler, ten `ld [c],a`
sixteen dots apart, the whole frame inheriting the phase the LYC=0 STAT
interrupt sets. So a uniform 3 is either 3 dots at the handler's entry or 3
dots at every write. **It is neither, and it cannot be either**, for one reason
each:

* 3 dots at the **write** is refused by mealybug. Both carts are DMG carts on a
  CGB, both write BGP mid-mode-3, and `-d:gb_px_trace` puts their writes on
  known dots (daid's band `k` on dot `93 + 16k`, mealybug's `$12` on dot 97).
  The first pixel a write reaches is `dot − 94 − r`, and mealybug's CGB
  reference pins `r = 1` (`CGB_MIXER_LATENCY`) to the pixel — `m3_bgp_change`,
  `m3_bgp_change_sprites` and `m3_obp0_change` are all pixel-exact on the
  `_cgb_c` set at that value and all move off it at any other. daid's reference
  wants `r = −2`. The two cannot both be a property of the palette path.
* 3 dots at the **dispatch** is refused by arithmetic before it is refused by
  any ROM. mealybug's handler is a STAT interrupt too (`ldh [rSTAT], $20`, the
  mode-2 source, every line) and it is exact on CGB, so there is no general
  dispatch delta — and a CPU cannot move by 3 dots anyway. Every path into a
  handler ends on an M-cycle boundary, so a dispatch that changes at all
  changes by 4.

The 3 factors, exactly, into **+4 − 1**, and each factor was measured on its
own rather than fitted:

* **+4 — one M-cycle at the handler's entry.** Patching the ROM's `statInt`
  prologue `nop` into a one-byte two-M-cycle `ld a,[hl]` — the ROM's only
  `E1 FB 00 21` becomes `E1 FB 7E 21`, header checksum refixed — delays the
  whole frame by exactly one M-cycle and nothing else. That run scores
  **576/23040 wrong (97.50%)**, one pixel per band boundary, edges at `16k − 1`.
* **−1 — the CGB-C → CGB-D palette step.** `CGB_MIXER_LATENCY` is that step and
  mealybug ships both sides of it: at `=1` dingbat is **pixel-exact on
  `m3_bgp_change_cgb_c.png`** and at `=0` it is **pixel-exact on
  `m3_bgp_change_cgb_d.png`** (0 wrong, both verified; the two references
  themselves differ by 864 pixels, one per write edge on every line, with D one
  pixel earlier than C).

Put together: the patched ROM built at `CGB_MIXER_LATENCY=0` is **0/23040
wrong** against `ppu_scanline_bgp.gbc.png`. The decomposition is exact and
complete, and it says daid's capture is a **CGB-D-class device** — a later one
than the `_cgb_c` set this tree scores 27 mealybug rows against.

Neither factor ships.

The palette step does not because it is 27 rows against 1: at `=0` the CGB arms
go `m3_bgp_change` 100% → 96.7%, `_sprites` → 97.3%, `m3_obp0_change` → 99.8%,
`m3_lcdc_obj_en_change` → 99.7%, `_variant` → 99.1%. Picking the other side of
a revision to win one unwired row is not an accuracy gain, it is a different
machine.

The M-cycle does not because its own brackets do not hold, and the measurement
is worth keeping: it is `CGB_HALT_EXIT_MCYCLES` in `gb.nim`, shipping at 0. The
short version is that daid's CPU is **halted** when the LYC=0 interrupt arrives
(`vblankInt` ends `ei / halt`), which is what separates it from mealybug, and
gambatte has ten `halt/` ROMs whose file name states a different expected value
per device — all ten saying the CGB's post-halt read lands one boundary later,
across three unrelated boundaries, with dingbat answering DMG on all ten. At 1
those ten plus three `_ds_` members plus eight `dma/hdma_late_*` go green, and
**60 rows go red**: 42 `tima/*` (which halt, are woken by the timer, and have
ONE expected value for both devices — so the CGB does not SPEND the M-cycle,
because DIV and TIMA would advance through it) and 11 that are the same
`m0stat` ladder at SCX 2 and 5 where their SCX 3 and 4 siblings wanted it (so
part of the ten is really the CGB's mode 3 length against SCX). Net **−37
gambatte, 743 → 740** on a full pass. What is left is a CGB that is later than a
DMG out of a halt *without spending time*, which is a CPU-to-PPU phase and
belongs at the `lcd_offset` note, not here.

## 2026-08-09: the object fetch takes a TILE boundary, and the object picks it

The row above that said "not curable by any of the four `OBJ_BG_RUN` rules" was
right about the four rules and wrong about the shape of the answer. All four are
phrased on the fetcher's *phase* — which dots of the penalty it may advance on —
and the frame that has to be reproduced is not a function of the fetcher's phase
at all.

`m3_lcdc_tile_sel_change` proves that on its own. Its objects at OAM **X = 0**
and **X = 8** trigger on the same dot (94, the first push, which is what fills
the FIFO and lets the shifter ask the question), cost the same 11 dots, and
leave the fetcher on the same counter — and the DMG reference gives band 0 both
bitplane reads *inside* the 8-dot LCDC pulse and band 8 *neither*. Two identical
fetcher states, two different answers. What differs is the tile The Pixel is in.

Read all eighteen bands back that way and the rule is one sentence: **the
penalty is inserted after the fetch of tile `floor(X / 8)`**, and The Pixel of
an object at OAM X sits in tile `floor(X / 8) - 1`. The fetcher runs a tile
ahead of the shifter, so the boundary the object takes is the end of the fetch
that was in flight while The Pixel's own tile was on screen — Pan Docs' "waiting
for the BG fetch to finish", with the one-tile lead spelled out. In this
renderer's state that is `idx` at the trigger and nothing else:

* `idx >= 0` — The Pixel is in the tile the FIFO is displaying, so the fetch of
  the tile after it is in flight. It runs to completion inside the penalty and
  then parks, because a stopped shifter cannot empty the FIFO.
* `idx < 0` — an object hanging off the left edge (OAM X < 8). The fetch it
  waits for finished *on the trigger dot itself*, so the object takes the bus
  from the next dot for the whole penalty and the fetcher resumes one dot after
  the shifter does. **Band 4** (X = 4, penalty 7) is the only band in the suite
  that separates that dot, and it wants it.

Landed as `OBJ_BG_RUN = 4`, derived in full at `tick_sprite_fetcher` in
`gb/fifo_ppu.nim`. Wrong pixels of 23040, DMG:

| row | before | after |
|---|---|---|
| `m3_lcdc_bg_map_change` | 192 | **0** |
| `m3_lcdc_tile_sel_change` | 776 | **8** (all eight on LY 0, i.e. bucket 0 / the `line_0_fix` item above) |
| `m3_scy_change` | 417 | **83** |

Mealybug DMG 550274 → 551568 matching pixels, CGB 1852598 → 1854215, and no
mealybug row on either device loses a pixel except CGB
`m3_lcdc_bg_map_change`, 320 → 384. That one trade is entirely inside tile 1 of
bands 0–2 — band 0 fixed (64 px), bands 1 and 2 broken (128) — i.e. the band the
transition sits in moved by one, which is the CGB's own write latency and not
this rule: `-d:CGB_LCDC_LATENCY=1` takes that row 384 → **192** wrong, better
than it ever was, while costing 401 subpixels elsewhere and the gambatte
`window` rows the sweep at `CGB_SCY_LATENCY` already prices. It is a separate
decision with a separate bill, and the mechanism is the one mealybug's own PPU
notes state for SCY ("on CGB and AGB devices, writes appear to take effect
2 T-cycles later").

The regression surface, all of it measured:

* **mode 3's length does not move.** `tools/gbppu/objtab.py` against GBMicrotest
  `ppu_spritex_vs_scx` stays **0/153**, and 1660 ROM/device runs across gambatte
  `sprites`, `oam_access`, `vram_m3`, `scx_during_m3`, GBMicrotest and mealybug
  are line-for-line identical under `-d:gb_m3_len`. Per-object cost, the
  `172 + 11N` measurement and `NspritesPrLine`'s pass set are untouched.
* **gambatte 3658 → 3659**, one row: `scx_during_m3/scx_attrib_during_m3_spx1_ds`
  goes FAIL → PASS and its `spx2_ds` sibling 80 → 16 wrong pixels. `sprites`
  394/476, `oam_access` 52/69 and `vram_m3` 35/50 are unchanged row for row.
* mooneye `acceptance/ppu/intr_2_mode0_timing_sprites` **fails before and after**,
  unmoved.
* the exact rows stay exact: `m3_obp0_change`, `m3_wx_4_change_sprites`,
  `m3_lcdc_win_en_change_multiple`, and `m3_lcdc_obj_en_change` at its same 2.
* runner total 704 → **705**.

**Cost, named.** The run arm does the background fetch inside the object's stall
instead of after it, so `tick_bg_fetcher` is called on up to six dots per object
that the old rule skipped. Retired instructions, 2400 frames: Pokemon Blue
**+0.76%**, Shantae +0.41%, Pokemon Crystal +0.01%. All of it is the rule —
the same file with `-d:OBJ_BG_RUN=1` forced back on measures **−0.06%** against
the revision before it, so the plumbing (a `bool` result from
`tick_sprite_fetcher` so `tick_shifter` keeps a single call site) is free. Two
things bought 0.3 points of that back and are worth keeping in mind for anything
else on this path: skipping the call when the fetcher is parked at counter 7,
and refusing to add a field — `idx < 0` is `obj_tile_fx != fetcher_x`, which the
penalty algorithm already keeps, and a fifth `bool` in `GbFifoPpu`'s bool block
cost 0.10% on Crystal in layout alone.

**What it does not fix, and why that is now a duplicate.**
`m3_lcdc_tile_sel_win_change` is unchanged at 106, and the trace says it is not
this mechanism: 8 of its pixels are LY 0 and the other 98 are band 8 alone —
`y = 64..71`, tiles 0 and 1 — which is the **same** band, the same tile and the
same cause as `m3_lcdc_win_map_change`'s 34. Both ROMs run WY = 0 / WX = 7, so
`win_lx == 0`, and band 8's object (OAM X = 8) triggers at `lx == 0` too; the
shifter asks the object question first and the window start is deferred behind
a whole object fetch. That tie is the item already open above ("Simply resolving
the tie the other way is refused, and was measured out"), and the two rows
should be taken together by whatever settles it.

## 2026-08-09: the discarded fetch at the head of mode 3 is FOUR dots

`m3_scy_change`'s last 29 pixels were all in **tile 0** and all on
`LY ≡ 7 (mod 8)`, which is the one place SCY 0 and SCY 1 disagree about both the
map row and the row inside the tile. That is not a hint, it is the whole
measurement: this ROM's reference **inverts** (map `65 + row + col`, BGP
identity, SCX 0, blank objects), so each 8-pixel tile of it decodes exactly into
the triple (SCY at B, SCY at 0, SCY at 1) the fetch saw. Decoded, all eighteen
bands say the same thing — tile 0's `B` read takes the value written at dot 81
while both its bitplane reads take the one written at dot 89 — and dingbat had
tile 0 at B = 90, 0 = 92, 1 = 94.

It is **not** a shift of the head: tile 1's reads at 96/98/100 are already right,
so the gap from tile 0's map read to tile 1's is 8 dots on hardware where this
tree had 6. What decides it is the head's budget. Mode 3 is 172 at SCX & 7 = 0
and 160 of those are pixels, so the discarded fetch plus the first real one are
12 dots; writing the 8-step cycle `s B s 0 s 1 s push`, a discarded fetch of *n*
dots puts the first real reads at `d+n+1, d+n+3, d+n+5` and its push at `d+n+7`,
which has to be `d+11`. n = 6 puts `B` at 90 (the residual), n = 2 puts the `0`
read at 88 where the reference refuses it *and* cannot reach the push, and
**n = 4 satisfies every band**: B = 88, 0 = 90, 1 = 92, push at 94.

Shipped as `M3_THROWAWAY_DOTS = 4` (`gb/gb.nim`, derived at `tick_bg_fetcher`).
`-d:M3_THROWAWAY_DOTS=6` is the control build and reproduces the old numbers to
the pixel. The SCX fine-scroll latch moves with it — from "when the throw-away
fetch completes" to the `B` of the first `B01s` cycle, which is
`m3_scx_low_3_bits`' header verbatim and **the same dot**, 88, so that ROM's
two-sided bracket never moves.

| | before | after |
|---|---|---|
| mealybug `m3_scy_change` DMG | 29 wrong px | **0** |
| mealybug `m3_scy_change` CGB | 592 wrong subpx | **0** |
| gambatte `scy` | 61/67 | **67/67** |
| gambatte `scx_during_m3` | 43/141 | **49/141** |
| gambatte total | 3781/5005 | **3793/5005** |
| runner total | 716/981 | **719/981** |

Those are the only rows that move, in either direction, anywhere. The regression
surface:

* **mode 3's length does not move.** `-d:gb_m3_len` over all 5,005 gambatte
  ROM/device runs is byte-identical between the two arms — 2,000,000 lines — and
  `tools/gbppu/objtab.py` against GBMicrotest `ppu_spritex_vs_scx` stays 0/153.
* the whole runner is unchanged row for row apart from the four rows above;
  `results_mgba_suite.md` does not move at all.
* the six `scx_during_m3` rows gained are `scx_0060c0/_2`, `_3`, `_ds_2`,
  `_ds_3` and `scx_0063c0/_3`, `_ds_3`. They are **not** the seven that
  `LY0_PIPE_MCYCLES` traded (`scx_during_m3_spx0/1/2` and siblings); that item
  is still open.
* perf: retired instructions **−0.020%** (Pokemon Crystal CGB) and **−0.018%**
  (Link's Awakening DMG) — i.e. free, and slightly the right side of free. Both
  slots built off the same revision with
  `GBGATE_FLAGS_A=-d:M3_THROWAWAY_DOTS=6`, minimum of four runs each, `cycles=`
  identical in every pair. The change is two `bool` tests in `tick_bg_fetcher`'s
  Get-Tile and Data-High branches — once per 8 dots, not per dot — and the
  `head_cycle` flag goes in the existing bool block next to
  `dropped_first_fetch`; what pays for them is the two dots of throw-away fetch
  that no longer run.

## 2026-08-09: the mixer tail is clocked in DOTS, and pixel 0 holds it open

Three rows left in the mixer/palette family — `m3_bgp_change` (1 px),
`m3_bgp_change_sprites` (104) and `m3_lcdc_bg_en_change` (59) — and they are two
mechanisms, one per constant. Both are ±1-step measurements off the DMG
references, and each is confirmed by a row it was not derived from.

### `MIXER_TAIL_DOTS`: an object fetch DRAINS the tail, it does not freeze it

Everything above counted the tail's reach back from `lx`, which is right for as
long as the shifter takes one pixel per dot — every dot of a line except an
object fetch and the tail burst. The two `_sprites` rows are the ones that stop
the shifter under a mid-mode-3 write, and they say **dots**: a write reaches a
pixel iff that pixel left the FIFO within `back` DOTS of it, stall or no stall.

`m3_bgp_change_sprites` is eighteen measurements of exactly that — its object's
OAM X advances one per band while the handler's BGP write stays on a fixed dot,
so each band asks the question at a different stall age. The DMG reference
answers **zero** pixels back for a stall older than the tail (bands 8..12, where
the edge sits exactly on the stalled `lx`), **one** for a stall one dot old
(band 13) and the full **two** for a shifter still running (bands 14..17). A
pixel-clocked tail holds the last two pixels through the whole 6..11 dot fetch
and repaints them: that is all 104 of this row's wrong pixels, 55 of
`m3_lcdc_bg_en_change`'s 59 one stage shallower, and — because it subsumes the
burst latch — `m3_bgp_change`'s single LY-0 pixel at x = 158, where
`LY0_PIPE_MCYCLES` holds the mode 3 flag for four dots after the burst and the
position has to keep counting through them.

### `MIXER_HEAD_LINGER`: the line's first pixel keeps the shallow stages live

`m3_lcdc_bg_en_change`'s last 4. Its object sweeps its OAM X down the screen, so
the dot pixel 0 leaves the FIFO on moves band by band — **105, 104, 103, 102,
101, 100** for bands 0..5, `-d:gb_px_trace` — while the handler's LCDC write
stays on dot **105** for every one of them (`-d:gb_m3_trace`; LY 0 is 101 for
both, so it cancels). The reference blanks x = 0 in bands 0, 1 and 2 and leaves
it alone in bands 3..7, i.e. pixel 0 is reachable **exactly two dots** after it
leaves, where `MIXER_PRIORITY_BACK` is one and every other pixel of the very
same bands obeys that one. Both neighbours are refused: a reach of 1 loses band
2, a reach of 3 blanks band 3.

The palettes are **not** extended, and the same suite says so — `m3_bgp_change`
writes BGP on dot 97 (traced: 81, 97, 109, 169, 181, 241, 253) with pixel 0
leaving on dot 94, and its reference puts the `old or new` pixel at x = **1**,
not at x = 0: the same `MIXER_PALETTE_BACK` two stages that govern every other
pixel of that line, with no extension for the first. So the rule is
not "pixel 0 lingers a dot", it is the two stages **coinciding** for the line's
first pixel: a register read at a stage shallower than the deepest one reaches
pixel 0 for as long as the deepest one does. `m3_lcdc_obj_en_change`'s last 2
pixels are the independent confirmation — the write-up above had them as "what
the mixer holds at the first dot after an object fetch" and could fit no uniform
number of stages to them; they are OAM X = 2's object column 6, i.e. screen
pixel 0, and the same one dot answers them.

### Wrong pixels of 23040, one build per constant

| row | main | `TAIL_DOTS` only | `HEAD_LINGER` only | both |
|---|---|---|---|---|
| `m3_bgp_change` | 1 | **0** | 1 | **0** |
| `m3_bgp_change_sprites` | 104 | **0** | 104 | **0** |
| `m3_lcdc_bg_en_change` | 59 | 4 | 59 | **0** |
| `m3_lcdc_obj_en_change` | 2 | 2 | **0** | **0** |
| `m3_lcdc_obj_en_change_variant` | 98 | 98 | 96 | 96 (0 once the object fetch's cancel lands, below) |
| `m3_window_timing` | 33 | 21 | 33 | 21 |

CGB (DMG-compat, subpixels of 69120): `m3_bgp_change` 3 → 0,
`m3_bgp_change_sprites` 216 → 0, `m3_window_timing` 81 → 63. The runner goes
**725 → 731** (main measured, not the checked-in file, which was a revision
stale at 721); gambatte stays 3809/5005 row for row with
`dmgpalette_during_m3_3` and `lycint_dmgpalette_during_m3_1` each one pixel
better — that family's PNGs carry no `old or new` pixel at all, so it is not a
second oracle here, and the remaining disagreement is `MIXER_PALETTE_OR`'s
already-named cost. Nothing else in the tree moves in either direction, and
`-d:MIXER_TAIL_DOTS=0 -d:MIXER_HEAD_LINGER=0` reproduces main pixel for pixel.

### What it may NOT cost: the dot loop

`tail_dot0` has to answer "where is the shifter now" on a register write, and
the obvious way to keep it is to note `cycle_counter - lx` on every emitted
pixel. That is **+5.02% of retired instructions** (Pokemon Crystal, min of four
runs a side) — the inline cliff, not the arithmetic. It is not payable, and it
is not necessary: `cycle_counter - lx` cannot change while the shifter takes one
pixel per dot, so it is written only where the shifter STOPS — the object
trigger, a BG FIFO reset, and the tail burst — all of which are already cold
branches. See the block above `fifo_recompose_span`.

The one thing that costs is the test that replaces it. Two of the three stalls
are a flag and a bound; a mid-line window restart has no state of its own, and
an empty BG FIFO alone will not do (the FIFO also empties for a dot at an
ordinary tile boundary). `fifo.size == 0 and lx == mix_run` separates them, and
`m3_window_timing` line 17 is the one pixel that measures it.

Perf, `tools/gbppu/counters.sh`, minimum of five runs a side, `cycles=` identical
in every pair, idle machine: **+0.20%** retired instructions on Pokemon Crystal
and **+0.25%** on Link's Awakening against main — and **all of it is code
layout, none of it the mechanism**. The control says so directly: the same
branch built `-d:MIXER_TAIL_DOTS=0 -d:MIXER_HEAD_LINGER=0` measures **+0.195%**
and **+0.250%** against the same main, i.e. the two mechanisms together are
within 0.005% of free and what is being measured is where the linker put things.
The per-function size diff agrees — 91 functions change size for a net **+220
bytes**, `fifo_tick_slow` is 120 bytes *smaller*, and the only new symbol is
`mixer_tail_front` (+284, out-of-lined from its two cold callers now that it
returns a triple).

### The one place it is knowingly incomplete

A window START inside the tail (`WIN_TAIL_FETCH`, WX = 166) restarts the fetch
with `lx` at 159 and runs `lx` to 160 before `fetcher_retired` is true, so the
retire dot's `lx < GB_WIDTH` guard skips its note and `tail_dot0` stays at what
`fifo_reset_bg` wrote six dots earlier. A palette write in the first dots of
that line's H-Blank would therefore under-reach by the length of the restart.
Nothing in the tree can see it — no mealybug row and none of the 5,005 gambatte
rows moves whichever way it is spelled — and it is strictly better than what
preceded it, where that line's `tail_dot0` was left over from the *previous*
line. Recorded rather than guessed at: closing it needs a run-start note at the
BG push, and a push is speculative (an object can trigger on the same dot and
the shifter never emits), which costs more rows than it buys — built and scored,
it loses 62 pixels on `m3_obp0_change` alone.

## 2026-08-09: the window's head is six dots whatever WX is, and its WX is read late

`MIXER_TAIL_DOTS` (above) took `m3_window_timing` from 33 wrong pixels to 21 by
fixing the two-line lag in its stair. The 21 it left were all on **LY 0..6**, a
triangular staircase at x = 3..8, and they are a different mechanism: the head
of a line that *starts* as a window line.

The ROM is a ruler — WX = LY, WY = 0, SCX = 0, BGP driven black at a fixed dot,
so black-start x IS the number of dots the head consumed before x = 0:

| WX (= LY) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7..10 | 11..16 | 17+ |
|---|---|---|---|---|---|---|---|---|---|---|
| reference | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 4..9 | 9 |
| was (main) | 9 | 3 | 4 | 5 | 6 | 7 | 8 | 3 | 4..9 | 9 |

The 17+ tail is the control: there the window starts right of everything the
write can reach, so 9 is what a line with no window head reads at all.

**1. The window's own fine-scroll discard is absorbed** (`WIN_HEAD_ABSORB`, WX
1..6). The reference is FLAT at 3 across WX = 0..6, and 3 is also what
WX = 7..10 read — lines whose window starts on screen and pays the ordinary
six-dot startup fetch. So a line-start window costs the same six dots, which is
the ROM's own header sentence: it accounts for the entire WX-dependence of the
frame with "the 6 T-cycle window startup fetch" moving relative to a fixed
write, and names no other per-WX term (`docs/gb-mealybug-sources.md` §3.5 and
§5 read that out of the source alone, before this was built). The `7 − WX`
discard itself stays — it is what ALIGNS the window's glyphs, and a flat −6
seeding takes `m3_wx_4_change` to 12809, `m3_wx_5_change` to 14731 and
`m3_window_timing_wx_0` to 22914 — so only the DOTS move, as `WX − 1` idle steps
at the head of the window's fetch (the negative entries of `FETCHER_ORDER`).
Mode 3 is then 172 + 6 at every WX in 0..6, the length WX = 7 already had.

**2. WX is read at the end of the head's throw-away fetch**
(`WIN_LINE_START_LATCH`, LY 0's 6 px). This ROM writes WX *inside* mode 3 — dot
85, and dot 81 on LY 0, whose handler is one M-cycle shorter (`line_0_fix`) — so
reading WX at the mode 2 → 3 edge reads the PREVIOUS line's value, which on LY 0
is the 144 left from the bottom of the frame. We drew no window on LY 0 at all.
The other side of the bracket is `m3_wx_6_change`, whose dot-93 write must NOT
be seen or its LY 4 and LY 5 grow a window the reference has not got; the last
dot of the throw-away fetch is the fetcher event between them.

**Two length instruments that never look at a pixel confirm (1)**, which is the
one of the two that changes mode 3's duration:

| | `_a` reads | `_b` reads | hardware's mode 0 starts in | so mode 3 is | was | is |
|---|---|---|---|---|---|---|
| GBMicrotest `win<WX>` | cc 257, wants 3 | cc 261, wants 0 | [256, 259] | 176..179 | WX 4 → 175, WX 5 → 174 | **178 at every WX** |

(Hardware samples the mode bits at `cc − 2`; see the mode-0 latch section
above.) `-d:gb_stat_read_trace` shows `win4_a` and `win5_a` passing on a mode
flag that was already 0 when the ROM read it — `rm=3` over `live=0`. And
gambatte's WX = 3 length brackets go green: `window/m2int_wx03_m3stat_1`,
`window/m2int_wx03_scx3_m3stat_1`, `window/late_wx_wx03_2` and
`sprites/space/10spritesPrLine_wx{3,4,5}_m3stat_ds_1`, on both devices.

| | before | after |
|---|---|---|
| mealybug `m3_window_timing` DMG / CGB | 21 / 63 wrong px | **0 / 0** |
| mealybug `m3_lcdc_win_en_change_multiple_wx` DMG | 343 | 296 |
| mealybug DMG / CGB totals | 552500 / 1856612 | **552568 / 1856675** |
| gambatte | 3809/5005 | **3818/5005** |
| runner | 731/981 | 730/981 (+9 gambatte ROMs, +2 rows, −3 rows) |

The regression surface, checked row by row against main:

* gambatte is **+9 rows and −0 rows** over all 5,005 ROM/device runs. The two
  sentinels for the window-tie work this composes with are untouched: all 111
  `wxA6` rows and all 193 `m0enable` rows are identical verdicts.
* every mealybug row main takes to 0 stays 0 on both devices, and nothing else
  in either set moves a pixel. `results_mgba_suite.md` is identical.
* GBMicrotest trades **three rows**: `win3_b`, `win4_b`, `win5_b`. All eighteen
  `win*_b` rows now report the identical `0x83`-against-`0x80` signature, i.e.
  bucket 15's readback lag, and the `_a` bracket above says two of the three
  were only green because the mode-3 end was wrong in the compensating
  direction. Same precedent as `win6_b` and `win0_scx3_b`; all of them come back
  when bucket 15 lands.
* perf: retired instructions **−0.90%** (Pokemon Crystal CGB) and **−0.86%**
  (Link's Awakening DMG) against main, minimum of five runs a side, `cycles=`
  identical in every pair. It is a *win* because the window head's idle steps
  need `FETCHER_ORDER` to run below zero, which means deleting the
  `fetch_counter = fetch_counter and 7` that used to run on every dot of mode 3;
  the wrap it replaced only ever happened at `fsPushPixel` and is now written
  there.

### Why this branch's own `MIXER_TAIL_DOTS` was dropped rather than merged

This work was developed in parallel with the tail-in-dots branch and arrived at
the same mechanism independently, with a different spelling: the last two dots
the shifter did NOT emit on, and a tail whose low end is `lx` minus the emits in
the window, against main's run base (`tail_dot0`) plus run start (`mix_run`)
noted at the stop sites. Both hit the same +2.5–5% inline cliff in their first
per-emit form and both moved the state off the dot loop. Measured on this tree,
`-d:MIXER_TAIL_DOTS=0` against the shipping build is **+0.001%** of retired
instructions on Pokemon Crystal (minimum of four runs, `cycles=` identical) —
i.e. main's spelling has no cost left to win back, so replacing a documented,
in-tree mechanism that is already integrated with `MIXER_HEAD_LINGER`'s
`(back, head)` reach would have been churn at equal row outcome. Only the two
window mechanisms were ported.

## `m3_lcdc_obj_en_change_variant`'s last 96 pixels: the object fetch is CANCELLED

The variant's bands 16 and 17 are the only two in either `obj_en` ROM where the
handler's `ld [c], a` lands *inside* an object's stall (OAM X = 16/17, trigger
dots 102/103, write on dot 109). Pan Docs says the fetch is abandoned there and
this tree did not model it; `fifo_obj_abort` in `gb/fifo_ppu.nim` now does, and
that row goes **96 -> 0**.

What is worth recording is not the cancel but the ONE DOT the two instruments
that measure it disagree over, because it is the cleanest example in the tree of
a flag oracle and a pixel oracle reading the same event:

* twelve gambatte `sprites/sprite_late_{,late_}disable_*` rows read the mode
  3 -> 0 flag back through STAT and bracket the refund from both sides at
  `charge = W - 1 - T` (`W` the write dot, `T` the trigger dot);
* the variant's BGP pulse is a pixel ruler -- its bands 8..15 calibrate it
  exactly at run start `= 161 - P` for penalty `P` -- and its two aborted bands
  put the run at x = 156 and 157, i.e. `charge = W - 2 - T`.

Read as a function of `W - T`, ten of the twelve gambatte rows accept the
mealybug answer too, so the whole conflict is **one ROM** (`spx19`, read at two
STAT dots, hence two rows) against **two bands**, at configurations congruent to
the dot: X mod 8 = 1, wait 4, `W - T` = 6, opposite answers.

The split that satisfies both is a mechanism this tree already asserts -- mode 3
ends when the FETCHER retires, not when the last pixel leaves:

| | dots refunded | constant |
|---|---|---|
| shifter (pixels) | 2 | `OBJ_ABORT_LEAD`, = `M3_PIPE_DELAY` |
| fetcher (mode 3 -> 0 flag) | 1 | `OBJ_ABORT_FLAG_HOLD`, carried in `m3_hold` |

i.e. the cancelled VRAM cycle still owns the bus for its last dot. One build per
cell, whole suites:

| lead | hold | gambatte | mealybug DMG | what fails |
|---|---|---|---|---|
| 1 | 0 | 3818 | 552580 | variant bands 16/17, 16 px |
| 2 | 0 | 3816 | 552596 | `spx19_2`, `late_late_spx19_2` |
| **2** | **1** | **3818** | **552596** | nothing |

At (2, 1) the whole 5,005-row gambatte suite is identical row for row AND detail
for detail to (1, 0), because the flag's length is `W - 1 - T` either way, and
the mealybug CGB set does not move at any setting. **No third ROM separates the
pair from "one of the two instruments is a dot out"**; what would settle it is
the gambatte geometry re-cut with a BGP pulse instead of a STAT read.

Two other things fall out of the same commits and are pinned separately:

* `fetch_work_pending` was holding mode 3 open for an object LCDC.1 had already
  disabled -- `-d:gb_m3_len` read 174 where 172 was owed, on 96 lines of one
  gambatte run -- which is four more `sprite_late_disable_*_1` rows;
* `CGB_OBJ_ABORT = 0`: the same cart against `_cgb_c` gives those bands the FULL
  penalty, 288 subpixels out with the cancel on. That one row cannot separate
  "the CGB has no cancel" from "the CGB's LCDC.1 reaches the fetcher four or
  more dots later", and every row that could is double-speed.

Perf, `tools/gbppu/counters.sh`, five runs a side, `cycles=` identical in every
pair: **-0.04%** retired instructions on `cgb-acid2` and **-0.18%** on
`m3_lcdc_obj_en_change` (the latter genuinely does less work -- aborted lines
are shorter). Nothing is added to the dot loop; the whole mechanism is two
guards on an LCDC write.

## 2026-08-09: the window's TILE goes where its own first pixel is — the last 2 px

`m3_lcdc_win_en_change_multiple_wx`'s last two wrong pixels, LY 0 at x = 9 and
LY 6 at x = 7, and with them **the whole scored DMG mealybug set: 24 rows,
23040/23040 each.**

### Why this ROM alone can see it

It is the only ruler in the suite that measures the window's tile PHASE rather
than a dot. Every other window ROM drives BGP or reads a black-start x, i.e. it
counts head dots; this one turns LCDC.5 off again partway across every line with
`WX = LY`, and its own header says what that shows: *"when the window is turned
on and off it will always display a multiple of 8 pixels, **except when the
window begins off the left edge of the screen**"*. The background resumes on the
WINDOW's tile boundary, so the length of the black run at the head of each line
IS the phase of the window's first tile, read off the reference per line:

| WX (= LY) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | ≥ 8 |
|---|---|---|---|---|---|---|---|---|---|
| reference black run | 9 | 10 | 3 | 4 | 5 | 6 | 7 | 8 | 0 |
| implied first tile | −7..0 | −6..1 | −5..2 | −4..3 | −3..4 | −2..5 | −1..6 | 0..7 | — |
| dingbat, before | 10 | 10 | 3 | 4 | 5 | 6 | **8** | 8 | 0 |

(WX = 0 and 1 read one tile later than their own boundary — 1 + 8 and 2 + 8 —
because the abort catches the fetch after the next one; that is the same
"multiple of 8" the header describes and it is common to both columns.)

Every row is `first tile = (WX − 7) .. WX`: **the window's tile sits at the
window's own first pixel, at every WX.** Two of ours did not, and they are the
two ends of the same statement.

### The two exceptions we carried, and why they were both about dots

Both were spellings that got the number of DOTS right by moving a PIXEL, which
no other ROM in the tree can distinguish — the rulers all measure dots.

**1. WX = 0 (`WIN_WX0_PHASE`).** The head budget for a line that starts as a
window line is `idle + discard = 6` (`WIN_HEAD_ABSORB`), with `discard = 7 − WX`
and `idle = WX − 1`. At WX = 0 that idle is **−1**, which the code could not
express, so it clamped the idle to 0 and shortened the discard to 6 instead —
right dots, tile one pixel right. The −1 now comes out of the window's startup
fetch: one of `FETCHER_ORDER`'s sleeps is skipped, so the fetch pushes a dot
early and the seventh discarded pixel spends that dot back.

Where the skip is taken matters twice over. It is taken at the dot SCX is
LATCHED on, not at the head two dots earlier: this ROM and
`m3_window_timing_wx_0` both write their register per line inside mode 3, and at
the head dot SCX is still the previous line's value (`-d:gb_m3_trace` prints
both — the `HEAD` line and the `LATCH` line). Deciding it at the head instead
costs 105 CGB pixels of `m3_window_timing_wx_0`, on exactly the `LY ≡ 0` and
`LY ≡ 1 (mod 8)` lines the staleness lands on. And it comes out of the fetch's
own sleep rather than off its front, so the map read — and the SCX latch riding
on it, which `m3_scx_low_3_bits` brackets to one M-cycle — does not move.

`m3_window_timing_wx_0`'s *"window activating one T-cycle later when WX = 0 and
SCX > 0"* is the other half of the same sentence: with `SCX & 7 > 0` there is no
shortening, and the head is the ordinary `6 + SCX & 7` plus that documented dot.
The old `+1 / −1` pair in the sampler was that dot spelled as a pixel; it is now
spelled as the absence of the skip, which is what "activating later" says.

**2. WX = 6 (`WIN_PRE_PX_PHASE`).** The comparator matches one slot LEFT of the
shifter's first pixel (`WIN_START_PRE_PIXEL`, bracketed on three consecutive
scanlines of `m3_wx_6_change`), and `win_lx` is clamped UP to that first pixel so
the equality can fire at all. The clamp is right about the DOT and was wrong
about the TILE: it moved the window's tile with the match, to `0..7`. Now the
start takes the shifter back onto the window's own pixel (x = −1, off the left
edge, so the framebuffer never sees it) and enters `FETCHER_ORDER` one step in.
**Five dots of fetch plus that pixel is six dots and no pixel**, so the line's
first drawn pixel lands on the dot it landed on before.

That last identity is why no length instrument moves: GBMicrotest `win6_a/_b`
still bracket 178, and gambatte's WX = 3 and WX = 6 families are unchanged —
except `sprites/space/10spritesPrLine_wx6_m3stat_ds_2` [cgb], which goes
**GREEN**. That row is a mode-3 length probe at WX = 6 in double speed, where
the fetcher's five-dot phase against an object's penalty is visible at 2-dot
sampling; it is an independent confirmation from a suite that never looks at a
pixel.

### Before / after

| | before | after |
|---|---|---|
| mealybug `m3_lcdc_win_en_change_multiple_wx` DMG | 23038/23040 | **23040/23040** |
| mealybug DMG total (24 rows) | 552,958 | **552,960 = 24 × 23040** |
| mealybug CGB total (27 rows) | 1,861,920 | 1,861,920 (identical, row for row) |
| gambatte | 3849/5005 | **3850/5005** (+1, −0) |
| runner | 765/981 | **766/981** |
| `results_mgba_suite.md` | — | byte-identical |

Perf, retired instructions against a control build of the same tree
(`-d:WIN_WX0_PHASE=0 -d:WIN_PRE_PX_PHASE=0`, which reproduces the old totals
exactly), minimum of five runs a side with `cycles=` identical in every pair:
**−0.034%** (Pokemon Crystal CGB) and **−0.042%** (Link's Awakening DMG). Both
rules sit off the dot loop — one runs once per line at the fine-scroll latch,
the other once per window start — and the WX = 0 term is written as an add
rather than a branch because the `if` form measured +0.03% where this form
measures −0.03%, which is the same inlining cliff the rest of this file keeps
meeting.

### What DocBoy's window looks like, and what it was used for

DocBoy scores 24/24 on this set, so it was read as a hypothesis generator —
behaviour only, and the derivation above is off our own oracles. Two structural
facts are worth recording because they explain why we needed four constants
where it needs none:

* **Its shifter runs eight pixels before screen x = 0** (they are popped and not
  displayed), so `WX = 0..7` are ordinary matches on the ordinary comparator.
  Ours starts at `−(SCX & 7)`, which is why WX below 7 needs a line-start path
  at all (`WIN_LINE_START_WX`), why the WX = 6 slot needs a clamp
  (`WIN_START_PRE_PIXEL`), and why the discard has to be re-created as negative
  `lx` with idle fetcher steps against it (`WIN_HEAD_ABSORB`). Our `idle + 
  discard = 6` is that eight-pixel prologue seen through a shorter one.
* **The activation dot is wasted and the first window tile is pushed a step
  early**, so a window start costs six dots however it is reached. That is the
  same six this tree already spends, and it is what makes "one step in" the
  natural spelling for a start whose slot is left of our first pixel.

Nothing was copied and no constant of theirs is used: both changes are pinned by
the reference table above, by `m3_window_timing_wx_0`'s own header sentence, and
by the two length suites that did not move.

## Reproducing any of this

```
nimble test_build
TMPDIR=<private> DINGBAT_ROM_CACHE=<private> ./dingbat_test_runner
tools/gbppu/gamall.sh /tmp/g_base                  # 5005-row verdict file, ~6 s
python3 tools/gbppu/famflip.py /tmp/g_base.txt '*' # per-family flip points

git clone https://github.com/mattcurrie/mealybug-tearoom-tests   # @ 70e88fb
python3 tools/gbphoto/validate.py mealybug-tearoom-tests/photos/DMG-blob \
    $DINGBAT_ROM_CACHE/game-boy-test-roms/mealybug-tearoom-tests/ppu
python3 tools/gbphoto/photogrid.py adjudicate <photo>.jpg --ref <ref>.png --got <ours>.png
```

All three of `TMPDIR`, `DINGBAT_ROM_CACHE` and the nimcache are shared across
worktrees and have produced wrong results here; `tests/results*.md` are committed
baselines that every runner pass rewrites in place.

## Free rows waiting on a republished mGBA suite ROM

Not a dingbat bug, and worth ~7 rows for no emulator work.

`tests/dingbat_test_runner.nim` fetches the suite from
`mattrbeck/mgba-suite-auto/releases/latest/download/suite.gba`. Against the build
that URL currently serves (sha1 `00480cf1`, guarded by `MgbaSuiteSha1`), the
Misc. edge-case section scores **4/12**.

Six of the eight failures are the `H-blank bit start` rows, and they are **not a
timing error on our side**. Those rows compare a runtime measurement against
constants upstream re-measured for one specific compiler, so they are calibrated
to the toolchain that built the ROM. Reading them correctly — `src/misc-edge.c`
is the one file whose `doResult` inverts its arguments, so there "Got" is the
ROM's constant and "vs" is ours — the published build carries the same constants
as a local build of the same source, yet dingbat measures different values from
the two ROMs (Hblank `0x4D0` vs `0x4D3`, Flip 1 `0x87` vs `0x92`, Flip 3 `0xE5`
vs `0xE4`). Same emulator, same timing, different ROM code.

A local rebuild of the same `mattrbeck/mgba-suite-auto` master with the devkitARM
at `/opt/devkitpro` scores Misc **11/12**. That candidate ROM, its sha256 and a
`gh release create` line are at `~/Documents/mgba-suite-v1.1/`. Republishing from
that toolchain would take Misc 4/12 -> 11/12.

Two things to know before doing it:

* **Score Misc with `DINGBAT_NO_WAITLOOP=1`.** Under the default idle-loop
  fast-forward the corrected ROM scores 5/12, because the six H-blank rows time a
  DISPSTAT spin loop with TM0 and the skip's granularity becomes their answer.
  `-d:gbaskipcap=15` recovers two of six; bounding the skip by the loop's own
  period is the real fix and `analyze_loop` does not currently measure it.
* **Update `MgbaSuiteSha1` and the CI rom-cache key in the same commit.** That key
  is exact-match, so a stale one serves the old ROM from cache and makes the
  release look like a no-op.

The remaining Misc failure either way is `DMA Prefetch Break`, whose expected
value is `0x10000000 + 4*iterations` and is therefore not comparable across
builds by construction.

## 2026-08-10: the CGB revision axis becomes runtime-selectable

Three CGB behaviours are now selected by `GB.revision` rather than by a `-d:`
constant, and one of them was previously not modelled at all. `--cgb-rev=<0|A|B
|C|D|E>` on `tests/dingbat_test` selects the machine (it is spelling sugar over
the `--model=` token that already existed; `--model=cgbd` is the same thing).
Everything resolves once at construction into `GbQuirks` — nothing added here
branches on the revision in a hot path.

**The default CGB machine moved from `grCgbE` to `grCgbC`, and this is a
correction rather than a change.** The tree has been scored against C-class
references all along — mealybug's `_cgb_c` set, `CGB_MIXER_LATENCY = 1`,
`cgb-acid-hell`'s C-class capture, and `docs/gb-derivations.md`'s own "every
reference it is scored against is CPU CGB C" — while the enum's default claimed
E. The move is behaviour-neutral by construction (C and E resolve to the same
`bmCgbABCDE` boot table and the same `length_clock_any_nrx4 = false`) and
measured to be so; what it changes is which revision the two new quirks below
hand the default machine.

### What each revision setting changes

| behaviour | 0 / A / B | C | D | E / AGB | evidence |
|---|---|---|---|---|---|
| extra length clocking (`length_clock_any_nrx4`) | on | off | off | off | SameSuite `*_extra_length_clocking-cgb0B.asm`, quoted at the flag |
| palette write dot at the mixer (`mixer_write_immediate`) | charged | charged | **dropped** | **dropped** | mealybug `_cgb_c` vs `_cgb_d` reference pair |
| LCDC write dot at the mixer (`gb_lcdc_mixer_latency`) | charged | charged | charged | charged | the same pair, which is IDENTICAL on the LCDC ROMs |
| `$FEA0-$FEFF` (`unusable_region`) | RAM, `addr and not $18` | same | **RAM, unmasked** | **nibble echo** | Pan Docs + `cgb-acid-hell`'s own readback |

`CGB_HALT_PPU_LEAD` is **not** revision-gated and must not be gated on a guess.
It ships at 0 for a reason that has nothing to do with silicon revision — a
pixel-exact local-suite row (`strikethrough-cgb`; the shootout's strikethrough
row runs on DMG) refuses the quantity from the other side, and the section
below this one sharpens that into a contradiction inside gambatte's own halt
family — and no reference pair, ROM header or Pan Docs sentence splits the
CGB halt phase by revision. The same goes for `CGB_HALT_EXIT_MCYCLES` and
`SPEED_SWITCH_STALL_T`. Its own write-up in `gb.nim` is the place that argues
the quantity; this axis has nothing to add to it.

### The palette dot is a palette dot, not a mixer dot

The interesting result of wiring this up. `CGB_MIXER_LATENCY` was being
subtracted at BOTH mixer call sites — the palette stage and the LCDC/priority
stage — and `CGB_LCDC_MIXER_LATENCY` sat declared and unread beside it, because
both constants are 1 and nothing could tell them apart. The C/D split is the
first thing that can. Run every mealybug ROM that ships both captures:

* the palette ROMs' two references **differ** (`m3_bgp_change` by 864 px,
  `m3_bgp_change_sprites` by 716, `m3_obp0_change` by 42);
* the LCDC ROMs' two references are **identical** (`m3_lcdc_bg_en_change`,
  `m3_lcdc_obj_en_change` — dingbat scores the same against both at every
  revision).

Hardware shipping two identical captures is hardware saying the behaviour did
not change between those devices, so gating LCDC on the revision would be
inventing a difference the captures deny. Measured, gating it anyway: 23040 ->
22637 and 23040 -> 22980 **on both references at once**, which is the signature
of moving a stage no reference wanted moved. So `mixer_write_immediate` gates
the palette stage only, `gb_lcdc_mixer_latency` is ungated, and
`CGB_LCDC_MIXER_LATENCY` is now the live constant it always described.

### Mealybug, per revision: 20 ROMs ship both captures

`--cgb-rev=C` is exact on `_cgb_c` for 18 of 20; `--cgb-rev=D` (and `E`, which
is identical here) is exact on `_cgb_d` for 17 of 20.

* **Five flip sides as intended**: `m3_bgp_change`, `m3_bgp_change_sprites`,
  `m3_obp0_change`, `m3_window_timing`, `m3_window_timing_wx_0` — each pixel-
  exact on `_cgb_c` at C and pixel-exact on `_cgb_d` at D.
* **One is fixed by the LCDC split**: `m3_lcdc_obj_en_change_variant` reaches
  23040/23040 on `_cgb_d` at D only because LCDC keeps its dot; with LCDC gated
  it stalled at 22980.
* **Two fail identically at every revision**: `m3_lcdc_bg_map_change` (22656)
  and `m3_lcdc_win_map_change` (22858) are off on BOTH captures by the same
  count, so they are pre-existing and revision-independent. Not this axis.
  **Closed 2026-08-19**, and the revision-independence is what said where to
  look: it is a CGB/DMG delta and not a C/D/E one. Both ROMs invert into "which
  map did each tile's B read use", both DMG captures are already exact, and all
  four edges of the two frames put the CGB's LCDC.3/LCDC.6 arrival at the map
  read exactly two dots behind the DMG's. Shipped as `CGB_MAP_LATENCY = 2`;
  derivation at that constant in `gb.nim` and the band tables in
  docs/gb-mealybug-sources.md §3.12. Both rows, both their `2`-suffixed
  siblings and gambatte's whole `bgtilemap` family (28/40 → 40/40) are now
  exact, at C, D and E and against both captures.
* **One is the honest gap: `m3_scy_change`**, 23040 on `_cgb_c` at C and
  16823/23040 on `_cgb_d` at D. This is the OTHER documented CGB-D difference
  and dingbat does not model it. Pan Docs, `Scrolling.md`: *"All models before
  the CGB-D read the Y coordinate once for each bitplane (so a very precisely
  timed SCY write allows 'desyncing' them), but CGB-D and later use the same Y
  coordinate for both no matter what."* That is a fetcher change, not a mixer
  one, and it is the next quirk anyone extending this axis should take: the
  evidence is a Pan Docs sentence naming the revision outright, and the target
  is 6217 pixels on one row.

### `$FEA0-$FEFF`: what Pan Docs gives, and what it refuses to

Pan Docs' "FEA0-FEFF range" splits the region three ways and dingbat now
implements all three (`GbUnusableRegion`). It gives the DMG case (`$00`) and the
CGB-E case (`(addr >> 4 and $F) * $11`) outright, formula included. For CGB 0-D
it says the region is *"a unique RAM area, but is masked with a revision-
specific value"* — **and then never states the value, anywhere in the book.**
There is no table, footnote or other page supplying it.

So the mask is sourced from the ROM that measures it rather than from the book.
`cgb-acid-hell` writes `$55` to `$FEA0` and `$44` to `$FEB8`, reads `$FEA0`
back, and draws different tile data depending on whether it sees `$55`. Two
hardware captures bracket the answer: the author's bundled reference (dingbat's
scored PNG) is the not-`$55` branch, and the repo's issue tracker carries a
photo of a real device taking the `$55` branch. For the reference device the
`$FEB8` store must therefore land on `$FEA0`, which is `addr and not $18`.
SameBoy was read afterwards and agrees; it was a check on a derived answer, not
the source of one.

**Measured, and this closes the hazard the 2026-08-10 entry above raised.**
`cgb-acid-hell`, scored against its bundled reference:

| revision | result |
|---|---|
| 0, A, B, C | **23040/23040 pixel-exact** |
| D | 22864/23040 |
| E | **23040/23040 pixel-exact** |
| default (no flag) | **23040/23040 pixel-exact** |

The scored runner row is untouched, and the hazard's own target is met: a CGB-C
reads `$44` back and keeps the reference branch. The rev-D number is **correct
behaviour, not a failure** — the ROM's gate exists precisely to refuse CGB-D
(*"the bugs in the PPU this test relies on work differently on CGB-D"*), the
bundled reference is a C-class capture, and a D machine has no business
matching it.

That the 176 pixels are the gate and nothing else is proved rather than
asserted: built with `-d:gb_unusable_zero` (the control arm that answers `$00`
everywhere, as the tree did before this change), `cgb-acid-hell` is
23040/23040 at C, D and E alike. The palette-dot split does not touch this ROM
at all, so every one of those 176 pixels is the `$FEA0` readback.

**One correction to the entry above.** It predicts that the `$55` branch draws
the `SORRY YOU CAN'T GET TO PLAY` screen. The frame says otherwise: the two
branches differ by 176 pixels, which is a tile-data swap and not a full-screen
refusal. The branch demonstrably flips (proof in the paragraph above); what it
draws is smaller than the disassembly reading assumed.

**What is NOT modelled, deliberately.** Pan Docs opens the section with *"This
area returns $FF when OAM is blocked"*, and dingbat answers the per-revision
model during mode 2/3 instead. That gap predates this change — the OAM read
lock lives inside `ppu_read`, which only `$FE00-$FE9F` reaches — and closing it
is a different axis from the revision one. The OAM-DMA half IS handled and
always was (`mem_read_busy` answers `$FF` for the whole page). `cgb-acid-hell`
waits for STAT bit 1 to clear before every access, so it does not depend on the
gap either way.

### Score

Full local runner, default build, against the base commit:

| | rows | pass | gambatte |
|---|---|---|---|
| base (`a8a549e`) | 981 | 769 | 3850/5005 |
| this change | 981 | 769 | **3876/5005** |

**Zero rows moved sides.** The whole delta is +26 / -0 inside
`gambatte/oamdma`, and every one of the 26 is a `busypushFEA1` or
`busypushFF01` `[cgb]` row — the family the Tier-1 table above priced at
"+26 / -0" and the only rows in the suite that read `$FEA0`. Their expected
values are named `cgb04c`, i.e. a C-class device, which is a third independent
witness for the default revision.

The revision plumbing on its own is byte-identical: built with
`-d:gb_unusable_zero`, `results.md` matches the base commit's exactly but for
its timestamp, and gambatte returns to 3850/5005. So every row this work moved,
the `$FEA0` model moved.

### Perf

Free, as a per-PPU-register-write site should be. `tools/gbgate/build.sh`
a8a549e vs d7e3467 (`git archive` both sides, so neither can see the other's
artifacts), `DINGBAT_BENCH_COUNTERS=1 DINGBAT_NO_WAITLOOP=1`, retired
instructions, 2400 frames after 300 warmup, minimum of six interleaved runs
per arm:

| ROM | A (`a8a549e`) min | B (`d7e3467`) min | delta | A's own 6-run spread |
|---|---|---|---|---|
| Pokemon Crystal (CGB) | 23,696,710,663 | 23,696,721,992 | **+0.00005%** | 0.0047% |
| Shantae (CGB) | 35,953,316,118 | 35,953,490,243 | **+0.00048%** | 0.0032% |
| Link's Awakening (DMG) | 24,244,700,866 | 24,245,131,306 | **+0.00178%** | 0.0116% |

Emulated `cycles=` is identical in all 36 runs (168,537,600 / 325,669,176 /
168,395,236), which is the control that says both arms did the same work.
Every delta is an order of magnitude below its own arm's run-to-run spread,
i.e. not resolvable. Wall-clock is not quoted: it lies below ~1.3%.

## 2026-08-10: `CGB_HALT_PPU_LEAD` is refused by two rows of one gambatte family

`CGB_HALT_PPU_LEAD` (gb.nim) is the CGB halt phase: while a CGB CPU is halted the
PPU runs behind the rest of the machine and gets the dots back at the wake, so an
LCD-sourced wake lands later in machine time and a timer wake does not move. It
scores gambatte 3853/5005 against 3850 and it ships at 0, with one row —
ashiepaws' `strikethrough-cgb` — named as the thing between it and shipping. This pass went
after that row and after the seven `dma/hdma_late_disable_*` it also costs.

**Neither is recoverable, and the reason is a contradiction inside gambatte's own
halt evidence rather than anything about OAM DMA.** What follows is the
measurement; every dot below is from `-d:gb_dma_trace` on the ROM named.

### The contradiction, in one line of one family

Three rows, the **same wake** — a CGB halted with `LYC = 1` and the LYC STAT
source armed — measured at three different dots of that same line 1:

| row | after the wake | lands at | brackets | wants |
|---|---|---|---|---|
| `halt/lycirq_m2stat_2` | reads STAT, 20 M-cycles on | line 1 dot **81** | mode 2->3 at dot **80** | the read one M-cycle **later** |
| `dma/hdma_late_disable_1` | writes FF55, 48 M-cycles on | line 1 dot **249** | mode 3->0 at dot **252** | the write **not** later |
| `dma/hdma_late_disable_2` | the same, one NOP on | line 1 dot **253** | the same edge | already past it |

`lycirq_m2stat_2` is `dmg08_out2 / cgb04c_out3` and `hdma_late_disable_*` are
CGB-only, so both are statements about a CGB and there is no device comparison to
argue with. `lycirq_m2stat` halts with IME clear and `hdma_late_disable` with IME
set, and that is the ONLY structural difference between them: same source, same
LYC value, same line, same rise dot.

A halt phase cannot answer both. The post-wake CPU is one thing, and between dot
81 and dot 249 nothing in the model moves it.

### Why the quantity cannot be made smaller

The obvious escape is that the phase is not a whole M-cycle. The bracket in
`CGB_HALT_PPU_LEAD`'s note is a bracket on whole M-cycles (0, 1, 2) and says
nothing about 1, 2 or 3 dots, and this tree is full of sub-M-cycle CGB latencies
(`CGB_MIXER_LATENCY` 1, `CGB_SCY_LATENCY` 2, `CGB_OBJ_SIZE_LATENCY` 3).

`CGB_HALT_PPU_LEAD_DOTS` was added for exactly that sweep. It does not help, and
the reason is worth writing down because it applies to any future knob here:
**the halt's exit is latched on the M-cycle grid** (`cpu_halt_tick`), so a lag of
N dots does not move a wake by N dots. It moves it by a WHOLE M-cycle for a
source that rises within N dots of the latch, and by nothing at all for every
other source. dingbat's LYC source rises on the last dot of an M-cycle, so **one
dot is already the whole M-cycle** for every LYC-woken halt.

Measured, one build per setting (`SPEED_SWITCH_STALL_T=65544` throughout):

| DOTS | gambatte | `lycirq_m2stat_2` | `hdma_late_disable_1` | strikethrough-cgb | daid `ppu_scanline_bgp` |
|---|---|---|---|---|---|
| 0 | 3850 | red | green | **23040/23040** | 4 px early |
| 1 | -- | green | red | 23033/23040 | 4 px early |
| 2 | **3860** | green | red | 23033/23040 | 4 px early |
| 3 | -- | green | red | 23033/23040 | 4 px early |
| 4 | 3853 | green | red | 23033/23040 | **exact** |

Two things fall out of that table that were not known before:

* **Every value from 1 to 4 breaks strikethrough and `hdma_late_disable`
  identically**, to the same seven pixels and the same `got 7`. There is no
  sub-M-cycle setting that buys the halt rows without the cost.
* **`DOTS=2` is a strictly better setting of this knob than the `DOTS=4` the
  constant currently spells** — gambatte 3860 against 3853, +25 -15 against
  +27 -24. It keeps all ten `halt/` wins and all eleven `speedchange` wins and
  additionally holds `m0{int,irq}_m0stat_scx{2,5}_1` and
  `hdma_late_enable_ds_2`, which `DOTS=4` loses. It is not shippable either: it
  breaks the same strikethrough and `hdma_late_disable` rows AND it loses daid's
  `ppu_scanline_bgp` on CGB, which only comes back at the full 4. If this
  mechanism is ever revisited, 2 is the number to start from, not 4.

daid's row is the reason 4 is not simply "too much": its LYC=**0** source (the
LY 153 quirk path, not an ordinary line boundary) sits in a different position
against the M-cycle grid, and 1, 2 and 3 dots do not reach it. So the sweep has
sources in two different buckets and still no setting that separates the rows
that need the M-cycle from the rows that refuse it.

### The one PPU-side escape, and the row that closes it

The contradiction has exactly one shape that is not about the CPU: if the CGB's
mode 3 spanned **four more dots** than dingbat models, the same post-halt CPU
could be one M-cycle late at dot 81 and on time at dot 249. `hdma_late_disable`
agrees with that to the dot — at `DOTS=4` its write lands at 253 against an edge
at 252, so an edge anywhere in [254, 257] passes both `_1` and `_2`.

**strikethrough refuses it, in the opposite direction, on the same edge.** Its
STAT handler ($0230) is

```
0230  LDH A,($FF41)      ; 8 M-cycles per iteration = a 32-DOT sampling comb
0232  AND $03
0234  JR NZ,$0230        ; wait for mode 0
0236  <28 NOPs>
0252  LD A,$C0
0254  CALL $FF80         ; LDH ($FF46),A -- the OAM DMA the picture is made of
```

so the DMA start is pinned to the wake **modulo 32 dots**, not to the mode-0 edge.
Measured on line 67: the poll's samples are at dots 49, 81, ... 241, 273, the
mode 0 edge is at dot **252**, and the winning sample is 273 — twenty-one dots of
margin. At `DOTS=4` the comb is 53 ... 245, 277, the winner is still 277, and the
DMA starts at dot 453 instead of 449. One byte of the transfer, and the object at
OAM X=79 reads `01` off the DMA's bus where it should read `00`; that is the
seven pixels, all on line 68, x=71..78.

To put that winner back on 245 the CGB's mode-0 edge would have to arrive **at
least seven dots EARLIER** than the DMG's. `hdma_late_disable` needs the same
edge two to five dots **LATER**. Same edge, same device, opposite signs — so no
adjustment of CGB mode 3, in either direction, satisfies both.

### Candidates measured and refused

Each of these was built and run, not argued away.

* **The debt repayment's placement relative to the wake M-cycle's bus half.**
  Refused structurally and confirmed by trace: wherever the repayment goes, it
  restores `PPU == machine` before the CPU's first post-wake bus access, so the
  post-wake CPU-vs-PPU offset is the wake M-cycle's own shift and nothing else.
  `DMASTART` in strikethrough is 448 dots after the wake — the halt is long over.
* **OAM DMA on the PPU's delayed half rather than the bus half.** Same trace kills
  it: strikethrough's transfer is armed 112 M-cycles after the halt ended, so no
  clock-domain assignment that only differs *during* a halt can reach it.
* **A CGB-specific OAM DMA start latency.** `CGB_OAM_DMA_START_T=4` (against the
  8 T both devices ship) makes **both** strikethrough rows pixel-exact at
  `DOTS=4` — and gambatte `oamdma` goes 681 -> 578, total 3853 -> **3750**. 103
  rows say the CGB's OAM DMA takes the bus 8 T after the write to FF46. The knob
  is kept at 8 in `gb.nim` so the refutation has somewhere to live.
* **IME / whether a vector is taken as the discriminator.** It is the only
  structural difference between `lycirq_m2stat` and `hdma_late_disable`, and it
  is refuted from the other side: `halt/m1int_ly_2` (`EI`/`HALT`, vector taken)
  and daid's `ppu_scanline_bgp` (`EI`/`HALT` in the VBlank handler, vector taken)
  both NEED the M-cycle, and `hdma_late_disable` (`EI`/`HALT`, vector taken)
  refuses it.
* **CGB mode 2 shorter, i.e. mode 3 starting four dots earlier.** This would
  explain `lycirq_m2stat_2` with no halt phase at all. `m2int_m2stat_{1,2}`
  refuse it: they bracket the same mode 2->3 edge at the same NOP index with no
  halt anywhere in the ROM, and they are `dmg08_cgb04c_out2` / `_out3` — one
  expected value for both devices.

### What `hdma_late_disable`'s `got 7` actually is

Worth recording, because "7" reads like a wild answer and it is not. The ROM's
verdict is `LD A,(HL)` with `HL = $8000`, `AND $07`. When the disable write beats
the mode-0 edge, no block moves and VRAM reads 0 (`out0`). When it loses the
race, the block has already moved and `hdma_active` is false, so the same
`XOR A / LDH ($FF55),A` is a **general-purpose** DMA of one block — which steals
the bus for 32 dots and pushes the verdict read into the next line's mode 3,
where VRAM reads `$FF`. `7` is `$FF and 7`: not a DMA count, a blocked read.

### Diagnostics added

`-d:gb_dma_trace` (tools only, compiled out of every shipping build) prints one
line for each of: the OAM DMA unit taking the bus (`DMASTART`), every FF55 write
with the mode and `hdma_active` at that dot (`FF55`), every HBlank/GP block copy
(`HDMABLOCK`), every STAT/LY read (`REGREAD`), and every mode change (`MODE`) —
all with `ly` and the PPU dot. Every number in this section came off it. It pairs
with `-d:gb_halt_trace`, which reports the wake.

## 2026-08-10: `scx_during_m3`, and the BG fetcher's address is a screen position

The family the mode-3 campaign named as its first target: **gambatte
`scx_during_m3`, 49/141**, the biggest single accuracy bucket in the tree. It is
now **113/141** shipping, **119/141** with one flag, and the whole suite went
**3940 → 4004**. Every row that moved is inside this family; nothing else in
5005 rows shifted, and the four screenshot witnesses this file spends most of
its length on are byte-identical either way.

### The family, decoded

Every ROM is one STAT handler at `$1000`. It takes a **mode-2** interrupt, then
writes SCX three times down a NOP slide; the directory name is literally the
three values (`scx_0363c0` is `$03, $63, $C0`). Successive members move the
second write one M-cycle **later** and the third one M-cycle **earlier** —
both move, which is why the boundaries in the frames walk in the direction they
do. `tools/gbscx/writedots.py` reads the three M-cycles straight from the bytes;
`tools/gbscx/disasm.py` is a plain SM83 disassembler written for this and useful
anywhere the suites' ROMs need reading.

**The frame is a ruler, not a picture, and that is a property of the ROM.** Its
background row is 32 map columns of two alternating tile pairs whose local
pattern is aperiodic enough that a dozen pixels pin the background coordinate
they came from. So a scanline reads back as a function `screen x → background X`,
and `X − x` is the effective SCX at that pixel. `tools/gbscx/scxread.py` does the
inversion (palette computed from the ROM's own `BGP = $27` and CGB palette, not
guessed, so it is device-independent); `scxmap.py` puts ours and hardware's
segmentation side by side. Reported **mod 16**, which is the honest resolution:
the background row is 16-pixel periodic inside each half, so an absolute
displacement is sometimes ambiguous but the tile-column PARITY and the fine
scroll never are — and those are exactly what a mid-line SCX write moves.

### Finding 1: the column carries a borrow (shipped, `SCX_FINE_BORROW`)

The BG fetcher is **not** addressed as "a tile index plus a scroll". Its map
column is

    ((SCX + 8*k − F) shr 3) and 31

where `8*k − F` is the **screen position** of the fetch and `F` is `SCX and 7` as
the line latched it. That is the old `k + (SCX shr 3)` in every case but one:
when a mid-line store **lowers** the low three bits below `F`, the subtraction
borrows and the column comes out one tile lower for the rest of the line. SCX's
low bits take part in the carry into the tile-address bits — one adder and one
register, which a tile index plus a scroll cannot express.

The correlation is exact in both directions across all six directories: every
failing row's disputed span followed a store that lowered `SCX and 7`, every row
without one passed, and `scx_0060c0` — the directory that never moves the low
bits — was green all along. The error was always the **same** error, one tile,
whatever the size of the drop (`3→0` is minus three, `7→1` is minus six, both
cost exactly 8 pixels), which is what says carry and not count.

Two neighbouring shapes are refused by measurement:

* *"the discard re-arms and throws 8 more pixels away"* — refused by the
  residue. Every measured span keeps the **old** fine offset, never the new one.
* *"an extra tile is fetched"* — refused by sign. The spans sit one tile
  **lower**, which is a borrow and not an insertion.

**A device split falls out, bracketed from both sides.** Three ROMs move only
the low bits and are the only rows in the tree that can see the borrow alone:

| ROM | drop | DMG hardware | CGB hardware |
|---|---|---|---|
| `scx1_scx0_during_m3_1` | 1→0 | no change at all | borrows at x = 63 |
| `scx2_scx1_during_m3_1` | 2→1 | no change at all | borrows at x = 62 |
| `scx2_scx0_during_m3_1` | 2→0 | borrows at x = 62 | borrows at x = 62 |

Same ROM, same dot, same drop of one, and the consoles disagree; a drop of two
borrows on both. So the DMG's threshold is one pixel tighter — it borrows on
`(SCX and 7) + 1 < F` where the CGB borrows on `(SCX and 7) < F` — and that is
`SCX_FINE_BORROW_DMG_LEAD`. At 0 the two `−1` rows go red on DMG, at 2 the `2→0`
row does. It is **not** `CGB_PIPE_MCYCLES`, which is four dots against machine
time; this is one pixel inside the fetcher's own sum.

**An independent oracle confirms it.** AGE's `m3-bg-scx` — three rows, both
devices and double speed, not used in the derivation — goes from 99.4/99.5%
to **pixel-exact**. Local runner 770 → 773.

**It is free, and the dot loop got cheaper.** The whole SCX term including the
borrow is cached by `fifo_arm_scx` and re-derived at the two events that can
change it, exactly as `win_lx` is kept by `fifo_arm_window`, so the fetch site
is the single add it already was and no longer does a shift. `git archive` both
sides, blargg cpu_instrs, 2400 frames after 300 warmup, six interleaved runs,
`cycles=` identical in all twelve: **−0.148%** retired instructions against the
base commit, six times the arm's own spread. The first spelling, which decided
the borrow at the fetch, measured **+0.22%** and is why the cached one exists.

### Finding 2: the fine-scroll sample is a window (derived, ships OFF)

`SCX_FINE_LATCH_LIVE`, worth a further **+6 / −1**. A store to SCX joins the
discard for as long as the discard still has pixels to throw away, moving the
line's fine scroll, its `lx` and mode 3's own length with it.

Traced, dingbat latches at dot 88 and the interesting stores land at 89 and 93:

| family | `F` | store at 89 | store at 93 | hardware's residue |
|---|---|---|---|---|
| `scx_0063c0` | 0 | no | no | keeps 0 — there is no discard |
| `scx_0367c0` | 3 | **yes** | no | takes 7, the whole of `$67` |
| `scx_0360c0` | 3 | **yes** | no | takes 0, the whole of `$60` |
| `scx_0761c0` | 7 | **yes** | **yes** | takes 1, the whole of `$61` |

Read down the `store 89` column and a fixed window is refused outright: same
dot, same offset from the same latch, and one family says no while three say
yes. The only thing separating them is `F`, which is exactly how many dots of
discard are left. Read across `scx_0761c0` and the window is still open five
dots in at `F = 7`, which no capped spelling reaches without also opening it at
`F = 0`. Swept as `min(N, F)`, the score saturates at N = 3 while the RESIDUES
keep falling to N = 7 (`scx_0761c0/scx_during_m3_4`: 6292 wrong pixels at N = 3
against 2145 at N = 7, and its DMG/CGB asymmetry vanishes). So the window is the
discard, and there is no constant.

Two spellings were built and refused:

* **`lx < 0`** — "the discard is still running", which reads like the same
  statement — scores **3992/5005**. The head's throw-away fetch parks the
  shifter, so `lx` stays negative long after the discard is spent and the window
  opens on exactly the `_4` steps hardware shuts it on.
* **widening the window by one M-cycle on line 0 alone**, which is the shape
  `LY0_PIPE_MCYCLES` predicts and which would buy back the one row this costs:
  **3998** against 4009. It loses eleven rows to win one.

It ships off on price. On the only whole-cartridge workload available here it
reads **+0.446%** of retired instructions, and five net rows do not buy that
much of the dot loop. Off is free — the field it needs costs +0.21% through
object layout with the mechanism compiled out, the same cliff `win_lx` and
`win_hold` each record, so the field is declared inside the `when` and the
default build matches the previous commit to 0.002%. **Re-price it on Pokemon
Crystal and Link's Awakening; it is one build.**

### What is left in the family, and the one bracket worth having

22 rows shipping, in three groups.

* **`scx_m3_extend_{1,ds_1}`, 3 rows — mode 3's LENGTH, and this is the
  interesting one.** SCX `$07` then `$05`, a low-bit drop, and the pair brackets
  the mode 3 → 0 edge to one M-cycle. Measured with `-d:gb_m3_len` and
  `-d:gb_dma_trace`: on the scored line our mode 3 is 179 dots and ends at dot
  **259**, the ROM's STAT read is at dot **269**, and `_2`'s is at **273**. `_1`
  wants mode 3 at 269 and `_2` wants mode 0 by 273, so **hardware's mode-3 end is
  11 to 14 dots later than ours on that line.** The borrow's natural 8 does not
  reach it, and the content rows cannot arbitrate because an extension past
  x = 159 is invisible in a 160-pixel frame. The double-speed member is a
  *descending staircase* — `SUB 2` and store, repeatedly — so the effect
  accumulates, which is what "m3 extend" is named for and the instrument to
  derive it with.
* **~16 rows, the discard-window boundary**, all bought by Finding 2 or sitting
  next to it.
* **3 rows at 8 pixels, CGB only** (`scx_during_m3_spx2`, `scx_attrib_*`), an
  object case that has nothing to do with either finding.

### What this did NOT touch, stated plainly

* **The same-wake contradiction is untouched.** `halt/lycirq_m2stat_2` versus
  `dma/hdma_late_disable_{1,2}` is byte-for-byte unmoved: the whole-suite row
  diff is `+64 / −0` and every one of the 64 is in `scx_during_m3`. Nothing here
  bears on it except one pointer, and it is a real one — `scx_m3_extend` is
  direct evidence that **mode 3's END can move without its CONTENT moving**,
  which is the "the edges do not move together" shape that contradiction needs.
  That bracket, above, is the cheapest place left to attack it.
* **acid-hell is unchanged at 23038/23040, and the shootout stays 260/261.**
  This is a positive statement rather than an absence: `cgb-acid-hell` writes
  LCDC and `daid/ppu_scanline_bgp` writes BGP, and neither writes SCX mid-line,
  so neither mechanism here can reach them. Verified rather than assumed —
  `cgb-acid-hell` at `--cgb-rev=C` and at `--cgb-rev=E`, `daid` on DMG and on
  CGB at rev C and rev D, both `strikethrough` frames and both acid2 frames are
  all **byte-identical** to a `-d:SCX_FINE_BORROW=0` control
  (`tools/gbscx/witness.sh`, `witdiff.sh`), and mealybug's CGB total is
  1863574 in both arms.

### Instruments

`tools/gbscx/`: `disasm.py` (SM83), `scxread.py` + `scxmap.py` (the displacement
ruler), `writedots.py`, `dumpfam.sh`, `gamdiff.sh` (attribute every moved row),
`sweep.sh` (one build and one whole-suite score per constant value),
`witness.sh` + `witdiff.sh` (the ladder, world against world),
`bench.sh` / `benchref.sh` (interleaved retired-instruction A/B, by flag or by
git ref), `mb.sh`, `handlers.sh`, `build.sh`, `r.sh`, `env.sh`.

## 2026-08-10 (round 2): mode 3's END, and the STAT mode field as its own observable

Round 1 handed forward one bracket — `scx_m3_extend` says hardware's mode-3 end
is 11–14 dots later than ours on a line whose CONTENT we render exactly — and
this round pulled it. The answer is **not** the one that was hoped for, and the
falsification is worth more than the hope was: **the STAT mode FIELD is not a
free observable.** It is pinned to the PPU's own dot, from both sides, by
hundreds of rows.

Nothing shipped. Two constants land at 0 carrying their refutations
(`STAT_MODE0_LAG`, `STAT_MODE3_LAG` / `_CGB` in `gb.nim`), and three new dot
brackets are established.

### The instrument: three ladders, read as dots instead of verdicts

`tools/gbscx/edgemap.sh` prints, for the line a ROM actually scores, every SCX
store with its dot, the fine scroll the line latched, mode 3's length, the dot
of the 3 → 0 edge, and the dot the ROM reads STAT on with the byte it got.
State is reset at every line boundary rather than keyed to LY — a trace covers
several frames and `ly = 0` recurs in each, so matching on LY alone silently
reports a different frame's line, which is a trap worth naming because the first
version of this tool fell in it.

With that, three gambatte families stop being pass/fail and become rulers.

### Bracket 1: `scx_m3_extend`, measured on both devices

| device | latch | store | our len | our edge | reads | hardware's edge | our deficit |
|---|---|---|---|---|---|---|---|
| DMG | dot 88, `$07` | `$05` at dot **93** | 179 | 259 | 269 wants m3, 273 wants m0 | **(269, 273]** | 11–14 dots |
| CGB | dot 88, `$07` | `$05` at dot **89** | 179 | 259 | 265 wants m3, 269 wants m0 | **(265, 269]** | 7–10 dots |

Both devices, same ROM, same latch, and the store lands 5 dots after the latch
on DMG and 1 dot after on CGB (`CGB_PIPE_MCYCLES` moves the CPU's stores 4 dots
earlier in PPU time). **The later the store lands, the bigger the extension** —
which is the shape any candidate rule has to reproduce, and it rules out a flat
"a mid-line SCX store costs one tile" (that would be 8 on both).

### Bracket 2: the `ly0_late_scx7` ladder is a LATCH-dot ruler

`enable_display/ly0_late_scx7_m3stat_scx{0,1,3}_{1,2,3}` had been read as a
mode-3-length family. It is not: each ROM sets SCX to its own initial value
(`scx0`/`scx1`/`scx3` is that value, not the store), enables the LCD, stores
`$07` at dot **81, 85 or 89**, and reads STAT at a dot fixed per ROM. What the
ladder brackets is **whether the line's fine scroll still takes that store**,
read out as mode 3 against mode 0.

The CGB arm is the finding, and it is a clean confirmation of something derived
elsewhere. On CGB the stores land 2 dots later again (`CGB_SCX_LATENCY`), and
hardware's answer depends on the ROM's INITIAL fine scroll:

| initial `F` | store at 85 | hardware | ours |
|---|---|---|---|
| 0 (`scx0_2`) | lands at 87 | **not** taken | not taken |
| 1 (`scx1_1`) | lands at 87 | **taken** | not taken |
| 3 (`scx3_1`) | lands at 87 | **taken** | not taken |

Turned into lengths (the reads sample dots 255, 255 and 259 respectively),
hardware's mode 3 on that line is `<= 175` at `F = 0`, `> 175` at `F = 1` and
`> 179` at `F = 3`. The first two are what taking the store into the latch
would give (`172 + 7 = 179`), and they agree with `SCX_FINE_LATCH_LIVE`'s rule
that the window is the discard's own length — with `F = 0` there is no discard,
so hardware refuses the store, which is the rule's sharpest prediction seen on a
family that was not used to derive it.

**The third does not fit any latch outcome**: `> 179` is longer than `172 + 7`,
so no choice of which value was latched reaches it. Measured rather than
inferred — with `SCX_FINE_LATCH_LIVE` on, `scx3_1` stays red on both devices
and `scx1_1 [cgb]` stays red too. Whatever supplies the extension in bracket 1
is needed here as well, and the window is not it.

The DMG arm carries a second fact that no candidate explains. At `scx3_1` our
latch DOES take `$07` — length 179, edge 259 — and the read at dot 261 samples
dot 259, where we report mode 0 and hardware reports mode 3. So hardware's edge
is past 259 and **hardware's mode 3 is longer than the plain `172 + F` whichever
value it latched**: by ≥ 1 dot if it latched 7, by ≥ 5 if it latched 3.

### Bracket 3: the plain per-SCX ladder, in dots

`m2int_m3stat/scx/m2int_scxN_m3stat_{1,2}` has DMG arms at N = 2, 3, 5 and each
pair brackets the 3 → 0 edge to one M-cycle with **no mid-line store at all**.
The STAT read samples the mode bits at `cc − 2` (`STAT_READ_SAMPLE`), so:

| SCX | our len | our edge | hardware's edge | hardware's length |
|---|---|---|---|---|
| 2 | 174 | 254 | (255, 259] | (175, 179] |
| 3 | 175 | 255 | (255, 259] | (175, 179] |
| 5 | 177 | 257 | (259, 263] | (179, 183] |

Solving `172 + s + K` against all three leaves **K = 3 or 4**. So on DMG, as the
STAT mode field reports it, mode 3 is three or four dots longer than this tree
computes, uniformly in the residue.

### The hypothesis this round was sent to test, and its refutation

The proposal was that the STAT mode field might have its own placement rule,
distinct from the pixel stream and from the interrupt sources — which would let
the field pay those 3–4 dots where `M3_END_EARLY`, `LCD_ON_HEAD_START` and
`LCD_ON_LINE0_TRIM` are each refused, and would give the same-wake pair the
degree of freedom it needs.

The seam exists and is clean: `stat_chg_dot` is the field's own timestamp and
nothing else reads it, so `STAT_MODE0_LAG` and `STAT_MODE3_LAG` move the field
and leave the mode-0 STAT source, the HBlank DMA trigger, the VRAM/OAM unlock
and the whole pipeline exactly where they are. Both were built and swept.

**`STAT_MODE0_LAG = 1` costs 98 rows and buys 16 — gambatte 4004 → 3922.**
Every one of the 98 is a `_2` member expecting `out0`, i.e. the same brackets
read from the other side: `sprites` alone loses 63. The field's 3 → 0 report is
pinned to the dot by hundreds of rows, and the three SCX-residue rows that want
it 3–4 dots later are outnumbered and contradicted rather than merely
outvoted. **A uniform field lag is two-sided refused.**

`STAT_MODE3_LAG = 1` (positive, the 2 → 3 edge) is +1 / −4, refused by
`m2int_m2stat/m2int_{,scx4_}m2stat_ds_2`, which read mode 3 immediately after
that edge.

### What the round DID sharpen: the same-wake contradiction is a register question

The old statement of it goes through the halt phase. It can now be stated
without mentioning halt at all, on one device and one edge.

`halt/lycirq_m2stat_2` splits its devices in the filename
(`dmg08_out2_cgb04c_out3`): out of the same wake, on the same line, at the same
dot, **a DMG reads mode 2 and a CGB reads mode 3**. dingbat reads 2 on both, so
the DMG arm is green and the CGB arm is red. Expressed as the field's own
placement it is one M-cycle: `STAT_MODE3_LAG_CGB = -1` makes the CGB field
report mode 3 one dot sooner and the row goes green, and `speedchange` gains two
more.

It is refused, on the same device and the same edge, by six rows that read the
field just as directly:

| row | wants |
|---|---|
| `halt/lycirq_m2stat_2 [cgb]` | the CGB 2 → 3 field edge **earlier** |
| `m2int_m2stat/m2int_m2stat_1 [cgb]` | where it is |
| `sprites/10spritesPrLine_m2stat_1 [cgb]` | where it is |
| `ly0/lycint152_m2stat_1 [cgb]` | where it is |
| `enable_display/nextstat_1 [cgb]` | where it is |
| `enable_display/frame{0,1}_m3stat_count_1 [cgb]` | where it is |

Net at −1: **+3 / −6, gambatte 4004 → 4001.**

The one structural difference between the row that wants motion and the five
that refuse it is still the **halt** — so the contradiction has not moved, but
it is now known to be *unreachable from the register side*: the refusers are
themselves STAT-field readers, so no rule that places the field can separate
them. That closes the door this round was sent to open, and it closes it with
its own witnesses rather than by argument.

### `SCX_FINE_LATCH_LIVE`, re-priced and still off

Round 1 left it off at +6 / −1 for +0.446% of retired instructions, with the
question of whether the mode-3-end structure was what it was missing. It is
not: with the window on, `scx_m3_extend_{1,ds_1}` still read mode 0 where
hardware reads mode 3, the totals are unchanged at 4009/5005 and the traded row
is the same `enable_display/ly0_late_scx7_m3stat_scx1_2 [dmg]`, and the
`ly0_late_scx7` rows that want mode 3 longer stay red with it on. The extension
is a different mechanism from the sample window and the two do not compose.

### The bracket handed forward

Mode 3's length under a mid-line SCX store, which is now measured on four
independent rows and fitted by nothing:

* store 1 dot after the latch, `F = 3 → 7`: extension **≥ 1** dot over
  `172 + 7`, or ≥ 5 over `172 + 3` (DMG `ly0_late_scx7_m3stat_scx3_1`)
* store 1 dot after the latch, `F = 7 → 5`: extension **7–10** dots (CGB
  `scx_m3_extend`)
* store 5 dots after the latch, `F = 7 → 5`: extension **11–14** dots (DMG
  `scx_m3_extend`)
* no store at all: extension **3–4** dots, uniform in the residue (DMG
  `m2int_scx{2,3,5}_m3stat`)

The last line is the one to explain first, because it needs no store: three or
four dots are owed on the plain per-SCX mode-3 length as the field reports it,
and a field-only payment is now refused, so the payment has to be somewhere that
`sprites`' 63 `_2` rows do not see. The `_2` rows all carry OBJECTS; the three
that want the dots do not. **Base length up 3–4 and the OBJ penalty down 3–4 is
the one composition that is still open**, and `tools/gbppu/objtab.py` against
`ppu_spritex_vs_scx` is the instrument that prices it — it is 153/153 today, so
it is a real constraint rather than a free parameter.

## 2026-08-10 (round 3): the composition lands, three suites disagree, and it ships off

Round 2 left one composition open: hardware's plain per-SCX mode-3 length solves
to `172 + s + K` with K = 3–4, every row refusing a payment carried OBJECTS and
the three demanding it carried none, so "base up by K, first-object penalty down
by K" should separate them.

**The composition is real and it works — and it is then refused by a suite that
was not in the original argument.** It is derived, implemented, measured on
three suites, and ships at 0. `STAT_M0_FIELD_TAIL` in `gb.nim` carries it.

### The rule is not base-plus-OBJ, it is FIELD-plus-OBJ, and the data says which

The rows were classified by whether their lines actually carry objects — run
under `-d:gb_m3_len` and read the `objx=` list (`tools/gbscx/hasobj.sh`) —
rather than by family name, which is what turned the two-way split into a
three-way one:

| observable | objects | rows | says our 3 → 0 edge is |
|---|---|---|---|
| interrupt | none | `m0enable/disable_scx{1,2,3,5,7}` ×10 | **right** |
| field | none | `m2int_scx{2,3,5}_m3stat_1 [dmg]` ×3 | **3–4 dots early** |
| field | **yes** | `sprites/*_m3stat_2` ×63 | **right** |

Rows 1 and 2 differ only in the OBSERVABLE, so the dots cannot be paid by moving
the edge: `M3_END_EARLY = -1` is **+41 / −138** with `m0enable` −24, and
`m0enable` is object-free and reads the interrupt. Rows 2 and 3 differ only in
the OBJECTS, so the field's payment has to be absorbed by an object fetch: an
unabsorbed field lag is round 2's `STAT_MODE0_LAG`, **+16 / −98** with `sprites`
−63. Both halves are two-sided, so the shape is forced:

> **On a DMG the STAT register's mode FIELD keeps reading 3 for three dots after
> the PPU has entered mode 0, and an object fetch on that line consumes those
> dots.** The mode-0 STAT source, the HBlank DMA trigger, the VRAM/OAM unlock and
> the whole pixel pipeline still turn on the PPU's own dot; only the field's own
> timestamp moves.

The absorption is by **objects specifically**, and that was measured rather than
assumed. Absorbing by the whole excess over `172 + SCX and 7` — which also counts
the window's penalty, and is the more obvious rule — scores **4008** against
4044 and hands back all 42 `window` gains. Only the object fetch drains this
tail, which is what `MIXER_TAIL_DOTS` already records about the mixer's tail one
stage upstream.

`K = 3` is a strict local maximum, swept whole-suite: 2 is +30 / −3, **3 is
+46 / −6**, 4 is +57 / −27. The CGB's value is **0**, bracketed from above —
at 1 the whole `m2int_m3stat` ladder's `_2` members go red on CGB (4015) and at
2 it is 3979. That the devices differ was predicted before it was measured, by
round 2's `scx_m3_extend` brackets, which are themselves one M-cycle apart
((269, 273] on DMG against (265, 269] on CGB).

### What it buys, including from suites that had no say in deriving it

* **gambatte 4004 → 4044**, +46 / −6. Four of the gains are the derivation's own
  rows; **42 are `window`** (+42 / −5), which was not used at all.
* **mooneye-wilbertpol +6 / −0**: `intr_2_mode0_scx{1,2,3,5,6,7}_timing_nops`,
  one row per residue, all red → green.

Two independent suites agreeing on a quantity derived from a third is as strong
as this tree's evidence gets.

### Why it ships at 0: GBMicrotest refuses it from both sides

`win{0..15}_{a,b}`, `win{0,10}_scx3_{a,b}` and `ppu_sprite0_scx{1,2,3,5,6,7}_{a,b}`
are PAIRS that bracket the same field report to one M-cycle. On the shipping
tree **both halves of every pair are green** — the report is pinned exactly where
it is, from both sides. At K = 3 the `_a` halves stay green and all **24 `_b`
halves go red**, with `actual = 0x83` against `expected = 0x80`: mode 3 where
hardware has already moved on.

Those 24 are object-free field readers, 18 of them on WINDOW lines — the same
class as the 42 gambatte `window` rows that go green. So no rule keyed on the
observable, on objects, or on the window can separate them.

The whole ledger: **gambatte +46 / −6, mooneye-wilbertpol +6 / −0, GBMicrotest
+0 / −24**, local runner 773 → 755. Three suites, one quantity, no agreement.

This is the same wall `M3_END_EARLY` records from the opposite side — that
constant makes GBMicrotest green and gambatte/mooneye red, this one makes
gambatte/mooneye green and GBMicrotest red. **Moving the payment from the EDGE
to the FIELD, which is exactly what this round set out to test, changes which
side is satisfied without dissolving the contradiction.** That is the round's
result, and it is a sharper statement of the tree's oldest open bucket than the
one it replaces: the disagreement is not about interrupts versus reads, and not
about objects, because the field/object split was built and it separates every
pair except this one.

### The same-wake pair in the new geometry (task 3)

Unmoved, and now known not to be reachable this way either. The tail is DMG-only
and `halt/lycirq_m2stat_2 [cgb]` and `dma/hdma_late_disable_*` are both CGB, so
neither can see it — `hdma_late_disable` is byte-for-byte unchanged in every
world built here.

The round-3 question was whether the object split separates the five same-device
refusers of `STAT_MODE3_LAG_CGB`. **It does not, and one row settles it:**
`m2int_m2stat/m2int_m2stat_1 [cgb]` is object-FREE (`hasobj.sh`, zero object
lines) and refuses the motion, while `halt/lycirq_m2stat_2 [cgb]` is object-free
too and demands it. Same device, same edge, same observable, same object class —
so no rule keyed on any of those four axes can hold one still and move the other.
`dma/hdma_late_disable_1` is also object-free, which removes the last hope that
the OBJ term could have shielded it.

### `SCX_FINE_LATCH_LIVE`, re-priced again (task 4)

Unchanged and still off. The field tail is DMG-only and per-line, the latch
window is per-store and device-independent, and they compose almost additively:
with both on the suite reads **4049** (+52 / −7) against 4044 and 4009
separately, the two mechanisms' gains being disjoint and one extra row
(`enable_display/ly0_late_scx7_m3stat_scx3_2 [dmg]`) falling out of the
interaction. Neither reaches `scx_m3_extend`, which still wants the 11–14 dots
nothing in this round supplies.

### Perf

Off is free and that took the round-1 lesson to get: the object accumulator
`obj_dots_line` is declared inside `when STAT_M0_TAIL_ANY`, so a default build
carries neither the field nor the add in the object-fetch path. blargg
cpu_instrs, 2400 frames after 300 warmup, five interleaved runs, `cycles=`
identical in all ten: the default build is 27,888,244,364 retired instructions
against main's 27,888,4xx, i.e. the same build; **turning the tail on costs
+0.253%**.

### The bracket handed forward

The contradiction is now fully localised and it has exactly three parties, all
reading the mode-0 boundary on object-free lines:

* GBMicrotest `win*_{a,b}` + `ppu_sprite0_scx*_{a,b}` — the field report is HERE,
  bracketed both sides, 24 rows.
* gambatte `m2int_scx{2,3,5}_m3stat_1` + 42 `window` rows — the field report is
  **3 dots later**.
* mooneye-wilbertpol `intr_2_mode0_scx*_timing_nops` — agrees with gambatte,
  6 rows.

What has NOT been tried is the possibility that these three disagree because they
sample the field through different CPU paths rather than because the field moves:
GBMicrotest's `win*_b` read STAT with a different instruction sequence from
gambatte's `m2int_*`, and `STAT_READ_SAMPLE` is one shared constant for all of
them. A per-instruction or per-bus-cycle read phase is the one axis this round
did not touch, and it is the only one left that can be keyed on something all
three witnesses actually differ in.

## 2026-08-10 (round 4): the three suites read STAT with different instructions

Round 3 ended with one quantity and three suites that would not agree about it,
and named the last untested axis: they might sample the field through different
CPU read paths. **They do, the correlation is exact, and gating on it lands the
whole thing.** Local runner **773 -> 779**, gambatte **4004 -> 4044**, and no row
anywhere goes the other way.

### The idioms, read off the ROMs

`tools/gbscx/readidiom.py` finds every instruction in a ROM that can address
`$FF41` and reports which M-cycle of its own instruction performs the IO read.
Run over a representative of each party:

| party | ROM | idiom | IO cycle | wants the tail? |
|---|---|---|---|---|
| GBMicrotest | `win0_{a,b}`, `ppu_sprite0_scx1_b` | `LDH A,($41)` | **M3 of 3** | **no** (24 rows) |
| gambatte | `m2int_scx3_m3stat_1`, the `window` set | `LD A,(C)` | **M2 of 2** | **yes** (45 rows) |
| mooneye-wilbertpol | `intr_2_mode0_scx1_timing_nops` | `LD A,(HL)` | **M2 of 2** | **yes** (6 rows) |

That is three independent suites, written by three different authors, and the
one thing that predicts which side of the disagreement a row falls on is the
addressing form of its read. Cross-tabulated over every row the field tail moves
(`tools/gbscx/idiomtab.sh`), gambatte's own moved rows are 45 gained / 5 lost on
`LD A,(C)` and exactly 1 gained / 1 lost on `LDH A,($41)` -- and those two are
the rows the gate then stops moving.

### The rule, and its bracket

> **An IO read sees the mode-0 field tail only if its IO cycle is its
> instruction's second M-cycle.** A read on the third (`LDH A,(n)`) or fourth
> (`LD A,(nn)`) does not.

`STAT_M0_TAIL_MAX_MC`, and it is bracketed on the structural quantity rather
than on an opcode list. Full local runner, one build per value:

| `MAX_MC` | what sees the tail | runner | gambatte |
|---|---|---|---|
| 1 | nothing — mechanism off | 773 | 4004 |
| **2** | `LD A,(C)`, `LD A,(HL)` | **779** | **4044** |
| 3 | + `LDH A,(n)` | 755 | 4044 |
| 4 | + `LD A,(nn)` | 755 | 4044 |

The boundary sits strictly between an IO read on its instruction's second
M-cycle and one on its third: at 3 GBMicrotest's 24 `LDH` rows go red, at 1 the
45 gambatte and 6 wilbertpol rows never go green. `K` re-bracketed in the new
geometry is still a strict local maximum — 2 is 777/4030, **3 is 779/4044**,
4 is 777/4035.

The term also had to move from the mode CHANGE to the READ, because two of the
three things that decide it are properties of the reader (the object absorption
and now the idiom). That move is behaviour-neutral on its own, measured +0/-0.

### What this does and does not claim

It is a fact about the ROMs before it is one about silicon: the parties really
do use different instructions, and gating on that reconciles 75 rows across
three suites with zero losses. Whether hardware's field is genuinely sampled at
a different point for a 3-M-cycle read, or whether the two idioms differ in
something else that happens to track the M-cycle index, **this evidence cannot
say** — every `LD A,(C)` witness in the tree is gambatte's and every
`LDH A,($41)` witness is GBMicrotest's, so idiom and suite are perfectly
confounded. That is exactly what hardware experiment (a) below is for, and it is
cheap: the same frame, the same dot, read twice with the two idioms back to
back.

### Perf

`+0.31%` of retired instructions, and it does not touch the mode 3 dot loop.
blargg cpu_instrs, 2400 frames after 300 warmup, four interleaved runs,
`cycles=` identical throughout: off is 27,888,682,794 (the same build as main,
to 0.001%) and on is 27,973,905,259. Attribution, since it was chased: ~0.25% is
the tail itself and ~0.05% the per-instruction opcode capture the gate needs;
moving `stat_m0_tail` out of line and moving `obj_dots_line` into the cold
block were both tried and neither recovers it. One `-d:STAT_M0_FIELD_TAIL=0`
reverts the whole mechanism at no cost.

Witness ladder byte-identical throughout (both acid2, both strikethrough,
cgb-acid-hell at rev C and E, daid on DMG and on CGB at rev C and D); mealybug
1863574 / 552960 unmoved on both devices.

## 2026-08-10: the DMG BGP transition pixel is a THREE-way split, and daid ships all three

Chased from a lead outside the tree — TASVideos submission
[9604S](https://tasvideos.org/9604S) — on the theory that a mid-pixel register
write ORs old and new, and that this might be what `cgb-acid-hell`'s last two
pixels are. The lead is **right about DMG BGP and cannot touch acid-hell**, and
chasing it turned up something the tree did not know: daid's three accepted DMG
references are the three outcomes the submission names, one dingbat build each.

### What the source actually claims, and what it does not

Submission 9604S is CasualPokePlayer's Pokémon Red arbitrary-code-execution
playaround, submitted 2025-03-30. Its linked forum thread
(`/Forum/Topics/26158`) was read too and adds nothing to the submission text.
Three claims, quoted:

* **The register is open.** "Unlike VRAM, the BGP register is never locked, and
  may be freely modified during Mode 3."
* **The three-way outcome.** "writing to BGP during rendering may result in the
  old palette and new palette values being OR'd together for one pixel on some
  Game Boys, or it might result in the old value still being used for a pixel,
  or it might result in the new value just being used as you'd normally expect.
  **This is dependent on the LCD revision used**."
* **The device split.** "On the Game Boy Color luckily, this doesn't matter so
  much, as the new color LCD used does not have this quirky behavior (the same
  goes for the Super Game Boy and Game Boy Advance anyways)."

**What it does not claim, and the negatives are load-bearing.** It says nothing
about WX, WY or LCDC — the OR is BGP-specific, and nothing in the submission
extends it to any other mid-line write. It names no unit count, no serial, no
device revision number and shows no photograph: this is a TAS author's working
note, not a capture, and it is treated below as a hypothesis with a specific
shape rather than as evidence. It also never says what physically ORs with
what. "the old palette and new palette values" is register-level wording, but
"dependent on the LCD revision used" puts the cause in the LCD assembly, which
sits *downstream* of the palette lookup. The source is internally in tension on
mechanism, and the next section shows why that tension is unresolvable from
pixels.

### Corroboration: the effect is solid, the "LCD revision" attribution is not

Searched for independent sources, with one clear negative result first.

**Pan Docs does not cover this at all**, so it is not citable here. Its
`Palettes.md` documents BGP only as a value-to-shade table; the single relevant
sentence in `Rendering.md` treats mid-scanline BGP writes as a *timing
instrument*, not a glitch ("mid-scanline writes to `BGP` allow observing this
behavior precisely, as any delay shifts the write's effect to the left by that
many dots"). `pixel_fifo.md` describes the per-pixel BGP read with no
write-conflict discussion, and gbdev/pandocs#379 explicitly defers this class of
material. Nothing in gbdev.gg8.se, GBEDG, gb-ctr or mGBA's gbdoc either.

**The primary source is [SameBoy issue
#65](https://github.com/LIJI32/SameBoy/issues/65)** (mattcurrie, 2018), filed
with photographs of real DMGs, and it is where the OR was established:

* LIJI32's first guess was the **opposite polarity** — "My guess is that the
  value read by the PPU in that moment is the result of a bitwise **AND**
  operation between the old and new version."
* mattcurrie settled it empirically by sweeping every colour transition:
  "**Shows that ORing the values is correct**, as you've done."
* The device split was in the first post: "The effect isn't seen on my MGB or
  CGB, **only on DMG**." Two DMGs (a DMG-CPU B and a blob) both showed it.
* The one physical mechanism anyone has proposed is PinoBatch's, quoted there:
  "When one component writes a value at the exact time something else reads it
  the time for the value to rise may differ from the time for it to fall. **A 1
  may linger longer than a 0 or vice versa.**" A lingering 1 in either operand
  is *mechanically* a bitwise OR, which is why the operation is what it is.

SameBoy implements it as `GB_write_memory(gb, addr, value | old_value)` for one
T-cycle before writing the true value (`Core/sm83_cpu.c`,
`GB_CONFLICT_PALETTE_DMG`) — the same shape dingbat arrived at independently.
Its conflict maps corroborate the device half of the submission directly: SGB is
`GB_CONFLICT_READ_NEW` and CGB/AGB write the new value.

**The strongest independent statement is daid's own**, in
[GBEmulatorShootout#9](https://github.com/gbdev/GBEmulatorShootout/issues/9),
and it is stronger than the submission's:

> "I'm quite sure this behavour is **instance depended**, so if you take 10 DMGs
> they don't all act the same. My own DMG does 1 or 2 **depending on the
> position in the scanline**. So even if the gambatte testrom shows something,
> it might act different on a different scanline. There is also difference
> between the **stock screen and modded screens**."

and the suite's own description (`testroms/daid.py`): "Which case occurs seems
to be **hardware and instance dependent** as some DMGs do not do a consistent
single case."

**So the submission's "This is dependent on the LCD revision used" is the
author's own framing and is corroborated by nobody.** No source anywhere maps
any of the three behaviours to a named DMG-CPU or panel revision; the total
published sample across every source found is about four units. The community
phrasing is "hardware and instance dependent", and daid's *intra-scanline*
variation on a single unit is a materially different and stronger claim than a
per-unit revision constant — it describes a metastable race, not a logic
difference. The screen-mod dependence is the only thing pointing at the panel,
and it is equally explained by a mod board re-sampling the shade lines on its
own clock.

**The ecosystem does not agree with itself**, which is worth knowing before
treating any single reference as truth: gambatte's `dmgpalette_during_m3*`
images encode the *clean-edge* behaviour, mealybug ships exactly **one** DMG
reference per BGP ROM and canonises the *OR*, and BizHawk's
`GambatteSuite.Cases.cs` carries the collision as ~20 permanent known-failures
("`dmgpalette_during_m3_3 on DMG in SameBoy`"). Notably mealybug's own
comprehensive PPU document, which details revision splits for `TILE_SEL` and
`SCY`, **has no palette section at all** — the one person who systematically
documented PPU revision differences never wrote this one up.

### Analog or digital is not observable here, and that is provable

OR is bitwise and a palette byte is four independent 2-bit fields, so for the
one colour index `c` a pixel actually uses,

    (old or new)[c]  ==  old[c] or new[c]

ORing the two register bytes and then looking the shade up is **arithmetically
identical** to looking the shade up in each palette and ORing the two 2-bit
shades on the wire to the panel. So "a digital latch read on the dot it is
written" and "an analog OR on the LCD drive lines" produce the same framebuffer
for every possible input, and no reference frame — daid's, mealybug's, or one
not yet captured — can separate them. dingbat implements the first spelling;
the second would be a comment change, not a code change.

**Where the distinction would bite, and it is the reason to keep it in mind.**
An analog drive-line mechanism lives on the 2-bit shade bus between the PPU and
the panel. It is downstream of every fetch, so it can perturb a *displayed
shade* and can never perturb a *byte read out of VRAM*. That is what disposes
of the acid-hell half of the lead below.

### What dingbat does today: it already implements the OR, derived independently

`MIXER_PALETTE_OR` (`gb/gb.nim`), applied at the FF47..FF49 write in
`gb/ppu.nim`. On DMG only, the single oldest pixel a palette write still reaches
(`MIXER_PALETTE_BACK` = 2 dots back) is recomposed as `old or new` on the packed
byte and every nearer pixel takes the new value cleanly; on CGB the effect is
suppressed, because that revision's own dot of write latency
(`CGB_MIXER_LATENCY`) puts the pixel out of reach.

It was derived on 2026-08-08 from **mealybug `m3_bgp_change`**, whose frame is
BGP's low two bits sampled once per dot — not from daid, and not from this
submission, which was not known here until today. The two derivations are
therefore independent and they agree on all three of the things that can be
checked: that the effect exists, that it lasts **exactly one pixel**, and that
it is DMG-only. The code's note already records the device half by measurement:
running the same two DMG carts on CGB hardware wants the clean edge
(`m3_bgp_change` 22732 with it, 22321 with an OR pixel).

### The new result: daid's three DMG references are the three outcomes

`daid/ppu_scanline_bgp` ships `_0`, `_1` and `_2` as equally accepted DMG
references and the runner passes on any of them. Scoring all three against
three builds that differ only in how a palette write reaches the mixer tail:

| build | `_0` | `_1` | `_2` |
|---|---|---|---|
| `MIXER_PALETTE_OR=1`, `BACK=2` — **shipping** | 22576 | **23040** | 22576 |
| `MIXER_PALETTE_OR=0`, `BACK=2` | 22464 | 22576 | **23040** |
| `MIXER_PALETTE_OR=0`, `BACK=1` | **23040** | 22576 | 22464 |

Every row is pixel-exact on exactly one reference and 464-576 pixels out on the
other two. There is no partial credit anywhere in the table, and the mapping
onto the submission's three-way sentence is exact, in its own order:

* **`_0` = "the old value still being used for a pixel"** — the write reaches
  one pixel less deep, so the deepest pixel in the tail keeps the old palette.
* **`_1` = "the old palette and new palette values being OR'd together"** —
  what ships.
* **`_2` = "the new value just being used as you'd normally expect"** — a clean
  edge at full depth.

This is the first thing in the tree that explains **why the shootout ships three
accepted references for one ROM**. They are not three tolerances or three
capture artefacts: they are the three documented outcomes, each reproducible
here byte-for-byte by a one-constant change.

**The suite's own commit history confirms the mapping independently, and it was
not consulted until after the table was measured.** `_0` and `_1` were added
together by daid on 2021-01-05 ("Allow two different results for the mid
scanline BGP change"); `_2` was added by CasualPokePlayer in PR #10 on
2022-04-05, whose issue #9 names the three cases with their emulator
attributions — "1. Old BGP is read (**bgb** behavior), 2. Bitwise OR between old
and new BGP is read (**SameBoy** behavior/what this test expects), 3. New BGP is
read (**Gambatte** behavior/what Gambatte's test suite expects)". So `_2` is by
construction the Gambatte/new-value case, which is exactly the reference the
`MIXER_PALETTE_OR=0` build lands on, and `_1` is by construction the SameBoy/OR
case, which is exactly where the shipping build lands. Three independent
routes — dingbat's mealybug-derived constant, the reference set's provenance,
and the submission's prose — agree on which image is which.

`BACK=1` is a whole-frame configuration built only to see which reference it
lands on. It is **not proposed for shipping** and was not scored past this
frame; the claim is about the mapping, not about the constant.

### What the instance-dependence claim does to the `_1` match

The `_1` match stays derived truth, and the derivation is now *bounded*, which
is the more useful state:

* The OR does not depend on daid at all — it came off mealybug — so `_1` is a
  **second, independent witness** that dingbat happens to match exactly.
* But "on some Game Boys" means `_1` is **one unit**, not "the DMG". dingbat
  cannot be right about all three references at once, and shipping `_1` is a
  choice *among instances* — structurally like the CGB-C/D palette-latency split
  the tree already makes runtime-selectable through `--cgb-rev`, except that
  nobody has established which instances, so there is not even a name to give
  the setting yet.
* So the honest restatement: **`MIXER_PALETTE_OR` is not a correctness constant,
  it is a revision constant that has no runtime selector yet.** If a DMG
  revision axis is ever wanted, this is its first member, and daid's three
  references are a ready-made scoring set for it — one build per revision, each
  pixel-exact, already measured in the table above.
* And the operational consequence for any future probe: **a DMG that shows a
  clean edge has not refuted the OR.** Expecting one answer is the mistake the
  claim is warning about.

**The sharper version of the same worry, from daid.** If one unit really does
"1 or 2 depending on the position in the scanline", then no per-frame constant
of any value is right, and `MIXER_PALETTE_OR` is an approximation to a
metastable race rather than a model of it. Two things bound how much that
matters here. Against it: the effect would then be position-dependent and
dingbat's is not. For it: dingbat is **23040/23040** against `_1` — a whole
frame, every write site, every scanline — so whichever unit produced that
capture behaved *consistently* across the line, and a position-dependent model
would have to reduce to the constant one on this ROM anyway. The residual risk
is that `_1` is one capture of a race and the tree has fitted a constant to it;
that is exactly what the probe below is for, and it is why the probe is
specified as **many units**, not one.

### The acid-hell verdict: the OR cannot reach those two pixels, four ways

The lead's second half — that an OR composite might explain `cgb-acid-hell`'s
residue, where the glitched fetch delivers a byte that is neither the old nor
the new one — is **refuted**, and each refutation is independent of the others.

**1. Wrong device, by the source's own sentence.** acid-hell is a CGB ROM and
the submission explicitly exempts the CGB LCD. The tree measured the same split
from the other side (the CGB run of the DMG carts wants the clean edge).

**2. Wrong data path.** acid-hell's failure is a *bitplane byte read out of
VRAM by the fetcher*. Whether the BGP effect is the digital latch or the analog
drive lines, both live at or after the shade lookup, which is downstream of
every fetch. Nothing in the BGP mechanism has a wire that reaches a fetch.

**3. The two pixels refute any fixed-polarity composite by disagreeing with each
other.** Read straight out of the current tree's `-d:gb_px_trace`:

| | HW | dingbat | `num` | `latch`/`uns`/`sgn` | `prevd` |
|---|---|---|---|---|---|
| `ly=68 lx=76 plane 1` | `$55` | `$5D` | `$55` | `$5D` | `$7F` |
| `ly=69 lx=76 plane 1` | `$49` | `$41` | `$49` | `$41` | `$7F` |

`ly = 68` needs `$5D and $55` — an **AND**. `ly = 69` needs `$41 or $49` — an
**OR**. One frame, one ROM, two adjacent lines, and they demand opposite
polarities, so no wired-OR and no wired-AND explains both. The only single
source that explains both is `num`, the tile index, which is what the shipping
`CGB_TDSEL_GLITCH` rule already delivers. (`num and prevd` matches both and is
a decoy: `prevd` is `$7F` on both lines, so the AND is arithmetically just
`num`, and it scores 136/192 on the corpus.)

**4. There is no substitution event left to re-value.** In the shipping world
neither disputed read is glitched at all — `glitch = 0` on both, the LCDC.4
change lands 4 dots off the read dot, and `tdselcells.py` puts acid-hell's
contribution to the corpus at **0 cells of 408**. A rule about *which byte* a
glitched read returns, of any shape whatever, has nothing to fire on. The
residue is a missing trigger, and the 2026-08-14 `tdselphase.py` table already
brackets that door shut from both sides.

### The composite hypothesis, priced on the whole corpus

Worth a number rather than an argument, so the OR family was scored as a
substitution source against all 408 cells (`tools/gbppu/tdselcells.py` rebuilt
on this tree: 216 SET / 192 RESET, self-check 0 wrong on all four mealybug
frames and exactly the 2 known planes wrong on acid-hell). Best of each kind:

| branch | source | score |
|---|---|---|
| RESET | `num` — **shipping** | **192 / 192** |
| RESET | `num or sgn` | 164 / 192 |
| RESET | `num and prevd` | 136 / 192 |
| RESET | `num and latch` | 134 / 192 |
| SET | `latch` — **shipping** | **216 / 216** |
| SET | `latch or prevd` | 202 / 216 |
| SET | `latch or sgn` | 196 / 216 |
| SET | `latch and uns` | 164 / 216 |

**Twenty composites were scored** — each branch's shipping source combined with
each of the five other candidate bytes, in both polarities — and **not one
reaches the clean single source**. The sharp form of that, which is the part
worth carrying: for **every one of the twenty**, the number of cells where the
composite *differs* from the clean source and the number where it is *wrong* are
the same integer — 20 and 20, 74 and 74, 157 and 157, 14 and 14, 180 and 180.
**Every cell in the corpus that can tell a composite from a clean source votes
for the clean source**, and the discriminating counts run from 14 to 180, so
this is a refutation and not a degenerate tie. Hardware's substituted byte is
one byte off one wire, on all 408 of them.

The scorer is committed as `tools/gbppu/tdselor.py` (it takes
`tdselcells.py`'s corpus JSON, and given the traced binary as a second argument
also re-reads acid-hell's two disputed planes, which are the table above).

### Nothing was built behind a `-d:` flag, and that is the finding

The rule this lead would have wanted — a `CGB_TDSEL_OR`-shaped constant making
a glitched read return `old or new` — was never compiled, because it died at
two cheaper and stronger gates: the arithmetic of two pixels that demand
opposite polarities, and a 408-cell corpus in which every discriminating cell
refuses every composite. Building it would have cost a rebuild and bought a
number already known from the corpus JSON. The refutation is the deliverable.

## The four hardware experiments this campaign leaves wanting

Written to be added to a probe ROM rather than to be argued about. The natural
home for (a) and (b) is `tests/roms/gbedge.py`, which already has the paging
viewer, the two-pass assembler and the determinism contract they need — each is
one page, one 32-byte result slot, raw values and no baked-in expectation. (c)
and (d) need pixels and so belong in the visual ROM (`gbvis.gb`, earmarked v3 in
`docs/hwprobe-questions.md`); (d) is also the only one of the four that needs
more than one console.

An AGB in GB-compat mode is a valid GB revision for all three; where it differs
from a DMG or a CGB that is itself the answer to a question this campaign asked
(the DMG/CGB splits in `SCX_FINE_BORROW_DMG_LEAD`, `STAT_M0_FIELD_TAIL_CGB` and
`STAT_MODE3_LAG_CGB`).

**Status, 2026-08-11.** All three are written, as standalone `.gb` files in
`tools/gbprobe/` rather than as pages of `gbedge.py` — they need their own LCDC,
their own anchor and, for (c), a whole frame, none of which fits a paging viewer
— and all three have been run in dingbat, SameBoy and DocBoy through one
harness. The answer tables and a verdict per experiment are in
`docs/gb-probe-oracle-results-2026-08-11.md`; the headlines are that both oracles
predict "no" for (a) and that all three engines predict "no" for (c); that (b)'s
extension is a one-M-cycle WINDOW worth 8 dots rather than a ramp, in both
engines that have one, so `64b445c`'s live fine-scroll latch and SameBoy now
differ by one M-cycle of position on CGB rather than by a mechanism; and that
(a) and (b) both hand back a DMG/CGB mode-0 boundary split that two oracles
agree on and dingbat does not model. The ROMs are the artifact for the
cartridge: correct headers, raw values, on-screen hex, and the same reader
script for a photograph as for a framebuffer.

### (a) Does the STAT mode field report differently to two read idioms?

**Settles:** the three-suite disagreement that rounds 3 and 4 are built on, and
with it whether `STAT_M0_TAIL_MAX_MC` is a fact about silicon or an artefact of
which suite wrote which ROM. Idiom and suite are perfectly confounded in every
test ROM that exists — every `LD A,(C)` witness is gambatte's and every
`LDH A,($41)` witness is GBMicrotest's — so no amount of re-reading the suites
can separate them.

**Setup.** LCD on, `LCDC = $91` (BG on, **OBJ off** — the tail is absorbed by an
object fetch, so the line must be object-free), `SCY = 0`, `WX`/`WY` parked off
screen, `SCX = 3`. Anchor on a mode-2 STAT interrupt so the slide starts on a
known dot.

**The one thing the probe must get right.** The two idioms have different
lengths, so equalising the *instruction start* would compare different dots.
Equalise the **IO cycle**: `LD A,(C)` (`F2`, 2 M-cycles, IO on M2) needs one
more preceding NOP than `LDH A,($41)` (`F0 41`, 3 M-cycles, IO on M3) for the
two reads to sample the same PPU dot. Build the slide as

    <N NOPs> ; LD A,(C)      -> store          (C = $41 preloaded)
    <N+1 NOPs> ; LDH A,($41) -> store

as two separate runs from the same anchor, and sweep `N` over ±3 M-cycles about
the mode-0 boundary, storing the two bytes per step — 14 bytes, one slot.

**What each outcome decides.**

* The two columns flip from `3` to `0` at the **same** `N`: the per-idiom rule is
  refuted, `STAT_M0_TAIL_MAX_MC` should be deleted, and the field tail with it —
  the three-suite disagreement is then something neither round found, and the
  60-odd rows it currently reconciles go back to being open.
* `LD A,(C)` flips one step **later** than `LDH A,($41)`: the rule is confirmed
  as written and `STAT_M0_FIELD_TAIL = 3` is measured rather than fitted.
* They flip at different `N` in the other order, or by more than one step: the
  rule is real but the value is wrong, and the sweep reads the right one off
  directly.

Run it at `SCX = 0` as a control: with no fine scroll the ladder's own bracket
(K solves against `172 + s`) predicts the flip moves by exactly `s`.

### (b) How much does a mid-line SCX store lengthen mode 3?

**Settles:** the `scx_m3_extend` bracket, which is the one measurement this
campaign could not explain with any mechanism it built. dingbat extends mode 3
by **0** dots; the two gambatte rows bracket hardware at **11–14** dots on DMG
and **7–10** on CGB, and the extension grows with how late the store lands.
Nothing derived in four rounds produces that.

**Setup.** As (a): BG only, no objects, no window. `SCX = 7` written during
mode 2 so the line latches a fine scroll of 7. Then, from the same anchor, a
slide of `M` NOPs, `LD A,$05` / `LD (C),A` (the store that lowers `SCX and 7`),
then a slide of `N` NOPs and `LDH A,($41)`; store the byte.

**The measurement** is the smallest `N` at which the read returns mode 0, as a
function of `M`. Sweep `M` over 0..7 M-cycles (the store walking across the head
of mode 3, which is where round 2 showed the effect is store-position dependent)
and for each `M` sweep `N` over the four M-cycles around the boundary — 32
bytes, one slot, and the page reads out as the extension law directly.

Include `M` large enough that the store lands after the discard is spent, and
one row with `SCX` written to the SAME value (`$07 -> $07`) as the control: a
store that does not change the fine scroll must not extend anything, and if it
does, the mechanism is the store and not the value.

### (c) acid-hell against daid, on one frame

**Settles:** the shootout's 261st row, and the oldest pixel-level contradiction
in the tree — `cgb-acid-hell` needs the CPU's writes aligned to the BG fetch
grid where they are, while `daid/ppu_scanline_bgp` needs them four dots later
relative to pixel EMISSION, on the same device, out of the same kind of anchor.
dingbat cannot express both and ships the daid side, at a cost of exactly 2
pixels of acid-hell (23038/23040).

**Why one frame.** Both ROMs already share an anchor — `rSTAT = $40`, `rLYC = 0`,
`halt`, then writes down a NOP slide — which is why the campaign kept finding
they move together. Run on separate frames the two are two measurements of two
things; run on ONE frame they arbitrate, because the fetch grid and the emission
grid are then the same grid.

**Setup.** CGB. One frame, one halt anchor, and a slide that does both jobs:

* an `LCDC.4` toggle every 8 dots at the acid-hell phase (`$E3 <-> $F3`), over a
  tile column whose MAP INDEX differs from its DATA at the row being drawn — the
  glitched bitplane read then shows up as a tile that is unambiguously the index
  and not the data, which is the whole of the acid-hell residue;
* a `BGP` write on a fixed dot of the same line, against a background of flat
  tiles, so the band edge's COLUMN reads out emission's phase — daid's ruler.

Photograph the frame and read two numbers off it: the column of the BGP band
edge, and whether the glitched column shows the index. **If the band edge sits
where daid's `_1` reference puts it AND the glitched column shows the index,
hardware really does separate emission from the fetch grid by four dots on one
frame**, and the renderer needs the split that four rounds of constants could
not supply. If they cannot both be true, one of the two reference frames this
tree is scored against is not describing the machine in front of us, and the
2-pixel residue is a reference question rather than a model one.

### (d) The DMG BGP transition pixel, on as many DMGs as can be borrowed

**Settles:** whether `MIXER_PALETTE_OR = 1` is a fact, a revision, or a coin
flip — and it is the one experiment here whose *design* is dictated by the
literature rather than by the tree. Every published source says the answer
varies by unit ("if you take 10 DMGs they don't all act the same"), one says it
varies *within a single scanline* on one unit, and the total published sample is
about four consoles. So the experiment is not "photograph a DMG"; **the sample
size is the experiment**, and a single unit cannot produce a usable result.

This one needs pixels, so it belongs with (c) in the visual ROM (`gbvis.gb`,
earmarked v3 in `docs/hwprobe-questions.md`).

**Setup.** DMG. Flat background tiles so every pixel is the same colour index,
which makes the frame a direct read-out of BGP — the `m3_bgp_change` trick, and
the reason that ROM could derive the effect at all. Then, on one frame:

* **A colour-transition sweep, because the operation is only pinned by one.**
  The three outcomes coincide whenever `old or new` happens to equal `old` or
  `new` — which is how the effect hid in this tree until 2026-08-08 — so the
  probe must write BGP transitions where all three differ. `$E4 -> $1B` and
  `$11 -> $12` are the useful shapes (`$11 or $12 = $13`, neither operand).
  Sweep several transitions down the frame, one per band, and the band's colour
  says which of the three cases that unit did. This is mattcurrie's method in
  SameBoy #65 and it is what turned LIJI32's AND guess into the measured OR.
* **The same transition repeated at many X positions**, because daid reports one
  unit doing different cases at different points in a scanline. If a unit's
  bands are uniform across X, that claim does not reproduce and the constant is
  safe; if they are not, `MIXER_PALETTE_OR` is the wrong *shape* of model and no
  value of it is right.
* **A no-op control** — write BGP the value it already holds, at the same dot.
  A transition pixel that appears there is measuring the write and not the
  value.

**What to record per unit**, and it must be recorded per unit rather than
pooled: the mainboard and CPU markings (DMG-CPU-0x, and whether the die is
blobbed), whether the screen is stock or modded, and the photograph. The point
of the metadata is the one question every source leaves open — **nobody has ever
mapped a behaviour to a named revision**, and a table of six units with their
markings would be the first, whichever way it comes out.

**What each outcome decides.**

* Units split across the three cases: `MIXER_PALETTE_OR` is confirmed as a
  *revision* constant, and the DMG needs a `--dmg-rev`-style selector the way
  CGB already has `--cgb-rev`. daid's `_0`/`_1`/`_2` are then its scoring set
  and the three builds in the table above are its three settings, already
  measured and already pixel-exact.
* Every unit ORs: the submission's "LCD revision" framing is wrong, mealybug's
  single DMG reference is right, `MIXER_PALETTE_OR = 1` is a fact, and the
  shootout's `_0`/`_2` are capture or panel artefacts rather than silicon.
* Any unit varies **within** a scanline: the constant is the wrong shape, and
  what needs modelling is a race whose bias depends on position — the first
  thing in this tree that would be genuinely non-deterministic, and a good
  reason to keep accepting all three references rather than pinning one.

Two extra pages are nearly free and worth having: the same frame at `SCX and 7`
of 0 and of 3, since the campaign's one solid new structural result
(`SCX_FINE_BORROW`) says the fetch grid's column carries a borrow off the fine
scroll, and no reference frame in existence exercises that on a CGB.

## The mode-3 structure campaign, four rounds: what to read first

Written so the next session can start here rather than from the top of the file.
The campaign was asked to derive the CGB's mode-3 internal structure, starting
from `gambatte/scx_during_m3` (49/141, the tree's biggest open bucket) and
aiming at two quarantined contradictions. It ran four rounds.

**Headline: gambatte 3940 -> 4044, local runner 770 -> 779.** Two mechanisms
shipped, two are parked with prices, five axes are refuted with both sides
named, and four hardware experiments are specified above.

### What shipped

| | what it says | worth | cost |
|---|---|---|---|
| `SCX_FINE_BORROW` (+ `_DMG_LEAD`) | the BG fetcher's map column is `((SCX + 8k - F) >> 3)` -- a screen position plus the LIVE SCX, so SCX's low bits carry into the tile address; a mid-line store that LOWERS them borrows one tile | gambatte **+64**, AGE `m3-bg-scx` x3 exact | **-0.148%** (the dot loop got cheaper) |
| `STAT_M0_FIELD_TAIL` (+ `_CGB`, `_ABSORB`, `STAT_M0_TAIL_MAX_MC`) | on a DMG the STAT mode FIELD reads 3 for three dots after the PPU enters mode 0 -- absorbed by an object fetch on that line, and visible only to a read whose IO cycle is its instruction's second M-cycle | gambatte **+40**, mooneye-wilbertpol **+6**, GBMicrotest **0** | +0.31% |

Both were derived from a ruler rather than fitted, and both were confirmed by
suites that had no part in deriving them -- AGE for the first, `window` (42
rows) and mooneye-wilbertpol for the second.

### What is parked, with its price

* **`SCX_FINE_LATCH_LIVE`** -- the fine-scroll sample is a WINDOW, not a dot: a
  store joins the discard for as long as the discard has pixels left. Derived
  and two-sided (the window's length is `F` itself: at `F = 0` hardware refuses
  a store that the `F = 1` and `F = 3` ROMs accept at the same dot), worth
  **+6 / -1**, costs **+0.446%**. Off on price alone. Re-price it on a real
  cartridge workload; this worktree has none.
* **The `M3_END_EARLY` half of the K composition** -- paying the three dots at
  the EDGE rather than at the field. Refused: **+41 / -138**, with object-free
  interrupt rows (`m0enable`) leading the refusal.

### Refuted axes, each with both sides named

1. **A uniform STAT mode-field lag** (`STAT_MODE0_LAG`, round 2): **+16 / -98**,
   and every one of the 98 is a `_2` member expecting `out0`.
2. **A field lag at the 2 -> 3 edge** (`STAT_MODE3_LAG`): +1 / -4.
3. **A CGB-only 2 -> 3 field LEAD** (`STAT_MODE3_LAG_CGB`), which turns
   `halt/lycirq_m2stat_2 [cgb]` green: +3 / -6, refused by five rows on the same
   device reading the same edge -- and round 3 showed the object split does not
   separate them either, because `m2int_m2stat_1 [cgb]` is object-FREE and
   refuses while `lycirq_m2stat_2 [cgb]` is object-free and demands.
4. **Absorbing the field tail by any mode-3 excess** rather than by objects
   specifically: 4008 against 4044, and it hands back all 42 `window` rows.
5. **`lx < 0` as the fine-scroll window** (round 1): 3992, because the head's
   throw-away fetch parks the shifter long after the discard is spent.

Two more from the round-1 borrow, refuted on the frames themselves: *"the
discard re-arms and throws 8 more pixels away"* (refused by the residue -- every
measured span keeps the OLD fine offset, never the new one) and *"an extra tile
is fetched"* (refused by sign -- the spans sit one tile LOWER, a borrow).

### The two quarantined contradictions, as they now stand

**Same-wake** (`halt/lycirq_m2stat_2 [cgb]` against `dma/hdma_late_disable_{1,2}`).
Untouched by all four rounds, and now much better characterised: it can be
stated without mentioning halt at all. On the same wake, same line, same dot, a
DMG reads mode 2 and a CGB reads mode 3, and we read 2 on both; the motion
needed is one M-cycle in the field. It is refused on the same device and the
same edge by five other field readers, and the three axes that could have
separated them -- observable, objects, device -- were each built and each fails.
Everything in this family is object-free, `hdma_late_disable_1` included.

**acid-hell against daid.** `cgb-acid-hell` is 23038/23040 and the shootout is
260/261, unchanged. Nothing in four rounds could reach it, and that is now a
positive statement rather than an absence: neither ROM writes SCX mid-line and
neither reads the STAT mode field, so no mechanism this campaign built can see
them. Every world built in all four rounds left both acid frames, both
strikethrough frames, both acid2 frames and daid on three device/revision
settings **byte-identical**. Hardware experiment (c) is the way to settle it.

### The one bracket nothing explains

`scx_m3_extend`: a mid-line SCX store that lowers `SCX and 7` lengthens mode 3
by **11-14 dots on DMG and 7-10 on CGB**, and the extension grows with how late
the store lands (1 dot after the latch: >= 1 dot; 5 dots after: >= 11). dingbat
extends it by zero. The borrow's natural 8 does not reach it, the latch window
does not touch it, and the field tail is the wrong observable. This is the
campaign's largest single unexplained quantity, and hardware experiment (b) is
specified to measure its law directly.

### The instruments, and how to re-derive any of it

Everything is in `tools/gbscx/`, and each tool exists because a question could
not be answered without it:

| tool | the question it answers |
|---|---|
| `disasm.py` | what does this suite ROM actually do |
| `readidiom.py` | which instruction reads STAT, and on which M-cycle of it |
| `scxread.py` / `scxmap.py` | where did hardware put each pixel's background coordinate |
| `edgemap.sh` | what are the dots of the line a row actually scores |
| `hasobj.sh` | does this ROM's mode 3 carry an object at all |
| `idiomtab.sh` | cross-tabulate idiom against which side of a disagreement a row falls |
| `writedots.py`, `handlers.sh`, `ladder.sh`, `scxladder.sh` | the families as M-cycle rulers |
| `gamdiff.sh`, `sweep.sh`, `sweep2.sh`, `runsweep.sh` | attribute every moved row; one build per value, gambatte or the whole runner |
| `witness.sh` + `witdiff.sh` | the nine-frame ladder, world against world |
| `bench.sh` / `benchref.sh` | interleaved retired-instruction A/B, by flag or by git ref |
| `mb.sh`, `dumpfam.sh`, `build.sh`, `r.sh`, `env.sh` | mealybug, frame dumps, builds, environment |

The method that produced both shipped results is the same one twice: take a
family whose verdict is one integer, find the property of the ROM that turns its
frames or its dots into a **ruler**, read hardware's answer off it directly --
and then bracket the derived quantity from both sides before believing it.

## 2026-08-10 (round 5): the discard is a slot counter, and it wraps

The campaign's four rounds ended with one bracket nothing explained --
`scx_m3_extend`, a mid-line SCX store lengthening mode 3 by 11-14 dots on DMG
and 7-10 on CGB, store-position-dependent -- and a pointer at SameBoy's
changelog. This round pulled that bracket. **gambatte 4044 -> 4051**, and the
mechanism is one sentence.

The clue source is used as a clue source: what follows was read off SameBoy's
COMMIT HISTORY as a statement about hardware, and every quantity below is then
derived and bracketed against our own rows. No constant of theirs is adopted and
no code of theirs is copied.

### What the five changelog entries turned out to mean

| entry | release | what it discovered |
|---|---|---|
| "Improved accuracy of mid-line SCX writes, fixes Infinity" | v0.14.6 | The BG fetcher has **no column counter**. The column is a live combinational sum, `(SCX + x) >> 3`, and the commit deletes the fetcher's `x` register outright. Dividing the two terms separately -- the older form -- **cannot borrow**. This is `SCX_FINE_BORROW`, independently arrived at here, confirmed with a date on it. |
| "Correct emulation of how SCX prolongs mode 3", "including 'SCX banging'" | v0.15 | The fine-scroll discard is **not a countdown**. It is a three-bit slot counter compared each dot against the LIVE `SCX and 7`; equality ends the discard, and slot 7 without equality **wraps and runs the eight slots again**. A ROM that keeps moving the target faster than the counter can meet it prevents mode 3 from ever ending -- "banging" -- and SameBoy warns that this damages a real LCD. |
| "More accurate emulation of SCX write conflicts on all models" | v1.0 | Per-model timing of *when in the write M-cycle* the new SCX becomes visible to the PPU: DMG/SGB/double-speed-CGB two T-cycles early, single-speed CGB at the normal point. Validated against mealybug `m3_scx_high_5_bits` on DMG. |
| "More accurate PPU fetcher timings, fixes Mr. Chin's Gourmet Paradise" | v1.0 | Each fetcher stage is a **two-T-cycle VRAM access split T1/T2**: T1 latches the address, T2 performs the read. A register written between the two does not affect that access. |
| (same commit) | v1.0 | A CGB-only **one-pixel** lead in the position the map column is taken from, suppressed during object fetches. |

Two of those five we had already derived independently and one is the answer to
the open bracket. The remaining two are recorded below as things this tree does
not model and now knows it does not.

### The mechanism, and our own derivation of it

> **The discard is a slot counter that wraps.** It runs 0..7 from the latch dot
> and compares its slot each dot against the live `SCX and 7`. A store landing at
> a slot at or below the NEW value is matched on this pass (that is
> `SCX_FINE_LATCH_LIVE`, already derived here). A store landing ABOVE the new
> value but at or below the old one has already been walked past and cannot be
> matched until the counter runs to 7, **wraps, and runs the eight slots again**
> -- one whole extra pass. A store past the old value arrives after the match and
> does nothing.

Round 2's "the later the store lands, the bigger the extension" is exactly the
boundary between the first two regimes sweeping as the store moves later, and it
is the shape that ruled out a flat one-tile cost.

`SCX_FINE_LATCH_WRAP` carries it. It is priced on our rows and not on theirs.

### The banging ROM is the ruler, and it prices the wrap at 8

`scx_m3_extend_{ds_1,ds_2}` is the whole derivation. Read with `edgemap.sh`, the
pair writes SCX **twelve times on one line**, every six dots, cycling the low
bits `4,2,0,6,4,2,0,6,4,2,0,6` against a latched fine scroll of 7 -- which is
what "banging" means, and this tree had it in the suite the whole time without
reading it as one. The pair brackets hardware's 3 -> 0 edge to **(329, 331]**
where the shipping tree sits at **259**: seventy-one or seventy-two dots.

Nine of those twelve stores lower the target against the value standing when
they land and three raise it. `9 * 8 = 72`, and **no other division of that
line's stores lands in the bracket** -- twelve stores would need six dots each,
and the level predicate `SCX_FINE_BORROW` uses (every one of the twelve is below
the latched 7, so it fires once) gives eight. The banging row separates a
per-store EVENT from a level by a factor of nine.

With the rule at 8, dingbat lands on **330** -- inside a two-dot window arrived
at by twelve stores compounding. That is the round's strongest single number.

**The mask is the mechanism.** Counting slots without `and 7` makes every store
after the first wrap measure against an ever-growing number, all twelve wrap,
and mode 3 runs to 355 and off the end of the line. Hardware stops because a
store that RAISES the target above the current slot can still be met on the pass
it lands in. The runaway is not a bug to suppress -- it is the behaviour the
changelog names, and our own row says where hardware draws the line.

### Bracketed from both sides

Swept whole-suite, one build per value, `tools/gbscx/wrapsweep.sh`:

| `SCX_FINE_LATCH_WRAP` | gambatte |
|---|---|
| 6 | 4049 |
| 7 | 4050 |
| **8** | **4051** |
| 9 | 4050 |
| 10 | 4050 |

A strict local maximum, and 8 is one whole pass of an eight-slot window rather
than a fitted number.

The DMG arm needed one further thing, and it was already in the tree rather than
invented for it: the comparison is made against the **lead-corrected** fine
scroll, the same `SCX_FINE_BORROW_DMG_LEAD` quantity that constant's own sum
uses. Same sum, same device term, and it is free on a CGB where the lead is
zero.

### The ledger

* **gambatte 4044 -> 4051**, +8 / -1 with `SCX_FINE_LATCH_LIVE`; the wrap's own
  share over that flag alone is **+2 / -0**. Both CGB arms of `scx_m3_extend`
  and both halves of the banging pair go green, the `out0` partners holding --
  so the length is bracketed to one M-cycle, not merely overshot.
* The single red row is `SCX_FINE_LATCH_LIVE`'s own known cost,
  `enable_display/ly0_late_scx7_m3stat_scx1_2 [dmg]`, unchanged.
* Local runner **779**, unmoved. mealybug **1863574 / 552960**, unmoved on both
  devices. All nine witness frames **byte-identical** (both acid2, both
  strikethrough, `cgb-acid-hell` at rev C and E, daid on DMG and on CGB at rev C
  and D).
* Default arm **+0 / -0** against main and byte-identical in verdicts.

### `SCX_FINE_LATCH_LIVE`'s price was stale by a factor of sixteen

Worth stating on its own, because the flag has been parked on price for two
rounds. The +0.446% in its note was measured before `STAT_M0_FIELD_TAIL`
shipped, and that mechanism's `obj_dots_line` sits in the same object-scratch
block whose layout the old figure was blaming. Re-benched in the tree that ships
it -- blargg cpu_instrs, 2400 frames after 300 warmup, four interleaved runs,
`cycles=` identical in all eight -- the same flag reads **+0.027%**.

So the reason it is off no longer holds: +6 / -1 for a fortieth of the quoted
cost. The wrap on top of it is **+0.232%**, and that is the branch in
`fifo_arm_scx` rather than its field -- carrying the latch slot as an `int32`
instead of a byte benches the same to within the noise, which is the one place
the `win_lx` layout cliff would have predicted a difference and does not give
one.

Both still ship at 0 here. The re-pricing is the finding; the flip is one build
and belongs to whoever wants to spend 0.23%.

### The residual, much smaller than the bracket it replaces

`scx_m3_extend_1 [dmg]`, one row. It wants its 3 -> 0 edge 3-6 dots further
still, and no wrap supplies that -- a second one is 8 and overshoots. It cannot
be paid by `STAT_M0_FIELD_TAIL` either, and that is **settled rather than
assumed**: `readidiom.py` says this ROM reads STAT with `LDH A,($41)`, IO on its
third M-cycle, so round 4's `STAT_M0_TAIL_MAX_MC` rule excludes it by
construction. What is left is a DMG-only, single-row, sub-M-cycle question about
where that device's SCX store lands against the latch -- where round 4 handed
forward an 11-14 dot bracket over the whole family.

### Refuted on the way: the extension is not a stall

Charging the eight dots as a blunt pipeline stall -- freeze fetcher and shifter,
which is content-equivalent to the borrow in magnitude -- is **+2 / -65**. It
turns the same two CGB rows green and breaks 65 PNG rows, because a stall
displaces the pixel stream from the STORE's dot where `SCX_FINE_BORROW`
displaces it from the next fetch boundary. The quantity was right and the
currency was wrong, which is what sent this round at the discard comparator
instead. `SCX_STORE_STALL_DOTS` keeps that experiment and its refutation.

### What the archaeology says we do NOT model

Neither is touched here; both are named so the next session does not rediscover
them.

* **The fetcher's T1/T2 split.** Each stage is two T-cycles, the address latched
  in the first and the read performed in the second, so a register written
  between them does not affect that access. This is the Mr. Chin's / Turrican
  finding, and it is a statement about LCDC's tileset and map bits as much as
  about SCX. This tree's fetcher stages are whole dots.
* **Per-model SCX write-visibility inside the write M-cycle.** DMG, SGB and
  double-speed CGB see the new value two T-cycles earlier than single-speed CGB
  does. We carry `CGB_SCX_LATENCY = 2` in the other direction, and the DMG
  residual above is a sub-M-cycle question in exactly this area, so the two are
  probably one question.

Neither `Infinity` nor `Mr. Chin's Gourmet Paradise` could be checked: this
worktree's ROM cache holds test suites only, with no commercial library.

## 2026-08-11: the bus is wider than the data path, and the stall has two clocks

A single triage pass over **all 47 gambatte buckets**, ranked by failing-row
count, with the two best evidence-to-size buckets taken to two-sided and the
rest written up below as ranked next-steps.

**Headline: gambatte 4051 -> 4131, local runner 779 -> 780.** Two mechanisms
shipped, three axes refuted with both sides named, and one standing "declined
pending hardware" bucket resolved without hardware.

### The ranking this pass started from

954 failing rows, by bucket: `window` 115, `dma` 107, `oamdma` 104,
`speedchange` 92, `enable_display` 50, `m1` 46, `lycEnable` 44, `sprites` 39,
`serial` 32, `halt` 31, `cgbpal_m3` 28, `m2enable` 26, `m2int_m0irq` 25, `ly0`
22, `lcd_offset` 21, `irq_precedence` 20, `scx_during_m3` 20, `oam_access` 16,
`m0enable` 15, `tima` 14, `vram_m3` 13, `bgtilemap` 12, `miscmstatirq` 11,
`dmgpalette_during_m3` 10, `lycm2int` 7, then eighteen buckets of <= 4.

### What shipped

| | what it says | worth |
|---|---|---|
| `OAMDMA_WRAM_A12` | on CGB the OAM DMA drives the **address** bus too: a non-colliding CPU access to `$C000-$FDFF` keeps its own A0-A11 and region decode but takes **A12 from the DMA's source** | gambatte **+64 / -0** |
| `SPEED_SWITCH_STALL_CPU` + `SPEED_SWITCH_PPU_EXTRA_DOTS` + `..._RUNS_CPU_CLOCK` | the speed-switch stall is 2^17 cycles of the **new** CPU clock (not a fixed real time), it is a HALT so the timer/serial/OAM-DMA run through it, and the **PPU advances 12 dots further than the CPU clock does** | gambatte **+26 / -10**, AGE `spsw-stop-prefetch` |

Whole-suite perf, interleaved retired-instruction A/B on blargg `01-special`
with `cycles=` identical in every arm: **-0.00036%**, inside the 0.002%
reproducibility floor. All nine witness frames (`acid2` x2, `acidhell` C and E,
`daid` DMG/cgbC/cgbD, `strikethrough` x2) are **byte-identical** to a control
build with all four constants off.

#### `OAMDMA_WRAM_A12`, and why bucket 16 is now closed

**Bucket 16 ("CGB `$D000` window aliases `$C000`", 64 rows) was declined pending
a hardware dump. It should not have been a hardware question.** The old
experiment forced `$D000-$DFFF -> wram[0]` unconditionally, measured +64/-2, and
was refused because the ROMs' shared prologue writes `SVBK = 2` and two banking
ROMs contradict the alias. That contradiction was an artefact of reading an
**address-bus** effect as a **banking rule**.

The real rule is conditional and symmetric: while an OAM DMA whose source is on
the external bus is running, the WRAM half-select A12 comes from the DMA's
address -- so `$D000` reads as `$C000` when the source's A12 is clear **and
`$C000` reads as `$D000` when it is set**. Outside a DMA banking is untouched,
which is why the two banking ROMs are unaffected.

Proved by construction rather than fitted. gambatte ships two templates per
(source, stem) pair -- one pre-loading the stack cells at their true addresses,
one at those addresses with bit 12 flipped -- and emits the flipped form **iff
`A12(source) != A12(CPU address)`**. Over all 314 `busy*` ROMs that predicate
selects the failing set with **0 mismatches**, and resolving each store through
the echo fold and comparing against `(cell and not $1000) or (A12(src) shl 12)`
matches all 64 with **0 mismatches**. `src7F00_busypopDFFF` and
`src0000_busypopDFFF` are the same stem with different source pages and expect
the byte from different halves; only the source's A12 separates them.

Bracketed on five sides, each by rows green today:

1. *untouched* (this tree until now) -- refused by all 64.
2. *WRAM conflicts like any same-bus access* -- refused by the 116 passing
   external-source rows, and by the expected values themselves, which are the
   live `$55`/`$AA` data and never the `$00` source filler or a latch `$FF`.
3. *the whole address comes from the DMA* -- refused because the low bits are
   the CPU's: with the DMA at `$7F9E` a read of `$DFFF` returns half-offset
   `$FFF`, not `$F9E`.
4. *any running DMA does it* -- refused by the 40 video-source and 40
   WRAM-source rows, all green.
5. *it happens on DMG too* -- refused by the perfect 312/312 DMG column; a DMG
   folds WRAM into `dbExternal`, so the access collides outright and A12 is
   never observable.

#### The stall has two clocks, and daid's own three frames prove it

The stall was modelled as a fixed **real time** (`SPEED_SWITCH_STALL_T`, 65548
T), which pins the PPU to 65548 dots in *both* directions. Three independent
gambatte observables refuse that:

* **TIMA.** `speedchange_tima00_{1a,1b,2a,2b}` run TAC = $04 (one tick per 1024
  CPU cycles) and want +0x80 = **128 ticks = 131072 CPU cycles**, bracketed to a
  single M-cycle by the `1a`/`1b` pair. A frozen timer gives +0.
* **The second switch is not the first.** `speedchange2_tima00_{2a,2b}` want
  **+1**, not +256 -- the switch that ends in SINGLE speed also contributes 128
  ticks, i.e. the same cycle count on a clock running half as fast, i.e. twice
  the real time. This row refuses "fixed real time" outright.
* **LY.** `speedchange2_..._ly_1` wants $25 = 37 where constant-dots answers
  $2F = 47; 0x44 + 431 lines is 37 (mod 154), and 431 lines = 196536 dots =
  65540 + 131080 -- the two directions, added.

That the stall is a HALT and not a STOP is the same finding from the other side:
only a **running** timer can produce those 128 ticks. Pan Docs' "`DIV` does not
tick" belongs to the STOP leaves, where the machine's whole clock stops.

**Then daid contradicted itself, and the contradiction was the measurement.**
Under any single "the stall is N cycles" model its three speed-switch frames
cannot all be pixel-exact:

| | 131072 (2^17) | 131096 |
|---|---|---|
| `daid/speed_switch_timing_div` | **0 px** | 226 px |
| `daid/speed_switch_timing_ly` | 452 px | **0 px** |
| `daid/speed_switch_timing_stat` | 575 px | **0 px** |

`div` reads DIV back, so it needs the CPU-domain stall to be a whole multiple of
256; `ly`/`stat` need the PPU to advance **65548** dots into double speed. Two
different quantities, and their difference is the 12 dots the PPU is clocked
through a re-alignment the CPU clock is not yet counting -- exactly the
mechanism `SPEED_SWITCH_STALL_T`'s own note named as unmodelled ("the 6-cycle
switch countdown plus the PPU re-alignment freeze") and never had an instrument
for. Split in two, **all three frames go pixel-exact** and the gambatte trade
falls from -32 to -10.

`SPEED_SWITCH_PPU_EXTRA_DOTS` is bracketed on both sides by those frames, one
build per dot:

```
EXTRA_DOTS      11    *12*   13    14    15    16
daid ly px     109     0      0     0     0    125
daid stat px     0     0      0     0   233    233
```

[12,14] is the legal window; gambatte is flat across it (1138 / 1137 / 1138 rows
of `speedchange`+`sound`+`dma`+`oamdma`), so it has no say, and 12 is picked
because 65536 + 12 is exactly the 65548 the frames pin.

### Refuted this pass, each with both sides named

1. **"On CGB the mode-0 STAT boundary is one M-cycle EARLIER than on DMG"**
   (SameBoy and DocBoy both model it; this pass was sent to arbitrate it off
   gambatte's per-device filenames). **Refuted, 40 families / 40 EQUAL.** A
   filename-derived expectation parser validated against the runner at **4670
   rows / 0 mismatches** was used to read the DMG and CGB flip step of every
   family probing the mode-3 -> 0 edge. Four independent instrument types --
   VRAM unlock, OAM unlock, the STAT mode field, the IF flag -- each cover all
   four M-cycle dot-phases of the edge, and every one says DMG == CGB.
   `vramw_m3end_{1..6}` is the strongest single row: six steps, two flips at 3
   and 5, byte-identical `_dmg08_cgb04c_out*` on all six, where a one-M-cycle
   CGB shift would have moved both flips.
   Suite-wide, 67 families DO flip one step earlier on CGB, and they classify
   cleanly: **61 are a register WRITE racing an edge** (`late_wy_*`,
   `late_scx_*`, `ff41_disable`, `late_ff45_enable`,
   `tima/tc00_irq_late_retrigger`, `serial/start_wait_*`, ...), **6 are
   halt-anchored**, and **0 are a pure read or interrupt-latency probe of a mode
   boundary**. The residue signature is identical in both classes (delta = 2
   dots, phase 2, `-1` at SCX = 0,3 mod 4; 19 rows, then 8 more), so it is one
   CPU-side phase observed two ways.
   It is also **the same quantity as the already-refuted `CGB_HALT_PPU_LEAD`**,
   with a controlled dissociation to prove it: `halt/m0int_m0stat_scx3` is
   `_dmg08_out0_cgb04c_out2` (a device split) while its halt-free twin
   `m0int_m0stat/m0int_m0stat_scx3` is `_dmg08_cgb04c_out{0,2}` (one value for
   both). `cmp -l` of the pair is **nine bytes**: the header title, `NOP` ->
   `HALT`, and the print mask. Insert a halt and the split appears; remove it
   and it vanishes.
   Direction check: the one genuine device split gambatte names on an m3
   boundary goes the *opposite* way -- `vram_m3/preread_2_dmg08_out3_cgb04c_out0`
   says the CGB's VRAM lock at the mode-3 **start** begins one M-cycle **later**
   (5 failing rows, unmodelled, and a candidate in its own right).
   **Do not attempt this; it is settled without hardware.**

2. **The serial shift-clock tap.** gambatte brackets the DMG tap two-sidedly and
   wants it one M-cycle lower than it ships, for +3 / -0 over the whole suite
   with no collateral in any other bucket:

   ```
   SERIAL_TAP_DMG   -8  -4  -2 | 0   1   2   3 | 4   5   6   8
   serial rows      50  50  50 | 53  53  53  53| 50  50  50  50
   ```

   The plateau is exactly 4 T wide (the observable is quantised to the M-cycle,
   which is what says the tap is a phase and not a duration), and the CGB column
   has the same shape and already sits inside it -- so the two SoCs would want
   the *same* tap. **`mooneye/acceptance/serial/boot_sclk_align-dmgABCmgb`
   refuses [0,3] and pins 4.** It is hardware-verified, so it wins and the three
   gambatte rows stay red deliberately.
   The obvious escape is closed too: re-partitioning 4 T between the tap and the
   boot divider seed changes nothing, because `boot_div` reads `tdiv shr 8` and
   cannot see the low bits at all, while both suites' ROMs start from the same
   boot state and neither writes DIV before the transfer -- so each sees only
   the **sum**. The disagreement is in something both ROMs traverse before the
   SC.7 write, not in this constant. Both values stay swept as `SERIAL_TAP_DMG`
   / `SERIAL_TAP_CGB`.

3. **"The DMG refuses a window START on the line's last pixel"** -- the
   pixel-path twin of `CGB_WIN_TAIL_LAST`, built as `DMG_WIN_START_LAST_PX` and
   **shipped off**. It moves the DMG frames but *away* from their reference
   (`wxA6_3 [dmg]` 10780 -> 10844 wrong pixels; whole suite +1). What survives
   of it is item 1 below, where the oracle is unusually good.

### The ranked remainder, with the question that blocks each

Ordered by rows-per-unit-of-work, not by row count.

**1. `window/on_screen` -- 14 rows, LANDED 2026-08-13 (`DMG_WIN_LAST_PX_CARRY`,
gb.nim + fifo_ppu.nim). gambatte 4145 -> 4159, +14 GAINED and 0 LOST.**
`window` 361/476 -> 375/476, `on_screen` 21/36 -> 34/36.

**The DMG's window start on the line's last pixel is not lost -- it is owed to
the next line.** `CGB_WIN_TAIL_LAST` already said the DMG's mode 3 ends with the
last PIXEL and the CGB's with the last FETCH; read that as a statement about
when the line's end-of-line cleanup runs and the rest follows. Hardware's "the
window has started" latch is set by the WX comparator and cleared when the line
ends, so on a DMG a match on x = 159 lands on the same dot as the clear and
survives it. The next line the window is ENABLED on then begins with the window
already the fetch source and draws the window map end to end, with no WX match of
its own. Three consequences, each isolated by one ROM:

* the restart's first pixel is never shifted out, so x = 159 keeps the
  background entry the FIFO was holding. `wxA6_late_we_reenable_4` is that alone
  -- 120 lines, one pixel each. **On its own this is worth ONE row**, which is
  why the old reading below only looked right;
* the latch survives into the next line and across the FRAME boundary.
  `wxA6_wy8F`'s only match is on LY 143 and its only wrong line was LY 0 of the
  frame after;
* the latch is spent at the head of a line only if LCDC.5 is set THERE, and is
  NOT cleared if it is not. `wxA6_wy01_weoff_ly02` sets it on LY 1, spends the
  rest of the frame with the bit clear, and still draws LY 0 of the next frame
  as a window line. Conversely LCDC.5 does not gate SETTING it:
  `wxA6_weoff_at_xposA6` clears the bit at x = 96 of every line and still
  carries.

Three numbers came out of the reference pairs and each is two-sided:

* **where the head spends it** -- `wxA6_late_we_reenable_1..4` put LCDC.5 back
  at dots 77, 81, 85 and 89 of the same line, every line. 77/81/85 are spent and
  89 is not, which puts the read at `fifo_head_window`'s own dot (86, the end of
  the throw-away fetch) -- the same dot `WIN_LINE_START_LATCH` reads WX on;
* **the tile column** (`WIN_CARRY_TILE = 1`) -- the carried line starts at
  window map column 1, not 0, because the aborted start already ran column 0's
  map read. The `on_screen` window maps are a diagonal, so this is a whole tile
  of the staircase;
* **the extra window LINE on a reactivation** (`WIN_CARRY_REACT_LINES = 1`) --
  a carry that has to bring LCDC.5 back counts one more window line than one
  that never lost it. `wxA6_wy00`/`wxA6_wy01` never touch the bit and want their
  window rows every EIGHT lines; `late_we_reenable_1..3` and
  `weoff_at_xposA6` toggle it once a line and want them every FOUR.

Mode 3's LENGTH needed one term with it (`fetch_work_pending`): a carried line
begins with the window already fetching and its WX = 166 match still ahead of
the shifter, and the fetcher owes that restart just as it owes an ordinary one.
Without it the carried line reads 172 dots where hardware reads 174 and
`m2int_wxA6_{m3stat,oambusyread,vrambusyread}_1` and `_spxA7_m3stat_1` go red.
The object-on-the-last-pixel arm of that term must be DMG-gated or four
`m0enable/enable_wxA6_2x_spxA7*` CGB rows go with it.

*Guards, all byte-identical to the control build:* mealybug DMG 27 rows at
100.0%, mealybug CGB identical, GBMicrotest 429/84 (`win*` 36/36), mooneye
97/18, AGE unchanged. `-d:DMG_WIN_LAST_PX_CARRY=0` reproduces the 4145 baseline
row for row. *Cost:* +0.29% of retired instructions on cgb-acid-hell, +0.20% on
blargg cpu_instrs -- but only in the template spelling: the same code with the
pixel emit factored into an `{.inline.}` proc fell off clang's inline cliff at
**+3.63%**.

*What is left (1 row):* `wxA6_late_we_reenable_3 [dmg]`, 916 wrong pixels. Its
window rows are one line early for the whole frame -- ONE extra window line
across 127 of them -- and its only difference from `_1`/`_2` is that it puts
LCDC.5 back at dot 85 rather than 77 or 81. Denying it the
`WIN_CARRY_REACT_LINES` credit wholesale is refused (916 -> 6520), so the credit
is right on 126 lines and wrong on one: the rule that is missing is about the
FIRST reactivated line, not about the dot. (`wx17_weoff_wxA5_weon [cgb]`, 960
pixels, is the family's other red row and is a CGB row that predates all of
this.)

*The falsified reading this replaces,* kept because it is exactly half right:
"the DMG does start the window at WX = 166 but its mode 3 ends with the last
PIXEL, so the restart's first pixel is never shifted out." True, and worth one
row. What it misses is that the start is still owed afterwards.

**2. `oamdma`'s DMA-start latency -- 26 rows. NOT the DMA's start: it is the
mode-2 OAM scan against the transfer, DERIVED 2026-08-13, +16 / −0, SHIPS OFF.**
See the 2026-08-13 section below and `OAM_SCAN_DMA_LOCK` in `gb/fifo_ppu.nim`.
The start-latency reading this entry used to carry is falsified outright -- the
`late_sp*` set does not move by a single row anywhere between
`CGB_OAM_DMA_START_T` = 4 and 40. What is left of the 26 is 7 rows in ROMs that
run with **objects disabled** (`LCDC = $91`: the six `_ds` ones and
`late_sp39x_4`), where no sprite-list model can reach the mode 3 they want, plus
`oamdma_late_halt_stat_1` and `oamdma_late_speedchange_stat_2`. The `_ds` seven
carry bucket 13's exact signature (`exp=C3,C0 got=C0,C0` with the sibling
passing) and belong to it, not here.

**3. `tima/tc00_late_tc01` -- 6 of the 8 rows LANDED 2026-08-13
(`TAC_SELECT_LEAD_T = 4`, timer.nim).** The tap-change response was a pure
1-step (4 T) shift on both devices (`exp FF,FF,FF,FF,00,FE,FF,FF` against `got
FF,FF,FF,00,FE,FF,FF,00`), and the shift is in ONE half of the multiplexer
glitch: the **newly selected** divider bit is read one M-cycle before the byte
lands (i.e. at the start of the write's M-cycle), while the bit being LEFT stays
the value latched at the end of it. Both halves are pinned, in opposite
directions, by two families -- `tc00_late_tc01` lands right where bit 9 rises
($B600) and wants the arriving tap early; `tc00_tc01_late_tc00_of_2` switches
back across a bit-3 edge ($B528) and wants the departing tap late, and a uniform
4 T lead on both halves takes it down. Two-sided: 0 fails 8 rows, 4 fails 2, 8
fails 4 (`_7` goes red while `_5` is still red). Replaying the rewound cycles
under the new tap is also refused (`_4`'s `FF`).
*What is left:* `_5` (2 rows) is **not** the tap. Its second increment is an
ordinary bit-3 edge at $B610 and the ROM reads TIMA at $B614 -- exactly where
dingbat's 4-cycle reload countdown expires -- so it reads `FE` where hardware
still reads `00`. That is a reload-vs-read phase question shared with the rest
of `tima/`; arming the countdown at 5 instead is refused outright (the family
goes 14/16 -> 8/16).

**4. `halt/ifandie_ei_halt_sra` -- 2 rows, LANDED 2026-08-13 (cpu.nim).** On
`EI; HALT` with `IF & IE != 0`, hardware arms the **halt bug**: at the `HALT`'s
FETCH the `EI`'s IME has not landed yet. dingbat printed `$09` because `EI`
schedules its IME 4 cycles out and that fires inside the `HALT`'s own opcode
fetch, so `cpu_halt` saw `ime = true` and halted plainly. The fix is two
pieces: `GbCpu.ime_set_cycle` (scratch, not serialized) stamps the cycle etIME
raises IME on, and `cpu_halt` tests the IME as of the fetch; and the dispatch
that follows **spends** the armed bug by pushing the HALT's own address, so the
`RET` lands back on the HALT (IME 0 again, joypad still pending), the plain bug
arms and `INC A` runs twice for the ROM's `$0A`.
That second half is what the neighbouring rows arbitrate: holding the dispatch
off for the doubled instruction instead also prints `$0A`, but it moves
`ifandie_ei_halt_m2int_m0stat_1` a whole M-cycle and takes its CGB row down, and
letting the bug reach the handler mis-decodes the handler's own `CB 2F` (`$EF`).
SameSuite's `interrupt/ei_delay_halt` flips to PASS with this too. Whole-suite
A/B: gambatte +2 and nothing else, mooneye and GBMicrotest byte-identical.

**5. `OBJ-LATE-SIZECHANGE` -- SHIPPED 2026-08-13, +24 / -0 (gambatte 4145 ->
4169, `sprites` 437 -> 461/476, the whole bucket).** The family is not an object
FETCH measurement at all: it is the **OAM SCAN**, and the reason no knob at the
fetch would move it is that none of these ROMs writes LCDC.2 during mode 3. Every
one of the 38 ROMs sets up an object that is on the line at 8x16 and off it at
8x8, moves LCDC.2 **once, during mode 2 of line 8**, and prints 3 if the scan
kept the object and 0 if it did not. Under a new `-d:gb_lcdc2_trace` the write
dots come straight out, and the filename names the object -- `_sp00`, `_sp01`,
`_sp02`, `_sp39` -- so the family is a **ruler over the scan**, not one boundary:

* **The device-independent half (+14 on its own): object N's Y-range test reads
  LCDC.2 on dot 2N of the line.** dingbat ran the whole 40-object scan in one go
  on the dot mode 2 ENDS, so every object saw the register as of dot 80. The four
  brackets (`obj 0` at dots 453/1, `obj 1` at 1/5, `obj 2` at 1/5, `obj 9` at
  13/17/21, `obj 39` at 73/77/81) intersect to `{2N - 1, 2N}` and nothing else;
  `OBJ_SCAN_DOT_ADJ` in `fifo_ppu.nim` expresses the pair and is two-sided
  (`sprites`: -2 -> 446, **-1 -> 461, 0 -> 461**, +1 -> 445, +2 -> 445).
* **The CGB half (+10): `CGB_OBJ_SCAN_LEAD = 2`** (`gb.nim`). Three CGB cells --
  obj 1 at dot 1, obj 9 at 17, obj 39 at 77, each `2N - 1` -- come out **8x16
  whichever way the write moved the bit** (`late_sizechange_sp01_2` says a CLEAR
  there is not seen, `late_sizechange2_sp01_1` says a SET there is), which no
  single sample dot can produce. The CGB tests the object against the DMG's dot
  **and** the dot one M-cycle earlier and keeps it if either says it is on the
  line -- `sprite_on_line` is monotone in the height, so that is exactly a
  glitching comparator whose LCDC.2 input is mid-transition. Two-sided on
  `sprites`: 0 -> 451, 1 -> 458, **2 -> 461**, 3 -> 456, 4 -> 455.
* **Double speed inverts the lead and kills the glitch.** The seven `_ds` rows
  are unambiguous: at double speed every cell is a clean single boundary and the
  arrival is `CGB_OBJ_SCAN_LEAD` dots **early** instead of late. Getting this
  wrong is not free -- the first cut, which shipped the single-speed rule at both
  speeds, took those seven previously-passing rows down (53/60 instead of 60/60).

*The blocking question is answered, and the answer is that it was the wrong
question.* The "-1 M-cycle on CGB" the siblings were read as wanting is a
**scan** measurement, and read as one its sign **agrees** with
`CGB_OBJ_SIZE_LATENCY = +3`: both say LCDC.2 reaches the object logic LATER on a
CGB. There was never a conflict, only two readers -- the mode-2 range comparator
and the mode-3 bitplane read -- filed under one constant. `CGB_OBJ_SIZE_LATENCY`
and `OBJ_PLANE1_LAG`/`OBJ_PLANE1_HEAD` were not touched, and sweeping either of
them across the whole family moves **zero** rows, which is the direct proof that
the fetch reader is not what these ROMs see.
Guards, all byte-identical before/after: mealybug DMG 552960/552960 and CGB
1863574 (`m3_lcdc_obj_size_change` and its `_scx` sibling both still 100%),
GBMicrotest 429/513 row for row, mooneye 183 row for row, and the dmg-acid2 /
cgb-acid2 / cgb-acid-hell / strikethrough frames pixel-identical.
*Perf, and a trap worth keeping:* the scan is mode-2 hot, so the per-object
sample lives in a `{.noinline.}` proc behind one test and the old loop is
untouched -- **+0.011%** retired instructions on Pokemon Blue and +0.013% on
Crystal. Two earlier spellings were not free. Testing the flag *inside* the loop
costs **+1.20%**. More surprisingly, moving the `fifo_get_sprites` CALL up to sit
before `fifo_reset_sprite` (which is where the LCDC.2 history it reads used to be
cleared) costs **+1.11%** on its own, for no change of work at all -- it is
purely where clang then places the proc relative to the mode 2 -> 3 block. The
fix is to leave the call where it was and let the scan retire the history on its
way out. Another instance of the inline cliff in `docs/perf-measurement`: a
call-site move is not a no-op here, and the counters find it while wall clock
would not.

**6. `enable_display` + `lcd_offset` -- 71 rows, and the filing is wrong.**
`lcd_offset` **does not enable the LCD**: none of its 62 ROMs contains an
LCDC-enable sequence, and every one instead runs 2-4 `LDH ($4D),A; STOP` speed
switches in the preamble to offset the PPU's dot grid from the CPU's M-cycle
boundary by a chosen number of dots. So it belongs with bucket 13, not bucket
17, and -- now that the speed-switch stall is a derived quantity -- it is the
tree's only **sub-M-cycle dot ruler**. Use it to price candidates for
`enable_display`, not to score alongside it.
**Amended 2026-08-13 (second):** the ruler is currently miscalibrated by one dot
and it says so itself -- `offset1_lyc99int_m0stat_count_scx1_ds` and
`offset1_lyc99int_m0irq_count_scx1_ds` are the STAT flag and the IRQ of the same
mode-0 edge at the same offset, SCX and device, and they demand opposite
parities of the switch's dot offset. That is the "1 dot early" defect below,
seen from inside the instrument, so read `lcd_offset` to +/-1 dot and no better
until it is fixed. The switch counts are also exact rather than "2-4":
`offset1` = 2 switches, `offset2` = 4, `offset3` = 2 with a NOP between the
second `LDH ($4D),A` and its `STOP`, and every `_ds` member carries one more.
The `*_count_*` families are also not interrupt counters: their loop period is
exactly 456 dots and their `LDH ($0F),A` is tuned to coincide with the STAT
IRQ's raise dot every line and suppress it, so the printed LY is the line where
the coincidence breaks -- an IF-write-vs-IRQ-raise coincidence ruler calibrated
by SCX at 1 dot per SCX unit. Read that way, dingbat's mode-0 STAT raise is a
constant **1 dot early in steady state and 2 dots early in the LCD-enable
frame**, so the LCD-on head start contributes exactly one dot on top of a defect
that is not about the LCD at all. `frame0` and `frame1`/`frame2` are therefore
*not* the homogeneous group of refusers `LCD_ON_LINE0_TRIM` treats them as.

**7. `window/arg/late_wy_*`'s DMG half -- ~15 rows, a rule and not a constant.**
The existing note frames the family as "dingbat models no device difference".
But the DMG failures partition perfectly: **all 15 DMG failures are "arm the
window late" ROMs** (`FFto0/1/2`, `10to0/1`, `late_scx_late_wy_FFto4`,
`late_enable_afterVblank`), and **all three "disarm late" families pass on DMG
exactly** (`late_wy`, `late_wy_1toFF`, `late_wy_2toFF`). A symmetric shift of one
latch dot cannot produce that -- it would move both deadlines together and break
the disarm ROMs. So the window-Y condition can be turned **on** by a write
hardware refuses, but is turned **off** on exactly hardware's dot. Fixing only
the CGB delta caps the family at ~34 of 49 rows, not 49. (Confirmed separately
here: `CGB_WY_LATENCY = 4`, the one-M-cycle value the old sweep table never
reached, having stopped at 2, buys **+1**. It is not a write latency.)

**8. `dma`'s `hdma_start` -- SHIPPED 2026-08-13, +6 / -0** (`HDMA_VISIBLE_DOTS`
in `gb.nim`, gambatte 4131 -> 4137). The reading in this item was right about
the defect and wrong about the units, and both corrections came from putting
each ROM's `HDMABLOCK` dot next to its `VRAMRD` dot under `-d:gb_dma_trace`
(a new trace line, added for this):

* It is the **bytes** and not the block. Delaying the whole block one M-cycle --
  copy, dots and register writes together -- scores **4131 -> 4126**:
  `hdma_late_disable_2`, `_scx2_2`, `_scx3_2` break and the whole
  `hdma_late_m3speedchange_*` ladder slides a step. Those rows read FF55, LY and
  TIMA, i.e. the block's *bus occupancy*, and they say it starts where it does
  today. Holding only the transferred data moves nothing outside `hdma_start`.
* The delay is **4 dots, not 1 M-cycle**. Bus M-cycles and dots agree only at
  normal speed and only when a block starts on an M-cycle boundary;
  `hdma_start_ds_1` (double speed) and `hdma_start_scx5_2` (block starting 1 dot
  into its M-cycle) are the two rows that separate them, and an M-cycle-counting
  version of the same fix scores 4135 and misses one of the two whichever way it
  rounds. The seven measurable rows give seven inequalities that intersect at
  exactly one value (table at the constant); the sweep is a strict two-sided
  maximum, 7/9/11/**13**/11/8/6 of 14 at 0/2/3/4/5/6/8 dots.
* The hold is taken only for a block the **mode-0 edge** starts, which is the
  one copied inside a CPU access still in flight. Extending it to the blocks an
  FF55 write starts costs `hdma_disabled_display_1` and gains nothing.
* Landing the bytes is **lazy** -- looked for at a CPU VRAM read or write and at
  the next mode change, not counted down per tick. Per-tick costs **+1.36% of
  retired instructions** on Pokemon Crystal; lazy costs **+0.13%**.

One row is left, `hdma_start_scx5_1`, and it is not this constant: it reads VRAM
4 dots *before* its block and gets `$FF`, so it is refused by the mode-3 lock
rather than answered early -- the SCX residual on the mode 3 -> 0 edge (bucket
15) seen through this family. It is also why the item's "8 rows" was really 7 +
one row that belongs elsewhere.

The neighbouring `gdma_cycles`/`hdma_cycles` 20 rows are still **not**
separable and did not move: the recorded sweep wants 2 and still leaves the
SCX-carrying `long_scx{2,3,5}_2` short, so that residual is genuinely
SCX-dependent. `GDMA_SETUP_MCYCLES` was never a candidate for either.

**9. `serial`'s `start_wait_*` cluster -- 12 rows, both obvious readings
refused.** Twelve rows report one defect through three registers: `_read_sb`
(`exp 7F,FF got FF,FF` -- SB seeds at $00 and shifts in ones, so this counts the
shifts directly), `_read_sc` (SC.7 still set) and `_read_if` all flip on the same
M-cycle. So the eighth shift EDGE is early, not the interrupt's visibility.
Refused from both sides: **not the tap** (these 12 do not move by a single
verdict at any tap in [-8,+8], while `div_write_start_wait_read_if` next door
flips cleanly at 0), and **not a whole missed period** (`SERIAL_START_ARM`, which
spends the first falling edge on arming the shifter, lands step 1 right on all
six families and takes step 2 out on all six -- the error changes sign; +24/-32).
The quantity is strictly between 8 T and one bit period.
*Blocking question:* the next instrument has to move the transfer's START against
a stationary clock -- when SC.7's write commits relative to the divider -- which
is a bus-side question, not a serial-side one.

**10. Not landable, and worth saying so.** `halt`'s 31 rows: 11 are the refuted
`CGB_HALT_PPU_LEAD` and 16 are **mixed-direction inside the same family on the
same device** (`late_m0int...scx2_3a` wants earlier, `...scx3_2b` wants later),
i.e. the SCX / mode-3 -> 0 residual seen through a halt. `sprites`' S2
(`sprite_late_*_spx{18,19,1A,1B}`, 8 rows) is non-monotonic in X -- `disable`
passes at `spx1A` and fails at 18/19/1B, `enable` passes at `spx19` -- an
object-fetch-slot phase on an 8-dot grid, so `OBJ-LATE-DISABLE` will not fall to
one constant. `window` W2 (`late_disable*`, 23 rows) still needs the CGB-only
window fetcher abort.

### Two instrument notes that cost time this pass

* **`famflip.py` merges non-contiguous ladders.** `speedchange2_ly44_m3_stat_{1,2}`
  read at ROM `$101F/$1020` but `_{3,4}` read at `$1052/$1053` -- 50 M-cycles
  later, a *separate* bracket. famflip prints them as one 4-step ladder, which
  makes a monotonically advancing clock look non-monotone. Always `cmp -l` a
  pair before reading an offset off famflip.
* **`speedchange`'s `div` and `tima0{1,2,3}` rows are structurally blind.** A
  fully frozen timer passed 8 `div` rows and half the `tima01/02/03` rows,
  because 131072 CPU cycles is 8192 / 2048 / 512 ticks and 512 DIV increments --
  every one 0 (mod 256). Hardware and a frozen timer agree by arithmetic
  accident. Those passes were never evidence the stall model was right;
  `tima00` (128 ticks) is the only arm that can see the bug at all.

## 2026-08-13: bucket 19 is the mode-2 OAM scan, not the DMA's start — derived, +16 / −0, and it ships off

Tier-3 bucket 19 and item 2 of the ranked remainder both read the 27
`oamdma/late_*` rows as "the OAM DMA's start latency is in the wrong clock
domain, `CGB_OAM_DMA_START_T`". That reading is **falsified**, the real
mechanism is derived and bracketed on both sides at both speeds, and it is
built and left **off** because one pixel-exact screenshot ROM refuses its
duration. Everything below is measured on this tree at `e4c04e6`.

### 1. The start latency is not it, and the sweep says so outright

`CGB_OAM_DMA_START_T` was swept over 4, 6, 8, 10, 12, 16 and 40 T with the
whole `oamdma` group scored each time:

| start T | whole `oamdma` | the `late_sp*` families |
|---|---|---|
| 4 | 426/811 | **26/52** |
| 8 (ships) | **771/811** | **26/52** |
| 12 | 408/811 | **26/52** |
| 40 | 174/811 | **26/52** |

The constant is pinned to 8 by hundreds of `busypush`/`busypop` rows and moves
the target families by **exactly zero verdicts anywhere**, including at 40 T
(ten M-cycles late). Whatever these ROMs measure, it is not when the transfer
takes the bus relative to the `$FF46` write.

### 2. What they do measure

Each `late_sp{NN}{x,y}` ROM seeds OAM with **one** on-line object at entry `NN`
(`Y = $10`, everything else `$A0`), triggers a transfer whose source is `$10`
everywhere, and reads `STAT & 3` at a fixed dot late in a line. `out0` is mode 0
(the object was not on the line, mode 3 stayed 172 dots) and `out3` is mode 3
(it was). The `_1`/`_2` pair inserts one `NOP` before the `LDH ($46),A` and
removes one after the delay loop, so the read dot is identical in both and only
the transfer moves — one M-cycle, 4 dots at normal speed and 2 in double.

Tracing dingbat's own DMA start dot and STAT read dot for all 34 ROMs
(`-d:gb_dma_trace`) turns the sixteen normal-speed verdicts into sixteen
one-M-cycle brackets on a single quantity: **the dot the scan reads OAM entry
`n` on**. Writing that dot `D(n)`, and with `S` the dot the transfer takes OAM
and `E` the dot it gives it back (`S + 640`, i.e. 160 CPU M-cycles):

| family | side | verdicts | what it says |
|---|---|---|---|
| `sp00x` | start | `S = −3` → spoiled, `S = +1` → not | `D(0) ∈ [−3, 1)` |
| `sp01x` | start | `S = 1` → spoiled, `S = 5` → not | `D(1) ∈ [1, 5)` |
| `sp02x` | start | `S = 1` → spoiled, `S = 5` → not | `D(2) ∈ [1, 5)` |
| `sp39x` | start | `S = 77` → spoiled, `S = 81` → not | `D(39) ∈ [77, 81)` |
| `sp00y` | end | `E = −3` → not, `E = 1` → spoiled | `D(0) ∈ [−3, 1)` |
| `sp01y` | end | `E = 1` → not, `E = 5` → spoiled | `D(1) ∈ [1, 5)` |
| `sp02y` | end | `E = 1` → not, `E = 5` → spoiled | `D(2) ∈ [1, 5)` |
| `sp39y` | end | `E = 77` → not, `E = 81` → spoiled | `D(39) ∈ [77, 81)` |

The two halves are independent instruments — the `x` ROMs move the transfer's
first byte, the `y` ROMs its 160th, two whole lines apart — and they agree on
every one of the four entries. `D(n) = 2n` satisfies all eight windows: **mode
2's 80 dots are 40 entries at two dots each, and the scan reads entry `n` on dot
`2n`.** That is also the direct measurement of a fact mode 2's *length* has
always implied and nothing in the tree had ever used.

**And it was derived twice on the same day, from different suites, by two
sessions that did not share a line of reasoning.** The `sprites/late_sizechange*`
work (`OBJ_SCAN_DOT_ADJ`, same file) reaches `2N` by moving **LCDC.2** under the
scan and asking which objects changed height; this reaches it by moving an **OAM
DMA** under the scan and asking which objects vanished. Different register,
different suite, different failure mode — same forty two-dot slots, and the same
irreducible `{2N − 1, 2N}` cell at the end of it. The two knobs are now one
(`OBJ_SCAN_DOT_ADJ`) and the per-object comparator is one proc
(`obj_scan_on_line`), so the CGB scan rule cannot drift between them.

**The clock crossing is why no constant could have worked.** The transfer walks
OAM at one entry per 16 dots at normal speed and one per 8 in double; the scan
walks it at one per 2 dots at both. The entry the lock opens or closes on is a
function of both rates, so the same ±4 T moves different entries at the two
speeds — which is exactly the "sign flip" bucket 19 recorded.

### 3. The knob, and its two-sided bracket

`OBJ_SCAN_DOT_ADJ` (`gb/fifo_ppu.nim`) is the dot over and above `2n` — the
LCDC.2 scan's knob, which this work reuses rather than duplicating. Swept with
the lock on, over the 52 `late_*` rows:

| phase | −3 | −2 | −1 | 0 | 1 | 2 | 3 |
|---|---|---|---|---|---|---|---|
| rows | 34 | 34 | **42** | **42** | 34 | 30 | 26 |

A two-value plateau with both sides falling off it, which is the same
`{−1, 0}` the eight windows above allow: `D(2) ∈ [1,5)` refuses +1 and
`D(1) ∈ [1,5)` refuses −2.

### 4. What it is worth, and what refuses it

`OAM_SCAN_DMA_LOCK = 1` (an entry the scan reaches while a transfer holds OAM is
not read at all):

* **gambatte 4183 → 4199, +16 / −0**, all sixteen `late_sp*`. The 771 passing
  `oamdma` rows are untouched — `busypush`/`busypop` stay 312/312 on DMG.
  (Derived standalone against 4145 → 4161; re-measured on the composed tree at
  `8ec0a7d`, where the per-object LCDC.2 scan and the DMG window carry had
  landed. The total moved, the sixteen rows did not, and the shipping arm is
  row-for-row identical to a plain build of `8ec0a7d` across all 5005.)
* mooneye `acceptance/oam_dma/{basic,reg_read,sources-GS}`,
  `oam_dma_{restart,start,timing}` and all twelve `acceptance/ppu` rows:
  **byte-identical and green** on both arms.
* dmg-acid2 and cgb-acid2: byte-identical framebuffers.
* **`strikethrough` goes 23040 → 23033 on BOTH devices.** This is what stops it
  shipping. Its LY 68 has a transfer covering the whole of that line's mode 2,
  and its reference still draws OAM entry 39 — `Y = $54`, `X = $4F`, i.e. screen
  x 71..78, which is the diff's bounding box to the pixel. A lock that lasts the
  whole transfer cannot leave that entry readable.

Two narrower durations were built and measured and both are worse:

| duration | `late_*` rows | `strikethrough` |
|---|---|---|
| burst at dot 80, no lock (ships) | 26/52 | 23040 |
| only the entry the write port is on | 28/52 | 23033 |
| only the two M-cycles the bus changes hands | 38/52 | 23033 |
| the whole transfer | **42/52** | 23033 |

Neither narrow one saves `strikethrough`, and the reason is instructive: the
**progressive read** both of them need is enough to break it on its own. At LY 68
entries 0..5 have been overwritten by the transfer by dot 80 but not yet at their
own dots `0..10`, so a progressive scan reads their pre-transfer values, three of
which are on-line, and entry 39 falls out of the ten-object cap. The burst reads
the overwritten values there and matches the reference. So `strikethrough` says
the scan is **not** progressive and the eight families say it is, on the same
console, and that contradiction is the open question — not a tuning range.

### 5. What is left of the 27 rows even with the lock on

Ten of the 52 stay red and **seven of them are not reachable by any sprite-list
model**: the six `_ds` ROMs and `late_sp39x_4` run with `LCDC = $91`, i.e.
**objects disabled**, so their mode 3 is 172 dots whatever the scan finds. Their
signature (`exp 3, got 0`, sibling passing) is bucket 13's, and they belong
there. The other three are `oamdma_late_halt_stat_1` (both devices) and
`oamdma_late_speedchange_stat_2`, whose transfers are long finished before the
line they read.

### 6. Cost

Free at the shipping default and **not free if the incremental walk is left on
the common path**. Routing the shipping burst through the incremental body costs
**+2.07% of retired instructions** on dmg-acid2 (23,817,092,336 →
24,310,605,440, min of five per arm, `cycles=` equal), against a +0.13%
precedent for accepted work here. So `fifo_get_sprites` keeps its own burst body
and `oam_scan_advance` is compiled in only with the lock: the shipping arm
measured 23,817,493,384 against that tree's 23,817,235,813, **+0.0011%**, inside
the 0.002% reproducibility floor.

Re-measured after composing onto `8ec0a7d` (same ROM, min of five, `cycles=`
equal, load average ~4): 23,769,242,372 against a plain `8ec0a7d`'s
23,765,126,580, **+0.017%**. The shipping code path is the same statements it
always was — what is left is two `int32` scratch fields on `GbFifoPpu` and two
procs the shipping arm never calls, i.e. struct layout, two orders of magnitude
below the +0.13% precedent. Whole-gambatte at the default is row-for-row
identical to a plain build of `8ec0a7d`, and `strikethrough`, dmg-acid2 and
cgb-acid2 are byte-identical to it.

### 7. Where it merged

Rebased onto `8ec0a7d`, which carries the `sprites/late_sizechange*` work that
derived the SAME per-object scan dot from LCDC.2. The two are unified rather
than duplicated: this side dropped its own `OAM_SCAN_ENTRY_PHASE` in favour of
`OBJ_SCAN_DOT_ADJ`, the CGB scan rule moved into one `obj_scan_on_line` both
scans call, and `oam_scan_advance` retires the LCDC.2 history at the end of
mode 2 exactly as `fifo_get_sprites` does on the arm where the lock is off. The
lock's `strikethrough` cost is unchanged by the composition — the same 7 pixels
in the same bounding box.

## 2026-08-13 (second): bucket 13 is TWO constants, and the ladder in switch count derives both

Bucket 13 — "PPU dot phase coming out of a speed switch", 55 rows — is closed as
a **derivation**. It does not ship, and what blocks it is not this bucket.

**The answer, in one line: a KEY1 switch leaves the PPU 8 dots ahead of the CPU
clock when it ends in double speed and 3 dots ahead when it ends in single, and
the tree's single `SPEED_SWITCH_PPU_EXTRA_DOTS = 12` is the to-double 8 with the
CGB halt-exit M-cycle (`CGB_HALT_PPU_LEAD`, 4 dots) folded into it.**

### The switch timeline, as a timeline

At the `STOP` fetch, with a switch armed, no button held and no IRQ pending
(`stop_instr`, `gb/memory.nim`):

| T | unit | what happens |
|---|---|---|
| 0 | DIV | reset through the `FF04` write path, at the OLD speed, so the APU frame-sequencer tap, a shifting serial byte and a TIMA edge all see the reset |
| 0 | CPU clock | `current_speed ^= 1`; the scheduler and the APU channels' `next_step` deadlines are rescaled |
| 0 → S | CPU fetch | **stopped**. `S = 131072` cycles of the NEW CPU clock — 2^17, three-ways derived at `SPEED_SWITCH_STALL_CPU`, and it is a HALT, not a STOP leaf |
| 0 → S | timer / serial / OAM DMA | **run**, at the new CPU clock (`SPEED_SWITCH_STALL_RUNS_CPU_CLOCK`); this is what lets `speedchange_tima00_*` count 128 ticks |
| 0 → S | PPU / HDMA / APU length | **run**, at real time: `S >> new_speed` dots |
| S | PPU only | **+A more dots, with no CPU time**: `A = 8` into double speed, `A = 3` back into single. This is the re-alignment the CPU clock is not yet counting, and it is the whole of bucket 13 |
| S+ | CPU | resumes; its M-cycle grid is now `A mod 4` dots out of phase with the PPU's |

The 3 is the interesting number: it is not a whole M-cycle, so a machine really
does come out of a to-single switch on a **sub-M-cycle** offset — which is what
the `lcd_offset` family was built to measure, and where this model's one
residual is (below).

### The instrument: `ly44_m3` is a ladder in SWITCH COUNT

`speedchange{,2,3,4,5}[_nop]_ly44_m3[_nopxK]_m3stat[_scxS]_{1,2}` runs N
back-to-back `LDH ($4D),A ; STOP` pairs and then reads STAT once, with `_1` and
`_2` one CPU M-cycle apart across the mode 3 → 0 edge. Three properties make it
the best instrument in the tree for this quantity:

* **N multiplies the error.** A per-switch error of `d` dots shows up as `N*d`,
  so the family's own window (one M-cycle: 2 dots in double speed, 4 in single)
  divides down to `m_N / N` — 0.4 dots at N = 5.
* **N alternates the direction.** N switches from single speed go
  double, single, double, … so rung N measures `A`, `A+B`, `2A+B`, `2A+2B`,
  `3A+2B`. Five equations, two unknowns.
* **None of these ROMs halts**, so unlike daid's pixel pair they see the switch
  with nothing else folded in. (Verified: turning `CGB_HALT_PPU_LEAD` on moves
  zero rows of this family.)

Swept one build per dot with `tools/gbppu/sssweep.sh` (new; builds one
`dingbat_test` per define set, shards it, writes a `gamall.sh`-shaped row file
under a caller-chosen prefix so two sessions can sweep at once). Reading the
value of `SPEED_SWITCH_PPU_EXTRA_DOTS` at which each rung is green:

| N | ends in | 1 M-cycle | green at | ⇒ total PPU lead over N switches |
|---|---------|-----------|----------|----------------------------------|
| 1 | double  | 2 dots    | 8, 9     | **8** |
| 2 | single  | 4 dots    | 5, 6     | **11** |
| 3 | double  | 2 dots    | 6        | **19** |
| 4 | single  | 4 dots    | 5 / 6    | **22** |
| 5 | double  | 2 dots    | 6        | **30** |

The successive differences of the last column are **+3, +8, +3, +8** — they
alternate exactly with the direction each switch ends in. One constant cannot
produce that; two produce it with nothing left over.

### Two-sided, on both axes, and exact

With the direction split implemented (`SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE`,
`gb/memory.nim`), on the four speed-switch-carrying subdirectories
(`speedchange lcd_offset dma oamdma`, 1310 rows, baseline 1072):

```
A (B=3)    6     7    *8*    9    10    ...12 = 1072
rows     1078  1085  1116  1092  1077

B (A=8)    0     1     2    *3*    4     5     6     7     8    ...12 = 1072
rows     1088  1084  1091  1116  1096  1082  1083  1086  1083
```

At (8, 3) **all 55 `ly44_m3` rows are green and none is lost** — 14/55 → 55/55,
every rung, every SCX, every NOP count. B = 4 breaks 20 of them, B = 2 breaks
14. Whole gambatte suite: **4183 → 4228, +57 / −12.**

### Why it does not ship: the 12 was 8 + the CGB halt-exit M-cycle

`A = 8` puts daid's `speed_switch_timing_ly` and `_stat` 109 wrong pixels each
(one sample early), and those are top-level GREEN `results.md` rows. That is not
a refutation — it is the second half of the decomposition:

* daid's two ROMs each take **one halt** before their `STOP`
  (`speed_switch_timing_ly.gbc`, `halt` at `$019B`, IME clear, waiting for the
  first vblank after an LCD enable) and every one of their 128 `ldh a,[rLY]`
  samples hangs off that wake. So they pin **halt-lead + switch-extra**.
* The `ly44_m3` ladder pins **switch-extra alone**.
* `CGB_HALT_PPU_LEAD`'s own note (written 2026-08-10, from the other side)
  already recorded that turning the lead on slides daid's window to
  65544..65545 — i.e. to exactly this 8.
* 4 + 8 = 12, and the two instruments never disagree by a dot. **Composed:
  `-d:CGB_HALT_PPU_LEAD=1 -d:SPEED_SWITCH_PPU_EXTRA_DOTS=8
  -d:SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE=3` scores 4224 with all three daid
  frames back at 0 wrong pixels.**

The halt is the **only** carrier those 4 dots can have, and that is measured,
not assumed: `LCD_ON_HEAD_START` at 1 and at 9 (the `1 mod 4` neighbours of the
shipping 5) move daid's `_ly` and `_stat` by **zero** pixels each. A halt
re-anchors the CPU to a PPU event, so any whole-M-cycle shift of the PPU *before*
the wake cancels out; only something that moves the PPU relative to the CPU
*across* the wake survives, and `CGB_HALT_PPU_LEAD` is the only such thing in the
tree.

So the ledger for the three ways to spend this measurement, whole gambatte,
baseline 4183/5005:

| candidate | gambatte | daid ly/stat | `strikethrough-cgb` | verdict |
|---|---|---|---|---|
| `A=8 B=3` | **4228** (+57/−12) | 109 px each | 0 px | refused — two green rows lost |
| `A=8 B=3` + `CGB_HALT_PPU_LEAD=1` | 4224 (+75/−34) | 0 px | **7 px** | the derived model; blocked on bucket 22's one row |
| `A=12 B=−1` (sum kept, split not) | 4205 (+33/−11) | 0 px | 0 px | a fit, not a derivation — refused |

`CGB_HALT_PPU_LEAD=1` alone is **4180** today (−3), so it is only worth turning
on together with this; the pair is what makes it +41.

**What landed:** the direction-split constant, with both defaults *tied to*
`CGB_HALT_PPU_LEAD` — `SPEED_SWITCH_PPU_EXTRA_DOTS = 12 - 4*CGB_HALT_PPU_LEAD`
and `..._SINGLE = 3` when the lead is on, "same as the other" when it is off. At
the shipping `CGB_HALT_PPU_LEAD = 0` the build is **row-for-row identical** on
all 5005 gambatte rows and pixel-identical on daid's three frames and both
`strikethrough` frames. The day bucket 22 unblocks, bucket 13 lands with it and
no further edit.

### The residual: `lcd_offset` contradicts itself at this resolution

The 12 rows the pair costs are all `lcd_offset` or an `lcdoffset1` graft in
`window` / `m2enable` / `lycEnable`. They want `A+B ≡ 0 (mod 4)`; the ladder says
11. **The ruler cannot arbitrate, because it disagrees with itself by one dot:**
sweeping B at A = 8,

* `offset1_lyc99int_m0stat_count_scx1_ds` is green only at **odd** `A+B`,
* `offset1_lyc99int_m0irq_count_scx1_ds` is green only at **even** `A+B`,

and those are the same offset, the same SCX, the same device, the STAT flag and
the IRQ of the *same* mode-0 edge. That is finding 6's "dingbat's mode-0 STAT
raise is a constant 1 dot early in steady state", seen from inside the
instrument. Until that dot is fixed, `lcd_offset` prices candidates to ±1 dot
and no better — **amend finding 6 accordingly: it is the tree's only
sub-M-cycle dot ruler and it is currently miscalibrated by one dot, in a way
that shows up as an internal contradiction rather than as a failing row.**

Also worth recording about that family, since finding 6 left the count vague:
`offsetN` is not "2–4 switches" uniformly. Disassembled (`tools/gbppu/sm83dis.py`,
new): **`offset1` = 2 switches, `offset2` = 4 switches, `offset3` = 2 switches
with one NOP between the second `LDH ($4D),A` and its `STOP`** — and the `_ds`
members carry one more switch, which is why they respond with period 2 in B
where the rest respond with period 4.

### Refused this pass, each with both sides named

* **One constant for both directions.** N=1 wants 8 per switch and N=5 wants 6;
  every window in the table above is narrower than the 2 dots that would take.
* **`A = 12` with a compensating `B = −1`.** Keeps the sum the even rungs
  measure (11) and scores +33/−11 with every pixel row green, but leaves the
  odd rungs (N = 1, 3, 5 — 17 rows) red by construction, and −1 has no
  derivation: it is `8 + 3 − 12`, the halt M-cycle pushed into the other
  direction to hide it. This is the shape the tree calls fitting a constant to
  a suite past the ROM that measures it.
* **`LCD_ON_HEAD_START` as the carrier of the missing 4 dots.** 0 pixels moved
  at 1 and at 9. See above.
* **`OAM_SCAN_DMA_LOCK` cancelling the lead's `strikethrough` cost.** Composed
  (`A=8 B=3` + lead + lock) it scores 4240 but `strikethrough` goes 7 px wrong on
  **both** devices, where the lead alone costs only the CGB one. Not a
  cancellation.
* **`HALT_IF_SAMPLE_T = 2` alongside the lead.** 4204, and `strikethrough-cgb`
  still red. It is not the missing piece of this composition.

### The other two speedchange families, characterised and NOT this bucket

* **`tima0x` (20 rows).** Unmoved by every PPU-phase experiment, as expected —
  the CPU-clock stall is untouched. Swept `SPEED_SWITCH_STALL_CPU` instead
  (131072 / 131074 / 131075 / 131076 / 131080 / 131088 on `speedchange`,
  132/135/138/122/122/119): the family is **internally unsatisfiable**.
  `speedchange_tima02_1a` is green only at ≤ 131074, `speedchange_tima02_2a`
  only at ≥ 131076, and `speedchange_tima02_2b` at none of them. All the
  failures are one tick LOW, so the defect is in *which cycles the timer sees*
  around the `FF04` reset and the switch, not in the stall's length.
* **`ch2_nr52` (11 rows).** Also unmoved by any PPU-phase value, and the same
  shape under the stall sweep: every `_1a`/`_2a` member is green only at
  ≤ 131075 and every `_2b` member only at ≥ 131076, with no value satisfying
  both. Two-sided and empty, so it is the DIV-APU tap's phase across the switch
  (bucket 8's speedchange half), not the stall. Note the odd stall 131075 scores
  **138/208** on `speedchange` — the best any single constant reaches — entirely
  through PPU-phase side effects that `A=8, B=3` does better and cleanly.

### Instruments added

* `tools/gbppu/sssweep.sh` — build one `dingbat_test` per define set, shard it,
  write a `gamall.sh`-shaped row file under a caller-given prefix. ~12 s per
  point for four subdirectories, ~25 s for the whole suite. This is the loop for
  any constant that only a handful of families can see.
* `tools/gbppu/daidswitch.sh` — daid's three speed-switch frames plus both
  `strikethrough` frames as wrong-pixel counts, against one binary, in ~20 s.
  These five are the pixel gate every speed-switch or halt-phase change has to
  pass, and they are otherwise only reachable through a full runner.
* `tools/gbppu/pngdiff.py` — reference PNG vs `--screenshot` PPM, masked to
  0xF8 per channel, pure stdlib. What the two scripts above are built on.
* `tools/gbppu/sm83dis.py` — enough SM83 to read a gambatte ROM's straight-line
  body. Written because bucket 13's whole geometry (how many switches, in which
  direction, with what between them) is in the ROMs and in nothing else.
