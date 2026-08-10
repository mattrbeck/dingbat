#!/usr/bin/env python3
"""Exact OCR for gbedge/gbaedge screenshots: matches 8x8 cells against the
generator's own font bitmaps.  Usage: ocr.py <shot.ppm> [shot2.ppm ...]"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gbedge import GLYPHS, FONT_ORDER


def glyph_bitmap(ch):
    rows = []
    for y in range(8):
        bits = 0
        if ch != " " and y < 7:
            for x, c in enumerate(GLYPHS[ch][y]):
                if c == "1":
                    bits |= 0x80 >> (x + 1)
        rows.append(bits)
    return tuple(rows)


BITMAPS = {glyph_bitmap(ch): ch for ch in FONT_ORDER}


def read_ppm(path):
    data = open(path, "rb").read()
    toks = []
    i = 0
    while len(toks) < 4:
        while i < len(data) and data[i:i+1].isspace():
            i += 1
        if data[i:i+1] == b"#":
            while data[i:i+1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j+1].isspace():
            j += 1
        toks.append(data[i:j])
        i = j
    assert toks[0] == b"P6", toks
    w, h = int(toks[1]), int(toks[2])
    body = data[i+1:]
    return w, h, body


def main(path):
    w, h, body = read_ppm(path)
    def lum(x, y):
        o = 3 * (y * w + x)
        return body[o] + body[o+1] + body[o+2]
    # threshold: darker than midpoint = ink
    thr = (max(lum(x, y) for y in range(h) for x in range(0, w, 7)) +
           min(lum(x, y) for y in range(h) for x in range(0, w, 7))) // 2
    print(f"== {path} ({w}x{h})")
    for row in range(h // 8):
        line = ""
        for col in range(w // 8):
            rows = []
            for y in range(8):
                bits = 0
                for x in range(8):
                    if lum(col * 8 + x, row * 8 + y) < thr:
                        bits |= 0x80 >> x
                rows.append(bits)
            line += BITMAPS.get(tuple(rows), "?")
        print(line.rstrip())
    print()


for pth in sys.argv[1:]:
    main(pth)
