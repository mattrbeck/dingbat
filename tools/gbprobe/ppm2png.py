#!/usr/bin/env python3
"""P6 PPM -> PNG, with no dependency beyond the standard library.

The three engine legs all emit P6 because it is the format every one of them
can write in ten lines and `cmp` can compare directly. PNG exists only so a
frame can be looked at, and so a shot can sit next to a hardware photo in a
results doc.

    ppm2png.py in.ppm out.png [scale]
"""
import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, 'rb').read()
    fields, off = [], 0
    while len(fields) < 4:
        while off < len(data) and data[off:off + 1].isspace():
            off += 1
        if data[off:off + 1] == b'#':
            while data[off:off + 1] not in (b'\n', b''):
                off += 1
            continue
        start = off
        while off < len(data) and not data[off:off + 1].isspace():
            off += 1
        fields.append(data[start:off])
    assert fields[0] == b'P6', fields[0]
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[off + 1:off + 1 + w * h * 3]


def write_png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        return (struct.pack('>I', len(body)) + tag + body +
                struct.pack('>I', zlib.crc32(tag + body) & 0xFFFFFFFF))

    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n' +
        chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
        chunk(b'IDAT', zlib.compress(raw, 9)) +
        chunk(b'IEND', b''))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    w, h, rgb = read_ppm(sys.argv[1])
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    if scale > 1:
        out = bytearray()
        for y in range(h):
            row = bytearray()
            for x in range(w):
                row += rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] * scale
            out += row * scale
        w, h, rgb = w * scale, h * scale, bytes(out)
    write_png(sys.argv[2], w, h, rgb)
    return 0


if __name__ == '__main__':
    sys.exit(main())
