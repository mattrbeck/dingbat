#!/usr/bin/env python3
"""Decode an AGE test ROM's result table -- offsets, values, and mismatches
(agetable.py gives the inversion map only; this adds the values).

    dingbat_test <rom> --mode=screenshot --timeout=600 --nosave \
        [--dmg|--cgb] [--model=<tok>] --screenshot=f.ppm
    tools/gbppu/agecells.py f.ppm [--json]

AGE's font is a 5x7 cell drawn one pixel below the tile row; label digits at
x = 2, 10, 18, value digits at a 16-pixel pitch per byte with the two digits
6 apart. The first non-blank tile row is the "TEST FAILED!" banner (its left
three tiles are blank) and is skipped. Inversion is read from the cell's
background shade, so the mismatch map survives an undecodable glyph.
"""
import json
import sys

W, H = 160, 144
LABEL_X = (2, 10, 18)
VAL_X = tuple(34 + 16 * i + 6 * j for i in range(8) for j in range(2))

# The font, as the 7 scanlines of a 5-pixel-wide cell, MSB left. The Nth data
# row is labelled N*8, so label glyphs can be learned from the frame, but a
# one-row table teaches only "000"; the pinned set wins and learned glyphs are
# the fallback. A, B, C absent: no AGE table seen prints one.
GLYPHS = {
    "0": "01110110111101111011110111101101110",
    "1": "00110011100011000110001100011000110",
    "2": "11110000110001101110110001100011111",
    "3": "11110000110001101110000110001111110",
    "4": "00011001110101110011111110001100011",
    "5": "11110100001111000011000110001111110",
    "6": "01110110001111011011110111101101110",
    "7": "11111000110011000110011000110001100",
    "8": "01110110111101101110110111101101110",
    "9": "01110110111101111011011110001101110",
    "D": "11110110111101111011110111101111110",
    "E": "11111110001111011000110001100011111",
    "F": "11111110001111011000110001100011000",
}


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a P6 PPM")
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while data[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    w, h, _ = fields
    return w, h, data[i:]


def tile_lum(px, w, tx, ty):
    out = []
    for y in range(8):
        for x in range(8):
            o = ((ty * 8 + y) * w + tx * 8 + x) * 3
            r, g, b = px[o], px[o + 1], px[o + 2]
            out.append((r * 299 + g * 587 + b * 114) // 1000)
    return out


class Frame:
    def __init__(self, path):
        self.w, self.h, self.px = read_ppm(path)
        if (self.w, self.h) != (W, H):
            raise SystemExit(f"expected {W}x{H}, got {self.w}x{self.h}")
        self.bg = {}
        self.rows = []
        for ty in range(self.h // 8):
            shades = [sorted(tile_lum(self.px, self.w, tx, ty))
                      for tx in range(self.w // 8)]
            self.bg[ty] = [s[32] for s in shades]
            if all(s[0] == s[-1] for s in shades):
                continue                      # blank line
            if all(shades[tx][0] == shades[tx][-1] for tx in range(3)):
                continue                      # banner: no offset label
            self.rows.append(ty)

    def bits(self, ty, x0):
        out = []
        for y in range(1, 8):
            for x in range(x0, x0 + 5):
                o = ((ty * 8 + y) * self.w + x) * 3
                out.append(1 if abs(self.px[o] - self.bg[ty][x // 8]) > 40 else 0)
        return "".join(str(b) for b in out)

    def inverted(self, ty, tx):
        return self.bg[ty][tx] < 128


def decode(path):
    f = Frame(path)
    book = {v: k for k, v in GLYPHS.items()}
    for n, ty in enumerate(f.rows):
        label = "%03X" % (n * 8)
        for k, x0 in enumerate(LABEL_X):
            book.setdefault(f.bits(ty, x0), label[k])
    cells = []
    for n, ty in enumerate(f.rows):
        for c in range(8):
            x0, x1 = VAL_X[2 * c], VAL_X[2 * c + 1]
            val = book.get(f.bits(ty, x0), "?") + book.get(f.bits(ty, x1), "?")
            bad = f.inverted(ty, x0 // 8) or f.inverted(ty, x1 // 8)
            cells.append({"offset": n * 8 + c, "value": val, "bad": bad})
    return cells


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        raise SystemExit("usage: agecells.py <frame.ppm> [--json]")
    cells = decode(args[0])
    if "--json" in sys.argv:
        print(json.dumps({"cells": cells,
                          "bad_count": sum(1 for c in cells if c["bad"]),
                          "total": len(cells)}))
        return
    bad = [c for c in cells if c["bad"]]
    print(f"{args[0]}: {len(cells)} cells, {len(bad)} mismatching")
    for n in range(len(cells) // 8):
        row = cells[n * 8 : n * 8 + 8]
        print(f"  {n*8:03X}  " +
              " ".join(c["value"] + ("*" if c["bad"] else " ") for c in row))
    if bad:
        print("\nmismatching offsets: " +
              ", ".join(f"{c['offset']:03X}={c['value']}" for c in bad))


if __name__ == "__main__":
    main()
