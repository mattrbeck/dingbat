#!/usr/bin/env python3
"""Builds blendprobe.gba (+ blendprobe-auto.gba) — measures the GBA colour
special effects (alpha blend, brighten, darken) to the exact 5-bit output
value, readable from a photograph.

Why a nulling picture instead of colour swatches: rounding hypotheses for
these effects disagree by ONE 5-bit step, which a photo cannot resolve as an
absolute colour. So every measurement is a patch of vertical 4-pixel stripes
that alternates two things on the same screen:
  - the effect's OUTPUT: BG0 (1st target) over BG1 (2nd target), blended by
    the hardware, and
  - a CANDIDATE value drawn raw by BG2 (above BG0, not a target, so never
    blended).
Each measurement repeats the patch for a run of consecutive candidate values.
In the patch whose candidate equals the hardware's output the stripes
vanish into a flat block; its neighbours, one step off, show faint bars.
A photo only has to say which patch is flat, and the number printed under it
IS the output value. The CONTROL page (no effect) shows what a flat patch and
a one-step stripe look like on the photographing console.

All colours are greys (R=G=B), so a one-step difference moves all three
channels together, the most visible change.

Pages (RIGHT/A next, LEFT/B previous; the -auto build flips every 64 frames):
  CONTROL  raw stripes: level v next to v, v+1, v+2 (visibility calibration)
  ALPHA    EVA/EVB = 7/9 (sum 16), 5/6 (sum 11), 11/9 (sum 20), 20/0
           (a coefficient above 16)
  DARKEN   EVY = 7, 3, 11
  BRIGHTEN EVY = 7, 3, 11
Rows on each page are chosen so the candidate formulas listed in
blendprobe_layout.json predict different values; the picture does not
depend on any of them being right (candidates cover a contiguous range
around every prediction).

Emulator side: `python3 tests/roms/blendprobe_read.py` runs the -auto build
in the playtest drivers and reads each row's flat patch.

Requires arm-none-eabi-{as,ld,objcopy} and gbafix (see romfix.py).
"""
import itertools
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbedge import FONT_ORDER, font_1bpp, tile_of   # noqa: E402
import romfix                                        # noqa: E402

VERSION = 1


# ─────────────────────────── candidate formulas ───────────────────────────
# Per 5-bit channel. These only choose informative rows and label the
# analysis; the ROM measures whatever the hardware does.
def c16(e):
    return min(16, e)


ALPHA = {
    'term-trunc': lambda t, b, ea, eb: min(31, (t * c16(ea) >> 4) + (b * c16(eb) >> 4)),
    'sum-trunc': lambda t, b, ea, eb: min(31, (t * c16(ea) + b * c16(eb)) >> 4),
    'sum-round': lambda t, b, ea, eb: min(31, (t * c16(ea) + b * c16(eb) + 8) >> 4),
    'unclamped-coef': lambda t, b, ea, eb: min(31, (t * ea + b * eb) >> 4),
}
DARKEN = {
    'sub-trunc': lambda t, y: t - (t * c16(y) >> 4),
    'mul-trunc': lambda t, y: t * (16 - c16(y)) >> 4,
    'sub-round': lambda t, y: t - ((t * c16(y) + 8) >> 4),
    'mul-round': lambda t, y: (t * (16 - c16(y)) + 8) >> 4,
}
BRIGHTEN = {
    'add-trunc': lambda t, y: t + ((31 - t) * c16(y) >> 4),
    'mul-trunc': lambda t, y: (t * (16 - c16(y)) + 31 * c16(y)) >> 4,
    'add-round': lambda t, y: t + (((31 - t) * c16(y) + 8) >> 4),
    'mul-round': lambda t, y: (t * (16 - c16(y)) + 31 * c16(y) + 8) >> 4,
}

ROWS_PER_PAGE = 4
MAX_CANDIDATES = 5


def choose_rows(inputs, predict):
    """Greedy: rows that split the most still-unsplit formula pairs, then
    the widest spread, preferring mid-range levels (easier on a photo)."""
    names = list(predict(inputs[0]).keys())
    unsplit = set(itertools.combinations(names, 2))
    rows, patterns, tops = [], set(), set()
    for _ in range(ROWS_PER_PAGE):
        best = None
        for inp in inputs:
            if inp in rows:
                continue
            p = predict(inp)
            vals = set(p.values())
            # candidates are a contiguous run from min-1 to max+1
            if max(vals) - min(vals) + 3 > MAX_CANDIDATES:
                continue
            split = sum(1 for a, b in unsplit if p[a] != p[b])
            # which formulas agree with which: a new grouping is new evidence
            pattern = tuple(sorted(tuple(n for n in names if p[n] == v) for v in vals))
            new = pattern not in patterns
            mid = -abs(sum(vals) / len(vals) - 16)
            key = (split, new, len(vals), inp[0] not in tops, mid)
            if best is None or key > best[0]:
                best = (key, inp, pattern)
        if best is None:
            break
        rows.append(best[1])
        patterns.add(best[2])
        tops.add(best[1][0])
        p = predict(best[1])
        unsplit = {(a, b) for a, b in unsplit if p[a] == p[b]}
    return rows


def candidates_for(pred):
    vals = sorted(set(pred.values()))
    lo, hi = max(0, vals[0] - 1), min(31, vals[-1] + 1)
    return list(range(lo, hi + 1))


def build_pages():
    pages = [{
        'name': 'CONTROL', 'title': 'CONTROL NO EFFECT', 'bldcnt': 0, 'bldalpha': 0, 'bldy': 0,
        'rows': [{'label': f'V{v:02}', 'top': v, 'bottom': 0,
                  'candidates': [v, v + 1, v + 2], 'predict': {'raw': v}} for v in (6, 14, 22, 28)],
    }]
    levels = range(32)
    for ea, eb in ((7, 9), (5, 6), (11, 9), (20, 0)):
        funcs = dict(ALPHA)
        if max(ea, eb) <= 16:
            del funcs['unclamped-coef']

        def pred(inp, ea=ea, eb=eb, funcs=funcs):
            t, b = inp
            return {n: f(t, b, ea, eb) for n, f in funcs.items()}
        rows = choose_rows([(t, b) for t in levels for b in levels], pred)
        pages.append({
            'name': f'ALPHA{ea}-{eb}', 'title': f'ALPHA EVA {ea:02} EVB {eb:02}',
            'bldcnt': 0x0241, 'bldalpha': ea | (eb << 8), 'bldy': 0,
            'rows': [{'label': f'T{t:02} B{b:02}', 'top': t, 'bottom': b,
                      'candidates': candidates_for(pred((t, b))), 'predict': pred((t, b))} for t, b in rows],
        })
    for mode, funcs, bldcnt in (('DARKEN', DARKEN, 0x00C1), ('BRIGHTEN', BRIGHTEN, 0x0081)):
        for y in (7, 3, 11):
            def pred(inp, y=y, funcs=funcs):
                return {n: f(inp[0], y) for n, f in funcs.items()}
            rows = choose_rows([(t,) for t in levels], pred)
            pages.append({
                'name': f'{mode}{y}', 'title': f'{mode} EVY {y:02}',
                'bldcnt': bldcnt, 'bldalpha': 0, 'bldy': y,
                'rows': [{'label': f'T{t:02}', 'top': t, 'bottom': 0,
                          'candidates': candidates_for(pred((t,))), 'predict': pred((t,))} for (t,) in rows],
            })
    return pages


# ─────────────────────────────── layout ───────────────────────────────────
# 8x8 tiles, 30x20 visible. Row i: patches on tile rows 2+4i .. 4+4i, the
# value printed on tile row 5+4i; the row label at tile x 0-6; patch k at
# tile x 8+4k (3 tiles = 24px wide, 3 stripe periods).
TRANSPARENT, BACKDROP = 0, 0


def gray_index(v):
    return 1 + v                       # palette 1..32 = grey levels 0..31


WHITE = gray_index(31)
PATCH_W, PATCH_H = 3, 3


class TileSet:
    def __init__(self):
        self.tiles = [bytes(64)]
        self.index = {bytes(64): 0}

    def add(self, data):
        data = bytes(data)
        if data not in self.index:
            self.index[data] = len(self.tiles)
            self.tiles.append(data)
        return self.index[data]


def solid(v):
    return bytes([gray_index(v)] * 64)


def stripe(v):
    row = bytes([gray_index(v)] * 4 + [TRANSPARENT] * 4)
    return row * 8


def glyph_tiles():
    fd = font_1bpp()
    out = {}
    for i, ch in enumerate(FONT_ORDER):
        data = bytearray()
        for y in range(8):
            bits = fd[i * 8 + y]
            for x in range(8):
                data.append(WHITE if bits & (0x80 >> x) else TRANSPARENT)
        out[ch] = bytes(data)
    return out


def render(pages):
    ts = TileSet()
    glyphs = glyph_tiles()
    maps = []
    layout = []
    for pn, page in enumerate(pages):
        bg = [[[0] * 32 for _ in range(32)] for _ in range(4)]     # BG0..BG3

        def text(x, y, s):
            for k, ch in enumerate(s):
                bg[3][y][x + k] = ts.add(glyphs[ch])
        text(1, 0, page['title'])
        rows_out = []
        for i, row in enumerate(page['rows']):
            ty = 2 + 4 * i
            text(0, ty + 1, row['label'])
            patches = []
            for k, c in enumerate(row['candidates']):
                tx = 8 + 4 * k
                for dy in range(PATCH_H):
                    for dx in range(PATCH_W):
                        bg[0][ty + dy][tx + dx] = ts.add(solid(row['top']))
                        bg[1][ty + dy][tx + dx] = ts.add(solid(row['bottom']))
                        bg[2][ty + dy][tx + dx] = ts.add(stripe(c))
                text(tx, ty + PATCH_H, f'{c:02}')
                patches.append({'value': c, 'x': tx * 8, 'y': ty * 8, 'w': PATCH_W * 8, 'h': PATCH_H * 8})
            rows_out.append({**row, 'patches': patches})
        text(0, 19, f'BLENDPROBE V{VERSION} PG {pn:02}/{len(pages) - 1:02}')
        maps.append(bg)
        layout.append({'page': pn, 'name': page['name'], 'title': page['title'],
                       'bldcnt': page['bldcnt'], 'bldalpha': page['bldalpha'], 'bldy': page['bldy'],
                       'rows': rows_out})
    return ts, maps, layout


def palette():
    pal = [0] * 256
    pal[0] = 2 | (2 << 5) | (6 << 10)              # backdrop: dark blue
    for v in range(32):
        pal[gray_index(v)] = v | (v << 5) | (v << 10)
    return pal


def gen_inc(ts, maps, pages):
    out = ['.align 2', 'palette_data:']
    pal = palette()
    for i in range(0, 256, 8):
        out.append('    .hword ' + ','.join(f'0x{c:04X}' for c in pal[i:i + 8]))
    out += ['.align 2', 'tile_data:']
    for t in ts.tiles:
        out.append('    .byte ' + ','.join(str(b) for b in t))
    for pn, bg in enumerate(maps):
        for layer in range(4):
            out += ['.align 2', f'map_{pn}_{layer}:']
            for row in bg[layer]:
                out.append('    .hword ' + ','.join(str(v) for v in row))
    out += ['.align 2', 'page_table:']
    for pn, page in enumerate(pages):
        out.append(f'    .word map_{pn}_0, map_{pn}_1, map_{pn}_2, map_{pn}_3')
        out.append(f"    .hword 0x{page['bldcnt']:04X}, 0x{page['bldalpha']:04X}, 0x{page['bldy']:04X}, 0")
    return '\n'.join(out) + '\n'


def build(auto, inc_path):
    out = 'blendprobe-auto' if auto else 'blendprobe'
    defs = ['--defsym', 'AUTOPAGE=1'] if auto else []
    o, elf, gba = (os.path.join(HERE, out + ext) for ext in ('.o', '.elf', '.gba'))
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', *defs, '-I', HERE,
                    '-o', o, os.path.join(HERE, 'blendprobe.s')], check=True, cwd=HERE)
    subprocess.run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', elf, o], check=True, cwd=HERE)
    subprocess.run(['arm-none-eabi-objcopy', '-O', 'binary', elf, gba], check=True, cwd=HERE)
    rom = bytearray(open(gba, 'rb').read())
    rom[0xA0:0xAC] = b'BLENDPROBE\0\0'
    rom[0xAC:0xB0] = b'ABLE'
    rom[0xB0:0xB2] = b'01'
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    open(gba, 'wb').write(rom)
    romfix.gba_logo(gba)
    os.unlink(o)
    os.unlink(elf)
    print(f'{gba}: {len(rom)} bytes')


def main():
    pages = build_pages()
    ts, maps, layout = render(pages)
    assert len(ts.tiles) <= 512, len(ts.tiles)
    inc = os.path.join(HERE, 'blendprobe_gen.inc')
    with open(inc, 'w') as f:
        f.write(gen_inc(ts, maps, pages))
    with open(os.path.join(HERE, 'blendprobe_equ.inc'), 'w') as f:
        f.write(f'.equ NPAGES, {len(pages)}\n.equ NTILES, {len(ts.tiles)}\n')
    with open(os.path.join(HERE, 'blendprobe_layout.json'), 'w') as f:
        json.dump({'version': VERSION, 'auto_frames_per_page': 64, 'pages': layout}, f, indent=1)
    build(False, inc)
    build(True, inc)
    for p in layout:
        print(f"page {p['page']:02} {p['title']}: " +
              '; '.join(f"{r['label']} -> {r['candidates']}" for r in p['rows']))


if __name__ == '__main__':
    main()
