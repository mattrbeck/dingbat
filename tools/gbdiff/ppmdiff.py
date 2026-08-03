#!/usr/bin/env python3
"""Compare two 160x144 P6 PPMs and optionally render them side by side.

Usage: ppmdiff.py <a.ppm> <b.ppm> [--png OUT] [--quiet]

Prints the differing pixel count and the bounding box of the difference, which
is usually enough to classify a divergence without opening an image: a
difference confined to a few scanlines is a timing question, one spread over
the whole screen is a content question, and one that is the whole screen
shifted is a frame-phase question.

With --png, writes a 3-panel image: A, B, and a red mask of the differing
pixels. Written by hand with zlib rather than Pillow, so the harness keeps the
no-third-party-dependency property tools/gbgate/fb2png.py has.
"""

import struct
import sys
import zlib

W, H = 160, 144


def read_ppm(path):
    data = open(path, "rb").read()
    # P6\n<w> <h>\n255\n -- written by our own runners, so the header is fixed
    # form, but parse it rather than assuming a byte offset.
    parts = data.split(b"\n", 3)
    if parts[0] != b"P6":
        sys.exit("%s: not a P6 PPM" % path)
    w, h = (int(x) for x in parts[1].split())
    body = parts[3]
    if len(body) < w * h * 3:
        sys.exit("%s: short body" % path)
    return w, h, body


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, w, h, rows):
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    if len(args) < 2:
        sys.exit(__doc__)
    pa, pb = args[0], args[1]
    png_out = None
    for i, f in enumerate(sys.argv):
        if f == "--png":
            png_out = sys.argv[i + 1]
    quiet = "--quiet" in flags

    wa, ha, a = read_ppm(pa)
    wb, hb, b = read_ppm(pb)
    if (wa, ha) != (wb, hb):
        sys.exit("size mismatch: %dx%d vs %dx%d" % (wa, ha, wb, hb))
    w, h = wa, ha

    ndiff = 0
    x0, y0, x1, y1 = w, h, -1, -1
    diff = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            i = (y * w + x) * 3
            if a[i:i + 3] != b[i:i + 3]:
                ndiff += 1
                diff[y * w + x] = 1
                x0, y0 = min(x0, x), min(y0, y)
                x1, y1 = max(x1, x), max(y1, y)

    if not quiet:
        if ndiff == 0:
            print("IDENTICAL")
        else:
            rows_hit = sorted({i // w for i, v in enumerate(diff) if v})
            print("DIFFERS %d/%d px  bbox x[%d..%d] y[%d..%d]  %d scanlines"
                  % (ndiff, w * h, x0, x1, y0, y1, len(rows_hit)))
            print("scanlines: %s" % (rows_hit if len(rows_hit) <= 24
                                     else "%d..%d (%d)" % (rows_hit[0], rows_hit[-1], len(rows_hit))))

    if png_out:
        gap = 4
        ow = w * 3 + gap * 2
        rows = []
        for y in range(h):
            row = bytearray(b"\x00")
            for panel in range(3):
                for x in range(w):
                    i = (y * w + x) * 3
                    if panel == 0:
                        row += a[i:i + 3]
                    elif panel == 1:
                        row += b[i:i + 3]
                    else:
                        row += (b"\xff\x00\x00" if diff[y * w + x] else a[i:i + 3])
                if panel < 2:
                    row += b"\x20\x20\x20" * gap
            rows.append(bytes(row))
        write_png(png_out, ow, h, rows)
        print(png_out)


main()
