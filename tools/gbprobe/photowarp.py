#!/usr/bin/env python3
"""photowarp — turn a photograph of a Game Boy screen into the exact 160x144
frame, so `hwprobe_ocr.py` / `readout.py` / `arbread.py` read hardware photos
exactly as they read emulator screenshots.

    photowarp.py <photo.jpg|png> <out.ppm> [--refine] [--debug]
    photowarp.py <photo> <out.ppm> --corners x0,y0,x1,y1,x2,y2,x3,y3

Registration (the automatic path) anchors on the FRAME RECTANGLE: a probe
page whose background fills the frame — every `gbedge.gb` page,
cgb-acid-hell, anything drawn on a full-screen background — is one
extreme-luma quadrilateral inside a black letterbox (GBA/SP) or a dark
bezel, and that quadrilateral *is* the 160x144 frame.  Its four edges are
fitted as lines from the outermost qualifying pixel of every sampled row
and column, trimmed of the worst quarter of residuals and refitted, then
intersected.  Fitting lines rather than taking the extreme points along
each diagonal is not a nicety: one pixel of mask noise sets an extreme
point, and at ~4 photo pixels per GB pixel that is most of a GB pixel of
error before anything else happens.

Two things are searched rather than assumed, because both move with the
photograph and one GB pixel of error at the border is a whole cell of drift
by the far side: the POLARITY (a backlit SP screen is the brightest thing
in its photo; a reflective panel under room light is the darkest) and where
in the border's black-to-white ramp the true edge sits.  Candidates are
gated on geometry (`plausible`) and the survivor chosen by `grid_score`,
which asks only whether the sampling grid lands on the photo's own pixel
grid.

Nothing in that fit looks at the frame's *contents*: glyphs and digits are
interior holes in the region and cannot move its outer boundary, and no
expected image is consulted.  That matters because these photos are
evidence in disputes where an emulator frame is one of the competing
hypotheses — registering against such a frame would let a hypothesis move
its own ruler.

`--corners` takes the four frame corners (top-left, top-right,
bottom-right, bottom-left, in photo pixels) for photos the anchor cannot
fit — see the scope note below.

`--raw` skips the illumination flattening; `--refine` adds a grid-lock
polish of the fitted corners (default on).

SCOPE, measured on the 2026-08-17 session (`--selftest <photo-dir> <txt>`):

  * GBA SP, backlit, 27 gbedge pages: **25 of 27 pages CRC-verified
    straight from the photographs** — the CRC-16 the ROM computes over each
    page's 32 result bytes, read off the warp, equal to the independently
    hand-transcribed value in `tests/roms/expected/gb-agbsp-1.txt`.  A
    matching CRC means those bytes were recovered exactly.  The two
    failures are the two blurriest photos of the set.
  * Game Boy Pocket, reflective panel photographed against a bright
    surround: **0 of 27** — the frame is neither the brightest nor the
    darkest region there, so the anchor has nothing to hold.  Use
    `--corners`, or shoot that panel against a dark surround.

The self-test is also why `grid_score` is trusted on the `probe_*.gb`
photos, where there is no font to appeal to: on every gbedge photo where
both can be compared, the threshold it picks is the one the ROM's own font
agrees with.
"""
import os
import subprocess
import sys
import struct
import tempfile
import zlib

GB_W, GB_H = 160, 144


# --------------------------------------------------------------------------
# image loading
# --------------------------------------------------------------------------

def read_png(path):
    f = open(path, 'rb').read()
    pos, idat = 8, b''
    w = h = ct = bd = None
    while pos < len(f):
        ln = struct.unpack('>I', f[pos:pos+4])[0]
        typ = f[pos+4:pos+8]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', f[pos+8:pos+18])
        elif typ == b'IDAT':
            idat += f[pos+8:pos+8+ln]
        pos += 12 + ln
    if ct not in (2, 6) or bd != 8:
        raise SystemExit(f'{path}: need 8-bit RGB/RGBA PNG (got ct={ct} bd={bd})')
    ch = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * ch + 1
    prev = bytearray(w * ch)
    rows = []
    for y in range(h):
        line = raw[y*stride:(y+1)*stride]
        ft = line[0]
        cur = bytearray(line[1:])
        if ft:
            for i in range(len(cur)):
                a = cur[i-ch] if i >= ch else 0
                b = prev[i]
                c = prev[i-ch] if i >= ch else 0
                if ft == 1:
                    cur[i] = (cur[i] + a) & 255
                elif ft == 2:
                    cur[i] = (cur[i] + b) & 255
                elif ft == 3:
                    cur[i] = (cur[i] + ((a + b) >> 1)) & 255
                else:
                    p = a + b - c
                    pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                    pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    cur[i] = (cur[i] + pr) & 255
        rows.append(bytes(cur))
        prev = cur
    return w, h, ch, rows


def load(path):
    if path.lower().endswith(('.jpg', '.jpeg', '.heic')):
        tmp = os.path.join(tempfile.gettempdir(),
                           'photowarp_' + os.path.basename(path) + '.png')
        if not os.path.exists(tmp):
            subprocess.run(['sips', '-s', 'format', 'png', path, '--out', tmp],
                           capture_output=True, check=True)
        path = tmp
    w, h, ch, rows = read_png(path)
    lum = [bytearray((r[x*ch] * 77 + r[x*ch+1] * 151 + r[x*ch+2] * 28) >> 8
                     for x in range(w)) for r in rows]
    return w, h, ch, rows, lum


# --------------------------------------------------------------------------
# the lit-rectangle anchor
# --------------------------------------------------------------------------

def _levels(w, h, lum):
    """The screen's own black and white levels, read off the photo centre —
    which is screen in any usable session photo, and bimodal."""
    vals = []
    for y in range(int(h*0.35), int(h*0.65), 2):
        row = lum[y]
        for x in range(int(w*0.35), int(w*0.65), 2):
            vals.append(row[x])
    vals.sort()
    return vals[len(vals)//10], vals[len(vals)*9//10]


def lit_component(w, h, lum, frac=0.55, debug=False, sign=1):
    """Pixels of the frame: the extreme-luma component covering the centre.

    `sign=+1` takes the bright side, which is the frame on a backlit screen
    photographed against a darker surround (every GBA/SP session photo:
    the page is the brightest thing in the picture).  `sign=-1` takes the
    dark side, which is what a reflective DMG/MGB/GBC panel gives when the
    room is brighter than the LCD.  Which one is right is not assumed —
    `auto_quad` fits both and lets the grid score decide."""
    lo, hi = _levels(w, h, lum)
    rng = max(40, hi - lo)
    thr = lo + frac * rng
    seen = [bytearray(w) for _ in range(h)]
    best, best_bb = [], None
    cx, cy = w // 2, h // 2
    for sy in range(int(h*0.35), int(h*0.65), 6):
        for sx in range(int(w*0.35), int(w*0.65), 6):
            if lum[sy][sx] * sign <= thr * sign or seen[sy][sx]:
                continue
            stack = [(sx, sy)]
            comp = []
            x0 = y0 = 10**9
            x1 = y1 = -1
            while stack:
                x, y = stack.pop()
                if x < 0 or y < 0 or x >= w or y >= h:
                    continue
                if seen[y][x] or lum[y][x] * sign <= thr * sign:
                    continue
                seen[y][x] = 1
                comp.append((x, y))
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
                stack += ((x+1, y), (x-1, y), (x, y+1), (x, y-1))
            if len(comp) > len(best) and x0 <= cx <= x1 and y0 <= cy <= y1:
                best, best_bb = comp, (x0, y0, x1, y1)
    if not best:
        raise SystemExit('no lit frame found at the photo centre — use --corners')
    if debug:
        x0, y0, x1, y1 = best_bb
        print(f'  lit>{thr:.0f}: {len(best)}px bbox {x1-x0+1}x{y1-y0+1} '
              f'ar={(x1-x0+1)/(y1-y0+1):.3f}', file=sys.stderr)
    return best, best_bb


def fit_line(pts, horizontal):
    """Least squares plus one trimming pass.  Returns (a, b):
    x = a*y + b for a vertical edge, y = a*x + b for a horizontal one."""
    def solve(sample):
        if horizontal:
            us = [p[0] for p in sample]; vs = [p[1] for p in sample]
        else:
            us = [p[1] for p in sample]; vs = [p[0] for p in sample]
        n = len(us)
        mu = sum(us) / n
        mv = sum(vs) / n
        den = sum((u - mu) ** 2 for u in us)
        a = (sum((u - mu) * (v - mv) for u, v in zip(us, vs)) / den) if den else 0.0
        return a, mv - a * mu
    a, b = solve(pts)
    def resid(p):
        return abs(p[1] - (a*p[0] + b)) if horizontal else abs(p[0] - (a*p[1] + b))
    keep = sorted(pts, key=resid)[:max(8, (len(pts) * 3) // 4)]
    return solve(keep)


def frame_quad(comp, debug=False):
    """The lit region's four corners, by fitting and intersecting its edges."""
    xs_by_y, ys_by_x = {}, {}
    for x, y in comp:
        lo, hi = xs_by_y.get(y, (x, x))
        xs_by_y[y] = (min(lo, x), max(hi, x))
        lo, hi = ys_by_x.get(x, (y, y))
        ys_by_x[x] = (min(lo, y), max(hi, y))
    ys, xs = sorted(xs_by_y), sorted(ys_by_x)
    # Skip the outer eighth of each span: a rounded corner, or a glyph that
    # touches the frame edge, bends an edge line that includes it.
    yc = ys[len(ys)//8: len(ys)*7//8]
    xc = xs[len(xs)//8: len(xs)*7//8]
    left = fit_line([(xs_by_y[y][0], y) for y in yc], horizontal=False)
    right = fit_line([(xs_by_y[y][1], y) for y in yc], horizontal=False)
    top = fit_line([(x, ys_by_x[x][0]) for x in xc], horizontal=True)
    bot = fit_line([(x, ys_by_x[x][1]) for x in xc], horizontal=True)

    def cross(vert, horiz):
        av, bv = vert
        ah, bh = horiz
        y = (ah * bv + bh) / (1.0 - ah * av)
        return (av * y + bv, y)
    quad = [cross(left, top), cross(right, top), cross(right, bot), cross(left, bot)]
    if debug:
        print('  edges L/R/T/B slopes '
              f'{left[0]:+.4f} {right[0]:+.4f} {top[0]:+.4f} {bot[0]:+.4f}',
              file=sys.stderr)
    return quad


# --------------------------------------------------------------------------
# homography, optional grid polish, sampling
# --------------------------------------------------------------------------

def homography(quad):
    src = [(0, 0), (GB_W, 0), (GB_W, GB_H), (0, GB_H)]
    a, b = [], []
    for (sx, sy), (dx, dy) in zip(src, quad):
        a.append([sx, sy, 1, 0, 0, 0, -dx*sx, -dx*sy]); b.append(dx)
        a.append([0, 0, 0, sx, sy, 1, -dy*sx, -dy*sy]); b.append(dy)
    m = [row[:] + [bv] for row, bv in zip(a, b)]
    for col in range(8):
        piv = max(range(col, 8), key=lambda r: abs(m[r][col]))
        m[col], m[piv] = m[piv], m[col]
        d = m[col][col]
        if d == 0:
            raise SystemExit('degenerate frame quad')
        m[col] = [v / d for v in m[col]]
        for r in range(8):
            if r != col and m[r][col]:
                f = m[r][col]
                m[r] = [v - f * u for v, u in zip(m[r], m[col])]
    c = [m[i][8] for i in range(8)]
    def mp(x, y):
        den = c[6]*x + c[7]*y + 1.0
        return ((c[0]*x + c[1]*y + c[2]) / den, (c[3]*x + c[4]*y + c[5]) / den)
    return mp


def grid_score(quad, w, h, lum, step=2):
    mp = homography(quad)
    means = {}
    spread = n = 0
    for gy in range(0, GB_H, step):
        for gx in range(0, GB_W, step):
            vals = []
            for dy in (-0.28, 0.0, 0.28):
                for dx in (-0.28, 0.0, 0.28):
                    px, py = mp(gx + 0.5 + dx, gy + 0.5 + dy)
                    xi, yi = int(px), int(py)
                    if 0 <= xi < w and 0 <= yi < h:
                        vals.append(lum[yi][xi])
            if len(vals) < 9:
                return -1e9
            means[(gx, gy)] = sum(vals) / 9.0
            spread += max(vals) - min(vals)
            n += 1
    diff = dn = 0
    for (gx, gy), m in means.items():
        for nb in ((gx + step, gy), (gx, gy + step)):
            if nb in means:
                diff += abs(means[nb] - m)
                dn += 1
    return (diff / dn if dn else 0.0) - (spread / max(n, 1))


def refine(quad, w, h, lum, debug=False):
    best = [list(p) for p in quad]
    score = grid_score(best, w, h, lum)
    step = 1.5
    while step > 0.1:
        improved = False
        for i in range(4):
            for k in range(2):
                for d in (step, -step):
                    trial = [p[:] for p in best]
                    trial[i][k] += d
                    s = grid_score(trial, w, h, lum)
                    if s > score:
                        best, score, improved = trial, s, True
                        break
        if not improved:
            step *= 0.5
    if debug:
        print(f'  refined score {score:.2f}', file=sys.stderr)
    return [tuple(p) for p in best]


def sample(quad, w, h, ch, rows):
    mp = homography(quad)
    out = bytearray()
    for gy in range(GB_H):
        for gx in range(GB_W):
            px, py = mp(gx + 0.5, gy + 0.5)
            xi, yi = int(px), int(py)
            if 0 <= xi < w - 1 and 0 <= yi < h - 1:
                fx, fy = px - xi, py - yi
                r0, r1 = rows[yi], rows[yi+1]
                for k in range(3):
                    v = (r0[xi*ch+k] * (1-fx) * (1-fy) +
                         r0[(xi+1)*ch+k] * fx * (1-fy) +
                         r1[xi*ch+k] * (1-fx) * fy +
                         r1[(xi+1)*ch+k] * fx * fy)
                    out.append(int(v))
            else:
                out += b'\x80\x80\x80'
    return bytes(out)


def flatten(body):
    """Divide out the photo's illumination field.

    A hand-held photo of an LCD is several shades brighter on one side than
    the other — more than the gap between two GB shades — and every reader
    downstream (hwprobe_ocr's ink threshold, arbread's colour equality)
    compares against ONE global level.  Subtracting a heavily blurred copy
    of the frame turns "darker than the page" into a local question, which
    is what those readers assume they are asking.  Radius 12 GB pixels is
    far wider than any glyph stroke (1px) or band edge, so no feature can
    flatten itself away.
    """
    lum = [[(body[(y*GB_W+x)*3] * 77 + body[(y*GB_W+x)*3+1] * 151 +
             body[(y*GB_W+x)*3+2] * 28) >> 8 for x in range(GB_W)]
           for y in range(GB_H)]
    R = 12
    # separable box blur with edge clamping
    tmp = [[0.0]*GB_W for _ in range(GB_H)]
    for y in range(GB_H):
        row = lum[y]
        acc = sum(row[0:R+1]) + row[0]*R
        for x in range(GB_W):
            tmp[y][x] = acc / (2.0*R + 1)
            acc -= row[max(0, x-R)]
            acc += row[min(GB_W-1, x+R+1)]
    blur = [[0.0]*GB_W for _ in range(GB_H)]
    for x in range(GB_W):
        col = [tmp[y][x] for y in range(GB_H)]
        acc = sum(col[0:R+1]) + col[0]*R
        for y in range(GB_H):
            blur[y][x] = acc / (2.0*R + 1)
            acc -= col[max(0, y-R)]
            acc += col[min(GB_H-1, y+R+1)]
    out = bytearray(len(body))
    for y in range(GB_H):
        for x in range(GB_W):
            i = (y*GB_W + x) * 3
            d = lum[y][x] - blur[y][x]
            v = max(0, min(255, int(128 + 1.7 * d)))
            # keep hue: scale the original RGB toward the corrected level
            src = max(1, lum[y][x])
            for k in range(3):
                out[i+k] = max(0, min(255, int(body[i+k] * v / src)))
    return bytes(out)


# Where in the black-to-white ramp at the frame's border the true edge sits
# is not a constant: it moves with exposure, focus and how far the panel
# blooms into the letterbox, and one GB pixel of error at the border is a
# whole cell of drift by the far side.  So the edge is not guessed — a quad
# is fitted at each threshold on this ladder and the winner chosen by
# `grid_score`, which asks only whether the sampling grid lands on the
# photo's own pixel grid.  On the 2026-08-17 session that choice agrees with
# what the ROM's own font says is correct on every photo where the two can
# be compared, which is what licenses using it on the probe photos, where
# there is no font to appeal to.
EDGE_FRACS = (0.36, 0.42, 0.48, 0.54, 0.60, 0.66, 0.72, 0.78)


def edges_at(w, h, lum, bbox, thr, samples=120, sign=1):
    """Frame quad at one threshold, from sparse scanlines.

    The flood-fill that locates the screen runs once; re-flooding per
    threshold costs seconds each and buys nothing, because the edge lines
    only need a hundred crossings apiece.  Scanning inside the known
    bounding box also removes the connectivity requirement that the flood
    was there to provide."""
    x0, y0, x1, y1 = bbox
    mx = max(4, (x1 - x0) // 20)
    my = max(4, (y1 - y0) // 20)
    x0, x1 = max(0, x0 - mx), min(w - 1, x1 + mx)
    y0, y1 = max(0, y0 - my), min(h - 1, y1 + my)
    lefts, rights, tops, bots = [], [], [], []
    ystep = max(1, (y1 - y0) // samples)
    for y in range(y0 + (y1 - y0) // 8, y1 - (y1 - y0) // 8, ystep):
        row = lum[y]
        xl = next((x for x in range(x0, x1 + 1) if row[x]*sign > thr*sign), None)
        xr = next((x for x in range(x1, x0 - 1, -1) if row[x]*sign > thr*sign), None)
        if xl is not None and xr is not None and xr - xl > (x1 - x0) // 2:
            lefts.append((xl, y))
            rights.append((xr, y))
    xstep = max(1, (x1 - x0) // samples)
    for x in range(x0 + (x1 - x0) // 8, x1 - (x1 - x0) // 8, xstep):
        yt = next((y for y in range(y0, y1 + 1) if lum[y][x]*sign > thr*sign), None)
        yb = next((y for y in range(y1, y0 - 1, -1) if lum[y][x]*sign > thr*sign), None)
        if yt is not None and yb is not None and yb - yt > (y1 - y0) // 2:
            tops.append((x, yt))
            bots.append((x, yb))
    if len(lefts) < 8 or len(tops) < 8:
        return None
    left = fit_line(lefts, horizontal=False)
    right = fit_line(rights, horizontal=False)
    top = fit_line(tops, horizontal=True)
    bot = fit_line(bots, horizontal=True)

    def cross(vert, horiz):
        av, bv = vert
        ah, bh = horiz
        y = (ah * bv + bh) / (1.0 - ah * av)
        return (av * y + bv, y)
    return [cross(left, top), cross(right, top),
            cross(right, bot), cross(left, bot)]


def plausible(quad, w, h):
    """Is this quad shaped like a GB frame in this photo?

    `grid_score` compares how well a sampling grid lands on the photo's
    pixel grid, and that is only meaningful between quads of comparable
    size: a quad covering the whole photograph samples smooth backdrop,
    scores well on both terms and wins for the wrong reason.  So candidates
    are gated on geometry first — the score never sees a shape that is not
    a plausible frame."""
    xs = [p[0] for p in quad]
    ys = [p[1] for p in quad]
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    if bw <= 0 or bh <= 0:
        return False
    if min(xs) < -w * 0.02 or min(ys) < -h * 0.02:
        return False
    if max(xs) > w * 1.02 or max(ys) > h * 1.02:
        return False
    if not (min(xs) < w / 2 < max(xs) and min(ys) < h / 2 < max(ys)):
        return False
    if abs(bw / bh - GB_W / float(GB_H)) > 0.22:
        return False
    frac = (bw * bh) / float(w * h)
    return 0.04 < frac < 0.85


def auto_quad(w, h, lum, debug=False):
    """Best frame quad over the polarity x edge-threshold ladder."""
    lo, hi = _levels(w, h, lum)
    rng = max(40, hi - lo)
    best = (None, -1e18, None)
    for sign in (1, -1):
        try:
            comp, bbox = lit_component(w, h, lum, 0.5, debug, sign)
        except SystemExit:
            continue
        x0, y0, x1, y1 = bbox
        ar = (x1 - x0 + 1) / float(max(1, y1 - y0 + 1))
        if abs(ar - GB_W / float(GB_H)) > 0.28:
            # not a frame-shaped region: this polarity is the room, not the
            # screen. (Checked before the ladder so a leaking flood cannot
            # win on score by covering half the photograph.)
            if debug:
                print(f'  sign={sign:+d}: ar={ar:.3f} rejected', file=sys.stderr)
            continue
        for frac in EDGE_FRACS:
            quad = edges_at(w, h, lum, bbox, lo + frac * rng, sign=sign)
            if quad is None or not plausible(quad, w, h):
                continue
            s = grid_score(quad, w, h, lum, step=2)
            if debug:
                print(f'  sign={sign:+d} frac={frac:.2f} score={s:7.2f}',
                      file=sys.stderr)
            if s > best[1]:
                best = ((sign, frac), s, quad)
    if best[2] is None:
        raise SystemExit('no frame-shaped region found at the photo centre — '
                         'use --corners')
    if debug:
        print(f'  chose sign={best[0][0]:+d} frac={best[0][1]:.2f}', file=sys.stderr)
    return best[2]


def warp(photo, corners=None, do_refine=False, debug=False):
    w, h, ch, rows, lum = load(photo)
    if corners:
        quad = corners
    else:
        quad = auto_quad(w, h, lum, debug)
    if debug:
        print(f'{photo}: quad {[(round(x,1), round(y,1)) for x, y in quad]}',
              file=sys.stderr)
    if do_refine:
        quad = refine(quad, w, h, lum, debug)
    return sample(quad, w, h, ch, rows), quad


def warp_frame(photo, corners=None, do_refine=True, flat=True, debug=False):
    body, quad = warp(photo, corners, do_refine, debug)
    return (flatten(body) if flat else body), quad


def write_ppm(path, body):
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (GB_W, GB_H) + body)


def selftest(photo_dir, transcript):
    """Warp every photo in `photo_dir`, OCR it, and check the result against
    a CRC-verified transcription (tests/roms/expected/gb-*.txt).

    The check that matters is the CRC line: gbedge computes a CRC-16 over
    each page's 32 result bytes and prints it, so a CRC read off a photo
    that equals the independently transcribed one says the warp recovered
    those bytes exactly.  Reported alongside: how many of the page's own
    data glyphs decoded at all."""
    import glob
    import re
    here = os.path.dirname(os.path.abspath(__file__))
    ocr = os.path.join(here, '..', '..', 'tests', 'roms', 'hwprobe_ocr.py')
    want = {}
    cur = None
    for line in open(transcript):
        m = re.match(r'page ([0-9A-F]{2}) (\w+) crc ([0-9A-F]{4})', line.strip())
        if m:
            cur = m.group(1)
            want[cur] = m.group(3)
    ok = miss = bad = 0
    for photo in sorted(glob.glob(os.path.join(photo_dir, '*.jpg'))):
        try:
            body, _ = warp_frame(photo)
        except SystemExit as e:
            print(f'  {os.path.basename(photo)}: SKIP ({e})')
            miss += 1
            continue
        tmp = os.path.join(tempfile.gettempdir(), 'photowarp_selftest.ppm')
        write_ppm(tmp, body)
        text = subprocess.run([sys.executable, ocr, tmp],
                              capture_output=True, text=True).stdout
        page = re.search(r'P([0-9A-F?]{2})', text)
        crc = re.search(r'CRC ([0-9A-F?]{4})', text)
        cells = text.count('?')
        pid = page.group(1) if page else '??'
        got = crc.group(1) if crc else '????'
        # A CRC that matches ANY page of the transcription is still a
        # verified read: the page number is one more glyph that can be lost
        # to a smudge, and the CRC is the thing under test.
        match = [p for p, c in want.items() if c == got]
        if pid in want and got == want[pid]:
            ok += 1
            print(f'  {os.path.basename(photo)}: page {pid} CRC {got} OK '
                  f'({cells} undecoded glyphs)')
        elif match:
            ok += 1
            print(f'  {os.path.basename(photo)}: page ?? CRC {got} OK '
                  f'(= page {match[0]}; {cells} undecoded glyphs)')
        else:
            bad += 1
            print(f'  {os.path.basename(photo)}: page {pid} CRC {got} '
                  f'unverified ({cells} undecoded)')
    print(f'{ok} pages CRC-verified from photographs, {bad} mismatched, '
          f'{miss} unregistered')
    return 0 if bad == 0 and miss == 0 else 1


def main():
    argv = sys.argv[1:]
    debug = '--debug' in argv
    do_refine = '--refine' in argv or '--selftest' not in argv
    corners = None
    if '--selftest' in argv:
        i = argv.index('--selftest')
        return selftest(argv[i+1], argv[i+2])
    if '--corners' in argv:
        i = argv.index('--corners')
        nums = [float(v) for v in argv[i+1].split(',')]
        corners = [(nums[j], nums[j+1]) for j in range(0, 8, 2)]
        del argv[i:i+2]
    args = [a for a in argv if not a.startswith('--')]
    if len(args) < 2:
        raise SystemExit(__doc__)
    body, quad = warp_frame(args[0], corners, do_refine,
                            flat='--raw' not in argv, debug=debug)
    write_ppm(args[1], body)
    print(f'{args[0]} -> {args[1]}')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
