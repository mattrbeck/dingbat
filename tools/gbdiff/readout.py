#!/usr/bin/env python3
"""Read a gambatte test ROM's on-screen result out of a PPM screenshot.

Usage: readout.py <shot.ppm> [--glyphs N] [--ascii]

gambatte's test ROMs render their result as hex glyphs in the top-left corner,
and the expected value is in the ROM's own filename (`..._cgb04c_out3`). This
turns the screenshot back into the value.

The glyphs are the 8x8 tiles at the top-left, drawn as seven-segment figures.
Segments are sampled at fixed positions inside each tile and matched against
the standard seven-segment table; a shape that is not a hex digit is reported
as '?' rather than guessed at, so a misread is visible instead of silent.

--ascii dumps the tile bitmaps as text, which is what to look at when a glyph
comes back '?'.
"""

import sys

W, H = 160, 144

# Standard seven-segment encodings, segment order (a, b, c, d, e, f, g):
#   a = top, b = top-right, c = bottom-right, d = bottom,
#   e = bottom-left, f = top-left, g = middle
SEGMENTS = {
    (1, 1, 1, 1, 1, 1, 0): "0",
    (0, 1, 1, 0, 0, 0, 0): "1",
    (1, 1, 0, 1, 1, 0, 1): "2",
    (1, 1, 1, 1, 0, 0, 1): "3",
    (0, 1, 1, 0, 0, 1, 1): "4",
    (1, 0, 1, 1, 0, 1, 1): "5",
    (1, 0, 1, 1, 1, 1, 1): "6",
    # gambatte's 7 is not drawn as a seven-segment figure at all: it is a top
    # bar and a diagonal stroke down to the left, so the only sample point it
    # lands on is the top bar. No other hex glyph in this font leaves just
    # that, so the signature is unambiguous -- but it does mean a misread here
    # shows up as '?' rather than as the wrong digit. Dump --ascii when one
    # appears.
    (1, 0, 0, 0, 0, 0, 0): "7",
    (1, 1, 1, 0, 0, 0, 0): "7",
    (1, 1, 1, 1, 1, 1, 1): "8",
    (1, 1, 1, 1, 0, 1, 1): "9",
    (1, 1, 1, 0, 1, 1, 1): "A",
    (0, 0, 1, 1, 1, 1, 1): "B",
    (1, 0, 0, 1, 1, 1, 0): "C",
    (0, 1, 1, 1, 1, 0, 1): "D",
    (1, 0, 0, 1, 1, 1, 1): "E",
    (1, 0, 0, 0, 1, 1, 1): "F",
}


def read_ppm(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    if parts[0] != b"P6":
        sys.exit("%s: not a P6 PPM" % path)
    w, h = (int(x) for x in parts[1].split())
    return w, h, parts[3]


def glyphs(path, nglyphs):
    """Decode the first `nglyphs` result glyphs. Importable so a sweep does
    not pay a process spawn per screenshot."""
    w, h, body = read_ppm(path)

    def dark(x, y):
        return body[(y * w + x) * 3] < 0x80

    out = []
    for g in range(nglyphs):
        ox = g * 8
        seg = (dark(ox + 4, 1), dark(ox + 7, 3), dark(ox + 7, 5), dark(ox + 4, 7),
               dark(ox + 1, 5), dark(ox + 1, 3), dark(ox + 4, 4))
        out.append(SEGMENTS.get(tuple(int(s) for s in seg), "?"))
    return "".join(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    nglyphs = 2
    for i, a in enumerate(sys.argv):
        if a == "--glyphs":
            nglyphs = int(sys.argv[i + 1])
    want_ascii = "--ascii" in sys.argv

    if want_ascii:
        w, h, body = read_ppm(path)
        for g in range(nglyphs):
            ox = g * 8
            print("glyph %d:" % g)
            for y in range(9):
                print("  " + "".join(
                    "#" if body[(y * w + ox + x) * 3] < 0x80 else "." for x in range(8)))

    print(glyphs(path, nglyphs))


# Guarded so gambatte_ab.py can import glyphs() without running the CLI.
if __name__ == "__main__":
    main()
