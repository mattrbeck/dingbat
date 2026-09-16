#!/usr/bin/env python3
"""Reads blendprobe-auto.gba in emulators: which candidate patch is flat in
every row, i.e. what each emulator outputs for each colour effect.

  python3 tests/roms/blendprobe_read.py [--emus dingbat,mgba,nba] [--out DIR]

Uses the playtest drivers (tools/playtest/build.sh). Per row it prints the
effect's measured output (read straight from the blended pixels), the
candidate patch whose stripes vanished, and which formulas in
blendprobe_layout.json predicted that value. On a console, the photo gives
the flat patch; this gives the same answer for each emulator to compare.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLAYTEST = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'tools', 'playtest')
sys.path.insert(0, PLAYTEST)
import emu as emulib   # noqa: E402
import img             # noqa: E402


def read_row(frame, row):
    """-> (measured 5-bit output, flat candidate or None, per-patch stripe contrast)"""
    q = img.to555(frame)
    contrasts, blended_vals = [], []
    for p in row['patches']:
        stripe, blend = [], []
        for y in range(p['y'], p['y'] + p['h']):
            for x in range(p['x'], p['x'] + p['w']):
                (stripe if (x - p['x']) % 8 < 4 else blend).append(tuple(q[y, x]))
        # inputs are grey; an output that is not (channels differ) cannot be
        # a 15-bit result of a per-channel formula, so it is reported as RGB
        sv = {c for c in stripe}
        bv = {tuple(int(x) for x in c) for c in blend}
        blended_vals.extend(bv)
        contrasts.append(sum(abs(sum(int(c[i]) for c in stripe) / len(stripe) - sum(int(c[i]) for c in blend) / len(blend))
                             for i in range(3)))
        assert all(int(c[0]) == int(c[1]) == int(c[2]) == p['value'] for c in sv), f"stripe pixels {sv} != candidate {p['value']}"
    measured = sorted({c[0] if c[0] == c[1] == c[2] else c for c in blended_vals}, key=str)
    flat = [p['value'] for p, c in zip(row['patches'], contrasts) if c == 0]
    return measured, (flat[0] if len(flat) == 1 else None), contrasts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emus', default='dingbat,dingbat-bios,mgba,nba')
    ap.add_argument('--out', default=os.path.join(os.environ.get('TMPDIR', '/tmp'), 'blendprobe-read'))
    args = ap.parse_args()
    layout = json.load(open(os.path.join(HERE, 'blendprobe_layout.json')))
    rom = os.path.join(HERE, 'blendprobe-auto.gba')
    per = layout['auto_frames_per_page']
    results = {}
    for name in args.emus.split(','):
        e = emulib.Emulator(name, rom, os.path.join(args.out, name))
        frames = {}
        for page in layout['pages']:
            target = page['page'] * per + per // 2
            e.run(target - e.frame)
            path = os.path.join(args.out, f"{name}-p{page['page']:02}.ppm")
            e.shot(path)
            frames[page['page']] = img.read_ppm(path)
            img.write_png(path[:-4] + '.png', frames[page['page']])
        e.kill()
        results[name] = {}
        for page in layout['pages']:
            for row in page['rows']:
                measured, flat, _ = read_row(frames[page['page']], row)
                results[name][(page['page'], row['label'])] = (measured, flat)

    names = args.emus.split(',')
    for page in layout['pages']:
        print(f"\n== page {page['page']:02} {page['title']}")
        for row in page['rows']:
            cells = []
            for n in names:
                measured, flat = results[n][(page['page'], row['label'])]
                v = measured[0] if len(measured) == 1 else measured
                who = [f for f, pv in row['predict'].items() if pv == v]
                cells.append(f"{n}={v}" + ('' if flat == v else f'(flat {flat}!)') + f" [{','.join(who) or '-'}]")
            print(f"   {row['label']:8} " + '  '.join(cells))


if __name__ == '__main__':
    main()
