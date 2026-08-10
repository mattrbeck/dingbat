#!/usr/bin/env python3
"""refcount.py <reference> <frame...> -- exact matching-pixel count of each
frame against a reference image, the same 23040-pixel figure the local runner
reports for a screenshot row.

Reference may be PNG (including sub-byte palette depths) or PPM; frames may be
either. Colours are compared exactly, which is what the mealybug and acid rows
score on; the shootout's luma-tolerance rule is deliberately NOT applied here,
so a number from this tool is never more generous than the runner's.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bandedge import read_image  # noqa: E402


def main():
    ref = sys.argv[1]
    wr, hr, rr = read_image(ref)
    total = wr * hr
    print('reference %s (%dx%d, %d px)' % (os.path.basename(ref), wr, hr, total))
    for f in sys.argv[2:]:
        if not os.path.exists(f):
            print('  %-42s MISSING' % os.path.basename(f))
            continue
        w, h, r = read_image(f)
        if (w, h) != (wr, hr):
            print('  %-42s SIZE %dx%d' % (os.path.basename(f), w, h))
            continue
        n = sum(1 for y in range(h) for x in range(w) if r[y][x] == rr[y][x])
        print('  %-42s %5d/%d  %s'
              % (os.path.basename(f), n, total,
                 'EXACT' if n == total else '%.2f%%' % (100.0 * n / total)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
