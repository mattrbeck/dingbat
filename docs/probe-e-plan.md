# probe (e): the shot list, and what each frame decides

**ROM:** `tools/gbprobe/probe_e_objgrid.gb` (one paged ROM — LEFT/RIGHT picks
SCX 0-7, UP/DOWN picks the object's X: `FF` = off, then 0..15). The top-left
prints the current setting as two hex bytes, **SCX then object X**, so every
photograph names its own setting.

**Read with:** `tools/gbprobe/read_probe_d_photo.py <photo.jpg> --skip-top 16
--bands` — the `--bands` reader anchors a 9-row grid on the topmost bar
instead of using connected components, which merge a band's bar into its
neighbour's once an object shifts the columns.

## What is being measured

An object that stalls the fetcher for N dots pushes every later fetch N dots
later, so the staircase's **column** moves. Two readings per frame:

* **the alternation phase** — does the TOP bar read grey (`2`) or black
  (`#`)? Visible by eye.
* **the staircase's column**, measured against the objects-OFF baseline at
  the *same* SCX. This is the penalty in pixels.

## dingbat's predictions (registered before hardware)

| SCX | object X | top bar | sequence | bar column | shift vs OFF |
|---|---|---|---|---|---|
| 0 | OFF | grey | `2#2#2#2#2#2#2#` | 32 | — |
| 0 | 00 | black | `#2#2#2#2#2#2#2` | 24 | **−8** |
| 0 | 02 | black | `##############` | 24 | −8 |
| 4 | OFF | grey | `2#2#2#2#2#2#2#` | 28 | — |
| 4 | 00 | black | `#2#2#2#2#2#2#2` | 20 | **−8** |
| 4 | **01** | black | `#2#2#2#2#2#2#` | **28** | **0** |
| 7 | OFF | grey | `2#2#2#2#2#2#2#` | 25 | — |
| 7 | 00 | black | `#2#2#2#2#2#2#2` | 17 | **−8** |

Two things in that table carry the experiment:

1. **`SCX 04 / OBJ 01` is acid-hell's own configuration, and it is the one
   place dingbat predicts NO column shift** while every other object setting
   shifts by 8. If hardware shifts there, that is the missing dots — and
   almost certainly the 261st shootout row.
2. **`OBJ 00` at SCX 0, 4 and 7 answers Pan Docs' self-contradiction**
   directly. dingbat shifts by −8 at all three, i.e. a penalty that does not
   vary with SCX (`Rendering.md`'s flat 11). If the shift changes with SCX,
   `pixel_fifo.md` is right instead and dingbat's `OBJ_FETCH_DOTS` rule needs
   the SCX term — which would be a finding well beyond this one row.

`SCX 00 / OBJ 02` is a free consistency check: it is the only setting that
predicts an all-black staircase, so it is obvious at a glance whether the
ROM and the reading agree.

## RESULT — 2026-08-17, GBA SP (photos IMG_3824-3831)

Read with the `--bands` reader; every frame's own header confirmed its
setting (IMG_3824 reads `04 FF`, and the `00 xx` group is legible in the
OCR). Full staircases, one column per band:

| setting | hardware | dingbat |
|---|---|---|
| 04 FF | 20 28 28 36 36 44 44 52 52 59 59 67 68 76 | 28 36 36 44 44 52 52 60 60 68 68 76 76 84 |
| **04 01** | **28 35 36 43 44 51 52 59 60 67 68 75 76** | **28 35 36 43 44 51 52 59 60 67 68 75 76** |
| 04 00 | 20 28 28 36 36 44 44 51 51 59 59 67 67 75 | 20 20 28 28 36 36 44 44 52 52 60 60 68 68 |
| 00 FF | 24 32 32 40 40 48 48 56 56 64 64 72 72 80 | 32 40 40 48 48 56 56 64 64 72 72 80 80 88 |
| 00 00 | 24 32 32 40 40 48 48 56 56 64 64 72 72 80 | 24 24 32 32 40 40 48 48 56 56 64 64 72 72 |
| 07 FF | 17 25 25 33 33 41 41 49 49 57 57 65 65 73 | 25 33 33 41 41 49 49 57 57 65 65 73 73 81 |
| 07 00 | 17 25 25 33 33 41 41 49 49 57 57 65 65 73 | 17 17 25 25 33 33 41 41 49 49 57 57 65 65 |

Absolute columns are not comparable between machines, so the reading is
each machine against **its own** objects-off baseline:

1. **`04 01` — acid-hell's configuration — matches dingbat column for
   column, all thirteen bands.** Whatever is wrong with acid-hell's two
   pixels, an object at X = 1 displaces the fetch grid exactly as modelled.
2. **An object at X = 0 does not move the grid on hardware at all.** At
   SCX 0, 4 and 7 the `OBJ 00` staircase is identical to that SCX's
   objects-off staircase (within a pixel of photo drift). dingbat displaces
   it by 8 dots at all three, and its bands 0-1 collapse to one column
   (`20 20`, `24 24`, `17 17`) where hardware keeps alternating. **This is
   a real, reproducible model error, found three times independently.**
3. Turning the X = 0 flat-11 exception off (`sub = idx and 7` for every X)
   was measured and does NOT reproduce hardware either: the staircase's
   structure becomes right but it still sits 8 dots left of its own
   baseline. So the exception is not simply spurious.

**The objects-off baseline also disagrees**, on all three SCX values, by
the same 8 dots — and probe (d) showed no such offset. That was the one
thing standing between these readings and a quantified answer, so it was
chased down separately; see below.

## The baseline offset is real, and SameBoy settles the whole table

Three independent checks, in order.

**1. The registration is sound.** `tools/gbprobe/read_probe_e.py` measures
each bar against the *parameter header inside the same frame* rather than
against the frame's left edge. The header's glyphs always begin at GB
x = 0, so any translation the warp introduced cancels in the subtraction.
The header's own left edge reads 0, 1 and 3 at SCX 4, 0 and 7 — matching
dingbat's 0, 1 and 3 exactly — so the frames are aligned and the 8 px is
not a warp artifact. (A left-clipped warp, the failure mode that would
mimic this, would have driven all three to 0.)

**2. The anchor line, not the object path, is what probe (d) and probe (e)
do differently.** Rebuilt with `ANCHOR_LINE` free (and `NOHEADER` so a band
can sit on line 0), dingbat gives the same column at lines 16, 25 and 40
and a different one at line 0. probe (d) anchors on line 0 — a line dingbat
special-cases (`LY0_PIPE_MCYCLES`, the 153→0 snapback) and one where the
LYC = 0 compare happens during line 153 rather than at a line start. So
probe (d) never measured the normal-line phase at all, and its agreement
with hardware does not vouch for it. `LCDC.2` and OAM's contents were ruled
out directly: with `LCDC.1` clear, parking OAM off-screen and dropping
`LCDC.2` each leave dingbat's column bit-identical.

**3. SameBoy reproduces the hardware photographs on all eight settings.**
Built headless from `tools/gbfuzz/sameboy_runner.c` against the prebuilt
`libsameboy.a`. Five of the eight are byte-for-byte identical to the photo
reading; the other three differ only in the final band, where the
photograph's own perspective drift is worth a pixel. It agrees with silicon
at every point where dingbat does not — including `OBJ 00`, where it also
shows no displacement.

Two consequences:

* **The findings above stand, and the baseline offset is dingbat's alone.**
  Being 8 dots out on a line with *no objects on it* is the larger of the
  two errors, and it is the one to fix first: the object readings are
  measured against that baseline.
* **This probe no longer needs a hardware session.** SameBoy is validated
  against the GBA SP at eight points, so it can stand in for the rest of
  the sweep. `tools/gbprobe/probe_e_compare.sh` runs both emulators over
  the setting matrix and prints only the disagreements. A setting they
  disagree on is worth a photograph; one they agree on is not.

## What the sweep says, with SameBoy as the oracle

Sweeping object X = OFF, 0..7 at SCX 4 on **both** models, stock dingbat
agrees on **0 of 9** either way, and the error is a single continuous
quantity: dingbat's LCDC.4 write lands **4 dots late on DMG and 8 dots late
on CGB**, relative to the fetch grid. On DMG that shows up as the staircase
stepping one band later (`28 28 36 36` where SameBoy has `28 36 36 44`);
on CGB as the whole staircase sitting one tile right, with the same
stepping phase.

### It is a pure time offset, and here is its size

Guessing knobs was the wrong instrument; the probe can measure the offset
directly. `BASE` is the M-cycles between the anchor's wake and the LCDC.4
write, so sweeping it in SameBoy asks "what delay would make SameBoy behave
the way dingbat does?" — and if some `BASE` reproduces dingbat's staircase
*exactly*, the two differ by a time offset and nothing else.

One does, on each model, with all fourteen bands agreeing:

| | dingbat at the shipping `BASE=26` | SameBoy reproduces it at | so dingbat is |
|---|---|---|---|
| CGB | `28 36 36 44 44 52 52 60 60 68 68 76 76 84` | `BASE=28` | **2 M-cycles late** |
| DMG | `28 28 36 36 44 44 52 52 60 60 68 68 76 76` | `BASE=25` | **1 M-cycle early** |

The staircase's *shape* is identical in every case — only its position
moves. So the fetch grid's structure is not implicated, and neither is the
fine-scroll discard: one number per model describes the whole disagreement.

The two numbers are more interesting read the other way round. At the same
`BASE`, SameBoy's CGB column sits 8 px left of its DMG column — **on
silicon the CGB runs this path 2 M-cycles ahead of the DMG.** dingbat's two
models produce the *same* column, so it models no difference here at all.
That is very likely `CGB_TDSEL_LATENCY = 1` (which delays the LCDC.4 write
on CGB by 1 M) cancelling `CGB_PIPE_MCYCLES = 1` (which advances the CGB
pipeline by 1 M) to a net zero, where hardware wants a net −2.

### Is it the halt, or the pipeline? Take the halt away and see

mealybug's `m3_lcdc_tile_sel_change` is the same register written mid-mode-3
and compared against a hardware capture, and it passes on both models — as
do `_change2`, `_win_change` and the rest of that family. A uniform
CPU-versus-PPU offset should have moved those frames too. The one thing
probe (e) has that they do not is the **STAT-LYC halt anchor**, which is
also the only path on which a 2-M-cycle error would explain
`STAT_LYC_LEAD=2` reproducing the column exactly.

So `ANCHOR_POLL` builds the same probe reaching the same line by polling
`rLY` instead of halting on it. The poll's exit phase is not the halt's, so
the absolute column moves — identically in every emulator running that
build, which is why the comparison still holds. Running the `BASE`
equivalence again on both anchors and both models:

| | halt anchor | polled anchor |
|---|---|---|
| CGB | dingbat 2 M **late** | dingbat 3 M **late** |
| DMG | dingbat 1 M **early** | dingbat 1 M **early** |

That separates the problem cleanly, and neither half is what was guessed.

**On DMG the offset is anchor-independent**, the same 1 M-cycle whether the
line is reached by halting or by polling. It is therefore not the halt at
all: dingbat's LCDC.4 write reaches the DMG fetcher one M-cycle early,
full stop.

**On CGB the two anchors disagree with each other by 1 M-cycle**, which
means dingbat and SameBoy also differ over *when a new `LY` becomes visible
to the CPU* on CGB — a second, independent disagreement that only the
polled build can see, sitting on top of a 3-M-cycle write-phase error.

No model change is made here. What a fix needs is now known: two separate
terms, sized to the M-cycle, on a named side of the CPU/PPU boundary. What
is still missing is a reason to believe any particular knob spends them in
the place hardware does — and the one knob that reproduces the column
(`STAT_LYC_LEAD=2`) is measured to cost hundreds of gambatte rows, which is
what spending it in the wrong place looks like.

## Fitting the cost model: what is eliminated, and why

`tools/gbprobe/probe_e_fit.sh` scores a build against the oracle over the
whole matrix — 8 SCX × 17 object settings = **136 cells**, in *absolute*
columns rather than per-SCX shifts. Absolute matters: at SCX 0 both
emulators only ever emit column 24 or 32, and the objects-off cell is the
oracle's 24 against dingbat's 32. Read as shifts that inverts the sign of
every object cell and looks like two unrelated bugs; read absolutely it is
one table with cells in the wrong places. **Stock dingbat fits 68/136.**

### Where we cost too much

The two laws, with `R = (X + SCX) mod 8` and LOW/HIGH the tile under the
write and the one after it:

* **oracle** — OFF → LOW; X=0 → LOW; R=0 → LOW; R=1 → HIGH−1; R≥2 → HIGH
* **dingbat** — OFF → **HIGH**; R∈{0..4} → LOW; R∈{5,6,7} → HIGH

dingbat's "free" window is **three residues wide**, and that is not a
coincidence: the penalty is
`(OBJ_FETCH_DOTS-1) + max(0, (7-R) - (OBJ_WAIT_SUB-1))`, so the window's
width *is* `OBJ_WAIT_SUB = 3`. Hardware's window is one residue wide.
Setting `OBJ_WAIT_SUB = 6` gives the oracle's shape exactly and takes the
fit **68 → 113/136** — and is rejected: the full runner goes 884 → 842 and
gambatte 4201 → 3947.

### Why no knob can fix it

That rejection is the finding, not a setback — but the first reading of it
here was wrong and is corrected below, because "it regresses rows" is not by
itself evidence of anything. **Passing a row is evidence that the model
matches whatever produced that row's expectation, which is not always
hardware.** gambatte's 5,005 rows are gambatte's own output and this tree
already disagrees with some 800 of them, so −254 of them is the loudest
number in the rejection and the least probative. The rest of the list is
what decides it:

| what rejects `OBJ_WAIT_SUB=6` | where its expectations come from |
|---|---|
| 29 mealybug rows | **captures of real DMG/CGB silicon** |
| 6 GBMicrotest `sprite*` rows | the ROMs' own hardware-derived self-checks |
| mooneye `intr_2_mode0_timing_sprites`, 2 age rows, wilbertpol | hardware-derived |
| 254 gambatte rows | gambatte |

And the decisive one is not in the runner at all. `tools/gbppu/objtab.py`
scores GBMicrotest `ppu_spritex_vs_scx` — 153 cells of OBJ penalty **in
dots**, with the expected values transcribed from the ROM's own `cp`
operands, i.e. measured on silicon and baked into the test:

    stock              mismatched cells:  0/153
    OBJ_WAIT_SUB=6     mismatched cells: 99/153

**So the penalty's length is hardware-pinned, and this tree already has it
exactly right.** `OBJ_WAIT_SUB=6` is refused by silicon, not by gambatte.

### The correction that follows

The earlier claim here — that probe (e) "wants `6 + max(0, 2-R)`" — assumed
the fetch grid's displacement *is* the penalty's length, which is true in
this tree and is precisely what is not true on hardware. Hardware satisfies
`objtab`'s length law and probe (e)'s column table **at the same time**, so
those are two different quantities on silicon, and the one this tree has
wrong is the displacement, not the length. `OBJ_WAIT_SUB=6` fits 45 more
probe (e) cells by breaking the length instead — the right target reached
with the wrong lever, which is exactly what a 113/136 fit looks like when
the fit is measuring the wrong thing.

So the structural requirement is sharper than stated before: a path by which
stalled dots reach mode 3's length **without** reaching the fetch grid,
holding `objtab` at 0/153 while moving probe (e) off 68/136. In this
architecture displacement is identically the stall length, because a stalled
shifter never empties the FIFO and the fetcher parks — which is why the three
knob families below cannot express it.

### Scoring hardware separately from emulators

`tools/gbppu/hwscore.sh` exists so this cannot be confused again. It reports
only instruments anchored in silicon, for any set of knobs:

    knobs: <stock>
      objtab (mode 3 length, hardware `cp` operands) : 0/153
      probe (e) (fetch grid, SameBoy = GBA SP)       : 68 / 136 cells [cgb]
      cgb-acid-hell (vs reference)                   : 2 differing pixels

mealybug is a fourth such instrument — its references are silicon captures —
but only the full runner scores it colour-correctly, so it stays out of the
triple and is read from the runner's mealybug rows instead.

Three ways of spending the difference were tried and all are inert:

1. **`OBJ_BG_RUN`** — the existing "which fetch does the object abandon"
   axis, whose 2026-08-08 sweep concluded nothing in the tree separated its
   four policies. probe (e) does not separate them either: all four, and
   "freeze completely", score an identical **68/136**. They differ in
   *which* background fetch dies next to the object, not in the grid's net
   displacement.
2. **A new head-of-penalty knob.** `OBJ_GRID_KEEP` was implemented — let the
   BG fetcher run for the first up-to-3 wait dots, so the length term keeps
   its dots and the displacement term loses them. **68/136 at every value
   from 1 to 5**, i.e. provably inert, and the reason is already written down
   at `OBJ_BG_RUN = 4`: while the shifter is stalled the FIFO never empties,
   so the fetcher parks at `fetch_counter == 7` and ticking it does nothing.
   *Displacement is identically the stall length by construction.* The knob
   was reverted rather than shipped, since a constant that cannot change a
   frame is not a finding, it is dead code.
3. **`OBJ_FETCH_DOTS`** — moves the fit hard (4 → 98, 5 → 83, 7 → 23), which
   only confirms the coupling: both halves of the penalty displace the grid
   one dot per dot.

So the change this needs is structural — a path by which stalled dots can be
charged to mode 3 without being charged to the fetch grid — and not a
constant. That is the one thing the 136-cell harness is now able to score.

## cgb-acid-hell: the residual is not the object penalty

Diffed against the reference with `tools/gbprobe/ppmdiff.py`, the two pixels
are a **vertical swap**, not a shift: at x=80 dingbat has black on ly=68 and
yellow on ly=69, the reference has them the other way round. Tracing ly=68:

* x=80 is a **window** pixel — `WINHIT ly=68 dot=126 lx=26`, so the window
  covers everything from x=26 rightwards.
* acid-hell pulses LCDC every eight dots across the line ($E1/$80/$E3/$F3…),
  toggling window-enable, object-enable and tile-select together. The failing
  pixel sits inside the `$F3` pulse written at dot 177 (lx=77..85).
* ly=68 carries **exactly one object, at X = 1**, i.e. `R = (1+180) mod 8 =
  5` — a cell where dingbat and the oracle **agree**.

Which is why `OBJ_WAIT_SUB = 6`, for all that it buys 45 cells of probe (e),
leaves acid-hell at exactly 2 pixels. So does every other knob tried against
it: `CGB_TDSEL_IDX_DOTS` 0/4/12, `CGB_TDSEL_LATENCY` 0/2, `WIN_REACT_PHASE`
6/8, `CGB_WX_LATENCY`, `CGB_WIN_EN_HOLD` 1/2/3, `WIN_EN_HOLD` 1/3,
`WIN_EN_ABORT`, `WIN_HEAD_ABSORB`, `WIN_EN_HOLD_BACK`, `WIN_EN_HOLD_ZERO` —
**seventeen values across three families, every one of them 2 px.** The row
is insensitive to the whole parameter space it plausibly lives in, which is
consistent with the standing verdict in `docs/gb-failure-triage.md` that it
needs a structural change rather than a constant.

One tempting unification was checked and **refuted**: the `R=1` cells, where
the oracle reads HIGH−1, are not hardware splitting a mid-fetch LCDC change
inside a tile. Its bar there is nine pixels wide (`x=31-39`) — but so is
dingbat's, one band later. The whole `R=1` discrepancy is the same one-band
phase shift as the rest of the table, not a sub-tile mechanism, so it does
not explain acid-hell's single pixel either.

## `CGB_TDSEL_LATENCY = 5`: the old flag, and what it actually was

The constant that used to make acid-hell pixel-exact, and was given up when
probe (d) measured the latency on silicon, turns out to move **all three**
silicon-anchored instruments the right way at once:

```
knobs: -d:CGB_TDSEL_LATENCY=5
  objtab (mode 3 length, hardware `cp` operands) : 0/153      (held)
  probe (e) (fetch grid, SameBoy = GBA SP)       : 113/136    (from 68)
  cgb-acid-hell (vs reference)                   : 0 px       (from 2)
```

45 probe (e) cells and the 261st shootout row, with the hardware-pinned
penalty length untouched. A full runner pass costs **six rows**: the four
mealybug-cgb `tile_sel` rows, two `age/m3-bg-lcdc`, one gambatte —
884 → 878.

**It is still not the mechanism, and the reason is now two-sided.** Latency
is exactly what mealybug's `tile_sel` family measures, and *every* value
other than 1 moves those rows — 2, 3, 4 and 5 alike, and 5 paired with
`CGB_TDSEL_IDX_DOTS` at 0, 4, 12 or 16. The damage is not a line-0 artifact
either: at latency 5 `m3_lcdc_tile_sel_change` differs from the shipping
frame on **all 144 scanlines**, 16 px at x=8..23 on each. So a hardware
capture brackets latency = 1 from both sides, probe (d) measured it as 1 on
the GBA SP, and the two agree.

Which makes the reading unambiguous: **`CGB_TDSEL_LATENCY = 5` is four dots
of compensation parked in the one path that must not carry them.** acid-hell
and probe (e) genuinely want those four dots; `tile_sel` and probe (d)
genuinely forbid them here. The mechanism that supplies them has to be
something acid-hell and probe (e) exercise and `tile_sel` does not.

`LY0_PIPE_MCYCLES` was the obvious candidate for that and is refuted: at 0,
2 and 3 alongside latency 5 the `tile_sel` rows still move, and 2 and 3 take
`m3_lcdc_bg_map_change` and `m3_scy_change` with them.

### What acid-hell has that `tile_sel` does not

From the ly=68 trace: the window is **live** from x=26 (`WINHIT dot=126`),
and the LCDC pulses toggle **window-enable and tile-select in the same
write** ($E1/$80/$E3/$F3 every eight dots). `m3_lcdc_tile_sel_change` moves
tile-select alone; `m3_lcdc_tile_sel_win_change` has a window but does not
pulse both bits together. That corner — two LCDC bits whose fetcher-side
effects have different latencies, changed on one dot, with the window's
re-fetch in flight — is the narrowest description of what is left, and it is
not covered by any existing row.

`tools/gbppu/hwscore.sh` and `atrisk.sh`'s frame-equality check (stock passes
these rows, so a byte-identical frame still passes — no colour correction
needed) are what make this search cheap enough to run per candidate.

`STAT_LYC_LEAD=2` reproduces the hardware column exactly and must still be
rejected: a full runner pass with it shows gambatte `sprites` 461 → 239,
`m2enable` 94 → 62, `m2int_m3stat` 42 → 25, `scx_during_m3` 121 → 77 and a
dozen more. It moves the anchor rather than the thing the anchor is
measuring, so it buys this one column by mispricing every other STAT row.

## The penalty law, swept over all 136 settings

This is what the probe was built to answer, and with the oracle in place it
costs four minutes instead of a hardware session.
`tools/gbprobe/probe_e_penalty.sh` sweeps SCX 0-7 against object X = 0..15
and prints each setting's column shift against that SCX's own objects-off
baseline:

```
SCX   baseline  00  01  02  03  04  05  06  07  08  09  0A  0B  0C  0D  0E  0F
0     24         0   7   8   8   8   8   8   8   0   7   8   8   8   8   8   8
1     23         0   8   8   8   8   8   8   0   7   8   8   8   8   8   8   0
2     22         0   8   8   8   8   8   0   7   8   8   8   8   8   8   0   7
3     21         0   8   8   8   8   0   7   8   8   8   8   8   8   0   7   8
4     20         0   8   8   8   0   7   8   8   8   8   8   8   0   7   8   8
5     19         0   8   8   0   7   8   8   8   8   8   8   0   7   8   8   8
6     18         0   8   0   7   8   8   8   8   8   8   0   7   8   8   8   8
7     17         0   0   7   8   8   8   8   8   8   0   7   8   8   8   8   8
```

Every cell is one of three values, and which one is fixed by a single rule:

    shift = 0   if X = 0
    shift = 0   if (X + SCX) mod 8 = 0
    shift = 7   if (X + SCX) mod 8 = 1
    shift = 8   otherwise

The 7s sit immediately after each 0 and are almost certainly an 8 whose
bar has one column clipped, which would leave the law as: **an object
displaces the fetch grid by a whole tile unless it lands exactly on a tile
boundary, and X = 0 is a special case that never displaces it at all.**

Two things follow, and the second is the one worth upstreaming.

1. **The X = 0 exception is real.** dingbat models one (`sub = 0` when
   `sprites[0].x == 0`) and GBMicrotest's `ppu_spritex_vs_scx` only ever
   places an object there, so the exception has never been separable from
   the general rule before. It is separable now, and it exists.
2. **The general penalty is not flat, and not simply `SCX & 7` either.**
   `Rendering.md` says an object at X = 0 "always incurs an 11-dot penalty,
   regardless of SCX"; `pixel_fifo.md` says the penalty is "whatever the
   lower 3 bits of SCX are" once `SCX & 7 > 0`. Neither states the term
   that actually decides it, which is **`(X + SCX) mod 8`** — the object's
   position relative to the *fetch grid*, not to the screen or to SCX
   alone. Both docs are describing the two ends of that one expression.

**One thing is deliberately not claimed here: the sign.** A stall ought to
push the grid later and move the bar LEFT, and the measured shift is to the
RIGHT. Either the bar marks the fetch after the disturbance rather than the
one under it, or the object does something other than stall — an abort and
re-sync would also produce this. The *structure* above does not depend on
resolving that; a dots-of-penalty figure does, so none is quoted. Settling
it needs one more probe, not one more photograph.

## How to shoot it

1. Boot the ROM once. It comes up at `00 FF` (SCX 0, objects off).
2. For each row of the table: set SCX with LEFT/RIGHT and the object with
   UP/DOWN, **check the two hex bytes at the top-left read what you intend**,
   then photograph the whole screen.
3. Shoot each SCX's `OFF` baseline in the same sitting as its object shots,
   from a similar distance and angle — the measurement is the *difference*
   in column between them, so a consistent framing costs nothing and makes
   the comparison robust.
4. Eight photographs total, in this order (the first three are the ones that
   matter most):

       04 FF   04 01   04 00   00 FF   00 00   00 02   07 FF   07 00

Everything is on the GBA SP; the Pocket is optional as a DMG control (it has
no CGB tile-select latency, so it reads the DMG column and is a check on the
setup, not on the question).
