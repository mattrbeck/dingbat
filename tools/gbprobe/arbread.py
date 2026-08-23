#!/usr/bin/env python3
"""Read probe (c)'s two staircases off a frame.

    arbread.py <shot.ppm> [first_line] [last_line]

Per scanline it reports two columns:

  band   the BGP band edge: the first column whose colour differs from
         column 0's (where emission had got to when the BGP write landed).
  glit   the start of the glitched run: the first column after the band edge
         whose colour differs from the post-edge colour (the tile the BG
         fetcher was on when LCDC.4 pulsed).

Both carry the halt-wake latency, so only the map from one to the other is
the measurement. `glit` steps in eights (a fetch), `band` in fours (the CPU's
quantum), so a four-dot emission-vs-fetch separation is one step of the finer
staircase.

Colour is compared by equality only: in DMG-compatibility mode the boot ROM
picks the palette, so hues differ between machines while geometry does not.
"""
import sys


def read_ppm(path):
    data = open(path, 'rb').read()
    fields, off = [], 0
    while len(fields) < 4:
        while data[off:off + 1].isspace():
            off += 1
        start = off
        while off < len(data) and not data[off:off + 1].isspace():
            off += 1
        fields.append(data[start:off])
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[off + 1:]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    w, h, rgb = read_ppm(sys.argv[1])
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 32

    def px(x, y):
        i = (y * w + x) * 3
        return rgb[i:i + 3]

    print('line  band  glit  glit-band')
    for y in range(lo, min(hi, h)):
        left = px(0, y)
        band = next((x for x in range(w) if px(x, y) != left), None)
        if band is None:
            print(f'{y:4d}     -     -          -')
            continue
        right = px(band, y)
        glit = next((x for x in range(band, w) if px(x, y) != right), None)
        if glit is None:
            print(f'{y:4d}  {band:4d}     -          -')
        else:
            print(f'{y:4d}  {band:4d}  {glit:4d}  {glit - band:9d}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
