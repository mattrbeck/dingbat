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
| **31** GBMicrotest | The ROM **never writes `$FF82`**, the byte `--mode=microtest` scores, so the harness reads uninitialised HRAM forever | Scanned all 513 bundled ROMs for `E0 82` (`ldh ($82),a`) and `EA 82 FF`. 482 contain one; **31 do not — and those 31 are exactly 31 of the failing rows, with none of them passing.** Verified independently of the agent that found it |
| 3 | AGE revision-locked pairs | `lcd-align-ly-cgbBC`/`-cgbE`, `spsw-tima-cgbBC`/`-cgbE`, `spsw-interrupts-cgbBC`/`-cgbE` are CGB-only pairs differing only in SoC revision. dingbat has one CGB boot model (`bmCgbABCDE`), so at most one of each pair can ever be green |
| 1 | `mooneye/utils/bootrom_dumper` | A tool, not a test — dumps the boot ROM over serial and has no verdict. `build_wilbertpol_tests` already skips `utils/`; the Gekkio path does not |
| 1 | mGBA `DMA Prefetch Break` | Expects `0x10000000 + 4 × iterations` where the count depends on where gcc put the loop; already documented as unscoreable |
| 1 | `bully/bully` at 0.6% | A whole-machine torture test whose single reference is a CGB capture the author's own DMG-C fails. One row standing for dozens of independent checks; not triageable as a bucket |

`ppu_spritex_vs_scx` was already known to be in the first group; **the other 30
were not**, and GBMicrotest's headline therefore reads 403/513 when the honest
figure is 403/482. The recoverable total is **1,674 − 37 = 1,637**.

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
| **1** | **`$FEA0-$FEFF` is real RAM on CGB** — dingbat answers `$00` for every model; the ROMs seed the region with a `PUSH` and read it back | **26** (`oamdma` `busypushFEA1`/`busypushFF01`) | the ROM itself | ~5 lines + a savestate field (payload revision bump) | cold | **+26 / −0** |
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
37 (blocked on STAT), `WIN-FETCH-ABORT` 29 (hot, blocked), `OBJ-LATE-SIZECHANGE`
24, `top ≤16 lines` 22, `window/on_screen` 18, `CGBPAL-M3END` 18 (a missing
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
| 9 | **HDMA start one M-cycle early** — opposite sign to #6, so either the block is 2 M-cycles wide where hardware is 1, or the two edges are separately wrong | **7** (`hdma_start*`) | famflip `exp=0,1 got=1,1` | small | cold | #6 |
| 10 | **`FF55` / HDMA1-4 latch phase** — `ppu_write_machinery`'s M-cycle boundary rule | **11** (`hdma_late_enable/disable` 8, `destl`/`length`/`wrambank` 3) | famflip | small | cold | — |
| 11 | **Serial restart / `trigger_int8` ordering** — different shape from #7, do not fold | **6** | famflip, opposite direction | small | cold | #7 |

### Tier 3 — real mechanism, needs a model rather than a number

| # | bucket | rows | why it is not cheap |
|---|---|---|---|
| 12 | **HDMA block owed to a CPU that is off the bus** (halted, or stalled by a speed switch) | **61** (`dma` 30 + speed-switch 31) | The rule — a CPU off the bus stalls the block — is already in the tree for HALT (`eb75393`) and is right *in kind*. Built for the speed-switch half: **+11 / −10**. It fixes every `_1` family member and breaks every `_2`/`_3`, because hardware still delivers the **one block already owed** at the instant of the STOP. That last block's phase is set by the mode-0 edge, i.e. bucket 15 |
| 13 | **PPU dot phase coming out of a speed switch** | **55** (`speedchange*_ly44_m3_*m3stat*`) | Uniform `exp=C3,C0 got=C0,C0`. Sweeping `SPEED_SWITCH_STALL_T` is jagged (+0/+6/+6/+11/+6/+12/+12/+8) and **65544's +11 are all the single→double variants and none of the `speedchange2..5_` ones**, so it is not one stall length. 65540 is SameBoy's ripple counter and is pinned by the blargg canary. The derivable route is the mechanism the existing comment already names as unmodelled: the 6-cycle switch countdown plus the PPU re-alignment freeze |
| 14 | ~~**OAM STAT source rises one M-cycle late**~~ — and *only* that source | **+228 / −114 gambatte, +8 / −4 GBMicrotest, runner 765 → 773** | **MEASURED AND DERIVED 2026-08-09, and it ships OFF** — `STAT_M2_LEAD` + `M3_PIPE_AHEAD`, both `intdefine`s at 0, derivation at `STAT_M2_LEAD` in `gb/ppu.nim`. The source rises **one CPU M-cycle** (not a fixed dot count: the 75-row `_ds_`-only delta is the proof) before the line whose OAM scan it belongs to, on every line except line 0, whose predecessor is vblank. The cancellation this bucket named is real and is resolved: moving the dispatch alone costs `scy` 67/67 → 0/67, and one M-cycle of `M3_PIPE_AHEAD` gives **every** one of those pixel rows back, `scx_during_m3` and `bgtiledata` and `bgtilemap` included, with `LY0_PIPE_MCYCLES` going to 0 because line 0's four dots ARE this lead. Two-sided on both axes; GBMicrotest pins the lead alone (429 / 433 / 425 at 0 / 1 / 2). **What blocks it is a different bucket:** all 17 rows it costs are ROMs that wait with `EI; HALT`, and the twelve wilbertpol `*_timing_nops` rows — the same measurements with the halt replaced by a sled — are among the rows it *wins*. See bucket 15's halt rows |
| 15 | ~~**The sub-M-cycle error at the mode 3 → 0 edge**~~ | **≥ 21 GBMicrotest + the `NspritesPrLine` family + 20 `halt` + ~13 SCX-residue rows** | **The readback half is CLOSED 2026-08-09** — see the section above. The unexplained dot was the `read_mode` latch being taken one dot before the M-cycle's first, so `STAT_READ_LAG`'s documented meaning and its implementation disagreed by a dot and the `4D + L = 4` grid was solved a dot out. The sample point is `cc − 2` at normal speed and `cc − 3` in double, bracketed both sides at both speeds by ROMs that take no interrupt. Runner 743 → 765, GBMicrotest 404 → 430, mooneye acceptance 66/66, gambatte 3856 → 3818 with all 102 traded rows owned by bucket 14. Still open here: the SCX-residue rows and the 20 `halt` rows |
| 16 | **CGB `$D000` window aliases `$C000`** | **64** (`oamdma`) | Forcing `$D000-$DFFF → wram[0]` measures **+64 / −2**, and the −2 are exactly the two ROMs that pin banking. But the ROMs' shared prologue writes `SVBK = 2`, so the 64 expectations assert that bank 2 *is* bank 0 — which contradicts the two banking ROMs. **Declined pending hardware**: dump WRAM on a real CGB-C after `LDH ($70),$02`; if `$CFFF ≠ $DFFF` these rows are permanently unreachable |
| 17 | **LCD-on / boot dot phase** | **75** (`enable_display` 49, `lcd_offset` 22, `display_startstate` 4) | Already written up at `LCD_ON_HEAD_START` / `CGB_BOOT_PHASE`; `lcd_offset` is 100% CGB-only |
| 18 | **Mode-1 / vblank STAT source values** | **42** (`m1`) | A *value* question (`exp=0,3 got=1,1`), not a phase one: whether the mode-1 STAT source asserts at all on entering vblank, and how it overlaps the vblank IF bit. Untouched by every STAT phase experiment run |
| 19 | **OAM-DMA start off-by-one whose sign flips with speed** | **27** | Single speed is 1 M-cycle early, `_ds` is 1 M-cycle late — so it is not a constant offset but a wrong clock domain. No single ±4 T constant can fix it |
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
(`$FEA0`: **+26/−0**; HDMA source: **+4/−0**, shipped) or backed by a rule the
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
| `m3_lcdc_win_en_change_multiple_wx` | 4215 | 343 | as above |
| `m3_lcdc_obj_en_change` | 60 | 2 | see below |
| `m3_lcdc_obj_en_change_variant` | 380 | 102 | the mixer |
| `m3_window_timing` | 299 | 29 | **0 as of 2026-08-09** — 12 px `MIXER_TAIL_DOTS`, 21 px `WIN_HEAD_ABSORB` + `WIN_LINE_START_LATCH` |
| `m3_bgp_change` | 1508 | 820 | second mechanism, see below |
| `m3_bgp_change_sprites` | 1044 | 536 | as above |
| `m3_window_timing_wx_0` | 902 | **4** | the SCX discard on a window-start line (2026-08-07); the 4 left were all LY = 0, i.e. bucket 0, and are **0 as of 2026-08-09** |
| `acid/cgb-acid-hell` (CGB) | 2 | 2 | see below |
| `m3_lcdc_obj_size_change_scx` | 30 | 30 | LCDC.2 is read once per BITPLANE — **0 as of 2026-08-09**, see below |
| `m3_lcdc_win_map_change` | 34 | 34 | see below — **0 as of 2026-08-09** (`obj_yields_to_window`) |
| `m3_lcdc_obj_size_change` | 57 | 57 | as above — **0 as of 2026-08-09** |
| `m3_lcdc_tile_sel_win_change` | 106 | 106 | the same WX = 7 tie as `m3_lcdc_win_map_change` — **0 as of 2026-08-09** (`obj_yields_to_window`). Its CGB twin is a different row and moved 830 → 474 on 2026-08-10 (`CGB_TDSEL_LATENCY` + `CGB_TDSEL_GLITCH`) |
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

**`acid/cgb-acid-hell`, the 2 pixels — mechanism identified, not landed.** The
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
