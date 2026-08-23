#!/usr/bin/env python3
"""ppmdiff — where two 160x144 frames differ, by pixel and by scanline.

    ppmdiff.py A.ppm B.ppm [--png REFERENCE.png]

A suite verdict says "this row fails"; this says which scanline and which x.
"""
import sys
import zlib
import struct

W, H = 160, 144


def read_ppm(path):
    data = open(path, 'rb').read()
    # P6 <w> <h> <max>\n, whitespace-separated, possibly with comments
    fields, i = [], 2
    while len(fields) < 3:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] not in (b'\n', b''):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    return data[i + 1:], fields[0], fields[1]


def read_png(path):
    # Enough PNG for the reference frames: 8-bit truecolour and indexed
    # 1/2/4/8-bit (the acid references). No Pillow.
    raw = open(path, 'rb').read()
    pos, idat, plte, w, h, depth, ctype = 8, b'', b'', 0, 0, 8, 2
    while pos < len(raw):
        ln = struct.unpack('>I', raw[pos:pos + 4])[0]
        typ = raw[pos + 4:pos + 8]
        body = raw[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, depth, ctype = (*struct.unpack('>II', body[:8]), body[8], body[9])
        elif typ == b'IDAT':
            idat += body
        elif typ == b'PLTE':
            plte = body
        pos += 12 + ln
    if ctype == 2 and depth == 8:
        bpp, stride = 3, w * 3
    elif ctype == 3:
        bpp, stride = 1, (w * depth + 7) // 8
    elif ctype == 0:
        # Greyscale, any sub-byte depth. mealybug ships several CGB references
        # as 1-bit greyscale (`m3_lcdc_bg_map_change_cgb_c.png` and friends) and
        # this reader used to reject them outright, which quietly made those
        # rows unscorable by every tool here except the runner itself.
        bpp, stride = 1, (w * depth + 7) // 8
    else:
        raise SystemExit(f'{path}: unsupported PNG (ctype={ctype} depth={depth})')

    data, out, prev = zlib.decompress(idat), bytearray(), bytes(stride)
    for y in range(h):
        f = data[y * (stride + 1)]
        line = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        if ctype == 3:
            per, mask = 8 // depth, (1 << depth) - 1
            for x in range(w):
                idx = (line[x // per] >> (8 - depth * (x % per + 1))) & mask
                out += plte[idx * 3:idx * 3 + 3]
        elif ctype == 0:
            per, mask = 8 // depth, (1 << depth) - 1
            scale = 255 // mask
            for x in range(w):
                v = ((line[x // per] >> (8 - depth * (x % per + 1))) & mask) * scale
                out += bytes((v, v, v))
        else:
            out += line
        prev = bytes(line)
    return bytes(out), w, h


def load(path):
    return read_png(path) if path.endswith('.png') else read_ppm(path)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        raise SystemExit(__doc__)
    a, wa, ha = load(args[0])
    b, wb, hb = load(args[1])
    if (wa, ha) != (wb, hb):
        raise SystemExit(f'size mismatch: {wa}x{ha} vs {wb}x{hb}')
    bad, per_line = [], {}
    for y in range(ha):
        for x in range(wa):
            i = (y * wa + x) * 3
            if a[i:i + 3] != b[i:i + 3]:
                bad.append((x, y, tuple(a[i:i + 3]), tuple(b[i:i + 3])))
                per_line[y] = per_line.get(y, 0) + 1
    print(f'{len(bad)} differing pixels on {len(per_line)} scanlines')
    for y in sorted(per_line):
        xs = [p[0] for p in bad if p[1] == y]
        print(f'  ly={y:3d}  {per_line[y]:3d} px  x={min(xs)}..{max(xs)}')
    for x, y, pa, pb in bad[:24]:
        print(f'    ({x:3d},{y:3d})  A={pa}  B={pb}')
    if len(bad) > 24:
        print(f'    ... {len(bad) - 24} more')


if __name__ == '__main__':
    main()
