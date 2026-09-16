#!/usr/bin/env python3
"""Reads blendprobe.gba photographs: for every row, how striped each
candidate patch is, and which one is flat.

  python3 tests/roms/blendprobe_photo.py PHOTO_PAGE00 PHOTO_PAGE01 ... PHOTO_PAGE10

One photo per page, in page order (HEIC/JPEG/PNG; converted with macOS
`sips`). The screen is located from the blue backdrop's four corners and
mapped with a homography, so a photo taken slightly off-axis is fine; each
patch is sampled across its inner 16 pixels (two stripe periods) and the
stripe amplitude is the magnitude of the profile's 8-pixel-period component,
which does not depend on exactly where the columns land. The flat patch has
an amplitude near 0; neighbours one step off sit well above it (page 00, the
control, shows the scale for that console and camera).
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def read_bmp(path):
    b = open(path, 'rb').read()
    off = struct.unpack_from('<I', b, 10)[0]
    w, h = struct.unpack_from('<ii', b, 18)
    ch = struct.unpack_from('<H', b, 28)[0] // 8
    row = (w * ch + 3) & ~3
    a = np.frombuffer(b, dtype=np.uint8, offset=off, count=row * abs(h)).reshape(abs(h), row)[:, :w * ch]
    a = a.reshape(abs(h), w, ch)[:, :, :3][:, :, ::-1]
    return (a[::-1] if h > 0 else a).astype(np.float32)


def homography(src, dst):
    rows = []
    for (x, y), (u, v) in zip(src, dst):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    return np.linalg.svd(np.array(rows))[2][-1].reshape(3, 3)


def screen_corners(img):
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    ys, xs = np.nonzero((b > r + 25) & (b > g + 20) & (b > 40))
    s, d = xs + ys, xs - ys
    return ((xs[s.argmin()], ys[s.argmin()]), (xs[d.argmax()], ys[d.argmax()]),
            (xs[d.argmin()], ys[d.argmin()]), (xs[s.argmax()], ys[s.argmax()]))


def stripe_amplitude(lum, H, patch):
    def at(x, y):
        p = H @ np.array([x, y, 1.0])
        return int(round(p[1] / p[2])), int(round(p[0] / p[2]))
    xs = np.arange(patch['x'] + 4, patch['x'] + 20, 0.25) + 0.125
    ys = np.arange(patch['y'] + 4, patch['y'] + patch['h'] - 4, 1.0) + 0.5
    prof = np.array([np.mean([lum[at(x, y)] for y in ys]) for x in xs])
    return float(abs(np.sum((prof - prof.mean()) * np.exp(-2j * np.pi * xs / 8))) * 2 / len(prof))


def main():
    photos = sys.argv[1:]
    layout = json.load(open(os.path.join(HERE, 'blendprobe_layout.json')))
    if len(photos) != len(layout['pages']):
        sys.exit(f"need {len(layout['pages'])} photos, one per page in order")
    tmp = tempfile.mkdtemp()
    for page, photo in zip(layout['pages'], photos):
        bmp = os.path.join(tmp, f"p{page['page']}.bmp")
        subprocess.run(['sips', '-s', 'format', 'bmp', photo, '--out', bmp], check=True, capture_output=True)
        img = read_bmp(bmp)
        tl, tr, bl, br = screen_corners(img)
        H = homography([(0, 0), (240, 0), (0, 160), (240, 160)], [tl, tr, bl, br])
        lum = img.mean(axis=2)
        print(f"page {page['page']:02} {page['title']}  ({os.path.basename(photo)})")
        for row in page['rows']:
            amps = [(p['value'], stripe_amplitude(lum, H, p)) for p in row['patches']]
            flat = min(amps, key=lambda a: a[1])
            second = sorted(a[1] for a in amps)[1] if len(amps) > 1 else 0
            match = sorted(n for n, v in row['predict'].items() if v == flat[0])
            print(f"  {row['label']:8} flat {flat[0]:2}  margin {second - flat[1]:5.1f}  [" +
                  '  '.join(f'{v}:{a:.1f}' for v, a in amps) + f"]  {','.join(match) or '-'}")


if __name__ == '__main__':
    main()
