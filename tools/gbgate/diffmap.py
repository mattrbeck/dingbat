#!/usr/bin/env python3
"""Where do two framebuffer dumps differ? Prints the bounding box, the count,
and an ASCII map at 8x8 tile granularity so the shape of a divergence is
readable without opening an image viewer.

Usage: diffmap.py <a.bin> <b.bin> [width] [height]
"""
import struct
import sys


def main():
    a = open(sys.argv[1], "rb").read()
    b = open(sys.argv[2], "rb").read()
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 160
    h = int(sys.argv[4]) if len(sys.argv) > 4 else 144
    pa = struct.unpack("<%dH" % (len(a) // 2), a)
    pb = struct.unpack("<%dH" % (len(b) // 2), b)
    diff = [(i % w, i // w) for i in range(w * h) if pa[i] != pb[i]]
    if not diff:
        print("identical")
        return
    xs = [p[0] for p in diff]
    ys = [p[1] for p in diff]
    print("%d differing pixels, bbox x=%d..%d y=%d..%d"
          % (len(diff), min(xs), max(xs), min(ys), max(ys)))
    tiles = set((x // 8, y // 8) for x, y in diff)
    for ty in range(h // 8):
        print("".join("#" if (tx, ty) in tiles else "." for tx in range(w // 8)))


main()
