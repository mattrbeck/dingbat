#!/usr/bin/env python3
"""Convert a raw dingbat framebuffer dump (DINGBAT_BENCH_DUMP_PATH) to PNG.

The dump is little-endian BGR555, 160x144 for GB/GBC. Written by hand with
zlib rather than Pillow so the gate has no third-party dependency.

Usage: fb2png.py <fb.bin> <out.png> [width] [height]
"""
import struct
import sys
import zlib


def bgr555_to_rgb(v):
    r5, g5, b5 = v & 31, (v >> 5) & 31, (v >> 10) & 31
    return ((r5 << 3) | (r5 >> 2), (g5 << 3) | (g5 >> 2), (b5 << 3) | (b5 >> 2))


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 160
    h = int(sys.argv[4]) if len(sys.argv) > 4 else 144
    raw = open(src, "rb").read()
    px = struct.unpack("<%dH" % (len(raw) // 2), raw)
    if len(px) < w * h:
        sys.exit("short framebuffer: %d pixels, want %d" % (len(px), w * h))
    rows = b"".join(
        b"\x00" + b"".join(bytes(bgr555_to_rgb(px[y * w + x])) for x in range(w))
        for y in range(h))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows, 9))
           + chunk(b"IEND", b""))
    open(dst, "wb").write(png)
    print(dst)


main()
