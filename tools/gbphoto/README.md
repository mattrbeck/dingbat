# gbphoto — read a real Game Boy screen out of a photograph

mealybug-tearoom-tests' `expected/` PNGs are not hardware captures (the suite's README:
"screenshots from my Game Boy emulator"); the only hardware evidence it ships is
`photos/<device>/*.jpg`. This turns a photo into a 160×144 grid of shade indices so a
disputed row can be adjudicated against the panel itself.

    python3 tools/gbphoto/photogrid.py adjudicate PHOTO.jpg --ref REF.png --got GOT.png
    python3 tools/gbphoto/photogrid.py recover    PHOTO.jpg --ref REF.png -o out.png
    python3 tools/gbphoto/validate.py  photos/DMG-blob expected/DMG-blob [row ...]

Needs `numpy`, `scipy`, `Pillow` and a clone of
`github.com/mattcurrie/mealybug-tearoom-tests`. `--ref` is the `_dmg_blob.png`, `--got`
dingbat's frame converted from the `--mode=screenshot` PPM.

## Pipeline

1. **Locate the panel.** `r - b` separates the orange bezel from the green/bluish panel;
   the threshold is the midpoint between the border median and the central-40% median.
   Edges are fitted as robust lines and intersected (an extreme mask point is one pixel
   of noise, most of a Game Boy pixel at ~13 photo px per cell).
2. **Register.** Eight corner coordinates maximising NCC against a template made only of
   cells the reference and the emulator already agree on, so registration cannot be
   pulled toward either hypothesis. Translation is searched by FFT cross-correlation
   over a grid of scales and rotations; tile-based frames are so 8-pixel periodic that a
   5% scale error aliases, so the best few peaks are each refined.
3. **Sample.** Median of a box at each cell centre (rejects the LCD grid lines and JPEG
   ringing).
4. **Forward model** `L ≈ a(x,y) · (K ∗ m[s]) + b(x,y)`: ridge-regularised Legendre
   illumination fields, four free shade levels, a fitted point-spread kernel (without it
   ~20% of one-pixel-stroke glyph cells misclassify), and a residual field smoothed at
   σ = 4 cells with the disputed cells excluded and interpolated across. Everything is
   fitted on agreeing cells eroded by the kernel radius.
5. **Adjudicate.** Both hypotheses predict a luminance through the same PSF and
   illumination; the measurement is projected onto the axis between them. `sep` (the
   gap in units of residual) says how much a cell can say; cells below 1σ are reported
   separately. `recover` also does a reference-free read-back by iterated conditional
   modes against the forward model.

## Validate before believing it

`validate.py`: **read-back** (recover with no hypothesis on a row the emulator passes;
every disagreement is pipeline error, reported overall and on cells with a uniform 3×3
neighbourhood), **hold-out** (refit with synthetic horizontal runs excluded, the shape a
real disputed region has, and score inside them — this says the correction is not
memorising the answer), **adjudication power** (slide bands of scanlines one pixel, the
shape every mealybug failure has, and ask `adjudicate` to choose). Quote the per-row
number, not an average; on the DMG-blob set power is ~87–100% per row, read-back error a
few percent on flat content and 9–22% on the full-page one-pixel-glyph rows.

## Limits

A single stray pixel is not recoverable at a run's confidence. A verdict on one cell is
worth little; on a several-hundred-cell region with its residual ratio, a great deal.
Flat-reference rows give registration little to hold (low `ncc` even when recovery is
fine). Only DMG is wired; the CGB photo sets exist and would need the 5-bit palette
conversion in place of the four grey levels.
