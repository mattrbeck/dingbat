#!/usr/bin/env python3
"""Standout Supporter icon concepts (not in the app yet): the crowned bat over
backgrounds that fill the tile and sit lighter than the bat, on a 64-cell grid at 4x.
Usage: standout_concepts.py REPO OUTDIR"""
import math
import os
import random
import sys

REPO, OUT = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(REPO, 'tools', 'logo_flap'))
import bat  # noqa: E402
import crown  # noqa: E402
import imgio  # noqa: E402

os.makedirs(OUT, exist_ok=True)
N, K = 64, 4
SPRITE = crown.still()
PAL = crown.palette(bat.PURPLE)


def grid(c):
    return [[c] * N for _ in range(N)]


def rect(g, x0, y0, x1, y1, c):
    for y in range(max(0, y0), min(N, y1)):
        for x in range(max(0, x0), min(N, x1)):
            g[y][x] = c


def put_bat(g, y0):
    x0 = (N - len(SPRITE[0])) // 2
    for y, r in enumerate(SPRITE):
        for x, c in enumerate(r):
            if c != '.' and 0 <= y0 + y < N:
                g[y0 + y][x0 + x] = c


def save(name, g, pal):
    imgio.png(os.path.join(OUT, name + '.png'), bat.scale([''.join(r) for r in g], K), pal)


def bricks(g, x0, y0, x1, y1, face='a', mortar='b', lit='c', h=5, w=9, shift=0):
    for y in range(y0, y1):
        for x in range(x0, x1):
            row = (y - y0) // h
            off = (w // 2) if row % 2 else 0
            if (y - y0) % h == 0:
                g[y][x] = mortar
            elif (x - x0 + off + shift) % w == 0:
                g[y][x] = mortar
            elif (y - y0) % h == 1:
                g[y][x] = lit
            else:
                g[y][x] = face


# ---- 1: the castle, wall to wall: a gatehouse of pale stone under a dusk sky
g = grid('s')
bricks(g, 0, 8, N, N)                                  # the curtain wall fills the tile
for x0, x1 in ((0, 13), (51, N)):                      # two towers, darker, standing proud
    bricks(g, x0, 4, x1, N, face='d', mortar='e', lit='a', w=7)
    for x in range(x0, x1, 3):                         # their merlons against the sky
        rect(g, x, 1, x + 2, 4, 'd')
for x in range(13, 51, 4):                             # the wall's merlons
    rect(g, x, 5, x + 2, 8, 'a')
for wx in (18, 44):                                    # arrow slits, lit
    rect(g, wx, 40, wx + 2, 46, 'y')
rect(g, 24, 46, 40, N, 'q')                            # the gate, its arch, the portcullis
for i, w in enumerate((10, 14, 16)):
    rect(g, 32 - w // 2, 43 + i, 32 + w // 2, 44 + i, 'q')
for x in range(26, 40, 3):
    rect(g, x, 47, x + 1, N, 'r')
for y in range(49, N, 4):
    rect(g, 24, y, 40, y + 1, 'r')
for wx in (5, 56):                                     # lit tower windows
    rect(g, wx, 20, wx + 3, 25, 'y')
put_bat(g, 13)
save('bg-castle', g, dict(PAL, s='#cdbff0', a='#c3c5cf', b='#9a9caa', c='#d6d8e0', d='#a9acb8', e='#868896',
                          p='#5b2e9a', y='#f2c14e', q='#3a3446', r='#6b6578'))

# ---- 2: gold sunburst, art deco
g = grid('g')
cx, cy = 31.5, 26
for y in range(N):
    for x in range(N):
        a = math.atan2(y - cy, x - cx)
        g[y][x] = 'g' if int((a + math.pi) / (2 * math.pi) * 24) % 2 else 'h'
rect(g, 0, 0, N, 2, 'i'); rect(g, 0, N - 2, N, N, 'i'); rect(g, 0, 0, 2, N, 'i'); rect(g, N - 2, 0, N, N, 'i')
put_bat(g, 14)
save('bg-sunburst', g, dict(PAL, g='#f7e2a8', h='#efcf7a', i='#c99a2e'))

# ---- 3: marble with a gold inlay
g = grid('m')
rnd = random.Random(11)
for _ in range(9):                                     # veins: wandering lines
    x, y = rnd.uniform(0, N), rnd.uniform(0, N)
    dx, dy = rnd.uniform(-1, 1), rnd.uniform(0.3, 1)
    for _ in range(90):
        if 0 <= int(x) < N and 0 <= int(y) < N:
            g[int(y)][int(x)] = 'v' if rnd.random() < 0.7 else 'w'
        x += dx + rnd.uniform(-0.7, 0.7)
        y += dy + rnd.uniform(-0.3, 0.3)
for i in (3, 4):                                       # the inlay, a gold frame inside the edge
    for t in range(i, N - i):
        g[i][t] = g[N - 1 - i][t] = g[t][i] = g[t][N - 1 - i] = 'y'
put_bat(g, 14)
save('bg-marble', g, dict(PAL, m='#efebe5', v='#cdc6bd', w='#b7afa6', y='#d9a93c'))

# ---- 4: stained glass, light panes in lead
rnd = random.Random(5)
seeds = [(rnd.uniform(0, N), rnd.uniform(0, N), rnd.choice('nptux')) for _ in range(22)]
cell = [[min(range(len(seeds)), key=lambda i: (x - seeds[i][0]) ** 2 + (y - seeds[i][1]) ** 2) for x in range(N)] for y in range(N)]
g = [[seeds[cell[y][x]][2] for x in range(N)] for y in range(N)]
for y in range(N):
    for x in range(N):
        if (x + 1 < N and cell[y][x + 1] != cell[y][x]) or (y + 1 < N and cell[y + 1][x] != cell[y][x]):
            g[y][x] = 'L'
put_bat(g, 14)
save('bg-glass', g, dict(PAL, n='#f6c6d6', p='#f9e2a2', t='#bfe6dc', u='#d9cdf4', x='#c8dcf6', L='#5a5470'))

# ---- 5: damask wallpaper
MOTIF = '''
.......xx.......
......x..x......
.....x.xx.x.....
....x.x..x.x....
...x.x....x.x...
..x..x.xx.x..x..
.x...x.xx.x...x.
x.....x..x.....x
.x...x.xx.x...x.
..x..x.xx.x..x..
...x.x....x.x...
....x.x..x.x....
.....x.xx.x.....
......x..x......
.......xx.......
................
'''.strip('\n').split('\n')
g = grid('l')
for y in range(N):
    for x in range(N):
        if MOTIF[y % 16][(x + (8 if (y // 16) % 2 else 0)) % 16] == 'x':
            g[y][x] = 'k'
rect(g, 0, 0, N, 2, 'y'); rect(g, 0, N - 2, N, N, 'y')
put_bat(g, 14)
save('bg-damask', g, dict(PAL, l='#ece6f4', k='#d7cbe9', y='#d9a93c'))
print(sorted(f for f in os.listdir(OUT) if f.startswith('bg-')))
