#!/usr/bin/env python3
"""read_probe_h -- read a probe_h_* latency page (a 160x144 frame: an engine
PPM, or a photograph put through photowarp.py) into one number per band.

    read_probe_h.py <frame.ppm|frame.png> [scx|scy|lcdc4|lcdc3|wx|bgp]

Without a page name the label row is not decoded (the font is digits only);
the page decides what is measured:

  fetcher pages   the doubled bar: the column of its RIGHT half, per band, and
                  any grey (mid-shade) column, which is a split bitplane read
  wx              the first x of the window (black) per band, or - for none
  bgp             the first black x per band

Bands are the 16 eight-line strips at lines 8 + 8b; the sample line is the
band's third line (clear of the object row on the fetcher pages, inside the
top half of the SCY page's half-tiles). Shades are classified by luma into
white / mid / black, so a CGB frame and a DMG frame read alike.
"""
import struct
import sys
import zlib

W, H = 160, 144


def read_ppm(path):
    data = open(path, 'rb').read()
    fields, off = [], 0
    while len(fields) < 4:
        while data[off:off + 1].isspace():
            off += 1
        if data[off:off + 1] == b'#':
            while data[off:off + 1] not in (b'\n', b''):
                off += 1
            continue
        start = off
        while not data[off:off + 1].isspace():
            off += 1
        fields.append(data[start:off])
    off += 1
    w, h = int(fields[1]), int(fields[2])
    px = data[off:off + w * h * 3]
    return w, h, px


def read_png(path):
    f = open(path, 'rb').read()
    pos, idat, w, h, ct, bd = 8, b'', None, None, None, None
    while pos < len(f):
        ln = struct.unpack('>I', f[pos:pos + 4])[0]
        typ = f[pos + 4:pos + 8]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', f[pos + 8:pos + 18])
        elif typ == b'IDAT':
            idat += f[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    if ct not in (2, 6) or bd != 8:
        raise SystemExit(f'{path}: need 8-bit RGB/RGBA PNG')
    bpp = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    out, prev = bytearray(), bytearray(stride)
    p = 0
    for _ in range(h):
        ft = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        for x in range(w):
            out += line[x * bpp:x * bpp + 3]
        prev = line
    return w, h, bytes(out)


def load(path):
    w, h, px = read_png(path) if path.lower().endswith('.png') else read_ppm(path)
    if (w, h) != (W, H):
        raise SystemExit(f'{path}: {w}x{h}, want {W}x{H} (photowarp.py first)')
    return px


def shade(px, x, y):
    i = (y * W + x) * 3
    luma = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000
    return 0 if luma > 170 else (2 if luma < 85 else 1)


def bands(px, page):
    out = []
    for b in range(16):
        y = 8 + 8 * b + 2
        row = [shade(px, x, y) for x in range(W)]
        if page in ('wx', 'bgp'):
            xs = [x for x in range(8, 152) if row[x] == 2]
            out.append(str(xs[0]) if xs else '-')
            continue
        # fetcher: runs of one shade; the doubled bar is the 16-wide run
        runs, x = [], 0
        while x < W:
            x0 = x
            while x < W and row[x] == row[x0]:
                x += 1
            runs.append((x0, x - x0, row[x0]))
        dbl = [r for r in runs if r[1] >= 12 and 8 <= r[0] and r[0] + r[1] <= 152]
        grey = [r[0] // 8 for r in runs if r[2] == 1 and r[1] >= 4]
        s = ','.join(str((r[0] + r[1]) // 8 - 1) for r in dbl) or '-'
        if grey:
            s += ' grey@' + ','.join(str(g) for g in grey)
        out.append(s)
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    page = sys.argv[2] if len(sys.argv) > 2 else 'scx'
    px = load(sys.argv[1])
    vals = bands(px, page)
    print(' '.join(vals))


if __name__ == '__main__':
    main()
