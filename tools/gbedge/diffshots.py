#!/usr/bin/env python3
"""diffshots.py <tag> <worldA> <worldB> [...] -- compare .shots/<tag>.<world>.ppm
frames against the FIRST world named, pixel by pixel.

The comparison this round needs is world-against-world, not frame-against-
reference: a constant that is genuinely a compensation for a moved pipeline
should return its witness to byte-identity with the control world, and that
statement needs no reference image and no tolerance rule to be meaningful.
"""
import sys
import os

W = '/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556'


def read_ppm(path):
    d = open(path, 'rb').read()
    # P6 <w> <h> <max>\n, whitespace/comment tolerant
    assert d[:2] == b'P6', path
    vals, i = [], 2
    while len(vals) < 3:
        while i < len(d) and d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] not in (b'\n', b''):
                i += 1
            continue
        j = i
        while j < len(d) and not d[j:j + 1].isspace():
            j += 1
        vals.append(int(d[i:j]))
        i = j
    i += 1
    w, h, _ = vals
    return w, h, d[i:i + w * h * 3]


def main():
    tag = sys.argv[1]
    worlds = sys.argv[2:]
    base = None
    print('== %s ==' % tag)
    for wd in worlds:
        p = os.path.join(W, '.shots', '%s.%s.ppm' % (tag, wd))
        if not os.path.exists(p):
            print('  %-14s MISSING' % wd)
            continue
        w, h, px = read_ppm(p)
        if base is None:
            base = (w, h, px, wd)
            print('  %-14s baseline %dx%d' % (wd, w, h))
            continue
        bw, bh, bpx, bwd = base
        if (w, h) != (bw, bh):
            print('  %-14s SIZE %dx%d vs %dx%d' % (wd, w, h, bw, bh))
            continue
        bad = [k for k in range(w * h) if px[k*3:k*3+3] != bpx[k*3:k*3+3]]
        if not bad:
            print('  %-14s IDENTICAL to %s' % (wd, bwd))
        else:
            ys = sorted({k // w for k in bad})
            xs = sorted({k % w for k in bad})
            print('  %-14s %d px differ  (x %d..%d, y %d..%d)'
                  % (wd, len(bad), xs[0], xs[-1], ys[0], ys[-1]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
