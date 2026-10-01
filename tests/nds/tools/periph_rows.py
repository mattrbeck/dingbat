#!/usr/bin/env python3
"""Read periph_suite's result words back from a screenshot.

    periph_rows.py SHOT.png [--words N]

The ARM9 of src/periph_suite draws RES[w] as a 4-pixel row at y = 4w on the
top screen, bit 31 leftmost in 8-pixel cells, white = 1 (periph.h). This
decodes them from a 256x384 PNG as written by tools/ndsrun.nim or
tools/ndsref (8-bit RGB/RGBA, any filter), so a reference run can be
compared word for word with `ndsrun --peek9`. Standard library only.
"""

import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG")
    pos, idat = 8, b""
    w = h = ctype = 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            if depth != 8 or ctype not in (2, 6):
                sys.exit(f"{path}: only 8-bit RGB/RGBA")
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, bpp, rows


def main():
    args = sys.argv[1:]
    words = 48
    if "--words" in args:
        k = args.index("--words")
        words = int(args[k + 1])
        del args[k:k + 2]
    w, bpp, rows = read_png(args[0])
    for r in range(words):
        v = 0
        for b in range(32):
            px = rows[r * 4 + 1][(b * 8 + 3) * bpp:(b * 8 + 3) * bpp + 3]
            if min(px) > 200:
                v |= 1 << (31 - b)
        print(f"{r:2d} {v:08X}")


if __name__ == "__main__":
    main()
