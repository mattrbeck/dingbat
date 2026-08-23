#!/usr/bin/env python3
"""read_probe_e — measure probe (e) against a ruler inside its own frame.

    read_probe_e.py <photo.jpg|frame.ppm> [--debug]

read_probe_d_photo.py gives each bar's absolute column in the warped frame,
and a registration error translates every column uniformly, which is
indistinguishable from a phase difference. probe (e) prints its parameter
header at a fixed position (glyphs start at GB x = 0), so

    bar column  -  header's left edge

cancels any translation the warp introduced. Prints, per band, the raw and
header-relative columns plus the header's own left edge.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import photowarp as P

W, H = 160, 144


def frame_luma(path):
    if path.endswith('.ppm'):
        body = open(path, 'rb').read().split(b'\n', 3)[3]
    else:
        body, _ = P.warp(path, do_refine=True)
    return [[(body[(y*W+x)*3]*77 + body[(y*W+x)*3+1]*151 + body[(y*W+x)*3+2]*28) >> 8
             for x in range(W)] for y in range(H)]


def read(path, debug=False):
    lum = frame_luma(path)
    flat = sorted(v for r in lum for v in r)
    bg, darkest = flat[len(flat)*3//4], flat[len(flat)//100]
    thr = bg - (bg - darkest) * 0.35

    # The header: dark pixels in the top two tile rows. Its leftmost column is
    # the ruler's zero -- the ROM always starts the first glyph at x = 0.
    head_x = [x for y in range(0, 16) for x in range(W) if lum[y][x] < thr]
    if not head_x:
        raise SystemExit('no header found: is this a probe (e) frame?')
    head_left = min(head_x)

    # Bands: anchor a 9-row grid on the topmost bar below the header.
    y0 = next((y for y in range(16, H)
               if sum(1 for x in range(W) if lum[y][x] < thr) >= 3), None)
    if y0 is None:
        raise SystemExit('no bars found below the header')
    rows = []
    for k in range(16):
        top = y0 + 9*k
        if top + 6 > H:
            break
        xs, vals = [], []
        for y in range(top + 1, min(top + 7, H)):
            for x in range(W):
                if lum[y][x] < thr:
                    xs.append(x); vals.append(lum[y][x])
        if not xs:
            break
        vals.sort()
        rows.append((min(xs), vals[len(vals)//2]))
    return head_left, y0, rows, bg, darkest


def main():
    debug = '--debug' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    for path in args:
        head_left, y0, rows, bg, dark = read(path, debug)
        blackest = min(m for _, m in rows) if rows else 0
        step = (bg - blackest) / 3.0 if rows else 1
        seq = ''
        rel = []
        for x, med in rows:
            k = round((med - blackest) / step) if step else 0
            seq += {0: '#', 1: '2', 2: '1', 3: '.'}.get(max(0, min(3, k)), '?')
            rel.append(x - head_left)
        print(f'{os.path.basename(path)}')
        print(f'  header left x={head_left}   first bar y={y0}   bands={len(rows)}')
        print(f'  raw cols : {" ".join(str(x) for x, _ in rows)}')
        print(f'  rel cols : {" ".join(str(r) for r in rel)}')
        print(f'  sequence : {seq}')


if __name__ == '__main__':
    main()
