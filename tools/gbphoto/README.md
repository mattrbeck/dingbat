# gbphoto — read a real Game Boy screen out of a photograph

The mealybug-tearoom-tests `expected/` PNGs that every emulator is scored
against are **not hardware captures**. The suite's own README says so: they are
"screenshots from my Game Boy emulator (which I believe to be correct)", i.e.
Beaten Dying Moon's output. The only actual hardware evidence shipped with the
suite is `photos/<device>/*.jpg`, "blurry photos of the ROMs running on real
devices".

That matters whenever dingbat and a reference disagree, because until now the
only way to adjudicate was another emulator. This turns the photos into a
160×144 grid of shade indices so a diff can be run against the panel itself.

    python3 tools/gbphoto/photogrid.py adjudicate PHOTO.jpg --ref REF.png --got GOT.png
    python3 tools/gbphoto/photogrid.py recover    PHOTO.jpg --ref REF.png -o out.png
    python3 tools/gbphoto/validate.py  photos/DMG-blob expected/DMG-blob [row ...]

Needs `numpy`, `scipy` and `Pillow`. Get the photos with

    git clone https://github.com/mattcurrie/mealybug-tearoom-tests

(the run in `docs/gb-failure-triage.md` used `70e88fb`, "Add test for MBC3's
RTC"). `--ref` is the `_dmg_blob.png` the shootout scores against and `--got` is
dingbat's own frame, converted from the `--mode=screenshot` PPM.

## What the pipeline does, and why each stage is there

1. **Locate the panel** (`panel_mask`, `rough_corners`). A DMG bezel photographs
   orange whatever the light; the panel is green, or bluish under a cool light.
   `r - b` separates them in both cases where `g - r` only works for the green
   ones, and the threshold is the midpoint between the median of a thin frame at
   the image border (all bezel — every photo in the suite is cropped tight) and
   the median of the central 40% (all panel). The four edges are then fitted as
   **robust lines and intersected**, not taken as the extreme points of the mask
   along the diagonals: an extreme point is set by one pixel of mask noise, and
   at ~13 photo pixels per Game Boy pixel that was most of a pixel of error
   before refinement even started.

2. **Register** (`coarse_align`, `refine_corners`). Eight corner coordinates,
   found by maximising NCC between the sampled grid and a template. Two things
   about it are load bearing:

   * The template is **only the cells on which the reference and the emulator
     already agree** — every disputed cell is masked out. Registration therefore
     cannot be pulled toward either hypothesis; it only ever sees pixels both
     sides call the same.
   * A local optimiser from the geometric quad walks into the wrong basin on
     about a quarter of the rows, so translation is searched by FFT
     cross-correlation (every shift scored at once) over a grid of scales and
     rotations. Mealybug frames are tile-based and so strongly 8-pixel periodic
     that the correlation surface has near-equal **aliases at a 5% scale error**
     (8/160), so `coarse_align` returns the best few well-separated peaks and
     each is refined; taking the argmax alone put five of the twenty-one DMG
     rows at NCC ≈ 0.1.

3. **Sample** (`sample_grid`). Median of a box at each cell centre. The median,
   not the mean, is what rejects the LCD's inter-pixel grid lines and the JPEG
   ringing.

4. **Fit a forward model** (`ShadeModel`): `L ≈ a(x,y) · (K ∗ m[s]) + b(x,y)`.

   * `a`, `b` are low-order **Legendre** polynomials (ridge-regularised — over a
     region containing a single shade the two are individually unidentifiable
     and an unpenalised monomial fit sends both to huge cancelling values).
   * `m[0..3]` are the four shade levels, free. A DMG's four shades are nowhere
     near evenly spaced in a photograph.
   * `K` is a small **point-spread kernel**, and it is the term that matters
     most. Without it a photo of a page of one-pixel-stroke glyphs misclassifies
     ~20% of cells no matter how good the registration is — measured, not
     assumed. Fitted, not assumed either; on these photos the centre tap comes
     out 0.85–1.0.
   * `refine_field` then folds the residual, smoothed over the fit mask only,
     into the offset — that is what absorbs the scratches and specular streaks a
     global polynomial cannot. It is smoothed with σ = 4 **cells**, well above
     the width of a disputed run, and estimated with the disputed cells excluded
     and interpolated across, so it cannot absorb the feature under test.

   All of it is fitted on the agreeing cells only, eroded by the kernel radius so
   no fitted quantity touches a disputed cell.

5. **Adjudicate** (`cmd_adjudicate`). The two hypotheses predict two luminances
   through the *same* fitted PSF and illumination field; the measurement is
   projected onto the axis between them. `sep`, the gap between the two
   predictions in units of the model's own residual, is the honest statement of
   how much a cell can say at all, and cells below 1σ are reported separately
   rather than counted.

   `recover` also produces a **reference-free** read-back by iterated
   conditional modes against the same forward model (`ShadeModel.deconvolve`) —
   that is what undoes the PSF; a per-cell nearest-level threshold cannot.

## Validate before believing it

`validate.py` runs three tests, in increasing order of how much they prove:

* **read-back** — recover with no hypothesis and count cells that disagree with
  the reference. On a row the emulator already passes, hardware, reference and
  emulator are agreed by construction, so every disagreement is the pipeline's
  own error. Reported overall and restricted to cells whose 3×3 neighbourhood is
  uniform, because an isolated pixel is smeared by the panel and the lens and can
  never be read back as reliably as the inside of a run.
* **hold-out** — refit with synthetic horizontal runs excluded from the
  illumination correction, the same shape and coverage a real disputed region
  has, and score only inside them. This is what says the correction is not
  quietly memorising the answer. It tracks the read-back number to within a
  couple of points on every row, which is the result that matters.
* **adjudication power** — manufacture a plausible wrong emulator output by
  sliding bands of scanlines one pixel sideways (the shape *every* mealybug
  failure has), then ask `adjudicate` to choose between the truth and the fake.
  This exercises the real decision procedure on the real kind of error, and its
  accuracy is the number to quote when the tool testifies about a failing row.

Measured on all 21 DMG-blob photos (2026-08-07), adjudication power is **87–100%
per row, median ≈ 95%**, and read-back error is 0.03–2.6% on the flat-content
rows and 9–22% on the three that are a full page of one-pixel-stroke glyphs
(`m3_wx_4_change`, `m3_wx_5_change`, `m3_bgp_change_sprites`). Quote the
per-row number; do not quote an average.

## Limits worth stating

* **A single stray pixel is not recoverable** at the same confidence as a run.
  Use `neighbourhood_uniform` and say which stratum a claim comes from.
* A verdict on **one** disputed cell is worth little. A verdict on a
  several-hundred-cell region, with the per-region residual ratio `adjudicate`
  prints, is worth a great deal — on the rows where it decided something the
  ratios ran from 1.5× to 230×.
* Rows whose reference is nearly one flat shade give the registration almost
  nothing to hold on to; `ncc` will be low (0.1–0.5) even when the recovery is
  fine, so read `ncc` together with the read-back number, not on its own.
* Only DMG is wired up. The CGB photo sets exist (24 each for CPU CGB C and D)
  and the same machinery would work with the 5-bit palette conversion in place of
  the four grey levels, but nothing here has been validated against them.
