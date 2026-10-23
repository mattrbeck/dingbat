"""Writers for pixel art given as rows of palette characters: PNG, ICO, animated GIF, SVG.

No image library needed: PNG and GIF are encoded here with zlib and a small LZW.
"""
import struct, zlib


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def png_bytes(rows, pal, bg=None):
    """RGBA PNG, one pixel per character; '.' (and anything not in pal) is transparent, or bg if given."""
    def px(c):
        if c in pal:
            return bytes(rgb(pal[c])) + b'\xff'
        return bytes(rgb(bg)) + b'\xff' if bg else b'\0\0\0\0'
    raw = b''.join(b'\0' + b''.join(px(c) for c in r) for r in rows)
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    W, H = len(rows[0]), len(rows)
    return (b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(raw, 9)) + ch(b'IEND', b''))


def png(path, rows, pal, bg=None):
    data = png_bytes(rows, pal, bg)
    open(path, 'wb').write(data)
    return data


def ico(path, pngs):
    """An ICO whose entries are PNG files (read by Windows Vista+ and every browser)."""
    data = [open(p, 'rb').read() if isinstance(p, str) else p for p in pngs]
    sizes = [struct.unpack('>II', d[16:24]) for d in data]
    off = 6 + 16 * len(data)
    out = struct.pack('<HHH', 0, 1, len(data))
    for (w, h), d in zip(sizes, data):
        out += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, 32, len(d), off)
        off += len(d)
    open(path, 'wb').write(out + b''.join(data))


def _icns_rle(b):
    """The .icns run-length code: 0x00-0x7f copies n+1 bytes, 0x80-0xff repeats one byte n-125 times."""
    out, i = bytearray(), 0
    while i < len(b):
        run = 1
        while i + run < len(b) and run < 130 and b[i + run] == b[i]:
            run += 1
        if run >= 3:
            out += bytes((run + 125, b[i]))
            i += run
            continue
        j = i
        while j < len(b) and j - i < 128 and not (j + 2 < len(b) and b[j] == b[j + 1] == b[j + 2]):
            j += 1
        out += bytes((j - i - 1,)) + b[i:j]
        i = j
    return bytes(out)


def argb_bytes(rows, pal):
    """An .icns ARGB entry (ic04 16 px, ic05 32 px): each channel's plane, run-length coded."""
    px = [(255, *rgb(pal[c])) if c in pal else (0, 0, 0, 0) for r in rows for c in r]
    return b'ARGB' + b''.join(_icns_rle(bytes(p[ch] for p in px)) for ch in range(4))


def icns(path, entries):
    """A macOS .icns from (OSType, data) pairs: PNG bytes, or argb_bytes for ic04 and ic05."""
    body = b''.join(t.encode() + struct.pack('>I', 8 + len(d)) + d for t, d in entries)
    open(path, 'wb').write(b'icns' + struct.pack('>I', 8 + len(body)) + body)


def svg(rows, pal):
    """Crisp SVG: one path per colour, a rectangle per horizontal run."""
    W, H = len(rows[0]), len(rows)
    d = {}
    for y, r in enumerate(rows):
        x = 0
        while x < W:
            c = r[x]; n = 1
            while x + n < W and r[x + n] == c:
                n += 1
            if c in pal:
                d.setdefault(c, []).append(f'M{x} {y}h{n}v1h-{n}z')
            x += n
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" shape-rendering="crispEdges">'
            + ''.join(f'<path fill="{pal[c]}" d="{"".join(v)}"/>' for c, v in d.items()) + '</svg>\n')


def _lzw(indices, min_size):
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    size = min_size + 1
    table = {(i,): i for i in range(clear)}
    nxt = eoi + 1
    bits, nbits, out = 0, 0, bytearray()

    def emit(code):
        nonlocal bits, nbits
        bits |= code << nbits
        nbits += size
        while nbits >= 8:
            out.append(bits & 0xff); bits >>= 8; nbits -= 8

    emit(clear)
    w = ()
    for k in indices:
        wk = w + (k,)
        if wk in table:
            w = wk
            continue
        emit(table[w])
        if nxt < 4096:
            table[wk] = nxt; nxt += 1
            if nxt > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear)
            table = {(i,): i for i in range(clear)}
            nxt, size = eoi + 1, min_size + 1
        w = (k,)
    if w:
        emit(table[w])
    emit(eoi)
    if nbits:
        out.append(bits & 0xff)
    return bytes(out)


def gif(path, frames, pal, delay_cs=4):
    """Looping animated GIF; transparent where '.'. frames: list of rows, all the same size."""
    chars = sorted({c for f in frames for r in f for c in r if c in pal})
    colours = [(0, 0, 0)] + [rgb(pal[c]) for c in chars]
    depth = max(2, (len(colours) - 1).bit_length())
    colours += [(0, 0, 0)] * ((1 << depth) - len(colours))
    idx = {c: i + 1 for i, c in enumerate(chars)}
    W, H = len(frames[0][0]), len(frames[0])
    out = bytearray(b'GIF89a' + struct.pack('<HHBBB', W, H, 0x80 | (depth - 1), 0, 0))
    out += b''.join(bytes(c) for c in colours)
    out += b'\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00'
    for f in frames:
        out += b'\x21\xf9\x04' + struct.pack('<BHBB', 0x09, delay_cs, 0, 0)   # dispose to background, transparent index 0
        out += b'\x2c' + struct.pack('<HHHHB', 0, 0, W, H, 0)
        data = _lzw([idx.get(c, 0) for r in f for c in r], depth)
        out += bytes([depth])
        for i in range(0, len(data), 255):
            blk = data[i:i + 255]
            out += bytes([len(blk)]) + blk
        out += b'\x00'
    out += b'\x3b'
    open(path, 'wb').write(out)
