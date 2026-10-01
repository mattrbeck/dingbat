#!/usr/bin/env python3
"""png_text.py SHOT.png [--top]: read back the text a 3D/2D test ROM printed.

The no-library test ROMs (tests/nds/src/3d_common/t3d.c, common2d) print
with a 3x5 font drawn 2x wide into 8x8 cells on the bottom screen. This
reads a 256x384 shot from ndsrun or tools/ndsref (top screen above bottom)
and prints the 32x24 text grid, so register readouts can be compared
between runners as text. Needs only numpy and zlib.
"""
import sys
import zlib

import numpy as np

CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:-!_/,()+=><"
GLYPHS = [
    "... ... ... ... ...",
    "### #.# #.# #.# ###", ".#. ##. .#. .#. ###", "### ..# ### #.. ###", "### ..# ### ..# ###",
    "#.# #.# ### ..# ..#", "### #.. ### ..# ###", "### #.. ### #.# ###", "### ..# ..# ..# ..#",
    "### #.# ### #.# ###", "### #.# ### ..# ###",
    "### #.# ### #.# #.#", "##. #.# ##. #.# ##.", "### #.. #.. #.. ###", "##. #.# #.# #.# ##.",
    "### #.. ### #.. ###", "### #.. ### #.. #..", "### #.. #.# #.# ###", "#.# #.# ### #.# #.#",
    "### .#. .#. .#. ###", "..# ..# ..# #.# ###", "#.# #.# ##. #.# #.#", "#.. #.. #.. #.. ###",
    "#.# ### ### #.# #.#", "##. #.# #.# #.# #.#", "### #.# #.# #.# ###", "### #.# ### #.. #..",
    "### #.# #.# ### ..#", "### #.# ##. #.# #.#", "### #.. ### ..# ###", "### .#. .#. .#. .#.",
    "#.# #.# #.# #.# ###", "#.# #.# #.# #.# .#.", "#.# #.# ### ### #.#", "#.# #.# .#. #.# #.#",
    "#.# #.# .#. .#. .#.", "### ..# .#. #.. ###",
    "... ... ... ... .#.", "... .#. ... .#. ...", "... ... ### ... ...", ".#. .#. .#. ... .#.",
    "... ... ... ... ###", "..# ..# .#. #.. #..", "... ... ... .#. #..", ".#. #.. #.. #.. .#.",
    ".#. ..# ..# ..# .#.", "... .#. ### .#. ...", "... ### ... ### ...", "#.. .#. ..# .#. #..",
    "..# .#. #.. .#. ..#",
]
# O/0 and S/5 share a glyph: the first (the digit) wins, as readouts are hex
LOOKUP = {}
for i, g in enumerate(GLYPHS):
    LOOKUP.setdefault(g.replace(" ", ""), CHARS[i])


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = body[0:4], body[4:8], body[8], body[9]
            w, h = int.from_bytes(w, "big"), int.from_bytes(h, "big")
            assert depth == 8 and ctype in (2, 6), "8-bit RGB/RGBA only"
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = np.zeros((h, stride), dtype=np.int32)
    prev = np.zeros(stride, dtype=np.int32)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = np.frombuffer(raw, dtype=np.uint8, count=stride, offset=y * (stride + 1) + 1).astype(np.int32)
        cur = np.zeros(stride, dtype=np.int32)
        if f == 0:
            cur = line
        elif f == 2:
            cur = (line + prev) & 255
        else:
            for x in range(stride):
                a = cur[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                if f == 1:
                    p = a
                elif f == 3:
                    p = (a + b) >> 1
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[x] = (line[x] + p) & 255
        out[y] = cur
        prev = cur
    return out.reshape(h, w, bpp)[:, :, :3]


def text(img, y0):
    rows = []
    for r in range(24):
        s = ""
        for c in range(32):
            bits = ""
            for gy in range(1, 6):
                for gx in range(3):
                    px = img[y0 + r * 8 + gy, c * 8 + gx * 2 + 1]
                    bits += "#" if px.sum() > 384 else "."
            s += LOOKUP.get(bits, "?")
        rows.append(s.rstrip())
    while rows and not rows[-1]:
        rows.pop()
    return "\n".join(rows)


if __name__ == "__main__":
    img = read_png(sys.argv[1])
    print(text(img, 0 if "--top" in sys.argv else 192))
