#!/usr/bin/env python3
"""rowshift.py A B -- is frame B frame A displaced VERTICALLY by k rows?

The mealybug PPU ROMs derive the value they write from rLY (`ldh a,[rLY]` is the
handler's first action, and m3_bgp_change then writes `swap a` straight into
BGP). So a model error that makes the handler read the WRONG LY shows up as the
whole band structure moving up or down by whole scanlines, while an error in
the write's DOT shows up as columns moving within a row.

This tool tells those two apart, which is the entire question in the
2026-08-10 LY-vs-OAM-source experiment: it reports, for each candidate vertical
shift k, how many rows of B match row+k of A exactly.
"""
import sys
sys.path.insert(0, '/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556/tools/gbedge')
from bandedge import read_image  # noqa: E402


def main():
    wa, ha, ra = read_image(sys.argv[1])
    wb, hb, rb = read_image(sys.argv[2])
    best = []
    for k in range(-24, 25):
        n = 0
        for y in range(hb):
            ys = y + k
            if 0 <= ys < ha and rb[y] == ra[ys]:
                n += 1
        best.append((n, k))
    best.sort(reverse=True)
    same = sum(1 for y in range(min(ha, hb)) if ra[y] == rb[y])
    print('rows identical at shift 0: %d/%d' % (same, hb))
    print('best vertical shifts (rows matching):')
    for n, k in best[:5]:
        if n:
            print('   k=%+3d rows : %d' % (k, n))
    return 0


if __name__ == '__main__':
    sys.exit(main())
