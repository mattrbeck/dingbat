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

**Caveat that has to be settled before the 8 dots are quantified.** probe
(e)'s objects-off baseline itself sits 8 px left of dingbat's on all three
SCX values, and probe (d) showed no such offset (its bar columns matched
hardware exactly). probe (e) differs from probe (d) in two ways — it
anchors at LY = 16 instead of LY = 0, and it sets LCDC.2 (8x16 objects)
even when objects are disabled. One of those moves the baseline, and until
it is known which, only the *relative* readings above are safe. The
relative readings are enough for the finding in (2), because that
comparison is internal to each machine.

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
