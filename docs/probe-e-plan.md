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

The 4-dot gap between the two models is exactly one CPU M-cycle, which is
the size of both `CGB_PIPE_MCYCLES` and `CGB_TDSEL_LATENCY`. That splits
the problem in two: a term both models share, and a CGB-only term on top.
Mode 3's *length* is not the culprit — GBMicrotest's `hblank_int_scx` family
and mooneye's mode-0 timing rows pin it and they pass; this is the grid's
*phase* against the CPU.

`STAT_LYC_LEAD=2` reproduces the hardware column exactly and must still be
rejected: a full runner pass with it shows gambatte `sprites` 461 → 239,
`m2enable` 94 → 62, `m2int_m3stat` 42 → 25, `scx_during_m3` 121 → 77 and a
dozen more. It moves the anchor rather than the thing the anchor is
measuring, so it buys this one column by mispricing every other STAT row.

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
