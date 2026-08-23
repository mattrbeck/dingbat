#!/usr/bin/env python3
"""photogrid — recover a 160x144 grid of DMG shade indices from a photograph of
a real Game Boy screen.

The mealybug-tearoom-tests `expected/` PNGs are the author's emulator output
(mealybug README); the suite's hardware evidence is `photos/<device>/*.jpg`.
This turns those photos into something a diff can be run against.

The pipeline:
1. Locate the panel.  A DMG photo is a green-yellow rectangle inside an
   orange-yellow bezel; ``g - r`` separates them cleanly (the screen is green
   dominant, the bezel red dominant).  Otsu on a heavily blurred ``g - r``,
   largest connected component, fill holes, then the four extreme points along
   the +-45 degree diagonals give a rough quadrilateral.

2. Refine the homography.  The rough quad is out by several device pixels,
   which at ~14 photo pixels per Game Boy pixel is fatal.  The 8 corner
   coordinates are refined by maximising the normalised cross-correlation
   between the sampled grid and a neutral template: the shades on which the
   reference PNG and the emulator frame already agree, with every disputed
   pixel masked out, so registration cannot be pulled toward either hypothesis.

3. Sample.  Each cell is the median of the photo inside a box around the
   cell centre (default 50% of the cell), which rejects the inter-pixel grid
   lines of the LCD and most of the JPEG ringing.

4. Flat-field.  Illumination across a hand-held photo of a reflective STN
   panel varies by more than the gap between two adjacent shades, so an
   absolute threshold is hopeless.  Instead a smooth model

       L(x, y) ~ a(x, y) * m[s] + b(x, y)

   is fitted, with ``a`` and ``b`` low-order 2-D polynomials and ``m[s]`` four
   free shade levels, using only the agreeing pixels.  Classification of a
   cell is then "which m[s] does the flat-fielded value sit closest to".

5. Adjudicate.  For every disputed pixel the fitted model predicts the
   luminance the reference's shade and the emulator's shade would each produce;
   whichever is closer wins, and the margin (in units of the local shade
   spacing) is reported as the confidence.

See ``validate`` below and README.md: a pipeline that cannot reproduce a row
dingbat already passes cannot testify about one it fails.

Usage:
    photogrid.py recover  <photo.jpg> --ref REF.png [--got GOT.png] [-o out.png]
    photogrid.py validate <photo.jpg> --ref REF.png
    photogrid.py adjudicate <photo.jpg> --ref REF.png --got GOT.png
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage, optimize

nd = ndimage      # re-exported: validate.py wants binary_dilation
_nd = ndimage

GB_W, GB_H = 160, 144
# DMG greyscale levels the suite mandates for 8-bit output (mealybug README).
SHADE_LEVELS = np.array([255.0, 170.0, 85.0, 0.0])


# --------------------------------------------------------------------------
# image loading
# --------------------------------------------------------------------------

def load_photo(path, maxdim=1600):
    im = Image.open(path).convert('RGB')
    if max(im.size) > maxdim:
        s = maxdim / max(im.size)
        im = im.resize((int(round(im.width * s)), int(round(im.height * s))),
                       Image.LANCZOS)
    return np.asarray(im).astype(np.float64) / 255.0


def png_shades(path):
    """Read a 160x144 reference/emulator PNG as shade indices 0..3."""
    a = np.asarray(Image.open(path).convert('L')).astype(np.float64)
    if a.shape != (GB_H, GB_W):
        raise SystemExit('%s is %s, expected (144, 160)' % (path, a.shape))
    d = np.abs(a[..., None] - SHADE_LEVELS[None, None, :])
    return np.argmin(d, axis=2).astype(np.int8)


# --------------------------------------------------------------------------
# step 1 - locate the panel
# --------------------------------------------------------------------------

def _otsu(v):
    hist, edges = np.histogram(v, bins=256)
    hist = hist.astype(np.float64)
    tot = hist.sum()
    w0 = np.cumsum(hist)
    w1 = tot - w0
    mids = (edges[:-1] + edges[1:]) / 2
    m0 = np.cumsum(hist * mids) / np.maximum(w0, 1e-9)
    m1 = np.cumsum((hist * mids)[::-1])[::-1] / np.maximum(w1, 1e-9)
    var = w0 * w1 * (m0 - m1) ** 2
    return mids[int(np.argmax(var[:-1]))]


def panel_mask(rgb):
    """Separate the lit panel from the bezel using ``r - b``.

    A DMG bezel photographs orange (r high, b low) whatever the lighting, while
    the panel is either green (r - b moderate) or, under a cool light, bluish
    (r - b negative).  ``r - b`` therefore separates the two in both cases,
    where ``g - r`` only works for the green ones.  The threshold is the
    midpoint between the median of a thin frame at the image border (all bezel,
    since every photo in the suite is cropped tight to the screen) and the
    median of the central 40% (all panel) - a well-posed threshold, unlike Otsu
    on a histogram this unbalanced.

    The mask is advisory: `rough_corners` only needs it to be roughly right,
    and `coarse_align` below recovers even when it is not.
    """
    d = ndimage.gaussian_filter(rgb[..., 0] - rgb[..., 2], 4)
    h, w = d.shape
    fy, fx = max(2, int(h * 0.012)), max(2, int(w * 0.012))
    frame = np.concatenate([d[:fy].ravel(), d[-fy:].ravel(),
                            d[:, :fx].ravel(), d[:, -fx:].ravel()])
    bez = float(np.median(frame))
    scr = float(np.median(d[int(h * .3):int(h * .7), int(w * .3):int(w * .7)]))
    if abs(bez - scr) < 0.02:            # no usable contrast; fall back
        return np.zeros_like(d, bool)
    t = (bez + scr) / 2
    m = d < t if scr < bez else d > t
    m = ndimage.binary_closing(m, np.ones((9, 9)))
    m = ndimage.binary_fill_holes(m)
    lab, n = ndimage.label(m)
    if n > 1:
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        m = lab == (int(np.argmax(sizes)) + 1)
        m = ndimage.binary_fill_holes(m)
    if not (0.45 < m.mean() < 0.995):    # implausible: content ate the mask
        return np.zeros_like(d, bool)
    return m


def _fit_line(t, u):
    """Robust y = a*t + b by iteratively reweighted least squares (Huber)."""
    w = np.ones_like(t)
    a = b = 0.0
    for _ in range(8):
        X = np.stack([t, np.ones_like(t)], 1) * w[:, None]
        sol, *_ = np.linalg.lstsq(X, u * w, rcond=None)
        a, b = sol
        r = u - (a * t + b)
        s = 1.4826 * np.median(np.abs(r - np.median(r))) + 1e-6
        w = 1.0 / np.sqrt(1.0 + (r / (2.0 * s)) ** 2)
    return a, b


def rough_corners(mask, shape):
    """Fit the four panel edges as lines and intersect them.

    Extreme points along the diagonals are set by a single pixel of mask noise
    and come out several device pixels wrong; a robust line per edge uses
    hundreds of boundary samples instead of one.
    """
    ys, xs = np.nonzero(mask)
    h, w = shape
    if len(xs) < 500:
        # Every photo in the suite is cropped tight to the screen, so the image
        # bounds inset by ~2% is a serviceable prior when the mask fails.
        ix, iy = 0.02 * w, 0.02 * h
        return np.array([[ix, iy], [w - 1 - ix, iy],
                         [w - 1 - ix, h - 1 - iy], [ix, h - 1 - iy]])
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    # trim the ends, where a rounded bezel corner curves the boundary
    ty, tx = int((y1 - y0) * 0.15), int((x1 - x0) * 0.15)
    rows = np.arange(y0 + ty, y1 - ty + 1)
    cols = np.arange(x0 + tx, x1 - tx + 1)
    lx, rx, ty_, by = [], [], [], []
    for r in rows:
        idx = np.nonzero(mask[r])[0]
        if len(idx):
            lx.append(idx[0]); rx.append(idx[-1])
        else:
            lx.append(np.nan); rx.append(np.nan)
    for c in cols:
        idx = np.nonzero(mask[:, c])[0]
        if len(idx):
            ty_.append(idx[0]); by.append(idx[-1])
        else:
            ty_.append(np.nan); by.append(np.nan)
    lx, rx = np.array(lx, float), np.array(rx, float)
    ty_, by = np.array(ty_, float), np.array(by, float)
    ok_r = ~np.isnan(lx)
    ok_c = ~np.isnan(ty_)
    # left/right edges: x = a*y + b ; top/bottom: y = a*x + b
    al, bl = _fit_line(rows[ok_r].astype(float), lx[ok_r])
    ar, br = _fit_line(rows[ok_r].astype(float), rx[ok_r])
    at, bt = _fit_line(cols[ok_c].astype(float), ty_[ok_c])
    ab, bb = _fit_line(cols[ok_c].astype(float), by[ok_c])

    def isect(a_v, b_v, a_h, b_h):
        # x = a_v*y + b_v  and  y = a_h*x + b_h
        y = (a_h * b_v + b_h) / (1 - a_h * a_v)
        return np.array([a_v * y + b_v, y])

    return np.array([isect(al, bl, at, bt), isect(ar, br, at, bt),
                     isect(ar, br, ab, bb), isect(al, bl, ab, bb)])


# --------------------------------------------------------------------------
# step 2/3 - homography and sampling
# --------------------------------------------------------------------------

def homography(corners):
    """Map unit square (0,0),(1,0),(1,1),(0,1) -> the four given corners."""
    dst = np.asarray(corners, dtype=np.float64)
    src = np.array([[0., 0.], [1., 0.], [1., 1.], [0., 1.]])
    A = np.zeros((8, 8))
    b = np.zeros(8)
    for i in range(4):
        x, y = src[i]
        X, Y = dst[i]
        A[2 * i] = [x, y, 1, 0, 0, 0, -x * X, -y * X]
        b[2 * i] = X
        A[2 * i + 1] = [0, 0, 0, x, y, 1, -x * Y, -y * Y]
        b[2 * i + 1] = Y
    h = np.linalg.solve(A, b)
    return np.append(h, 1.0).reshape(3, 3)


def _apply(H, u, v):
    d = H[2, 0] * u + H[2, 1] * v + H[2, 2]
    return ((H[0, 0] * u + H[0, 1] * v + H[0, 2]) / d,
            (H[1, 0] * u + H[1, 1] * v + H[1, 2]) / d)


def sample_grid(gray, corners, sub=3, frac=0.5):
    """Median of a `frac`-sized box at each of the 160x144 cell centres.

    `sub` x `sub` taps per cell, bilinear.  The median (not the mean) is what
    rejects the LCD's inter-pixel grid lines and JPEG ringing.
    """
    H = homography(corners)
    h, w = gray.shape
    off = (np.arange(sub) + 0.5) / sub - 0.5          # -0.5 .. +0.5
    off = off * frac
    cx = (np.arange(GB_W) + 0.5) / GB_W
    cy = (np.arange(GB_H) + 0.5) / GB_H
    taps = np.empty((sub * sub, GB_H, GB_W))
    k = 0
    for dy in off:
        for dx in off:
            u = (cx + dx / GB_W)[None, :] + np.zeros((GB_H, 1))
            v = (cy + dy / GB_H)[:, None] + np.zeros((1, GB_W))
            X, Y = _apply(H, u, v)
            X = np.clip(X, 0, w - 1.001)
            Y = np.clip(Y, 0, h - 1.001)
            x0 = np.floor(X).astype(int)
            y0 = np.floor(Y).astype(int)
            fx = X - x0
            fy = Y - y0
            taps[k] = (gray[y0, x0] * (1 - fx) * (1 - fy) +
                       gray[y0, x0 + 1] * fx * (1 - fy) +
                       gray[y0 + 1, x0] * (1 - fx) * fy +
                       gray[y0 + 1, x0 + 1] * fx * fy)
            k += 1
    return np.median(taps, axis=0)


def _highpass(a, sigma=6.0):
    return a - ndimage.gaussian_filter(a, sigma, mode='nearest')


def _warp_quad(corners, sx, sy, theta, tu=0.0, tv=0.0):
    """Scale about the centre, rotate, then translate by (tu, tv) *cells*."""
    c = np.asarray(corners, float)
    mid = c.mean(0)
    p = c - mid
    p = p * np.array([sx, sy])
    if theta:
        ct, st = np.cos(theta), np.sin(theta)
        p = p @ np.array([[ct, st], [-st, ct]])
    c = p + mid
    if tu or tv:
        ex = (c[1] - c[0] + c[2] - c[3]) / 2 / GB_W
        ey = (c[3] - c[0] + c[2] - c[1]) / 2 / GB_H
        c = c + tu * ex + tv * ey
    return c


def coarse_align(gray, corners, template, mask, ntop=4):
    """Grid-search scale and rotation; find translation by cross-correlation.

    The geometric quad can be a couple of Game Boy pixels out in scale, and a
    local optimiser started there walks into the wrong basin.  Because
    translating the quad by a whole cell is the same as
    rolling the sampled grid, every translation can be scored at once with one
    FFT per (scale, rotation) pair, so a 21x21x5 grid costs a few hundred
    samplings rather than a few hundred thousand.
    """
    t = _highpass(template.astype(np.float64)) * mask
    t = t - t[mask].mean() * mask
    T = np.fft.rfft2(t[::-1, ::-1])
    cands = []
    for sx in np.linspace(0.955, 1.045, 19):
        for sy in np.linspace(0.955, 1.045, 19):
            for th in np.deg2rad(np.linspace(-1.2, 1.2, 5)):
                c = _warp_quad(corners, sx, sy, th)
                s = _highpass(sample_grid(gray, c, sub=2))
                s = s - s.mean()
                xc = np.fft.irfft2(np.fft.rfft2(s) * T, s.shape)
                k = int(np.argmax(xc))
                v = float(xc.flat[k]) / (np.linalg.norm(s) + 1e-9)
                dv, du = np.unravel_index(k, s.shape)
                # peak index is (H-1+shift) mod H; unwrap to +-H/2
                dv = ((int(dv) - GB_H + 1 + GB_H // 2) % GB_H) - GB_H // 2
                du = ((int(du) - GB_W + 1 + GB_W // 2) % GB_W) - GB_W // 2
                cands.append((v, sx, sy, th, du, dv))
    # Mealybug frames are so strongly 8-pixel periodic that the correlation
    # surface has near-equal aliases at scale errors around 8/160 = 5%; the
    # argmax alone picks the alias, so return the best few separated peaks.
    cands.sort(key=lambda t: -t[0])
    out = []
    for v, sx, sy, th, du, dv in cands:
        if all(abs(sx - o[0]) > 0.012 or abs(sy - o[1]) > 0.012 for o in out):
            out.append((sx, sy, th, du, dv))
        if len(out) >= ntop:
            break
    return [_warp_quad(corners, *p) for p in out]


def refine_corners(gray, corners, template, mask, sub=3, frac=0.5, leash=0.06):
    """Maximise NCC between the high-passed sampled grid and a neutral template.

    `template` is -shade (bright = shade 0) and `mask` selects the cells where
    the reference and the emulator already agree, so registration is blind to
    every cell the two hypotheses argue about.

    `leash` bounds how far a corner may move from the geometric estimate, as a
    fraction of the panel width, with a quadratic penalty inside it.  Without
    it, a nearly blank reference (m3_wx_4_change_sprites is 97% one shade)
    gives NCC almost nothing to hold on to and the quad wanders off the panel.
    """
    t = _highpass(template.astype(np.float64))
    tm = t[mask]
    tm = tm - tm.mean()
    tn = np.linalg.norm(tm)
    span = np.linalg.norm(corners[1] - corners[0])
    lim = leash * span

    def cost(p):
        d = np.linalg.norm(p.reshape(4, 2), axis=1)
        if (d > lim).any():
            return 10.0 + float(np.max(d) / lim)
        c = corners + p.reshape(4, 2)
        s = sample_grid(gray, c, sub=sub, frac=frac)
        s = _highpass(s)[mask]
        s = s - s.mean()
        n = np.linalg.norm(s)
        if n < 1e-9 or tn < 1e-9:
            return 0.0
        ncc = float(s @ tm / (n * tn))
        return -ncc + 0.02 * float(np.mean((d / lim) ** 2))

    best = (cost(np.zeros(8)), np.zeros(8))
    # Coarse translate/scale search first: the geometric quad is usually out by
    # a device pixel or two, and Powell from a bad start stalls.
    for d in (span * 0.012, span * 0.004, span * 0.0015):
        improved = True
        while improved:
            improved = False
            base = best[1]
            for delta in _local_moves(d):
                c = cost(base + delta)
                if c < best[0] - 1e-6:
                    best = (c, base + delta)
                    improved = True
                    base = best[1]
    r = optimize.minimize(cost, best[1], method='Powell',
                          options=dict(xtol=0.05, ftol=1e-5, maxiter=4000))
    if r.fun < best[0]:
        best = (r.fun, r.x)
    p = best[1]
    c = corners + p.reshape(4, 2)
    s = sample_grid(gray, c, sub=sub, frac=frac)
    s = _highpass(s)[mask]
    s = s - s.mean()
    n = np.linalg.norm(s)
    ncc = float(s @ tm / (n * tn)) if n > 1e-9 and tn > 1e-9 else 0.0
    return c, ncc


def _local_moves(d):
    """Whole-quad translate/scale moves plus single-corner nudges.

    Corner order is TL, TR, BR, BL.  Translation moves all four the same way;
    horizontal scale pushes the left pair one way and the right pair the other;
    vertical scale does the same for the top and bottom pairs.
    """
    mv = []
    for s in (+1, -1):
        for ax in (0, 1):
            v = np.zeros((4, 2)); v[:, ax] = s * d                  # translate
            mv.append(v.ravel().copy())
        v = np.zeros((4, 2))                                        # scale x
        v[[0, 3], 0] = -s * d
        v[[1, 2], 0] = s * d
        mv.append(v.ravel().copy())
        v = np.zeros((4, 2))                                        # scale y
        v[[0, 1], 1] = -s * d
        v[[2, 3], 1] = s * d
        mv.append(v.ravel().copy())
    for i in range(4):                                              # one corner
        for ax in (0, 1):
            for s in (+1, -1):
                v = np.zeros((4, 2)); v[i, ax] = s * d
                mv.append(v.ravel().copy())
    return mv


# --------------------------------------------------------------------------
# step 4 - flat-field / shade model
# --------------------------------------------------------------------------

def _poly_basis(deg):
    """Tensor-product Legendre basis on [-1, 1]^2, total degree <= deg.

    Legendre rather than raw monomials because the illumination fit below is
    ridge-regularised, and a penalty on the coefficients only means anything if
    the basis is (near-)orthogonal.  With monomials a degree-5 fit is ill
    conditioned enough that the a and b fields trade off against each other and
    blow up over any region that contains only one shade.
    """
    from numpy.polynomial import legendre
    x = np.arange(GB_W) / (GB_W - 1) * 2 - 1
    y = np.arange(GB_H) / (GB_H - 1) * 2 - 1
    Lx = np.stack([legendre.Legendre.basis(i)(x) for i in range(deg + 1)])
    Ly = np.stack([legendre.Legendre.basis(i)(y) for i in range(deg + 1)])
    cols = []
    for i in range(deg + 1):
        for j in range(deg + 1 - i):
            cols.append(Ly[j][:, None] * Lx[i][None, :])
    return np.stack(cols, -1)          # H x W x K


def _ridge(X, y, lam, free=()):
    """Least squares with a Tikhonov penalty on every column but `free`."""
    n, k = X.shape
    scale = np.sqrt(max((X * X).sum() / max(n, 1), 1e-12))
    d = np.full(k, lam * scale)
    for i in free:
        d[i] = 0.0
    Xa = np.concatenate([X, np.diag(d)], 0)
    ya = np.concatenate([y, np.zeros(k)])
    sol, *_ = np.linalg.lstsq(Xa, ya, rcond=None)
    return sol


def _shift(a, dy, dx):
    return np.roll(np.roll(a, dy, axis=0), dx, axis=1)


class ShadeModel:
    """L(x,y) ~ a(x,y) * (K * m[s])(x,y) + b(x,y).

    Three parts, all of them necessary:

    * ``a``, ``b`` - low-order 2-D polynomials, the illumination field.  A
      hand-held photo of a reflective STN panel varies across the frame by more
      than the gap between two adjacent shades, so no global threshold works.
    * ``m[0..3]``  - the four shade levels.  Free, not assumed: a DMG's four
      shades are nowhere near evenly spaced in a photograph.
    * ``K``        - a small point-spread kernel.  This is the one that matters
      most.  A DMG's STN pixels have slow response and visible crosstalk, the
      lens adds its own blur, and JPEG adds more; the net effect is that an
      isolated one-pixel feature reaches nothing like its true shade.  Without a
      PSF term a photo of a page of 1-pixel-stroke glyphs misclassifies ~20% of
      cells no matter how good the alignment is.

    Fitted by alternating least squares.  Each of the three sub-problems is
    linear given the other two, and the whole thing converges in ~15 sweeps from
    a per-shade median seed.  Only pixels in ``mask`` contribute, and callers
    are expected to pass a mask that already excludes anything within the
    kernel's reach of a disputed cell.
    """

    def __init__(self, deg=3, ksize=5, lam=0.02):
        self.deg = deg
        self.ksize = ksize
        self.lam = lam
        self.B = _poly_basis(deg)
        self.nk = self.B.shape[-1]
        r = ksize // 2
        self.taps = [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1)]

    # -- helpers -------------------------------------------------------
    def _blur(self, M):
        out = np.zeros_like(M)
        for w, (dy, dx) in zip(self.K, self.taps):
            if w != 0.0:
                out += w * _shift(M, dy, dx)
        return out

    def fit(self, L, shades, mask, iters=15):
        m = np.zeros(4)
        for s in range(4):
            sel = mask & (shades == s)
            m[s] = np.median(L[sel]) if sel.sum() >= 20 else np.nan
        good = ~np.isnan(m)
        if good.sum() < 2:
            raise ValueError('fewer than two shades present')
        m = np.interp(np.arange(4), np.arange(4)[good], m[good])
        self.present = good
        self.K = np.zeros(len(self.taps))
        self.K[len(self.taps) // 2] = 1.0

        idx = np.nonzero(mask)
        Bm = self.B[idx]
        Lm = L[idx]
        ind = [(shades == s).astype(np.float64) for s in range(4)]
        m0, m3 = m[0], m[3]

        for it in range(iters):
            M = m[shades]
            Mb = self._blur(M)
            # (1) illumination, given m and K.  Ridge on everything but the two
            # constant terms: over a region containing a single shade, a and b
            # are individually unidentifiable and an unpenalised fit sends them
            # both to huge cancelling values.
            A = np.concatenate([Bm * Mb[idx][:, None], Bm], 1)
            coef = _ridge(A, Lm, self.lam, free=(0, self.nk))
            af = self.B @ coef[:self.nk]
            bf = self.B @ coef[self.nk:]
            # (2) shade levels, given illumination and K
            cols = [(af * self._blur(ind[s]))[idx] for s in range(4)]
            cols = [c for s, c in enumerate(cols) if self.present[s]]
            X = np.stack(cols, 1)
            sol, *_ = np.linalg.lstsq(X, Lm - bf[idx], rcond=None)
            new = m.copy()
            new[self.present] = sol
            miss = ~self.present
            if miss.any():
                new[miss] = np.interp(np.arange(4)[miss],
                                      np.arange(4)[self.present], sol)
            span = new[0] - new[3]
            if abs(span) > 1e-9:                       # pin the scale
                new = (new - new[3]) * ((m0 - m3) / span) + m3
            m = new
            # (3) kernel, given illumination and m
            M = m[shades]
            cols = [(af * _shift(M, dy, dx))[idx] for (dy, dx) in self.taps]
            X = np.stack(cols, 1)
            sol, *_ = np.linalg.lstsq(X, Lm - bf[idx], rcond=None)
            s = sol.sum()
            self.K = sol / s if abs(s) > 1e-9 else sol
        self.m = m
        self.A = af
        self.Bo = bf
        self.resid = float(np.sqrt(np.mean(
            (L[idx] - (af * self._blur(m[shades]) + bf)[idx]) ** 2)))
        return self

    def refine_field(self, L, shades, mask, sigma=4.0):
        """Absorb what a global polynomial cannot: scratches, specular streaks,
        the panel's own mottling.

        The residual of the global fit is smoothed over `mask` only (a
        mask-normalised Gaussian, so excluded cells are *interpolated across*
        rather than treated as zero) and folded into the offset field.  With
        `mask` set to the agreeing cells, the correction over a disputed run is
        extrapolated from its surroundings and cannot absorb the very feature
        under test - provided sigma stays well above the width of a run, which
        is why it is quoted in cells and defaults to 4.
        """
        r = np.where(mask, L - self.predict(shades), 0.0)
        w = mask.astype(np.float64)
        num = ndimage.gaussian_filter(r, sigma, mode='nearest')
        den = ndimage.gaussian_filter(w, sigma, mode='nearest')
        corr = num / np.maximum(den, 1e-6)
        self.Bo = self.Bo + corr
        idx = np.nonzero(mask)
        self.resid = float(np.sqrt(np.mean(
            (L[idx] - self.predict(shades)[idx]) ** 2)))
        return self

    # -- use -----------------------------------------------------------
    def predict(self, shade_grid):
        """Luminance this model says a whole 160x144 shade image would produce."""
        return self.A * self._blur(self.m[shade_grid]) + self.Bo

    def step(self):
        """Local luminance gap between two adjacent shades (H x W)."""
        return np.abs(self.A) * abs(np.diff(self.m)).mean() * self.K.max()

    def normalised(self, L):
        """Map a measured grid onto the shade axis (0..3, fractional).

        Ignores the PSF, so it is a *display* aid and a crude per-cell readout,
        not the basis of any verdict.
        """
        z = (L - self.Bo) / np.where(np.abs(self.A) < 1e-9, 1e-9, self.A)
        order = np.argsort(self.m)
        return np.interp(z, self.m[order], np.asarray(order, np.float64))

    def deconvolve(self, L, init=None, allowed=None, sweeps=8):
        """Reference-free readout: the shade image whose *predicted* photo is
        closest to the one measured.

        Iterated conditional modes - start from the per-cell nearest level and
        then repeatedly re-decide each cell against the full forward model,
        which is what undoes the PSF.  `allowed` restricts the candidate shades
        (a DMG frame that contains only two of the four shades should not be
        allowed to invent the other two out of blur).
        """
        cand = list(range(4)) if allowed is None else list(allowed)
        if init is None:
            z = self.normalised(L)
            init = np.array(cand)[np.argmin(
                np.abs(z[..., None] - np.array(cand)[None, None, :]), axis=2)]
        S = init.astype(np.int8).copy()
        for _ in range(sweeps):
            pred = self.predict(S)
            r = L - pred
            changed = 0
            for s in cand:
                # effect on pred of setting a cell to s: A * K * (m[s]-m[S])
                delta = self.A * self.K.max() * (self.m[s] - self.m[S])
                gain = np.abs(r) - np.abs(r - delta)
                better = (gain > 0) & (S != s)
                if better.any():
                    S = np.where(better, np.int8(s), S)
                    changed += int(better.sum())
            if changed == 0:
                break
        return S

    def classify(self, L):
        """Per-cell nearest-level readout, PSF ignored.  Kept for diagnostics."""
        lev = self.A[..., None] * self.m[None, None, :] + self.Bo[..., None]
        d = np.abs(L[..., None] - lev)
        return np.argmin(d, axis=2).astype(np.int8), d


# --------------------------------------------------------------------------
# top level
# --------------------------------------------------------------------------

class Recovery:
    pass


def recover(photo_path, ref, got=None, maxdim=2200, deg=5, ksize=5,
            sigma=4.0, verbose=True):
    """Align, sample, fit the forward model, and read the panel back.

    ``ref`` and ``got`` are the two competing 160x144 shade images.  Everything
    that could bias a verdict - the registration template and the model fit -
    sees only the cells on which the two already agree, eroded by the kernel
    radius so no fitted quantity is contaminated by a disputed cell.
    """
    rgb = load_photo(photo_path, maxdim)
    gray = rgb @ np.array([0.299, 0.587, 0.114])
    c0 = rough_corners(panel_mask(rgb), gray.shape)
    agree = np.ones((GB_H, GB_W), bool) if got is None else (ref == got)
    fitmask = agree
    if got is not None:
        r = ksize // 2
        fitmask = ~ndimage.binary_dilation(~agree, np.ones((2 * r + 1,) * 2))
    if fitmask.sum() < 3000:      # too little clean area; fall back to all
        fitmask = np.ones((GB_H, GB_W), bool)
    tmpl = -ref.astype(np.float64)
    starts = [c0] + coarse_align(gray, c0, tmpl, agree)
    corners, ncc = None, -2.0
    for st in starts:
        c, v = refine_corners(gray, st, tmpl, agree)
        if v > ncc:
            corners, ncc = c, v
    L = sample_grid(gray, corners, sub=5)
    model = ShadeModel(deg, ksize).fit(L, ref, fitmask)
    if sigma > 0:
        model.refine_field(L, ref, fitmask, sigma)
    present = sorted(set(np.unique(ref).tolist()) |
                     (set(np.unique(got).tolist()) if got is not None else set()))
    shades = model.deconvolve(L, allowed=present)
    r = Recovery()
    r.shades, r.model, r.L, r.corners, r.ncc = shades, model, L, corners, ncc
    r.agree, r.fitmask, r.present = agree, fitmask, present
    r.snr = float(abs(np.diff(model.m)).mean() * abs(model.A).mean() /
                  max(model.resid, 1e-9))
    if verbose:
        print('  ncc %.4f  resid %.4f  shade-step/resid %.2f  levels %s  K0 %.3f'
              % (ncc, model.resid, r.snr,
                 np.array2string(model.m, precision=4), model.K.max()))
    return r


def _render(shades, path, scale=3):
    img = SHADE_LEVELS[np.clip(shades, 0, 3)].astype(np.uint8)
    Image.fromarray(img).resize((GB_W * scale, GB_H * scale),
                                Image.NEAREST).save(path)


def neighbourhood_uniform(ref, r=1):
    """True where the reference is constant over a (2r+1) square.

    Recovery of an *isolated* pixel is fundamentally limited: the panel's own
    response plus the lens plus JPEG smear a one-pixel feature into its
    neighbours, so a single stray pixel can never be read back with the same
    confidence as the interior of a run.  Every confidence figure this tool
    prints is stratified on this.
    """
    same = np.ones(ref.shape, bool)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            same &= _shift(ref, dy, dx) == ref
    same[:r] = same[-r:] = False
    same[:, :r] = same[:, -r:] = False
    return same


def cmd_recover(a):
    ref = png_shades(a.ref)
    got = png_shades(a.got) if a.got else None
    r = recover(a.photo, ref, got, a.maxdim)
    dis = int((r.shades != ref).sum())
    print('  recovered vs reference: %d / %d cells differ (%.2f%%)' %
          (dis, GB_W * GB_H, 100.0 * dis / (GB_W * GB_H)))
    if a.out:
        _render(r.shades, a.out)
    if a.npy:
        np.save(a.npy, r.shades)


def cmd_validate(a):
    """Confidence report for one photo, using the reference as ground truth.

    Only meaningful on rows where the emulator already matches the reference
    exactly: there hardware, reference and emulator are all agreed, so every
    mismatch the pipeline reports is the *pipeline's* own error.
    """
    ref = png_shades(a.ref)
    got = png_shades(a.got) if a.got else None
    r = recover(a.photo, ref, got, a.maxdim)
    bad = r.shades != ref
    uni = neighbourhood_uniform(ref, 1)
    print('  read-back errors: %d / %d (%.3f%%)  |  in 3x3-uniform cells: '
          '%d / %d (%.3f%%)' %
          (bad.sum(), bad.size, 100 * bad.mean(),
           (bad & uni).sum(), uni.sum(), 100 * (bad & uni).sum() / max(uni.sum(), 1)))
    # discrimination power: could this photo tell shade s from shade s+/-1?
    pr = r.model.predict(ref)
    for s in range(3):
        alt = ref.copy()
        alt[ref == s] = s + 1
        pa = r.model.predict(alt)
        sel = ref == s
        if sel.sum() < 20:
            continue
        sep = np.abs(pr - pa)[sel].mean() / max(r.model.resid, 1e-9)
        win = (np.abs(L_of(r) - pr) < np.abs(L_of(r) - pa))[sel].mean()
        print('    shade %d vs %d: separation %.2f sigma, true wins %.1f%%'
              % (s, s + 1, sep, 100 * win))


def L_of(r):
    return r.L


def cmd_adjudicate(a):
    """Where ref and got disagree, ask the photo which of the two it looks like.

    Per cell the two hypotheses predict two luminances (through the *same*
    fitted PSF and illumination field); the measurement is projected onto the
    axis between them.  A positive margin means the photo sits on the
    reference's side.  ``sep`` - the gap between the two predictions in units of
    the model's own residual - is the honest statement of how much a given cell
    can say at all; cells below ~1 sigma are noise and are reported separately.
    """
    ref = png_shades(a.ref)
    got = png_shades(a.got)
    r = recover(a.photo, ref, got, a.maxdim)
    dis = ~r.agree
    n = int(dis.sum())
    if n == 0:
        print('  no disputed cells')
        return
    pr = r.model.predict(ref)
    pg = r.model.predict(got)
    sep = np.abs(pr - pg)
    sigma = max(r.model.resid, 1e-9)
    margin = (r.L - (pr + pg) / 2) * np.sign(pr - pg) / np.maximum(sep / 2, 1e-9)
    strong = dis & (sep > 1.0 * sigma)
    print('  disputed cells: %d   (with >1 sigma of discriminating power: %d)'
          % (n, strong.sum()))
    for nm, sel in (('all disputed', dis), ('>1 sigma', strong),
                    ('>2 sigma', dis & (sep > 2.0 * sigma))):
        k = int(sel.sum())
        if k == 0:
            print('  %-13s : none' % nm)
            continue
        rw = int((margin[sel] > 0).sum())
        print('  %-13s : n=%-5d  hardware ~ REFERENCE %5d (%5.1f%%)   '
              '~ EMULATOR %5d (%5.1f%%)'
              % (nm, k, rw, 100.0 * rw / k, k - rw, 100.0 * (k - rw) / k))
    if a.out:
        vis = np.repeat(SHADE_LEVELS[ref].astype(np.uint8)[..., None], 3, 2)
        vis[dis & (margin > 0)] = (0, 190, 0)
        vis[dis & (margin <= 0)] = (220, 0, 0)
        vis[dis & (sep <= 1.0 * sigma)] = (80, 80, 255)
        Image.fromarray(vis).resize((GB_W * 4, GB_H * 4), Image.NEAREST).save(a.out)
    if a.npy:
        np.save(a.npy, np.stack([r.shades.astype(np.float64), margin,
                                 sep / sigma]))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    for name, fn in (('recover', cmd_recover), ('validate', cmd_validate),
                     ('adjudicate', cmd_adjudicate)):
        q = sub.add_parser(name)
        q.add_argument('photo')
        q.add_argument('--ref', required=True)
        q.add_argument('--got')
        q.add_argument('-o', '--out')
        q.add_argument('--npy')
        q.add_argument('--maxdim', type=int, default=1600)
        q.set_defaults(fn=fn)
    a = p.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
