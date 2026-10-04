#!/usr/bin/env python3
"""Continuity check for the flap loops: per frame, how much of each wing is
still visible (% of frame 0), whether each lower wing still meets the body
or an upper wing, and how many separate pixel islands the sprite has.

Usage: check.py N [pose_param=value ...]    e.g. check.py 12 lower_amp=14
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flap  # noqa: E402
N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))


def components(px):
    seen, n = set(), 0
    for q in px:
        if q in seen:
            continue
        n += 1
        st = [q]
        seen.add(q)
        while st:
            x, y = st.pop()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    r = (x + dx, y + dy)
                    if r in px and r not in seen:
                        seen.add(r)
                        st.append(r)
    return n


def report(n, **kw):
    g = flap.load()
    p = flap.parts(g)
    base = None
    rows = []
    for i in range(n):
        px, own = flap.compose(p, *flap.pose(i / n, **kw), owners=True)
        cnt = {k: sum(1 for v in own.values() if v == k) for k in ("lw", "rw", "ll", "rl")}
        if base is None:
            base = cnt
        # a lower wing touches the body (colour to colour) or hides behind an
        # upper wing at its root
        touch = {}
        for k in ("ll", "rl"):
            touch[k] = any(own.get((x + dx, y + dy)) in ("core", "lw", "rw")
                           for (x, y), v in own.items() if v == k for dx, dy in N4)
        rows.append((i, {k: round(100 * cnt[k] / base[k]) for k in cnt}, touch, components(px)))
    for i, vis, touch, comp in rows:
        print("  f%02d vis%% lw %3d rw %3d ll %3d rl %3d | touch ll %d rl %d | islands %d"
              % (i, vis["lw"], vis["rw"], vis["ll"], vis["rl"], touch["ll"], touch["rl"], comp))


if __name__ == "__main__":
    kw = dict(a.split("=") for a in sys.argv[2:])
    kw = {k: float(v) for k, v in kw.items()}
    report(int(sys.argv[1]), **kw)
