#!/usr/bin/env python3
"""Validate the photogrid pipeline before believing anything it says.

Three tests, in increasing order of how much they prove:

1. Read-back: recover the panel with no hypothesis and count cells that
   disagree with the reference PNG. On a row the emulator already passes,
   every disagreement is the pipeline's own error. Reported overall and
   restricted to cells whose 3x3 neighbourhood is uniform (an isolated pixel
   is smeared by the panel and lens).

2. Hold-out: refit with synthetic horizontal runs excluded from the
   illumination correction, then score only inside those runs, to show the
   correction is not memorising the answer.

3. Adjudication power: slide a band of scanlines one pixel sideways to make a
   plausible wrong frame, then ask ``adjudicate`` to choose between truth and
   fake. Its accuracy is the number to quote for a failing row.

Usage:  validate.py <photos-dir> <expected-dir> [name ...]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import photogrid as pg


def holdout_mask(shape, rng, runlen=8, coverage=0.06):
    m = np.ones(shape, bool)
    n = int(shape[0] * shape[1] * coverage / runlen)
    for _ in range(n):
        y = rng.integers(0, shape[0])
        x = rng.integers(0, shape[1] - runlen)
        m[y, x:x + runlen] = False
    return m


def fake_shift(ref, rng, bands=6, height=6, dx=1):
    """A plausible wrong frame: whole scanline bands slid sideways by one pixel
    (the shape of a mid-mode-3 register write landing one dot early or late).
    """
    got = ref.copy()
    for _ in range(bands):
        y = int(rng.integers(0, ref.shape[0] - height))
        blk = ref[y:y + height]
        got[y:y + height] = np.roll(blk, dx, axis=1)
    return got


def main():
    photos, expected = sys.argv[1], sys.argv[2]
    names = sys.argv[3:]
    if not names:
        names = sorted(f[:-4] for f in os.listdir(photos) if f.endswith('.jpg'))
    rng = np.random.default_rng(20260807)
    print('%-38s %7s %7s %7s %7s %7s %7s' %
          ('row', 'ncc', 'sigma', 'err%', 'uni%', 'hold%', 'adj%'))
    for n in names:
        rp = os.path.join(expected, n + '.png')
        if not os.path.exists(rp):
            rp = os.path.join(expected, n + '_dmg_blob.png')
        if not os.path.exists(rp):
            print('%-38s  no reference' % n)
            continue
        ref = pg.png_shades(rp)
        r = pg.recover(os.path.join(photos, n + '.jpg'), ref, None, verbose=False)
        bad = r.shades != ref
        uni = pg.neighbourhood_uniform(ref, 1)
        # (2) hold-out
        hm = holdout_mask(ref.shape, rng)
        m2 = pg.ShadeModel(5, 5).fit(r.L, ref, hm)
        m2.refine_field(r.L, ref, hm, 4.0)
        s2 = m2.deconvolve(r.L, allowed=r.present)
        hb = (s2 != ref) & ~hm
        # (3) adjudication power
        fake = fake_shift(ref, rng)
        dis = fake != ref
        if dis.sum() > 20:
            fm = ~pg._nd.binary_dilation(dis, np.ones((5, 5)))
            m3 = pg.ShadeModel(5, 5).fit(r.L, ref, fm)
            m3.refine_field(r.L, ref, fm, 4.0)
            pr, pg_ = m3.predict(ref), m3.predict(fake)
            sep = np.abs(pr - pg_)
            margin = (r.L - (pr + pg_) / 2) * np.sign(pr - pg_) / np.maximum(sep / 2, 1e-9)
            strong = dis & (sep > 1.0 * max(m3.resid, 1e-9))
            adj = 100.0 * (margin[strong] > 0).mean() if strong.sum() else float('nan')
        else:
            adj = float('nan')
        print('%-38s %7.3f %7.4f %7.2f %7.2f %7.2f %7.1f' %
              (n, r.ncc, r.model.resid, 100 * bad.mean(),
               100 * (bad & uni).sum() / max(uni.sum(), 1),
               100 * hb.sum() / max((~hm).sum(), 1), adj))


if __name__ == '__main__':
    main()
