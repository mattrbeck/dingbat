#!/usr/bin/env python3
"""Mixer timing from a traced real-BIOS run (run.py ... --trace): for every
SoundDriverMain call, the cycle of each channel's first buffer store, and
the gaps between that channel's output samples grouped by how far its
sample pointer moved (the resampler's advances) and whether it crossed a
loop.
  mixtime.py <rom.gba> <prefix> [first_call] [last_call] [--samples]"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import load_marks, regions_of  # noqa: E402

rom = os.path.abspath(sys.argv[1])
prefix = sys.argv[2]
args = [a for a in sys.argv[3:] if not a.startswith("--")]
show = "--samples" in sys.argv
marks = load_marks(prefix, regions_of(rom))
AREA = regions_of(rom)[0][0]
wins = []
for i, (m, f, c, s) in enumerate(marks):
    if m == 0xF1 and i > 0 and marks[i - 1][0] == 0xF0:
        wins.append((marks[i - 1][2], c))
lo = int(args[0]) if args else 0
hi = int(args[1]) if len(args) > 1 else len(wins)


def load(path, kind):
    out = []
    for line in open(path):
        p = line.split()
        a, rest = p[3].split(":")
        out.append((int(p[1]), kind, p[2][3:], int(a, 16)))
    return out


ev = sorted(load(prefix + ".mem.txt", "st") + load(prefix + ".memread.txt", "rd"))
for k, (t0, t1) in enumerate(wins):
    if k < lo or k >= hi:
        continue
    evs = [e for e in ev if t0 <= e[0] <= t1]
    # channel visits: the byte read of a channel's status (pc 1EB8)
    visits = [e for e in evs if e[1] == "rd" and e[2] == "1EB8" and (e[3] & 0xFFFF0000) != 0]
    print(f"== call {k}: {t1 - t0} cycles, {len(visits)} channel visits")
    for vi, v in enumerate(visits):
        end = visits[vi + 1][0] if vi + 1 < len(visits) else t1
        sub = [e for e in evs if v[0] <= e[0] < end]
        stores = [e for e in sub if e[1] == "st" and AREA + 0x350 <= e[3] < AREA + 0xFB0]
        srcs = [e for e in sub if e[1] == "rd" and (e[3] >> 24) not in (3,)]
        if not stores:
            print(f"   ch@{v[3]:08X} +{v[0] - t0}: no output ({end - v[0]} cycles)")
            continue
        # output times = the second (A) store of each pair
        outs = stores[1::2]
        first = stores[0][0]
        gaps = collections.Counter()
        prev_t = None
        prev_src = None
        for o in outs:
            # the last source read before this output
            rs = [r for r in srcs if r[0] < o[0]]
            src = rs[-1][3] if rs else None
            if prev_t is not None:
                gaps[(o[0] - prev_t, (src - prev_src) if src is not None and prev_src is not None else None)] += 1
            prev_t, prev_src = o[0], src
        print(f"   ch@{v[3]:08X} visit +{v[0] - t0} first store +{first - t0} "
              f"last +{stores[-1][0] - t0} outputs {len(outs)} tail {end - stores[-1][0]}")
        for (g, d), n in sorted(gaps.items(), key=lambda x: -x[1])[:12]:
            print(f"       gap {g:4d} src+{d} x{n}")
