#!/usr/bin/env python3
"""Supporter alternate app icons (a design proposal, not in the app yet): the logo recoloured
(classic) and holidays.py's bats, each a flat N x N tile, full bleed (iOS rounds the corners).

Usage: alt_icons.py OUTDIR [N]    writes OUTDIR/<name>.png, holiday ones as h-<name>.png
"""
import os
import sys

OUT = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 256
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bat  # noqa: E402
import holidays  # noqa: E402
import imgio  # noqa: E402

os.makedirs(OUT, exist_ok=True)
MOON = bat.MOON


def crop(rows):
    ys = [y for y, r in enumerate(rows) if r.strip('.')]
    xs = [x for r in rows for x, c in enumerate(r) if c != '.']
    x0, x1 = min(xs), max(xs)
    return [r[x0:x1 + 1] for r in rows[ys[0]:ys[-1] + 1]]


def place(sprite, n, fill=0.80, dy=0):
    s = crop(sprite)
    k = max(1, int(n * fill) // len(s[0]))
    big = bat.scale(s, k)
    h, w = len(big), len(big[0])
    ox, oy = (n - w) // 2, (n - h) // 2 + dy
    rows = [['.'] * n for _ in range(n)]
    for y, r in enumerate(big):
        for x, c in enumerate(r):
            if c != '.' and 0 <= oy + y < n:
                rows[oy + y][ox + x] = c
    return [''.join(r) for r in rows], k


def disc(n, k, r_frac=0.36, cx=0.5, cy=0.5, craters=True):
    """A moon (or sun) on the bat's pixel grid: 'm' inside, 'c'/'s' craters, 'g' outside."""
    rows = []
    R = r_frac * n
    for y in range(n):
        line = []
        py = (y // k) * k + k / 2 - n * cy
        for x in range(n):
            px = (x // k) * k + k / 2 - n * cx
            if px * px + py * py <= R * R:
                ch = 'm'
                if craters:
                    f = n / 1024
                    for dx, dy, r in bat.MOON_CRATERS:
                        dx, dy, r = dx * f, dy * f, r * f
                        if (px - dx) ** 2 + (py - dy) ** 2 <= r * r:
                            lit = (px - dx - r * .22) ** 2 + (py - dy - r * .22) ** 2 <= (r * .82) ** 2
                            ch = 'c' if lit else 's'
                            break
                line.append(ch)
            else:
                line.append('g')
        rows.append(''.join(line))
    return rows


def stars(n, k, seed):
    import random
    rnd = random.Random(seed)
    pts = set()
    for _ in range(14):
        pts.add((rnd.randrange(0, n // k) * k, rnd.randrange(0, n // k) * k))
    rows = [['g'] * n for _ in range(n)]
    for (x, y) in pts:
        for yy in range(y, min(n, y + k)):
            for xx in range(x, min(n, x + k)):
                rows[yy][xx] = 'z'
    return [''.join(r) for r in rows]


def write(name, top, ground, pal):
    imgio.png(os.path.join(OUT, name + '.png'), bat.over(top, ground), pal)


still = bat.still()
P = bat.PURPLE

# ---- classic
classic = {
    # name: (bat palette, ground, moon colours or None, extra)
    'night-flyer': (P, bat.NIGHT_BG, (MOON, bat.CRATER, bat.CRATER_SHADOW)),
    'moonlit': (P, MOON, None),
    'dusk': (bat.DUSK, '#2a2140', ('#ffb36b', '#f39a52', '#e08540')),
    'midnight': (P, bat.NIGHT_BG, 'stars'),
    'paper': (P, '#f1eee8', None),
    'pea-soup': (dict(K='#0f380f', B='#306230', W='#306230', w='#0f380f', H='#8bac0f', E='#9bbc0f', C='#8bac0f', F='#9bbc0f'),
                 '#9bbc0f', None),
    'ember': (dict(K='#1a1206', B='#ffb04d', W='#c27a1e', w='#8f5312', H='#ffd08a', E='#1a1206', C='#ff8f6b', F='#fff0d6'),
              '#0c0e16', ('#3a2a14', '#2e2210', '#241a0c')),
    'glacier': (dict(K='#0b0e16', B='#769be5', W='#3c4a6b', w='#2c3852', H='#cdd9f0', E='#ffffff', C='#ff9fb8', F='#ffffff'),
                '#ccd9f0', None),
    'ink': (dict(K='#101010', B='#3a3a3a', W='#1e1e1e', w='#161616', H='#8a8a8a', E='#ffffff', C='#bdbdbd', F='#ffffff'),
            '#f4f4f2', None),
    'sunrise': (P, '#ff9e6b', ('#ffd36b', '#ffc24f', '#f2ae3a')),
}

for name, (pal, ground, moon) in classic.items():
    top, k = place(still, N, 0.80)
    if moon == 'stars':
        g = stars(N, k, 7)
        full = dict(pal, g=ground, z='#a98ae6')
    elif moon:
        g = disc(N, k)
        full = dict(pal, g=ground, m=moon[0], c=moon[1], s=moon[2])
    else:
        g = ['g' * N] * N
        full = dict(pal, g=ground)
    write(name, top, g, full)

# ---- seasonal (holidays.py's bats, frame 0, props included)
seasonal_moon = {
    'witch': (MOON, bat.CRATER, bat.CRATER_SHADOW),
    'vampire': ('#d9c2b0', '#c4a894', '#a98d79'),
}
sprinkle = {  # name: [(colour, seed)] flecks on the ground
    'santa': [('#ffffff', 3)],
    'snowy': [('#ffffff', 5), ('#a9cbe8', 9)],
    'party': [('#ff5c8a', 11), ('#ffd23f', 12), ('#3aa59b', 13)],
    'valentine': [('#ffb3cf', 21)],
    'lunar': [('#f2c14e', 31)],
}
for name, (_, ground, pal, _) in holidays.HOLIDAYS.items():
    fr = holidays.frames(name)[0]
    top, k = place(fr, N, 0.86, dy=N // 40)
    if name in seasonal_moon:
        m = seasonal_moon[name]
        g = disc(N, k, 0.34, cy=0.47)
        full = dict(pal, g=ground, m=m[0], c=m[1], s=m[2])
    else:
        g = ['g' * N] * N
        full = dict(pal, g=ground)
        for i, (colour, seed) in enumerate(sprinkle.get(name, [])):
            ch = '0123'[i]
            layer = stars(N, k, seed)
            g = [''.join(ch if l == 'z' else c for c, l in zip(gr, lr)) for gr, lr in zip(g, layer)]
            full[ch] = colour
    write('h-' + name, top, g, full)

print(sorted(os.listdir(OUT)))
