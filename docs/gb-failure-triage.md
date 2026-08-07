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
| **0** | **`LY0-RESYNC` — the vblank → LY=0 re-sync is one M-cycle long.** 125 png rows fail on **scanline 0 only**, with lines 1–143 pixel-exact | **125** (`scy` 55, `bgtilemap` 28, `bgtiledata` 24, `scx_during_m3` 17, `bgen` 1) | **boundary column, and an unusually sharp one**: a per-scanline PNG differ | small | **cold** — not in the dot loop; it is where line 0 starts | not built |
| **1** | **`$FEA0-$FEFF` is real RAM on CGB** — dingbat answers `$00` for every model; the ROMs seed the region with a `PUSH` and read it back | **26** (`oamdma` `busypushFEA1`/`busypushFF01`) | the ROM itself | ~5 lines + a savestate field (payload revision bump) | cold | **+26 / −0** |
| **2** | **HDMA source outside cartridge/WRAM moves `$FF`** | **4** (`dma`) | `dma_hiram_read_result` reports the *value* | done | cold | **+4 / −0**, shipped as `a7b6355` |
| **3** | **STAT edge-detector re-trigger** — *every* `*_late_retrigger` ROM in the suite fails, across five STAT sources and the timer, bidirectionally | **28** (`irq_precedence` 6, `m1` 6, `ly0` 6, `m2int_m2irq` 3, `lyc153int_m2irq` 3, `tima` 4) | pairs, ±1 M-cycle | small | cold | not built |
| **4** | **STAT source enabled by an `$FF41` write while already high must produce an edge** — the bit is *absent*, not mistimed | **8** (`lcdirq_precedence`, the whole family) | pass/fail only | small | cold | not built |
| **5** | **DMG CH3 wave-RAM access rule** — CGB already correct; the documented "wave RAM is only accessible on the dot CH3 reads it" gap | **8** (`sound`, DMG only) | famflip: `exp=FF,FF,FF,FF got=10,32,32,54` | small | cold (APU) | not built |

Tier 1 is **199 rows** for work that is individually small, individually
self-contained, and blocked on nothing.

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
| 14 | **OAM STAT source rises one M-cycle late** — and *only* that source | **157 gained / 258 lost** across `window`, `m2enable`, `m2int_*`, `oam_access`, `vram_m3`, `halt`, plus 7 GBMicrotest | The single largest finding in the triage and currently **net −101**. `STAT_IRQ_LEAD` moves all four sources together, which is why `D = 1` was correctly rejected before — the measurement says `D_oam = 1` and `D_hblank = D_lyc = D_vblank = 0`, a per-source lead that was never in the search space. GBMicrotest gives it a clean boundary column (7 rows, all exactly +1, all going exact under the fix). What refuses it is every family where a ROM *writes a PPU register from the STAT handler*, so the interrupt's dot doubles as the write's dot — `scx_during_m3` −28, `scy` −9, `bgtiledata`/`bgtilemap` → 0. **Exactly one of {OAM dispatch dot, mode-3 fetch phase} is wrong and they currently cancel.** Perf risk is **high**: it needs a second stop in `fifo_skip_target`, ~17.5k calls/frame |
| 15 | **The sub-M-cycle error at the mode 3 → 0 edge** | **≥ 21 GBMicrotest + the `NspritesPrLine` family + 20 `halt` + ~13 SCX-residue rows** | The most over-subscribed unknown in the tree. `M3_END_EARLY`, `LCD_ON_LINE0_TRIM`, `LCD_ON_HEAD_START` and `GDMA_SETUP_MCYCLES` have each been refused for it. Newly bracketed here: hardware samples mode 0 at `cc − 2` (tight both sides), dingbat no earlier than `cc − 5`, and **one of those dots is unexplained even at the shipping `L = 3`** |
| 16 | **CGB `$D000` window aliases `$C000`** | **64** (`oamdma`) | Forcing `$D000-$DFFF → wram[0]` measures **+64 / −2**, and the −2 are exactly the two ROMs that pin banking. But the ROMs' shared prologue writes `SVBK = 2`, so the 64 expectations assert that bank 2 *is* bank 0 — which contradicts the two banking ROMs. **Declined pending hardware**: dump WRAM on a real CGB-C after `LDH ($70),$02`; if `$CFFF ≠ $DFFF` these rows are permanently unreachable |
| 17 | **LCD-on / boot dot phase** | **75** (`enable_display` 49, `lcd_offset` 22, `display_startstate` 4) | Already written up at `LCD_ON_HEAD_START` / `CGB_BOOT_PHASE`; `lcd_offset` is 100% CGB-only |
| 18 | **Mode-1 / vblank STAT source values** | **42** (`m1`) | A *value* question (`exp=0,3 got=1,1`), not a phase one: whether the mode-1 STAT source asserts at all on entering vblank, and how it overlaps the vblank IF bit. Untouched by every STAT phase experiment run |
| 19 | **OAM-DMA start off-by-one whose sign flips with speed** | **27** | Single speed is 1 M-cycle early, `_ds` is 1 M-cycle late — so it is not a constant offset but a wrong clock domain. No single ±4 T constant can fix it |
| 20 | **Line-153 LY vs the LYC comparator** | **21** (`ly0`) | Readable LY and the comparator's copy need separate line-153 phases. **Not** the snapback dot — that was parameterised and built: gambatte 3614 → 3606 |
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

### Runner-up: decide bucket 14 (the OAM STAT source) by resolving the cancellation, not by scoring it

It is the largest single mechanism found — 7 GBMicrotest rows with a clean
boundary column, all exactly +1, all going exact under the fix — and it is
currently **net −101** because the 4 dots between the OAM STAT dispatch and the
mode-3 fetch phase are wrong in exactly one of the two places and currently
cancel. Scoring it will therefore always look like a regression, and no amount of
sweeping will separate the two. It needs bucket 15 settled first; then it is a
one-line per-source `D` and the 258 losses should evaporate. Note the perf flag:
the implementation needs a second stop in `fifo_skip_target` (~17.5k calls/frame),
so it must be gated with `tools/gbppu/counters.sh`, not fps.

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

| row | before | after | what the diff says |
|---|---|---|---|
| `m3_wx_4_change_sprites` (DMG) | 2 | **0** | the park, above |
| `m3_obp0_change` (DMG) | 74 | **0** | the mixer's second stage |
| `m3_lcdc_obj_en_change` (DMG) | 60 | 2 | see below |
| `acid/cgb-acid-hell` | 2 | 2 | see below |
| `m3_lcdc_obj_size_change_scx` (DMG) | 30 | 30 | untouched by either fix |
| `m3_lcdc_win_map_change` (DMG) | 34 | 34 | see below |
| `m3_lcdc_obj_size_change` (DMG) | 57 | 57 | untouched by either fix |
| `m3_lcdc_tile_sel_win_change` (DMG) | 106 | 106 | untouched by either fix |

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
Two byte-exact coincidences.

That is the CGB `TILE_SEL` glitch the mealybug PPU notes describe verbatim:
"resetting `TILE_SEL` on the same T-cycle as a bitplane data read will cause
the tile index to be instead used as the data for that bitplane". The notes'
other branch is measurably refuted here — the alternatives it lists for a
*setting* are "bitplane 1 data from the most recently drawn sprite" (`$41` and
`$22` on those lines, traced) and "from the most recently drawn tile when
`TILE_SEL` was last reset" (`$5D`), and neither is `$55`/`$49`.

Two things stop it being landed:

* **The polarity is inverted against the notes.** The fetch that glitches has
  its bitplane-1 read at dot 178 and the nearest LCDC write is `$E3 → $F3` at
  177 — a `TILE_SEL` **set**. The two resets on that line (177's neighbours at
  169 and 185) each sit one dot before a bitplane-1 read too and do NOT
  substitute: at those fetches the tile numbers are `$59` and `$07` against a
  byte of `$5D`, so a substitution there would be visible and the reference
  does not have it.
* **The coincidence needs one more dot.** dingbat's write is live from the dot
  it is logged on (`m3_lcdc_obj_en_change` pins that), so 177 and 178 are
  adjacent, not the same T-cycle. Making them coincide needs `TILE_SEL` to
  reach the FETCHER a dot after the write, which is a second claim and a
  second constant (`CGB_LCDC_TDSEL_LATENCY`, which ships at 0).

The rest of the frame cannot separate the candidate rules: 2731 of 2736 pushed
tiles match, and substituting the index at *every* `TILE_SEL` change that lands
on a bitplane read is never refuted anywhere in the frame — the palettes hide
it. So it is one field and one compare to implement and **two pixels of
evidence to choose between three rules**, which is precisely the shape that
should not be fitted. What would settle it is a second ROM: the four
`m3_lcdc_tile_sel_change*` mealybug rows scored against their CGB references
(they are not in the shootout, and `m3_lcdc_tile_sel_change` is 96.3% on CGB
today), which exercise the same glitch at a write cadence the picture does not
hide.

**`m3_lcdc_win_map_change`, the 34 pixels.** One 8x8 block, `x = 0..7`,
`y = 64..71`, and it is not background at all — it is the ® object of band 8
(OAM X = 8, screen `x = 0..7`) drawn here and absent on hardware. That band is
the one where the object's trigger (`lx == 0`) coincides with the window's
start, because the ROM runs WY = 0 / WX = 7, i.e. `win_lx == 0`. `tick_shifter`
asks the object question first, so the window start is deferred behind a
whole object fetch; hardware evidently resolves the tie the other way and the
object is lost outright (it does not reappear shifted — `x = 8..15` matches).
That is an ordering rule between the two triggers at one `lx`, not a dot.

**The two `obj_size_change` rows and `m3_lcdc_tile_sel_win_change` were not
diagnosed** in this pass and did not move. `obj_size_change_scx`'s 30 pixels are
two 6-row bands at the very top and bottom of the frame (`y = 2..7` and
`y = 130..135`, `x = 27..31`) with the diff going both ways within a row, which
is the signature of a 16-pixel-tall object's row selection rather than of a
write dot; `m3_lcdc_obj_size_change` has the same shape plus a left-edge
component at `x = 0..2`.

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

## Reproducing any of this

```
nimble test_build
TMPDIR=<private> DINGBAT_ROM_CACHE=<private> ./dingbat_test_runner
tools/gbppu/gamall.sh /tmp/g_base                  # 5005-row verdict file, ~6 s
python3 tools/gbppu/famflip.py /tmp/g_base.txt '*' # per-family flip points
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
