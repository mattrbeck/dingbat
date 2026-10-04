#!/usr/bin/env python3
"""Generate wing-flap frames for the dingbat logo (README/dingbat.png).

The logo is split into three layers: body (head, ears, legs) and the two
wings.  Each wing loses its silhouette outline, is rotated about its
shoulder with RotSprite-style sampling (EPX x3 = 8x, nearest sample), and is
re-outlined with the logo's own rule: a transparent pixel that 4-touches a
coloured pixel becomes outline.  The wings sit behind the body.

Usage: flap.py [OUT_DIR]   writes 8-, 12- and 16-frame loops (frame PNGs, a 1x
                           horizontal sheet, a 4x GIF) for both lower-wing
                           styles: OUT_DIR/{opposite,follow}/{8,12,16}/;
                           default OUT_DIR is ./frames
"""
import math
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "README", "dingbat.png")

T = None  # transparent


def load():
    im = Image.open(SRC).convert("RGBA")
    w, h = im.size
    g = [[None] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            p = im.getpixel((x, y))
            g[y][x] = None if p[3] == 0 else p[:3]
    return g


OUTLINE = (4, 1, 0)


def is_left_wing(x, y):
    return x <= 15 and y <= 15


def is_right_wing(x, y):
    return x >= 29 and y <= 13 and not (x <= 30 and y <= 7)


def layer(g, pred):
    h, w = len(g), len(g[0])
    return {(x, y): g[y][x] for y in range(h) for x in range(w)
            if g[y][x] is not None and pred(x, y)}


def strip_silhouette(px):
    """Drop outline pixels that touch the outside of this layer."""
    out = {}
    for (x, y), c in px.items():
        if c == OUTLINE and any((x + dx, y + dy) not in px
                                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            continue
        out[(x, y)] = c
    return out


def outline(px, keep=None):
    """Add 1px outline (4-neighbour rule) around coloured pixels."""
    out = dict(px)
    for (x, y), c in px.items():
        if c == OUTLINE:
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            q = (x + dx, y + dy)
            if q not in px:
                out[q] = OUTLINE
    return out


def epx(grid):
    h, w = len(grid), len(grid[0])
    o = [[None] * (w * 2) for _ in range(h * 2)]

    def at(x, y):
        if 0 <= x < w and 0 <= y < h:
            return grid[y][x]
        return None
    for y in range(h):
        for x in range(w):
            p = grid[y][x]
            a, b, c, d = at(x, y - 1), at(x + 1, y), at(x - 1, y), at(x, y + 1)
            e1 = e2 = e3 = e4 = p
            if c == a and c != d and a != b:
                e1 = a
            if a == b and a != c and b != d:
                e2 = b
            if d == c and d != b and c != a:
                e3 = c
            if b == d and b != a and d != c:
                e4 = d
            o[2 * y][2 * x], o[2 * y][2 * x + 1] = e1, e2
            o[2 * y + 1][2 * x], o[2 * y + 1][2 * x + 1] = e3, e4
    return o


def rot(p, c, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    dx, dy = p[0] - c[0], p[1] - c[1]
    return (c[0] + ca * dx - sa * dy, c[1] + sa * dx + ca * dy)


def ramp(v, lo, hi):
    t = min(1.0, max(0.0, (v - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)


def warp(px, pivot, angle, bend=None, sweep=(0.0, 0.0), pad=24):
    """RotSprite-style warp: bend the hand about the wrist, rotate about the
    pivot by angle (deg, clockwise on screen), then swing forward about the
    pivot's vertical axis, all sampled back to front from an 8x EPX copy.

    bend = (wrist, seam_end, extra_deg, side): pixels on the `side` (+1/-1)
    of the line wrist->seam_end rotate an extra extra_deg about the wrist,
    eased in over a few pixels so the membrane stretches instead of tearing.
    sweep = (arm_deg, hand_deg): forward swing toward the viewer; the hand
    swings arm_deg + hand_deg, so a forward stroke cups.  Seen head-on a
    swing only foreshortens toward the pivot (x scales by cos)."""
    xs = [p[0] for p in px]
    ys = [p[1] for p in px]
    x0, y0 = min(xs) - 2, min(ys) - 2
    x1, y1 = max(xs) + 3, max(ys) + 3
    grid = [[px.get((x, y)) for x in range(x0, x1)] for y in range(y0, y1)]
    big = epx(epx(epx(grid)))
    bh, bw = len(big), len(big[0])
    extra = 0.0
    if bend:
        (wx, wy), (ex, ey), extra, side = bend
        nx, ny = side * (ey - wy), -side * (ex - wx)
        nl = math.hypot(nx, ny)
        nx, ny = nx / nl, ny / nl
    arm_sw, hand_sw = sweep

    def weight(s):
        if not bend:
            return 0.0
        return ramp((s[0] - wx) * nx + (s[1] - wy) * ny, -1.0, 3.0)

    out = {}
    for y in range(min(ys) - pad, max(ys) + pad):
        for x in range(min(xs) - pad, max(xs) + pad):
            q = (x + 0.5, y + 0.5)
            s = rot(q, pivot, -angle)
            for _ in range(8 if (bend or arm_sw) else 1):
                w = weight(s)
                sw = math.radians(arm_sw + w * hand_sw)
                f = (pivot[0] + (q[0] - pivot[0]) / math.cos(sw), q[1])
                b = rot(f, pivot, -angle)
                s = rot(b, (wx, wy), -extra * w) if bend else b
            u, v = (s[0] - x0) * 8, (s[1] - y0) * 8
            iu, iv = int(math.floor(u)), int(math.floor(v))
            if 0 <= iu < bw and 0 <= iv < bh:
                c = big[iv][iu]
                if c is not None:
                    out[(x, y)] = c
    return out


def is_left_leg(x, y):
    return x <= 17 and y >= 19 and not is_left_wing(x, y)


def is_right_leg(x, y):
    return x >= 30 and y >= 17


def parts(g):
    wing = lambda x, y: is_left_wing(x, y) or is_right_wing(x, y)
    leg = lambda x, y: is_left_leg(x, y) or is_right_leg(x, y)
    return {
        "lw": strip_silhouette(layer(g, is_left_wing)),
        "rw": strip_silhouette(layer(g, is_right_wing)),
        "ll": strip_silhouette(layer(g, is_left_leg)),
        "rl": strip_silhouette(layer(g, is_right_leg)),
        "core": layer(g, lambda x, y: not wing(x, y) and not leg(x, y)),
    }


L_PIVOT = (16.0, 13.0)
R_PIVOT = (28.0, 13.0)
# wrist joint and the far end of the seam between arm-side and hand-side
# membrane; the seam's outer side is the hand
L_BEND = ((11.5, 4.5), (6.0, 14.0))
R_BEND = ((35.5, 3.5), (39.0, 12.0))
LL_PIVOT = (18.0, 19.5)
RL_PIVOT = (29.5, 18.0)
# lower wings bend at mid-length; the seam runs across the limb
LL_BEND = ((14.0, 23.0), (22.0, 30.0))
RL_BEND = ((34.0, 21.0), (27.0, 30.0))


def compose(p, flap, bend=0, bob=0, legs=0, legs_bend=0, sweep=0, cup=0,
            far=1.0, owners=False):
    """flap: degrees the upper wings have swung down from the logo pose;
    bend: extra degrees the hands lag (positive = tips trail below the arm);
    legs: degrees the lower wings swing in toward hanging straight down
    (negative = lifted outward); legs_bend: extra degrees their tips lag,
    same sense as legs; sweep: degrees the upper wings swing forward,
    toward the viewer; cup: extra forward swing of the hands; far: the
    right wing's share of the left wing's swing.  The logo is a 3/4 view
    with the right wing the far one, and a far wing's arc looks smaller.

    owners=True also returns {pixel: layer name} for the visible pixels
    (outline pixels as None)."""
    canvas, owner = {}, {}

    def put(name, px, keep=lambda q: False):
        for q, c in px.items():
            if keep(q):
                continue
            canvas[q] = c
            owner[q] = None if c == OUTLINE else name

    # back to front: lower wings, upper wings, then the body over the roots
    put("ll", outline(warp(p["ll"], LL_PIVOT, -legs, (*LL_BEND, -legs_bend, -1))))
    put("rl", outline(warp(p["rl"], RL_PIVOT, legs, (*RL_BEND, legs_bend, 1))))
    # the upper wings always pass in front of the lower ones; the far
    # (right) wing's smaller swing keeps it off its lower wing
    put("lw", outline(warp(p["lw"], L_PIVOT, -flap, (*L_BEND, -bend, -1), (sweep, cup))))
    put("rw", outline(warp(p["rw"], R_PIVOT, far * flap, (*R_BEND, far * bend, 1),
                           (far * sweep, far * cup))))
    # where a lower wing joins the body the logo has no outline between
    # them; the body's rebuilt outline yields to a lower wing there
    def joint(q):
        if q in p["core"] or owner.get(q) not in ("ll", "rl"):
            return False
        return any(math.hypot(q[0] + 0.5 - j[0], q[1] + 0.5 - j[1]) < 3.0
                   for j in (LL_PIVOT, RL_PIVOT))
    put("core", outline(p["core"]), joint)
    shift = lambda d: {(x, y + bob): v for (x, y), v in d.items()}
    return (shift(canvas), shift(owner)) if owners else shift(canvas)


# frame box: the logo sits at (OX, OY) so its own pixels never move
W, H, OX, OY = 56, 40, 4, 4


def to_image(px):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for (x, y), c in px.items():
        if 0 <= x + OX < W and 0 <= y + OY < H:
            im.putpixel((x + OX, y + OY), c + (255,))
    return im


def sheet(frames, scale=4, bg=(40, 44, 52, 255), gap=2):
    n = len(frames)
    im = Image.new("RGBA", (n * (W + gap) * scale, H * scale), bg)
    for i, f in enumerate(frames):
        big = f.resize((W * scale, H * scale), Image.NEAREST)
        im.alpha_composite(big, (i * (W + gap) * scale, 0))
    return im


def pose(t, amp=72, far=0.7, ease=0.6, bend_down=18, bend_up=34, lift=2, lower="opposite",
         swing=12, lower_amp=8, lower_bend=14, lower_lag=0.15, fwd=30, cup_amp=20, fwd_start=0.15, fwd_end=0.85):
    """Phase t in [0,1): 0 = logo pose (wings up), 0.5 = wings down.

    lower = "opposite": the lower wings flap against the upper pair, lifting
    outward on the downstroke and dropping back on the upstroke, tips
    lagging.  lower = "follow": they only hang straighter after the
    downstroke, like dangling legs."""
    c = math.cos(2 * math.pi * t)
    s_ = math.sin(2 * math.pi * t)
    # mostly eased, partly linear, so the 8-frame loop's steps are even
    tri = 1 - abs(1 - 2 * t)
    flap = amp * (ease * (1 - c) / 2 + (1 - ease) * tri)
    # tips lag wing speed; the lag grows smoothly from the downstroke's
    # strength to the upstroke's instead of switching at the bottom
    lag = (bend_down + bend_up) / 2 - (bend_up - bend_down) / 2 * s_
    bend = -lag * s_
    # the body is pushed up by the downstroke and peaks just after it
    bob = -round(lift * (1 - math.cos(2 * math.pi * (t - 0.08))) / 2)
    if lower == "opposite":
        # behind the upper wings, so an upper wing covers the lower one in
        # a single pass instead of uncovering and covering it again; rests
        # at exactly 0 in the logo pose so the loop has no seam
        w = t - lower_lag * math.sin(math.pi * t) ** 2
        legs = -lower_amp * (1 - math.cos(2 * math.pi * w)) / 2
        legs_bend = lower_bend * math.sin(2 * math.pi * w)
    else:
        # hang straighter while the body is driven up, then swing back; the
        # phase warp peaks them after the wings bottom out
        w = t - 0.11 * math.sin(math.pi * t) ** 2
        legs = swing * (1 - math.cos(2 * math.pi * w)) / 2
        legs_bend = 0
    # the upper wings reach forward most at the bottom of the stroke, where
    # head-on that reads as the tips wrapping in (at the level pose it only
    # reads as a shorter wing), and are drawn back during the upstroke, so
    # the tips loop instead of retracing; the hands lead, cupping the wing
    u = min(1.0, max(0.0, (t - fwd_start) / (fwd_end - fwd_start)))
    reach = math.sin(math.pi * u) ** 2
    sweep, cup = fwd * reach, cup_amp * reach
    return flap, bend, bob, legs, legs_bend, sweep, cup, far


def render(g, n, **kw):
    p = parts(g)
    frames = []
    for i in range(n):
        if i == 0:
            px = {(x, y): g[y][x] for y in range(len(g)) for x in range(len(g[0])) if g[y][x]}
        else:
            px = compose(p, *pose(i / n, **kw))
        frames.append(to_image(px))
    return frames


def save_gif(frames, path, ms, scale=4, bg=(40, 44, 52)):
    big = []
    for f in frames:
        im = Image.new("RGBA", (W * scale, H * scale), bg + (255,))
        im.alpha_composite(f.resize((W * scale, H * scale), Image.NEAREST))
        big.append(im.convert("RGB"))
    big[0].save(path, save_all=True, append_images=big[1:], duration=ms, loop=0)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "frames")
    g = load()
    for (lower, n), fps in (((l, n), f) for l in ("opposite", "follow")
                            for n, f in ((8, 12), (12, 18), (16, 24))):
        d = os.path.join(out, lower, "%d" % n)
        os.makedirs(d, exist_ok=True)
        frames = render(g, n, lower=lower)
        for i, f in enumerate(frames):
            f.save(os.path.join(d, "frame_%02d.png" % i))
        sheet(frames, 1, (0, 0, 0, 0), 0).save(os.path.join(d, "sheet.png"))
        save_gif(frames, os.path.join(d, "flap_x4.gif"), round(1000 / fps))
