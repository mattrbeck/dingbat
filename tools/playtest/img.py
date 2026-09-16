"""Frame I/O and comparison for the playtest harness (numpy + stdlib only).

Frames are compared at the GBA's native 15-bit colour depth (every driver
writes 5-bit channels expanded the same way), so an exact match is exact.
"""
import struct
import zlib

import numpy as np

W, H = 240, 160


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    # header: P6\n<w> <h>\n255\n
    parts = data.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    pixels = parts[4] if len(parts[4]) == w * h * 3 else data[-w * h * 3:]
    return np.frombuffer(pixels, dtype=np.uint8).reshape(h, w, 3)


def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw = b''.join(b'\x00' + rgb[y].tobytes() for y in range(h))

    def chunk(tag, body):
        c = tag + body
        return struct.pack('>I', len(body)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def upscale(rgb, k):
    return np.repeat(np.repeat(rgb, k, axis=0), k, axis=1)


# 3x5 digit/letter glyphs for composite captions (enough for emulator names)
_GLYPHS = {
    'a': '010101111101101', 'b': '110101110101110', 'c': '011100100100011',
    'd': '110101101101110', 'e': '111100110100111', 'f': '111100110100100',
    'g': '011100101101011', 'h': '101101111101101', 'i': '111010010010111',
    'k': '101101110101101', 'l': '100100100100111', 'm': '101111111101101',
    'n': '110101101101101', 'o': '010101101101010', 'p': '110101110100100',
    'r': '110101110101101', 's': '011100010001110', 't': '111010010010010',
    'u': '101101101101111', 'v': '101101101101010', 'w': '101101111111101',
    'x': '101101010101101', 'y': '101101010010010', 'z': '111001010100111',
    'j': '001001001101010', 'q': '010101101011001',
    '0': '111101101101111', '1': '010110010010111', '2': '110001010100111',
    '3': '110001010001110', '4': '101101111001001', '5': '111100110001110',
    '6': '011100111101111', '7': '111001010010010', '8': '111101111101111',
    '9': '111101111001110', '-': '000000111000000', '+': '000010111010000',
    ' ': '000000000000000', ':': '000010000010000', '.': '000000000000010',
    '=': '000111000111000', '(': '010100100100010', ')': '010001001001010',
    '/': '001001010100100', '_': '000000000000111', '%': '101001010100101',
}


def caption(text, width, scale=2):
    out = np.full((5 * scale + 4, width, 3), 32, dtype=np.uint8)
    x = 2
    for ch in text.lower():
        g = _GLYPHS.get(ch, _GLYPHS[' '])
        for i, bit in enumerate(g):
            if bit == '1':
                r, c = divmod(i, 3)
                y0, x0 = 2 + r * scale, x + c * scale
                out[y0:y0 + scale, x0:x0 + scale] = 230
        x += 4 * scale
        if x + 3 * scale >= width:
            break
    return out


def composite(frames, labels, scale=2):
    """Side-by-side labelled strip of equally-sized RGB frames."""
    cols = []
    for rgb, label in zip(frames, labels):
        big = upscale(rgb, scale)
        cols.append(np.vstack([caption(label, big.shape[1]), big]))
        cols.append(np.full((cols[-1].shape[0], 4, 3), 255, dtype=np.uint8))
    return np.hstack(cols[:-1])


# ---------------------------------------------------------------- comparison

def to555(rgb):
    return (rgb >> 3).astype(np.int16)


def compare(a, b):
    """Metrics between two frames: fraction of identical pixels, mean abs
    error on 5-bit channels, and a coarse block-structure correlation that
    tolerates small animated regions."""
    qa, qb = to555(a), to555(b)
    same = np.all(qa == qb, axis=2)
    exact = float(same.mean())
    mae = float(np.abs(qa - qb).mean())
    # 8x8 block means -> normalized cross-correlation of the luminance layout
    la = qa.mean(axis=2).reshape(H // 8, 8, W // 8, 8).mean(axis=(1, 3))
    lb = qb.mean(axis=2).reshape(H // 8, 8, W // 8, 8).mean(axis=(1, 3))
    da, db = la - la.mean(), lb - lb.mean()
    denom = np.sqrt((da * da).sum() * (db * db).sum())
    if denom < 1e-6:
        ncc = 1.0 if np.abs(la - lb).max() < 1 else 0.0
    else:
        ncc = float((da * db).sum() / denom)
    # bounding box of differing pixels
    ys, xs = np.nonzero(~same)
    box = [int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)] if len(xs) else None
    return {'exact': round(exact, 4), 'mae': round(mae, 3), 'ncc': round(ncc, 4), 'diff_box': box,
            'palette_only': palette_only(qa, qb), 'max_channel_delta': int(np.abs(qa - qb).max())}


def palette_only(qa, qb):
    """True when the two frames partition their pixels into the same colour
    regions and differ only in what colour each region is: a palette fade
    or colour-cycle step, not moved or missing content."""
    ka = (qa[..., 0].astype(np.int32) << 10) | (qa[..., 1].astype(np.int32) << 5) | qa[..., 2]
    kb = (qb[..., 0].astype(np.int32) << 10) | (qb[..., 1].astype(np.int32) << 5) | qb[..., 2]
    pairs = np.unique((ka.astype(np.int64) << 15) | kb)
    return len(pairs) == len(np.unique(ka)) == len(np.unique(kb))


def is_blank(rgb):
    """A single-colour screen (all black, all white, one backdrop)."""
    q = to555(rgb).reshape(-1, 3)
    return bool(np.all(q == q[0]))
