#!/usr/bin/env python3
"""bandedge.py -- compare the horizontal position of colour transitions between
two 160x144 Game Boy reference frames, row by row.

Built for the 2026-08-10 renderer-structure research (docs/gb-renderer-
structure-research-2026-08-10.md). The question it answers is narrow and it is
worth stating, because the instrument is only valid for that question:

    For a ROM whose frame is horizontal bands produced by a register write at a
    fixed dot of each line, WHERE (in x) does the band edge sit?

Two frames of the SAME ROM on two devices (or one frame against a reference)
can then be differenced without caring that the two use different palettes: we
compare the SET of transition columns per row, not the colours.

Usage:
    bandedge.py A.png B.png [--rows a:b] [--hist]

Output: per-row edge columns for each frame and the modal offset B - A.
"""
import sys
import zlib
import struct
from collections import Counter


def read_ppm(path):
    d = open(path, 'rb').read()
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
    rows = []
    for y in range(h):
        base = i + y * w * 3
        rows.append([tuple(d[base + x * 3:base + x * 3 + 3]) for x in range(w)])
    return w, h, rows


def read_image(path):
    if path.endswith('.ppm'):
        return read_ppm(path)
    return read_png(path)


def read_png(path):
    """Minimal PNG reader: returns (w, h, rows) with rows as lists of RGB
    tuples. Handles 1/2/4/8-bit RGB/RGBA/palette/grey, no interlace."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    pos = 8
    idat = b''
    plte = None
    trns = None
    w = h = depth = ctype = None
    while pos < len(data):
        (ln,) = struct.unpack('>I', data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            assert interlace == 0, 'interlaced PNG unsupported'
        elif typ == b'PLTE':
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif typ == b'tRNS':
            trns = body
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
    raw = zlib.decompress(idat)
    nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    # mealybug's references are 2-bit palette PNGs, so sub-byte depths are not
    # optional here. Unfiltering still works byte-wise; only the unpack differs.
    assert depth in (1, 2, 4, 8), 'unsupported bit depth %d' % depth
    stride = (w * nch * depth + 7) // 8
    bpp = max(1, (nch * depth) // 8)
    out = []
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        prev = line
        row = []
        if depth < 8:
            per = 8 // depth
            mask = (1 << depth) - 1
            vals = []
            for x in range(w):
                byte = line[x // per]
                shift = 8 - depth * (x % per + 1)
                vals.append((byte >> shift) & mask)
            for v in vals:
                if ctype == 3:
                    row.append(plte[v])
                else:
                    g = v * 255 // mask
                    row.append((g, g, g))
        else:
            for x in range(w):
                px = line[x * nch:(x + 1) * nch]
                if ctype == 3:
                    row.append(plte[px[0]])
                elif ctype in (0, 4):
                    row.append((px[0], px[0], px[0]))
                else:
                    row.append((px[0], px[1], px[2]))
        out.append(row)
    return w, h, out


def edges(row):
    """Columns x where row[x] != row[x-1]."""
    return [x for x in range(1, len(row)) if row[x] != row[x - 1]]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    if len(args) < 2:
        print(__doc__)
        return 2
    rows_sel = None
    for f in flags:
        if f.startswith('--rows'):
            a, b = f.split('=', 1)[1].split(':')
            rows_sel = (int(a), int(b))
    wa, ha, ra = read_image(args[0])
    wb, hb, rb = read_image(args[1])
    print('A %s  %dx%d' % (args[0], wa, ha))
    print('B %s  %dx%d' % (args[1], wb, hb))
    lo, hi = rows_sel if rows_sel else (0, min(ha, hb))
    deltas = Counter()
    for y in range(lo, hi):
        ea, eb = edges(ra[y]), edges(rb[y])
        mark = ''
        if len(ea) == len(eb) and ea:
            d = [q - p for p, q in zip(ea, eb)]
            if len(set(d)) == 1:
                deltas[d[0]] += len(d)
                mark = '  delta %+d' % d[0]
            else:
                mark = '  mixed %s' % d
                for v in d:
                    deltas[v] += 1
        elif len(ea) != len(eb):
            mark = '  STRUCTURE (%d vs %d edges)' % (len(ea), len(eb))
        if '--quiet' not in flags:
            print('y=%3d  A%-28s B%-28s%s'
                  % (y, str(ea[:8]), str(eb[:8]), mark))
    print('\nmodal edge offset B-A:')
    for d, n in sorted(deltas.items()):
        print('  %+d dots : %d edges' % (d, n))
    return 0


if __name__ == '__main__':
    sys.exit(main())
