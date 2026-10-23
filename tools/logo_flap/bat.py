"""The Night Flyer: dingbat's logo bat, as pixel art and as a rig that flaps.

The still is a 42 x 19 sprite: a hand-drawn body half (BODY), mirrored, with
procedural wings either side. A wing is a fan from the wrist: a root panel,
then one membrane panel per finger gap ending in a scallop. The flap moves
that shape, not its pixels: each panel's outline is subdivided, bent down
about the shoulder (more toward the tip, the hand lagging the arm) and swept
toward the viewer with a little perspective, then filled again at 1x, finger
bones drawn as 1 px polylines and the outline rebuilt. Frame 0 is the still.

Palette characters: K outline, B body, W wing, w wing turned away, H bones,
E eye, C cheek, F fang; '.' is transparent.
"""
import math

BODY = '''
.......
.KK....
.KHK...
.KHBK..
.KBBBKK
KBBBBBB
KBBBBBB
KBEEBBB
KBEKBBB
KBEKBBB
KBBBBBB
KBCBBKK
KBBBBFB
KBBBBBB
KKBBBBB
.KBBBBB
..KBBBB
...KKBB
.....KK
'''.strip('\n').split('\n')
BODY = [r[:7].ljust(7, '.') for r in BODY]

PURPLE = dict(K='#1b1028', B='#7a4fc4', W='#4d2f8a', w='#3a2270', H='#a98ae6', E='#ffffff', C='#ff8fb1', F='#f1eee8')
DUSK = dict(K='#1a1420', B='#3d3552', W='#2a2438', w='#211b2d', H='#6b5f8a', E='#ffcf4a', C='#e08aa0', F='#f1eee8')
NIGHT_BG = '#0e0a16'   # Night's background: the flat ground behind the bat on icons and cards

# the wing: W columns wide, wrist peak at row TIP_Y, attached to the body over rows TOP..BOTTOM
W, TIP_Y, TOP, BOTTOM, FINGERS, DEPTH = 13, 1, 5, 14, 3, 0.32
SHOULDER_Y = 9.0
N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))

# the flap: today's logo timing, the "fuller" reach
TUNE = dict(amp=52.0, fwd=26.0, cup=18.0, persp=70.0, bend_down=18.0, bend_up=34.0,
            squash=0.25, shade=0.8, front=3.0, down=0.5)


def inside(poly, x, y):
    c = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]; x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            c = not c
    return c


def line(a, b):
    (x0, y0), (x1, y1) = a, b
    n = int(max(abs(x1 - x0), abs(y1 - y0))) * 2 + 1
    return {(round(x0 + (x1 - x0) * t / n), round(y0 + (y1 - y0) * t / n)) for t in range(n + 1)}


def ss(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def wing_geom(Ww=W, tipY=TIP_Y, top=TOP, bottom=BOTTOM, fingers=FINGERS, depth=DEPTH):
    """The left wing as geometry: wrist, finger tips and the fan of panels."""
    shoulder = (Ww + 0.0, top + 0.3)
    wrist = (Ww * 0.42, tipY + 0.4)
    tip = (0.1, tipY + 2.6)
    end = (Ww + 0.0, bottom + 0.9)
    tips = []
    for i in range(1, fingers + 1):
        t = i / (fingers + 1)
        tips.append((tip[0] + (end[0] - tip[0]) * t * 0.92,
                     tip[1] + (end[1] + 1.2 - tip[1]) * math.sin(t * math.pi / 2)))
    chain = [tip] + tips + [end]
    scal = []
    for a, b in zip(chain, chain[1:]):
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        scal.append((mx + (wrist[0] - mx) * depth, my + (wrist[1] - my) * depth))
    panels = [[wrist, chain[i], scal[i], chain[i + 1]] for i in range(len(scal))]
    panels.append([wrist, end, shoulder])
    poly = [wrist, tip] + [p for a, s in zip(chain[1:], scal) for p in (s, a)] + [shoulder]
    return dict(wrist=wrist, tips=tips, panels=panels, poly=poly)


def wing_still(Ww=W, tipY=TIP_Y, top=TOP, bottom=BOTTOM, fingers=FINGERS, depth=DEPTH, H=19):
    """The wing at rest, rasterised: fill by pixel centre, bones, 4-neighbour outline."""
    geo = wing_geom(Ww, tipY, top, bottom, fingers, depth)
    g = {(x, y): 'W' for y in range(H) for x in range(Ww) if inside(geo['poly'], x + 0.5, y + 0.5)}
    for f in geo['tips']:
        for q in line(geo['wrist'], f):
            if q in g:
                g[q] = 'H'
    out = dict(g)
    for (x, y) in g:
        for dx, dy in N4:
            q = (x + dx, y + dy)
            if q not in g and 0 <= q[0] < Ww and 0 <= q[1] < H:
                out[q] = 'K'
    return [''.join(out.get((x, y), '.') for x in range(Ww)) for y in range(H)]


def mirror(rows):
    return [r + r[::-1] for r in rows]


def close_outline(rows):
    """Outline any fill touching empty space (the wing raster clips its outline at its own edge)."""
    H, Wd = len(rows), len(rows[0])
    g = [list(r) for r in rows]
    for y in range(H):
        for x in range(Wd):
            if rows[y][x] == '.' and any(0 <= x + dx < Wd and 0 <= y + dy < H and rows[y + dy][x + dx] not in '.K'
                                         for dx, dy in N4):
                g[y][x] = 'K'
    return [''.join(r) for r in g]


def crop(rows):
    ys = [y for y, r in enumerate(rows) if r.strip('.')]
    xs = [x for r in rows for x, c in enumerate(r) if c != '.']
    return [r[min(xs):max(xs) + 1] for r in rows[ys[0]:ys[-1] + 1]]


def pad(rows, Wd, H, ox=None, oy=None):
    w, h = len(rows[0]), len(rows)
    l = (Wd - w) // 2 if ox is None else ox
    t = (H - h) // 2 if oy is None else oy
    return ['.' * Wd] * t + ['.' * l + r + '.' * (Wd - w - l) for r in rows] + ['.' * Wd] * (H - h - t)


def scale(rows, k):
    return [''.join(c * k for c in r) for r in rows for _ in range(k)]


# ---------------------------------------------------------------- the flap

def pose(t):
    """Wing angles for phase t in [0, 1): flap, hand bend, body bob, forward sweep, hand cup."""
    amp, fwd, cup = TUNE['amp'], TUNE['fwd'], TUNE['cup']
    bd, bu = TUNE['bend_down'], TUNE['bend_up']
    c = math.cos(2 * math.pi * t); s = math.sin(2 * math.pi * t)
    tri = 1 - abs(1 - 2 * t)
    fl = amp * (0.6 * (1 - c) / 2 + 0.4 * tri)
    lag = (bd + bu) / 2 - (bu - bd) / 2 * s
    bend = -lag * s
    bob = -round((1 - math.cos(2 * math.pi * (t - 0.08))) / 2)
    u = min(1.0, max(0.0, (t - 0.15) / 0.7))
    reach = math.sin(math.pi * u) ** 2
    return fl, bend, bob, fwd * reach, cup * reach


def subdiv(poly, step=0.25, closed=True):
    pts = []
    n = len(poly)
    for i in range(n if closed else n - 1):
        a, b = poly[i], poly[(i + 1) % n]
        k = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) / step))
        pts += [(a[0] + (b[0] - a[0]) * j / k, a[1] + (b[1] - a[1]) * j / k) for j in range(k)]
    if not closed:
        pts.append(poly[-1])
    return pts


class Rig:
    def __init__(self):
        half = [wg + b for wg, b in zip(wing_still(), BODY)]
        rows = mirror(half)
        self.trim = 0
        while set(rows[self.trim]) == {'.'}:
            self.trim += 1
        rows = rows[self.trim:]
        while set(rows[-1]) == {'.'}:
            rows = rows[:-1]
        self.rows = rows
        self.H0, self.W0 = len(rows), len(rows[0])
        g = {(x, y): ch for y, r in enumerate(rows) for x, ch in enumerate(r) if ch != '.'}
        self.core = {q: ch for q, ch in g.items() if W <= q[0] < self.W0 - W}
        lw = [q[0] for q in g if q[0] < W]
        self.U = W - min(lw)
        self.c = (self.W0 / 2, self.H0 / 2)
        self.geo = wing_geom()

    def xf(self, p, pz):
        """A point of the left wing -> screen (X, Y), depth toward the viewer, and how much it faces us."""
        fl, bend, sweep, cup = pz
        sx, sy = W, SHOULDER_Y
        u = sx - p[0]
        v = p[1] - self.trim - sy
        w = min(1.0, max(0.0, u / self.U))
        a = math.radians(fl * ss(0.0, 0.45, w) + bend * ss(0.45, 0.95, w))
        # rows squash toward the shoulder as the wing comes down, none at rest
        sq = TUNE['squash'] * w * min(1.0, abs(fl) / TUNE['amp'])
        px, py = -u * math.cos(a), u * math.sin(a) + v * (1.0 - sq)
        s = math.radians(sweep * ss(0.0, 0.8, w) + cup * ss(0.55, 1.0, w))
        z = -px * math.sin(s)
        px = px * math.cos(s)
        X3, Y3 = sx + px, sy + py
        k = TUNE['persp'] / (TUNE['persp'] - z)
        return (self.c[0] + (X3 - self.c[0]) * k, self.c[1] + (Y3 - self.c[1]) * k), z, math.cos(s)

    def frame(self, t):
        """The bat at phase t as {(x, y): char}, in still-sprite coordinates."""
        d = TUNE['down']
        t = t * 0.5 / d if t < d else 0.5 + (t - d) * 0.5 / (1 - d)
        fl, bend, bob, sweep, cup = pose(t)
        pz = (fl, bend, sweep, cup)
        geo = self.geo
        lab, pinfo = {}, []
        for i, poly in enumerate(geo['panels']):
            P = [q for q, _, _ in (self.xf(p, pz) for p in subdiv(poly))]
            cx = sum(p[0] for p in poly) / len(poly); cy = sum(p[1] for p in poly) / len(poly)
            _, zc, fc = self.xf((cx, cy), pz)
            pinfo.append((zc, fc))
            xs = [p[0] for p in P]; ys = [p[1] for p in P]
            for y in range(math.floor(min(ys)) - 1, math.ceil(max(ys)) + 1):
                for x in range(math.floor(min(xs)) - 1, math.ceil(max(xs)) + 1):
                    if inside(P, x + 0.5, y + 0.5):
                        lab.setdefault((x, y), i)
        wing = {q: ('w' if pinfo[i][1] < TUNE['shade'] else 'W') for q, i in lab.items()}
        for f in geo['tips']:
            pts = [self.xf(p, pz)[0] for p in subdiv([geo['wrist'], f], 0.5, closed=False)]
            for a, b in zip(pts, pts[1:]):
                for q in line(a, b):
                    if q in wing:
                        wing[q] = 'H'
        X, Y = self.xf(geo['wrist'], pz)[0]
        wing[(round(X), round(Y))] = 'H'
        while True:   # membrane pixels touching no other wing pixel are stray nubs
            lone = [q for q, c in wing.items() if c in 'Ww' and not any((q[0] + dx, q[1] + dy) in wing for dx, dy in N4)]
            if not lone:
                break
            for q in lone:
                del wing[q]
                lab.pop(q, None)
        dep = {q: pinfo[i][0] for q, i in lab.items()}
        for q in wing:
            if q not in dep:
                dep[q] = max((dep.get((q[0] + dx, q[1] + dy), 0) for dx, dy in N4), default=0)
        out = dict(wing)
        for (x, y) in wing:
            for dx, dy in N4:
                r = (x + dx, y + dy)
                if r not in wing:
                    out[r] = 'K'
                    dep.setdefault(r, dep[(x, y)])
        W0 = self.W0
        both = dict(out); both.update({(W0 - 1 - x, y): c for (x, y), c in out.items()})
        dd = dict(dep); dd.update({(W0 - 1 - x, y): z for (x, y), z in dep.items()})
        canvas = {q: c for q, c in both.items() if dd.get(q, 0) <= TUNE['front']}
        canvas.update(self.core)
        canvas.update({q: c for q, c in both.items() if dd.get(q, 0) > TUNE['front']})
        return {(x, y + bob): c for (x, y), c in canvas.items()}


# the flap's box: wings reach 6 px past the still each side, 2 above
BOX_W, BOX_H, BOX_X, BOX_Y = 52, 28, 6, 2


def flap_frames(n=16):
    """n frames in the flap box, as rows; frame 0 holds the still at (BOX_X, BOX_Y) (its wingtip outline 1 px outside)."""
    rig = Rig()
    frames = []
    for i in range(n):
        px = rig.frame(i / n)
        g = [['.'] * BOX_W for _ in range(BOX_H)]
        for (x, y), c in px.items():
            if not (0 <= x + BOX_X < BOX_W and 0 <= y + BOX_Y < BOX_H):
                raise ValueError(f'frame {i} clips at {x},{y}')
            g[y + BOX_Y][x + BOX_X] = c
        frames.append([''.join(r) for r in g])
    return frames


def still():
    """The 42 x 19 logo: frame 0 of the flap, cropped (its wingtip outline closed)."""
    return crop(flap_frames(1)[0])


# ---------------------------------------------------------------- favicon drawings

def favicon32():
    """32 x 32: the same body and face, with shorter (8 px) wings."""
    half = [wg + b for wg, b in zip(wing_still(8, 1, TOP, BOTTOM, 2, 0.30), BODY)]
    return close_outline(pad(crop(mirror(half)), 32, 32))


FAVICON16 = '''
................
................
................
.....K....K.....
K...KBK..KBK...K
KK..KBBKKBBK..KK
KHK.KBBBBBBK.KHK
KWHKKBEBBEBKKHWK
KWWHKBKBBKBKHWWK
KWWWHKCBBCKHWWWK
.KWWKKKFFKKKWWK.
..KWK.KBBK.KWK..
...K...KK...K...
................
................
................
'''.strip('\n').split('\n')


# ---------------------------------------------------------------- the moon behind the app icons

MOON, CRATER, CRATER_SHADOW = '#f3e3a6', '#e2cd84', '#cdb466'
# Drawn for the 1024 icon at 22x, in icon pixels from the centre; other sizes scale by k / 22.
# The moon's radius, and its craters and the cream field's as (dx, dy, r): mixed sizes, uneven
# spacing, some under the bat and some cut by the edge, so nothing frames it.
MOON_R = 369
MOON_CRATERS = ((-190, -150, 72), (150, -262, 48), (55, 250, 84), (-240, 232, 46), (318, 118, 58), (-60, -318, 34))
FIELD_CRATERS = ((-235, 160, 122), (215, -240, 80), (-330, -340, 58), (438, 338, 108), (75, 338, 50),
                 (-70, -305, 40), (-455, 430, 72), (330, -455, 44))
MOON_PAL = dict(PURPLE, m=MOON, c=CRATER, s=CRATER_SHADOW, g=NIGHT_BG)


def moon_layers(n, k):
    """The app icon's layers, n x n with the bat at k x, each shape on the bat's own pixel grid:
    (bat, field, moon). bat is the logo on '.'; field the cream ground with its craters (the light
    icon's ground); moon the moon and its craters on the Night ground 'g' (the dark icon's)."""
    still_ = still()
    w, h = len(still_[0]) * k, len(still_) * k
    ox, oy, f = (n - w) // 2, (n - h) // 2, k / 22

    def crater(cx, cy, craters):
        for dx, dy, r in craters:
            dx, dy, r = dx * f, dy * f, r * f
            if (cx - dx) ** 2 + (cy - dy) ** 2 <= r * r:
                # the rim's shadow: the part of the crater outside a disc nudged down and right
                lit = (cx - dx - r * 0.22) ** 2 + (cy - dy - r * 0.22) ** 2 <= (r * 0.82) ** 2
                return 'c' if lit else 's'
        return None

    field, moon = [], []
    for y in range(n):
        fl, ml = [], []
        cy = oy + ((y - oy) // k) * k + k / 2 - n / 2
        for x in range(n):
            cx = ox + ((x - ox) // k) * k + k / 2 - n / 2
            fl.append(crater(cx, cy, FIELD_CRATERS) or 'm')
            on = cx * cx + cy * cy <= (MOON_R * f) ** 2
            ml.append((crater(cx, cy, MOON_CRATERS) or 'm') if on else 'g')
        field.append(''.join(fl))
        moon.append(''.join(ml))
    return pad(scale(still_, k), n, n), field, moon


def over(top, ground):
    """top's pixels over ground's, where top is '.'."""
    return [''.join(g if t == '.' else t for t, g in zip(tr, gr)) for tr, gr in zip(top, ground)]
