#!/usr/bin/env python3
"""Dump cgb-acid-hell's disputed neighbourhood side by side.

    tools/gbppu/hellpx.py <dingbat.ppm> <reference.png> [x0 x1 y0 y1]

Prints the block around the disputed pixels from both frames as palette
indices: a horizontal phase error and a swapped pair of scanlines both count
as "2 px" and only the shape tells them apart.
"""
import sys, zlib, struct


def read_ppm(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        parts.append(d[i:j])
        i = j
    w, h = int(parts[1]), int(parts[2])
    px = d[i + 1:]
    return w, h, [[tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3])
                   for x in range(w)] for y in range(h)]


def read_png(p):
    d = open(p, 'rb').read()
    pos, idat, pal = 8, b'', []
    w = h = depth = ctype = 0
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
        elif typ == b'PLTE':
            pal = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif typ == b'IDAT':
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype] * (depth // 8 or 1)
    stride = (w * (depth if ctype == 3 else depth * 3) + 7) // 8
    out, prev, o = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[o]; o += 1
        line = bytearray(raw[o:o + stride]); o += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        row = []
        for x in range(w):
            if ctype == 3:
                per = 8 // depth
                v = (line[x // per] >> (8 - depth * (x % per + 1))) & ((1 << depth) - 1)
                row.append(pal[v])
            else:
                row.append(tuple(line[x * 3:x * 3 + 3]))
        out.append(row)
    return w, h, out


def main():
    _, _, A = read_ppm(sys.argv[1])
    _, _, B = read_png(sys.argv[2])
    x0, x1, y0, y1 = (map(int, sys.argv[3:7]) if len(sys.argv) > 6
                      else (74, 90, 64, 74))
    keys, names = {}, "abcdefghijklmnopqrstuvwxyz"
    def k(c):
        if c not in keys:
            keys[c] = names[len(keys)]
        return keys[c]
    print("      " + "".join(str(x % 10) for x in range(x0, x1)))
    for y in range(y0, y1):
        a = "".join(k(A[y][x]) for x in range(x0, x1))
        b = "".join(k(B[y][x]) for x in range(x0, x1))
        mark = "  <<<" if a != b else ""
        print("ly%3d %s   ref %s%s" % (y, a, b, mark))
    print("legend: " + "  ".join("%s=%s" % (v, c) for c, v in keys.items()))


main()
