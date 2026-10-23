#!/usr/bin/env python3
"""Continuity check for the flap: per frame, the sprite's pixel islands (must be
1: nothing breaks off or floats), whether any pixel left the flap box (it
raises), and that frame 0 is the still logo exactly.

Usage: check.py [N]    (default 16 frames)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bat  # noqa: E402

N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))


def islands(rows):
    px = {(x, y) for y, r in enumerate(rows) for x, c in enumerate(r) if c != '.'}
    seen, n = set(), 0
    for q in px:
        if q in seen:
            continue
        n += 1
        st = [q]
        seen.add(q)
        while st:
            x, y = st.pop()
            for dx, dy in N4:
                r = (x + dx, y + dy)
                if r in px and r not in seen:
                    seen.add(r)
                    st.append(r)
    return n


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    frames = bat.flap_frames(n)
    bad = 0
    for i, f in enumerate(frames):
        k = islands(f)
        print(f'frame {i:2}: islands {k}')
        bad += k != 1
    rest = bat.crop(frames[0]) == bat.still()
    print('frame 0 is the still:', rest)
    sys.exit(1 if bad or not rest else 0)


if __name__ == '__main__':
    main()
