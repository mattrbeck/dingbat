#!/usr/bin/env python3
"""Read a gambatte `scx_during_m3` frame as a DISPLACEMENT MAP.

Why this works, and it is a property of the ROM rather than a trick. Every ROM
in the family paints the same background: 32 map columns of alternating tile
pairs, columns 0..11 from one pair and 12..31 from another, and the four tiles
are

    t0 = 0 2 2 2 2 2 2 0      t2 = 3 1 1 1 1 1 1 3
    t1 = 2 0 0 0 0 0 0 2      t3 = 1 3 3 3 3 3 3 1

so the 256-pixel background row is *aperiodic enough to locate*: a run of a
dozen pixels pins the background X coordinate it came from, usually uniquely.
A scanline is therefore not a picture, it is a function

    screen x  ->  background X the PPU emitted there

and `X - x` is the effective SCX at that pixel. The whole family is one ROM
writing SCX three times per line at swept dots, so reading that function off
the reference PNG says WHERE hardware let each write take effect, in screen
columns, with no model in the loop at all.

The output is a segmentation of each line into maximal runs of constant
displacement. Two frames of the same ROM (ours and the reference) segmented the
same way are directly comparable: same segment boundaries means the writes took
effect at the same pixel.

    tools/gbscx/scxread.py <frame.ppm|png> [--lines a:b] [--raw]
    tools/gbscx/scxread.py <ours.ppm> <reference.png>     # paired diff

The colour->index mapping is recovered by brute force over all 24 permutations
of the frame's own distinct colours, scored by how much of the frame becomes
explainable. That keeps the tool independent of BGP, of the CGB palette, and of
which device the frame came from.
"""
import sys
import os
from itertools import permutations

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'gbedge'))
from bandedge import read_image  # noqa: E402

W, H = 160, 144

TILES = {
    0: [0, 2, 2, 2, 2, 2, 2, 0],
    1: [2, 0, 0, 0, 0, 0, 0, 2],
    2: [3, 1, 1, 1, 1, 1, 1, 3],
    3: [1, 3, 3, 3, 3, 3, 3, 1],
}


def bg_row():
    """The 256-pixel background row every ROM in the family paints."""
    out = []
    for c in range(32):
        t = (2 + (c & 1)) if c < 12 else (c & 1)
        out.extend(TILES[t])
    return out


BG = bg_row()

# cand[i] = the set of background X whose colour index is i. Turning the
# per-pixel test into a set intersection is what makes the segmentation cheap.
CAND = [frozenset(x for x in range(256) if BG[x] == i) for i in range(4)]


# The colour of each BG palette index is not guessed, it is computed. Every ROM
# in the family writes BGP = $27 and the same CGB BG palette 0 ($0000, $5294,
# $2108, $FFFF), and the comparison space is gambatte's: DMG shades are the
# plain #000/#555/#AAA/#FFF ramp and CGB entries go through gambatte's colour
# correction, both masked to the top 5 bits per channel. So each device has one
# fixed table from RGB back to the palette index the fetcher pushed.
#
#   DMG, BGP = $27: index 0 -> shade 3, 1 -> shade 1, 2 -> shade 2, 3 -> shade 0
#   CGB: the four BGR555 entries, corrected, are $000000 $A0A0A0 $404040 $F8F8F8
DMG_MAP = {(0x00, 0x00, 0x00): 0, (0xA8, 0xA8, 0xA8): 1,
           (0x50, 0x50, 0x50): 2, (0xF8, 0xF8, 0xF8): 3}
CGB_MAP = {(0x00, 0x00, 0x00): 0, (0xA0, 0xA0, 0xA0): 1,
           (0x40, 0x40, 0x40): 2, (0xF8, 0xF8, 0xF8): 3}


def load_indexed(path):
    """Frame as a 144x160 grid of BG palette INDICES 0..3."""
    w, h, rows = read_image(path)
    assert (w, h) == (W, H), '%s is %dx%d' % (path, w, h)
    grid = [[tuple(v & 0xF8 for v in px) for px in row] for row in rows]
    colours = {px for row in grid for px in row}
    for cmap in (DMG_MAP, CGB_MAP):
        if colours <= set(cmap):
            return [[cmap[px] for px in row] for row in grid]
    raise SystemExit('%s: colours %s are neither the DMG nor the CGB table'
                     % (path, sorted(colours)))


def segment(line):
    """Split one scanline into maximal runs of constant displacement.

    Greedy left to right: keep the set of background offsets still consistent
    with every pixel seen so far, and close the run when it empties. Returns
    (start, end, offsets) with `offsets` the surviving set, as a sorted tuple.
    """
    out = []
    start = 0
    live = None
    for x in range(len(line)):
        c = CAND[line[x]]
        step = frozenset((k - x) % 256 for k in c)
        nxt = step if live is None else (live & step)
        if not nxt:
            out.append((start, x, tuple(sorted(live)) if live else ()))
            start = x
            live = step
        else:
            live = nxt
    out.append((start, len(line), tuple(sorted(live)) if live else ()))
    return out


def fmt(segs):
    parts = []
    for s, e, o in segs:
        if len(o) == 1:
            d = str(o[0])
        elif len(o) <= 4:
            d = '|'.join(str(v) for v in o)
        else:
            d = '?%d' % len(o)
        parts.append('%d-%d:%s' % (s, e - 1, d))
    return ' '.join(parts)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    lo, hi = 0, H
    for f in flags:
        if f.startswith('--lines'):
            a, b = f.split('=')[1].split(':')
            lo, hi = int(a), int(b)
    a = load_indexed(args[0])
    b = load_indexed(args[1]) if len(args) > 1 else None
    seen = {}
    for y in range(lo, hi):
        sa = fmt(segment(a[y]))
        sb = fmt(segment(b[y])) if b else None
        key = (sa, sb)
        seen.setdefault(key, []).append(y)
    for (sa, sb), ys in sorted(seen.items(), key=lambda kv: kv[1][0]):
        rng = '%d-%d' % (ys[0], ys[-1]) if len(ys) > 1 else str(ys[0])
        print('lines %-9s (%3d)' % (rng, len(ys)))
        print('   ours %s' % sa)
        if sb is not None:
            print('   hw   %s' % sb)


if __name__ == '__main__':
    main()
