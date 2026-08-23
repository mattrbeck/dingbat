#!/usr/bin/env python3
"""Read a probe's hex readout back off a framebuffer.

    readout.py <shot.ppm> <rom.gb> [--sym rom.sym]

The numeric probes paint their results as hex digits so the same reader
works on an emulator frame and on a photowarp'd photo of real hardware. The
glyphs are lifted out of the ROM image (the FontTiles label in the .sym) and
decoded from 2bpp, so the reader cannot disagree with what the ROM drew.

Prints a 20x18 grid of characters, '.' for blank and '?' for unmatched.
"""
import sys


def read_ppm(path):
    data = open(path, 'rb').read()
    fields, off = [], 0
    while len(fields) < 4:
        while data[off:off + 1].isspace():
            off += 1
        if data[off:off + 1] == b'#':
            while data[off:off + 1] not in (b'\n', b''):
                off += 1
            continue
        start = off
        while off < len(data) and not data[off:off + 1].isspace():
            off += 1
        fields.append(data[start:off])
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[off + 1:]


def font_from_rom(rom_path, sym_path):
    addr = None
    for line in open(sym_path):
        parts = line.split()
        if len(parts) >= 2 and parts[1] == 'FontTiles':
            bank, off = parts[0].split(':')
            addr = int(bank, 16) * 0x4000 + (int(off, 16) - (0x4000 if int(bank, 16) else 0))
    if addr is None:
        raise SystemExit('FontTiles not found in ' + sym_path)
    rom = open(rom_path, 'rb').read()
    glyphs = {}
    for d in range(16):
        tile = rom[addr + d * 16:addr + d * 16 + 16]
        mask = []
        for row in range(8):
            lo, hi = tile[row * 2], tile[row * 2 + 1]
            bits = 0
            for x in range(8):
                idx = (((hi >> (7 - x)) & 1) << 1) | ((lo >> (7 - x)) & 1)
                bits = (bits << 1) | (1 if idx >= 2 else 0)
            mask.append(bits)
        glyphs['0123456789ABCDEF'[d]] = tuple(mask)
    return glyphs


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ppm, rom = sys.argv[1], sys.argv[2]
    sym = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == '--sym' else rom[:-3] + '.sym'
    glyphs = font_from_rom(rom, sym)
    w, h, rgb = read_ppm(ppm)

    def ink(x, y):
        i = (y * w + x) * 3
        lum = (rgb[i] * 30 + rgb[i + 1] * 59 + rgb[i + 2] * 11) // 100
        return 1 if lum < 128 else 0

    lines = []
    for ty in range(h // 8):
        row = ''
        for tx in range(w // 8):
            mask = tuple(
                sum(ink(tx * 8 + x, ty * 8 + y) << (7 - x) for x in range(8))
                for y in range(8))
            if not any(mask):
                row += '.'
                continue
            hit = [c for c, g in glyphs.items() if g == mask]
            row += hit[0] if hit else '?'
        lines.append(row)
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())
