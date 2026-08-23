#!/usr/bin/env python3
"""Screenshot diff tool for cross-emulator comparison (pure stdlib).

Reads P6 PPMs, computes:
  - exact:  fraction of pixels identical
  - mae:    mean absolute error over RGB (0..255)
  - phash:  Hamming distance between 8x8 average-hash of grayscale (0..64)
  - ncc:    normalized cross-correlation of 30x20 downscaled grayscale (-1..1)
Verdict buckets: IDENTICAL / MINOR / DIFFERENT / MAJOR.

Also converts PPM -> PNG (tiny zlib-based encoder) for reports:
  imgdiff.py topng <in.ppm> <out.png>
  imgdiff.py diff <a.ppm> <b.ppm>        -> prints metrics JSON
"""
import json, struct, sys, zlib


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    if not data.startswith(b'P6'):
        raise ValueError(f'{path}: not P6')
    # header: P6 <w> <h> <max>\n
    parts = data.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    pix = parts[3][: w * h * 3]
    return w, h, pix


def write_png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    def chunk(tag, payload):
        c = tag + payload
        return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def gray(w, h, rgb):
    return [ (rgb[i*3] * 299 + rgb[i*3+1] * 587 + rgb[i*3+2] * 114) // 1000
             for i in range(w * h) ]


def downscale(g, w, h, dw, dh):
    out = []
    for dy in range(dh):
        y0, y1 = dy * h // dh, (dy + 1) * h // dh
        for dx in range(dw):
            x0, x1 = dx * w // dw, (dx + 1) * w // dw
            acc = n = 0
            for y in range(y0, y1):
                row = y * w
                for x in range(x0, x1):
                    acc += g[row + x]; n += 1
            out.append(acc / n)
    return out


def ahash(cells):
    avg = sum(cells) / len(cells)
    return [1 if c > avg else 0 for c in cells]


def metrics(pa, pb):
    wa, ha, a = read_ppm(pa)
    wb, hb, b = read_ppm(pb)
    assert (wa, ha) == (wb, hb), 'size mismatch'
    n = wa * ha
    same = sum(1 for i in range(n)
               if a[i*3:i*3+3] == b[i*3:i*3+3])
    mae = sum(abs(a[i] - b[i]) for i in range(n * 3)) / (n * 3)
    ga, gb = gray(wa, ha, a), gray(wa, ha, b)
    da, db = downscale(ga, wa, ha, 8, 8), downscale(gb, wa, ha, 8, 8)
    ham = sum(x != y for x, y in zip(ahash(da), ahash(db)))
    ca, cb = downscale(ga, wa, ha, 30, 20), downscale(gb, wa, ha, 30, 20)
    ma, mb = sum(ca) / len(ca), sum(cb) / len(cb)
    va = sum((x - ma) ** 2 for x in ca) ** 0.5
    vb = sum((x - mb) ** 2 for x in cb) ** 0.5
    if va < 1e-6 or vb < 1e-6:
        # one side is a flat screen; correlated only if both flat & equal level
        ncc = 1.0 if va < 1e-6 and vb < 1e-6 and abs(ma - mb) < 8 else 0.0
    else:
        ncc = sum((x - ma) * (y - mb) for x, y in zip(ca, cb)) / (va * vb)
    exact = same / n
    # Verdicts lean on perceptual metrics: animation-phase offsets between
    # emulators tank `exact` while the scene is really the same. The average
    # hash is unreliable on low-variance (mostly flat) screens — every cell
    # sits near the mean — so MINOR also accepts a tiny mean absolute error.
    if exact == 1.0:
        verdict = 'IDENTICAL'
    elif exact > 0.995 and mae < 3.0:
        # A handful of differing pixels is never a scene change: ncc is 0
        # when one side is flat, so a blank screen with two stray pixels would
        # otherwise score MAJOR.
        verdict = 'MINOR'
    elif ncc > 0.99 and (ham <= 1 or mae < 3.0):
        verdict = 'MINOR'
    elif ncc > 0.90:
        verdict = 'DIFFERENT'
    else:
        verdict = 'MAJOR'
    return {'exact': round(exact, 4), 'mae': round(mae, 2),
            'phash_hamming': ham, 'ncc': round(ncc, 4), 'verdict': verdict}


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'topng':
        w, h, rgb = read_ppm(sys.argv[2])
        write_png(sys.argv[3], w, h, rgb)
    elif cmd == 'diff':
        print(json.dumps(metrics(sys.argv[2], sys.argv[3])))
    else:
        sys.exit('unknown command')
