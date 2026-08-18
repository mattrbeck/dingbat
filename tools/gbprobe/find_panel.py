#!/usr/bin/env python3
"""find_panel — locate probe (e)'s lit 160x144 area in a photo, as corners.

    find_panel.py <photo.jpg> [--debug]

photowarp's own detector looks for a lit frame against a dark surround and
gives up on these GBA SP shots ("no lit frame found at the photo centre"),
which is the NCC-refinement gap the 2026-08-17 session already hit. It does
not have to be solved to read THIS probe: probe (e) fills its background with
tile $01, so the 160x144 area is a single bright near-white rectangle on a
black letterbox, and a luma threshold plus a row/column profile finds its
edges directly.

Prints the four corners in photowarp's `--corners` order (TL, TR, BR, BL) so
the reader can be driven with an explicit quad:

    photowarp.py <photo> out.ppm --corners $(find_panel.py <photo>)
    read_probe_e.py out.ppm
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import photowarp as P


def main():
    photo = sys.argv[1]
    w, h, ch, rows, lumrows = P.load(photo)

    def lum(x, y):
        return lumrows[y][x]

    # A global bright-pixel bounding box does NOT work on these shots: the desk
    # and the laptop lid are bright enough to be in range, so the box spans the
    # whole photo. The panel has to be found as the largest CONNECTED bright
    # region instead.
    step = max(1, min(w, h) // 300)
    gw, gh = w // step, h // step
    vals = sorted(lum(x * step, y * step) for y in range(gh) for x in range(gw))

    # One threshold does not fit both shots: a dimmer photo lets bezel glare
    # into the component and a brighter one can split the panel. Sweep the
    # percentile and keep whichever candidate is closest to the panel's TRUE
    # aspect -- 160/144 is a strong prior and the wrong blobs miss it badly.
    best_quad, best_err, best_thr = None, 1e9, None
    for pct in (0.80, 0.83, 0.86, 0.88, 0.90, 0.92, 0.94):
        thr = vals[int(len(vals) * pct)]
        q = component_quad(lum, gw, gh, step, thr)
        if q is None:
            continue
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = q
        bw = max(x1, x2) - min(x0, x3)
        bh = max(y2, y3) - min(y0, y1)
        if bw < w * 0.1 or bh < h * 0.1:
            continue
        err = abs(bw / max(1, bh) - 160 / 144)
        if err < best_err:
            best_quad, best_err, best_thr = q, err, thr
    if best_quad is None:
        raise SystemExit('no panel-shaped bright region found')
    if '--debug' in sys.argv:
        print('thr=%d aspect err %.4f' % (best_thr, best_err), file=sys.stderr)
        print('quad TL%s TR%s BR%s BL%s' % tuple(best_quad), file=sys.stderr)
    print(','.join('%d,%d' % p for p in best_quad))
    return


def component_quad(lum, gw, gh, step, thr):
    bright = [[lum(x * step, y * step) > thr for x in range(gw)] for y in range(gh)]

    # Union-find over 4-connected bright cells; the panel is one solid slab and
    # comes out as much the largest component.
    parent = list(range(gw * gh))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for y in range(gh):
        for x in range(gw):
            if not bright[y][x]:
                continue
            i = y * gw + x
            if x and bright[y][x - 1]:
                union(i, i - 1)
            if y and bright[y - 1][x]:
                union(i, i - gw)

    from collections import defaultdict
    comp = defaultdict(list)
    for y in range(gh):
        for x in range(gw):
            if bright[y][x]:
                comp[find(y * gw + x)].append((x, y))
    if not comp:
        return None
    best = max(comp.values(), key=len)

    # The panel is photographed at a slight angle, so its outline is a
    # trapezoid and an axis-aligned bounding box is the WRONG quad -- feeding
    # one to photowarp shears the frame and the reader comes back with a row of
    # zero columns. Take the extreme points along the two diagonals instead,
    # which gives the corners of a rotated/perspective quad directly.
    tl = min(best, key=lambda p: p[0] + p[1])
    br = max(best, key=lambda p: p[0] + p[1])
    tr = max(best, key=lambda p: p[0] - p[1])
    bl = min(best, key=lambda p: p[0] - p[1])
    return [(p[0] * step, p[1] * step) for p in (tl, tr, br, bl)]
    if '--debug' in sys.argv:
        print('thr=%d panel x=%d..%d y=%d..%d (%dx%d)'
              % (thr, x0, x1, y0, y1, x1 - x0, y1 - y0), file=sys.stderr)
        print('aspect %.3f (160/144 = %.3f)'
              % ((x1 - x0) / (y1 - y0), 160 / 144), file=sys.stderr)
    print('%d,%d,%d,%d,%d,%d,%d,%d' % (x0, y0, x1, y0, x1, y1, x0, y1))


main()
