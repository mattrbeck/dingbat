#!/usr/bin/env python3
"""read_probe_e_rows -- band columns from a NOISY warped probe (e) frame.

    read_probe_e_rows.py <warped.ppm> [first_band_y]

A fallback for read_probe_e.py, not a replacement: use that one first.

read_probe_e's global threshold collapses on the SCX-4 photo: the SP's LCD
moire puts a lot of mid-grey into the background, so "dark" either swallows the
whole frame or nothing. This reads each band's own row instead -- smooth the
row, then take the first column that is far below THAT ROW's own median -- which
is immune to a global level shift and to the moire's high-frequency component.
"""
import sys

W, H = 160, 144


def read_ppm(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        parts.append(d[i:j]); i = j
    px = d[i + 1:]
    return [[(px[(y * W + x) * 3] * 77 + px[(y * W + x) * 3 + 1] * 151
              + px[(y * W + x) * 3 + 2] * 28) >> 8 for x in range(W)]
            for y in range(H)]


lum = read_ppm(sys.argv[1])
first_y = int(sys.argv[2]) if len(sys.argv) > 2 else 16
cols = []
for b in range(14):
    y0 = first_y + b * 9
    if y0 + 6 > H:
        break
    # average the band's middle rows: the bar is 8 rows tall, the noise is not
    row = [sum(lum[y][x] for y in range(y0 + 2, y0 + 7)) / 5 for x in range(W)]
    sm = [sum(row[max(0, x - 1):x + 2]) / len(row[max(0, x - 1):x + 2])
          for x in range(W)]
    med = sorted(sm)[W // 2]
    lo = min(sm)
    thr = med - (med - lo) * 0.55
    hit = [x for x in range(W) if sm[x] < thr]
    cols.append(hit[0] if hit else -1)
print("bands:", " ".join(str(c) for c in cols))
