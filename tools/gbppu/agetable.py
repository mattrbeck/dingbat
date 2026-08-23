#!/usr/bin/env python3
"""Read an AGE test ROM's own failure table out of a rendered frame.

The Mooneye protocol scores an AGE ROM as one bit (and some never reach the
`LD B,B`), but every AGE ROM draws its result: a "TEST FAILED!" banner over a
table of 8-bit values, one row per 8 offsets, each mismatching cell inverted
(light glyph on dark). This reads that map back:

    dingbat_test <rom> --mode=screenshot --timeout=600 --nosave \
        [--dmg|--cgb] [--model=<tok>] --screenshot=f.ppm
    tools/gbppu/agetable.py f.ppm

Output is one line per table row -- the row's offset label, its eight cells, and
`<` markers under the inverted ones -- plus a summary listing every mismatching
offset.  `--json` emits {offset: {"text":..., "bad":bool}} for scripting a sweep.

Inversion is the majority shade of the 8x8 tile, independent of the glyph;
glyph text is `??` when undecodable.
"""
import json
import sys

W, H = 160, 144
TW, TH = W // 8, H // 8          # 20 x 18 tiles


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a P6 PPM")
    # header: P6 <w> <h> <maxval>, whitespace-separated, comments start with #
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
    px = data[i:]
    return w, h, px


def tile_shades(px, w, tx, ty):
    """The 64 luminances of one 8x8 tile, row-major."""
    out = []
    for y in range(8):
        for x in range(8):
            o = ((ty * 8 + y) * w + tx * 8 + x) * 3
            r, g, b = px[o], px[o + 1], px[o + 2]
            out.append((r * 299 + g * 587 + b * 114) // 1000)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv
    if len(args) != 1:
        raise SystemExit(__doc__.strip().splitlines()[0] + "\nusage: agetable.py <frame.ppm> [--json]")
    w, h, px = read_ppm(args[0])
    if (w, h) != (W, H):
        raise SystemExit(f"expected a {W}x{H} Game Boy frame, got {w}x{h}")

    # Classify every tile as normal (light background) or inverted (dark).
    # The background is the majority shade; a glyph never covers half a cell.
    dark = {}
    for ty in range(TH):
        for tx in range(TW):
            s = tile_shades(px, w, tx, ty)
            s.sort()
            dark[(tx, ty)] = s[len(s) // 2] < 128     # median shade

    # Rows that carry data: AGE lays the table out as a 3-tile offset label,
    # a gap, then eight 2-tile hex cells. Find them by looking for a row whose
    # left three tiles are non-blank and which has content out to the right.
    def blank(tx, ty):
        s = set(tile_shades(px, w, tx, ty))
        return len(s) == 1

    rows = []
    for ty in range(TH):
        if all(blank(tx, ty) for tx in range(TW)):
            continue
        if all(blank(tx, ty) for tx in range(3)):
            continue                                   # banner line
        rows.append(ty)

    bad = []
    lines = []
    for ty in rows:
        cells = []
        for c in range(8):
            tx = 4 + c * 2                             # two tiles per byte
            if tx + 1 >= TW:
                break
            inv = dark[(tx, ty)] or dark[(tx + 1, ty)]
            cells.append(inv)
        marks = "".join(" ^" if c else "  " for c in cells)
        lines.append((ty, cells, marks))
        for c, inv in enumerate(cells):
            if inv:
                bad.append((ty, c))

    if as_json:
        print(json.dumps({"rows": [{"tile_row": ty, "bad_cols": [i for i, c in enumerate(cs) if c]}
                                   for ty, cs, _ in lines],
                          "bad_cells": bad, "bad_count": len(bad)}, indent=2))
        return

    print(f"{args[0]}: {len(rows)} table rows, {len(bad)} mismatching cells")
    for ty, cells, marks in lines:
        flags = "".join("X" if c else "." for c in cells)
        print(f"  tile_row {ty:2d}  cells {flags}")
    if bad:
        print("\nmismatching (tile_row, cell): " + ", ".join(f"({a},{b})" for a, b in bad))
    else:
        print("\nno inverted cells — the ROM drew a clean table")


if __name__ == "__main__":
    main()
