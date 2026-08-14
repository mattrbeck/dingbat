#!/usr/bin/env python3
"""Count wrong pixels between a reference PNG and a dingbat `--screenshot` PPM.

    tools/gbppu/pngdiff.py <ref.png> <shot.ppm> [label]

Channels are masked to 0xF8 before comparing, which is what a BGR555
framebuffer actually carries and what the runner's own screenshot rows compare
(see tests/README.md). Pure stdlib so it runs anywhere the suite does; it is
the one-row equivalent of the runner's screenshot mode, for sweeping a build
against a single pixel witness without regenerating any results file.
"""
import sys, zlib, struct


def read_png(p):
    d = open(p, 'rb').read()
    i = 8
    w = h = bd = ct = 0
    idat = b''
    pal = None
    while i < len(d):
        n = struct.unpack('>I', d[i:i + 4])[0]
        t = d[i + 4:i + 8]
        b = d[i + 8:i + 8 + n]
        if t == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', b[:10])
        elif t == b'PLTE':
            pal = b
        elif t == b'IDAT':
            idat += b
        i += 12 + n
    raw = zlib.decompress(idat)
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = max(1, chans * bd // 8)
    stride = (w * chans * bd + 7) // 8
    out = []
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        ln = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = ln[x - bpp] if x >= bpp else 0
            bb = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: ln[x] = (ln[x] + a) & 255
            elif f == 2: ln[x] = (ln[x] + bb) & 255
            elif f == 3: ln[x] = (ln[x] + (a + bb) // 2) & 255
            elif f == 4:
                pp = a + bb - c
                pa, pb, pc = abs(pp - a), abs(pp - bb), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (bb if pb <= pc else c)
                ln[x] = (ln[x] + pr) & 255
        prev = ln
        row = []
        for x in range(w):
            if ct == 3:
                if bd == 8:
                    idx = ln[x]
                else:
                    per = 8 // bd
                    idx = (ln[x // per] >> (8 - bd * (x % per + 1))) & ((1 << bd) - 1)
                row.append(tuple(pal[idx * 3:idx * 3 + 3]))
            elif ct == 2: row.append(tuple(ln[x * 3:x * 3 + 3]))
            elif ct == 6: row.append(tuple(ln[x * 4:x * 4 + 3]))
            else: row.append((ln[x],) * 3)
        out.append(row)
    return w, h, out


def read_ppm(p):
    d = open(p, 'rb').read()
    tok = []
    i = 0
    while len(tok) < 4:
        while d[i:i + 1].isspace(): i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n': i += 1
            continue
        j = i
        while not d[j:j + 1].isspace(): j += 1
        tok.append(d[i:j])
        i = j
    i += 1
    w, h = int(tok[1]), int(tok[2])
    px = d[i:]
    return w, h, [[tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3])
                   for x in range(w)] for y in range(h)]


def main():
    label = sys.argv[3] if len(sys.argv) > 3 else ""
    try:
        w1, h1, a = read_png(sys.argv[1])
        w2, h2, b = read_ppm(sys.argv[2])
    except Exception as e:
        print("%-8s ERROR %s" % (label, e))
        return
    n = 0
    for y in range(min(h1, h2)):
        for x in range(min(w1, w2)):
            if tuple(c & 0xF8 for c in a[y][x]) != tuple(c & 0xF8 for c in b[y][x]):
                n += 1
    print("%-8s %d wrong pixels of %d" % (label, n, w1 * h1))


main()
