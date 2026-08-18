"""Read probe_d_tdsel's sixteen bands out of a 160x144 PPM (emulator frame or
a photowarp'd photograph) and print, per band, the bar's shade and column."""
import sys

SHADES = {255: '.', 170: '1', 85: '2', 0: '#'}
NAMES = {'.': 'none', '1': 'LOW plane', '2': 'HIGH plane', '#': 'both planes'}


def load(path):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def nearest(v):
    return min(SHADES, key=lambda k: abs(k - v))


w, h, px = load(sys.argv[1])
compact = '--compact' in sys.argv
if compact:
    out = []
    for band in range(16):
        votes = {}
        for dy in range(2, 8):
            y = band * 9 + dy
            if y >= h:
                continue
            row = [SHADES[nearest(px[(y*w+x)*3])] for x in range(w)]
            bg = max(set(row), key=row.count)
            run = [x for x, c in enumerate(row) if c != bg]
            if run:
                votes[row[run[0]]] = votes.get(row[run[0]], 0) + 1
        out.append(max(votes, key=votes.get) if votes else '.')
    print(''.join(out))
    raise SystemExit(0)
print('band  lines      bar shade      columns          meaning')
for band in range(16):
    votes = {}
    for dy in range(2, 8):                       # skip each band's edges
        y = band * 9 + dy
        if y >= h:
            continue
        row = [SHADES[nearest(px[(y*w+x)*3])] for x in range(w)]
        bg = max(set(row), key=row.count)
        run = [x for x, c in enumerate(row) if c != bg]
        if run:
            key = (row[run[0]], run[0], run[-1])
            votes[key] = votes.get(key, 0) + 1
    if not votes:
        print(f'{band:4d}  {band*9:3d}-{band*9+8:3d}   (uniform)')
        continue
    (sh, x0, x1), n = max(votes.items(), key=lambda kv: kv[1])
    print(f'{band:4d}  {band*9:3d}-{band*9+8:3d}   {sh} ({n}/6 lines)   '
          f'x={x0}..{x1}      {NAMES.get(sh, "?")}')
