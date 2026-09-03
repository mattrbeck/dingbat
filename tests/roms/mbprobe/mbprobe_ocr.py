#!/usr/bin/env python3
"""Reads the 20x10 text grid of an mbprobe screen back out of a dingbat
--mode=screenshot PPM (240x160, P6) using build.py's FONT.  Prints the ten
rows; unknown cells print '?'.  For photographs use the layout in
README.md by eye — this only decodes emulator captures.

  python3 mbprobe_ocr.py shot.ppm
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import FONT, glyph_rows                          # noqa: E402


def read_ppm(path):
    data = open(path, "rb").read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1
    assert fields[0] == b"P6", fields
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos:pos + w * h * 3]


def cell_bits(px, w, col, row):
    rows = []
    for gy in range(7):
        v = 0
        for gx in range(5):
            x = col * 12 + gx * 2
            y = row * 16 + gy * 2
            r, g, b = px[(y * w + x) * 3:(y * w + x) * 3 + 3]
            if r + g + b < 3 * 128:
                v |= 0x80 >> gx
        rows.append(v)
    return rows


def decode(path):
    w, h, px = read_ppm(path)
    assert (w, h) == (240, 160), (w, h)
    table = {tuple(glyph_rows(ch)): ch for ch in FONT}
    out = []
    for row in range(10):
        line = ""
        for col in range(20):
            bits = tuple(cell_bits(px, w, col, row))
            line += table.get(bits, "?")
        out.append(line.rstrip())
    return out


if __name__ == "__main__":
    for line in decode(sys.argv[1]):
        print(line)
