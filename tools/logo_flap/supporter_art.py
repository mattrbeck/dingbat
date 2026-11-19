#!/usr/bin/env python3
"""Supporter sheet art: the bat through the app's real hq4x / xBR shader math
(PresentShader.swift `upscale`, ported line for line), and the crowned bat.
Usage: supporter_art.py REPO OUTDIR   (FilterPreview-* assets come from the filter-*.png)"""
import math
import os
import struct
import sys
import zlib

REPO, OUT = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(REPO, 'tools', 'logo_flap'))
import bat  # noqa: E402
import holidays  # noqa: E402
import imgio  # noqa: E402

os.makedirs(OUT, exist_ok=True)


def png_rgb(path, w, h, px):
    raw = b''.join(b'\x00' + bytes(sum((list(px[y * w + x]) for x in range(w)), [])) for y in range(h))

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def hexrgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ---- the sprite as the game would hand it to the shader: 5-bit channels
GROUND = '#e6defc'
sprite = bat.still()
PADX, PADY = 3, 3
TW, TH = len(sprite[0]) + 2 * PADX, len(sprite) + 2 * PADY
tex = []
for y in range(TH):
    row = []
    for x in range(TW):
        sx, sy = x - PADX, y - PADY
        c = sprite[sy][sx] if 0 <= sy < len(sprite) and 0 <= sx < len(sprite[0]) else '.'
        r, g, b = hexrgb(GROUND if c == '.' else bat.PURPLE[c])
        row.append(tuple(round(v * 31 / 255) / 31 for v in (r, g, b)))
    tex.append(row)


def fetch(x, y):
    return tex[min(max(y, 0), TH - 1)][min(max(x, 0), TW - 1)]


def yuv(c):
    r, g, b = c
    return (0.299 * r + 0.587 * g + 0.114 * b, -0.169 * r - 0.331 * g + 0.5 * b, 0.5 * r - 0.419 * g - 0.081 * b)


def df(a, b):
    ya, yb = yuv(a), yuv(b)
    return abs(ya[0] - yb[0]) * 48 + abs(ya[1] - yb[1]) * 7 + abs(ya[2] - yb[2]) * 6


def similar(a, b):
    ya, yb = yuv(a), yuv(b)
    return abs(ya[0] - yb[0]) <= 48 / 255 and abs(ya[1] - yb[1]) <= 7 / 255 and abs(ya[2] - yb[2]) <= 6 / 255


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)


def upscale(filt, u, v):
    px, py = u * TW, v * TH
    bx, by = math.floor(px), math.floor(py)
    E = fetch(bx, by)
    if filt == 0:
        return E
    fx, fy = px - bx, py - by
    sx = -1 if fx < 0.5 else 1
    sy = -1 if fy < 0.5 else 1
    lx = fx if sx > 0 else 1 - fx
    ly = fy if sy > 0 else 1 - fy
    w = smoothstep(0.15, 0.85, lx + ly - 1)
    Ph, Pv, X = fetch(bx + sx, by), fetch(bx, by + sy), fetch(bx + sx, by + sy)
    if filt == 1:
        if not similar(E, Ph) and not similar(E, Pv) and similar(Ph, Pv):
            return mix(E, tuple(0.5 * (Ph[i] + Pv[i]) for i in range(3)), w)
        return E
    C, G = fetch(bx + sx, by - sy), fetch(bx - sx, by + sy)
    F4, H5 = fetch(bx + 2 * sx, by), fetch(bx, by + 2 * sy)
    D, I5 = fetch(bx - sx, by), fetch(bx + sx, by + 2 * sy)
    I4, B = fetch(bx + 2 * sx, by + sy), fetch(bx, by - sy)
    red = df(E, C) + df(E, G) + df(X, F4) + df(X, H5) + 4 * df(Pv, Ph)
    blue = df(Pv, D) + df(Pv, I5) + df(Ph, I4) + df(Ph, B) + 4 * df(E, X)
    if red < blue:
        return mix(E, Ph if df(E, Ph) <= df(E, Pv) else Pv, w)
    return E


def render(filt, k, name):
    W, H = TW * k, TH * k
    px = []
    for y in range(H):
        for x in range(W):
            c = upscale(filt, (x + 0.5) / W, (y + 0.5) / H)
            px.append(tuple(round(min(max(v, 0), 1) * 255) for v in c))
    png_rgb(os.path.join(OUT, name), W, H, px)


for filt, name in ((0, 'filter-sharp.png'), (1, 'filter-hq4x.png'), (2, 'filter-xbr.png')):
    render(filt, 8, name)

# ---- the crowned bat
CROWN = holidays.lines('''
.K...K...K.
KYK.KYK.KYK
KYYKYYYKYYK
KYYYYYYYYYK
KYJYYRYYJYK
KKKKKKKKKKK
''')
CROWN_PAL = dict(bat.PURPLE, Y='#f2c14e', R='#ff5c8a', J='#a98ae6')


def crowned(fr):
    tops = min(y for y, r in enumerate(fr) if r[20:32].strip('.'))
    f = ['.' * len(fr[0])] * holidays.PAD + fr
    return holidays.stamp(f, CROWN, 21, holidays.PAD + tops - 5, 'over')


def crop(rows):
    ys = [y for y, r in enumerate(rows) if r.strip('.')]
    xs = [x for r in rows for x, c in enumerate(r) if c != '.']
    return [r[min(xs):max(xs) + 1] for r in rows[ys[0]:ys[-1] + 1]]


CROWN2 = holidays.lines('''
K...KK...K
YK.KYYK.KY
YYKYYYYKYY
YYYYYYYYYY
YRYYJJYYRY
OOOOOOOOOO
''')
CROWN_PAL['O'] = '#b8862e'


def crowned_still():
    s = ['.' * 42] * 4 + bat.still()
    return holidays.stamp(s, CROWN2, 16, 4 + 4 - 6 + 1, 'over')


still = crop(crowned_still())
# transparent crowned bat at 8x (sheet hero, link screen)
imgio.png(os.path.join(OUT, 'crown-bat.png'), bat.scale(still, 8), CROWN_PAL)
# the flap, crowned, as a GIF on Night
frames = [[r.replace('.', 'g') for r in bat.scale(crop(crowned(f)) if False else crowned(f), 6)] for f in bat.flap_frames(16)]
imgio.gif(os.path.join(OUT, 'crown-flap.gif'), frames, dict(CROWN_PAL, g=bat.NIGHT_BG), delay_cs=4)
# the plain flap as a GIF on the card ground (clip studio)
plain = [[r.replace('.', 'g') for r in bat.scale(f, 6)] for f in bat.flap_frames(16)]
imgio.gif(os.path.join(OUT, 'flap.gif'), plain, dict(bat.PURPLE, g='#e6defc'), delay_cs=4)
print(sorted(os.listdir(OUT)), TW, TH, len(still[0]), len(still))

# ---- dusk bats (the link partner) and crowned icon tiles
DUSK_PAL = dict(bat.DUSK, Y='#f2c14e', R='#ff5c8a', J='#6b5f8a', O='#b8862e')
imgio.png(os.path.join(OUT, 'crown-dusk.png'), bat.scale(still, 8), DUSK_PAL)
imgio.png(os.path.join(OUT, 'dusk.png'), bat.scale(bat.still(), 8), bat.DUSK)
imgio.png(os.path.join(OUT, 'purple.png'), bat.scale(bat.still(), 8), bat.PURPLE)

N = 256
k = int(N * 0.80) // len(still[0])
big = bat.scale(still, k)
h, w = len(big), len(big[0])
ox, oy = (N - w) // 2, (N - h) // 2 + N // 40
top = [['.'] * N for _ in range(N)]
for y, r in enumerate(big):
    for x, c in enumerate(r):
        if c != '.':
            top[oy + y][ox + x] = c
top = [''.join(r) for r in top]
_, _, moon = bat.moon_layers(N, k)
imgio.png(os.path.join(OUT, 'icon-royal-moon.png'), bat.over(top, moon), dict(CROWN_PAL, m=bat.MOON, c=bat.CRATER, s=bat.CRATER_SHADOW, g=bat.NIGHT_BG))
imgio.png(os.path.join(OUT, 'icon-royal-plum.png'), bat.over(top, ['g' * N] * N), dict(CROWN_PAL, g='#2b1747'))
print('extra done')
