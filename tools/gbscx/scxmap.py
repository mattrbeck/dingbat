#!/usr/bin/env python3
"""The scx_during_m3 map: every row of the family as a displacement ruler.

Runs over a `tools/gbscx/dumpfam.sh` output directory, pairs each dumped frame
with its reference PNG through the TSV, and reads BOTH through
`scxread.segment`. For each row it prints, per distinct line shape, where the
effective SCX changed in HARDWARE and where it changed in ours -- in screen
columns, which for this family is the measurement.

    tools/gbscx/scxmap.py .tmp/scxdump [name-substring]

A row where the two agree everywhere is a pass. A row where the boundaries sit
at different columns says the write took effect at a different pixel, and the
difference IS the dot error divided by one dot per pixel.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from scxread import load_indexed, segment  # noqa: E402


def boundaries(segs):
    """(x0, x1, displacement mod 16) per run.

    The background row is 16-pixel periodic inside each of its two halves, so a
    run's absolute displacement is ambiguous but `d mod 16` never is: it carries
    the tile-column PARITY (the 8) and the fine scroll (the 0..7), which
    together are exactly what a mid-line SCX write changes. Reporting mod 16
    turns an ambiguity into a clean number instead of hiding a real difference
    behind a candidate set.
    """
    out = []
    for s, e, o in segs:
        m = sorted({v % 16 for v in o})
        d = str(m[0]) if len(m) == 1 else ('|'.join(map(str, m)) if len(m) <= 3
                                           else '?')
        # Every split the greedy search makes is a real one: it only cuts when
        # no background offset explains the next pixel, so a neighbouring pair
        # that agrees mod 16 differs by a nonzero multiple of 16 -- an even
        # number of tiles -- and merging them would hide exactly that.
        if len(o) <= 2:
            d += '(%s)' % ','.join(str(v) for v in o)
        out.append((s, e - 1, d))
    return out


def fmt(bs):
    return ' '.join('%d..%d=%s' % b for b in bs)


def main():
    root = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else ''
    tsv = [l.split('\t') for l in open(os.path.join(root, 'list.tsv'))
           if l.strip()]
    frames = {}
    for f in os.listdir(root):
        if f.endswith('.ppm'):
            frames[int(f.split('_', 1)[0])] = os.path.join(root, f)
    verdict = {}
    vf = os.path.join(root, 'verdicts.txt')
    if os.path.exists(vf):
        for l in open(vf):
            p = l.split()
            if len(p) >= 3 and p[0] == 'GAM':
                verdict[int(p[1])] = ' '.join(p[2:])
    for i, (dev, kind, ref, rom) in enumerate(tsv):
        rom = rom.strip()
        name = os.path.relpath(rom, os.path.dirname(os.path.dirname(rom)))
        label = '%s [%s]' % (name, dev)
        if want and want not in label:
            continue
        if kind != 'png' or i not in frames:
            continue
        ours = load_indexed(frames[i])
        hw = load_indexed(ref)
        shapes = {}
        for y in range(144):
            a = fmt(boundaries(segment(ours[y])))
            b = fmt(boundaries(segment(hw[y])))
            shapes.setdefault((a, b), []).append(y)
        print('### %-52s %s' % (label, verdict.get(i, '')))
        for (a, b), ys in sorted(shapes.items(), key=lambda kv: kv[1][0]):
            rng = ('%d-%d' % (ys[0], ys[-1])) if len(ys) > 1 else str(ys[0])
            tag = 'ok  ' if a == b else 'DIFF'
            print('  %s lines %-8s (%3d)' % (tag, rng, len(ys)))
            print('       hw   %s' % b)
            if a != b:
                print('       ours %s' % a)


if __name__ == '__main__':
    main()
