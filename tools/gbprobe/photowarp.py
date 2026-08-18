#!/usr/bin/env python3
"""photowarp — warp a photo of a GBA-SP screen running a GB cart into the
160x144 GB frame as a PPM, so readout.py / arbread.py can read hardware
photos the same way they read emulator screenshots.

STATUS 2026-08-17: EXPERIMENTAL. The letterbox-ring panel detection works
on the AGS session photos, but the resulting registration is a few pixels
off — too coarse for arbread's 4-dot phase reading (the band column comes
out pinned to the frame edge). The known fix: adapt
tools/gbphoto/photogrid.py's NCC corner refinement (registration against
the emulator frame's AGREEING cells only) to this letterbox geometry, then
re-read IMG_3804-3806/3808. The acid-hell smiley verdict did not need this
tool — see docs/flashcart-runbook.md, session 2.

    photowarp.py <photo.png> <out.ppm> [--gb-full]

Assumes the SP's panel (240x160) shows the GB frame 1:1 centered (the
GBA's GB-compat letterbox: 40-column pillars, 8-row bars). `--gb-full`
treats the detected quad as the bare 160x144 frame instead (for photos of
GB-only handhelds where the panel IS the frame).

Pipeline: luminance-threshold the darkest large region containing the
image centre (the lit LCD is far darker than any shell/background in a
normal exposure), take its extreme corners along the two diagonals, build
a projective map from the quad, bilinear-sample each GB cell's centre.
No dependencies beyond the stdlib; PNG input must be RGB8 (sips default).
"""
import sys
import struct
import zlib


def read_png(path):
    f = open(path, 'rb').read()
    pos, idat = 8, b''
    w = h = ct = None
    while pos < len(f):
        ln = struct.unpack('>I', f[pos:pos+4])[0]
        typ = f[pos+4:pos+8]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', f[pos+8:pos+18])
        if typ == b'IDAT':
            idat += f[pos+8:pos+8+ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {2: 3, 6: 4}[ct]
    stride = w * ch + 1
    prev = bytearray(w * ch)
    out = []
    for y in range(h):
        line = raw[y*stride:(y+1)*stride]
        ft = line[0]
        cur = bytearray(line[1:])
        for i in range(len(cur)):
            a = cur[i-ch] if i >= ch else 0
            b = prev[i]
            c = prev[i-ch] if i >= ch else 0
            if ft == 1: cur[i] = (cur[i] + a) & 255
            elif ft == 2: cur[i] = (cur[i] + b) & 255
            elif ft == 3: cur[i] = (cur[i] + (a + b) // 2) & 255
            elif ft == 4:
                p2 = a + b - c
                pa, pb, pc = abs(p2-a), abs(p2-b), abs(p2-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 255
        out.append(bytes(cur))
        prev = cur
    return w, h, ch, out


def find_panel(w, h, ch, rows):
    ## Dark mask on a decimated grid, flood-fill from the centre, then the
    ## component's diagonal extremes are the panel corners.
    step = max(1, w // 600)
    gw, gh = w // step, h // step
    lum = [[(rows[y*step][x*step*ch] + rows[y*step][x*step*ch+1] +
             rows[y*step][x*step*ch+2]) // 3 for x in range(gw)]
           for y in range(gh)]
    # Anchor on the GB-compat LETTERBOX: the SP always frames the 160x144
    # image with pure-black pillars/bars, so the panel is ringed by the
    # largest deep-black connected component whose bounding box contains the
    # image centre. Its diagonal extremes are the panel's outer corners.
    dark = [[lum[y][x] < 45 for x in range(gw)] for y in range(gh)]
    seen = [[False]*gw for _ in range(gh)]
    comp = []
    for sy in range(0, gh, 6):
        for sx in range(0, gw, 6):
            if not dark[sy][sx] or seen[sy][sx]:
                continue
            stack = [(sx, sy)]
            cur = []
            while stack:
                x, y = stack.pop()
                if x < 0 or y < 0 or x >= gw or y >= gh or seen[y][x] or not dark[y][x]:
                    continue
                seen[y][x] = True
                cur.append((x, y))
                stack += [(x+1, y), (x-1, y), (x, y+1), (x, y-1)]
            if len(cur) <= len(comp):
                continue
            xs = [p[0] for p in cur]; ys = [p[1] for p in cur]
            # must ring the centre AND stay inside the central window — a
            # merged background object (couch shadow, a laptop edge) pokes
            # out to the photo's borders and is rejected here.
            if not (min(xs) <= gw//2 <= max(xs) and min(ys) <= gh//2 <= max(ys)):
                continue
            if min(xs) < gw*0.08 or max(xs) > gw*0.95 or \
               min(ys) < gh*0.08 or max(ys) > gh*0.95:
                continue
            comp = cur
    if len(comp) < gw*gh//100:
        raise SystemExit(f"panel flood-fill found only {len(comp)} cells; "
                         "is the screen centred and lit?")
    tl = min(comp, key=lambda p: p[0]+p[1])
    br = max(comp, key=lambda p: p[0]+p[1])
    tr = max(comp, key=lambda p: p[0]-p[1])
    bl = min(comp, key=lambda p: p[0]-p[1])
    return [(x*step, y*step) for x, y in (tl, tr, br, bl)]


def homography(quad, dw, dh):
    ## Projective map from the unit dest rect to the quad (DLT, 4 points).
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = quad
    # dest corners: (0,0) (dw,0) (dw,dh) (0,dh)
    src = [(0, 0), (dw, 0), (dw, dh), (0, dh)]
    dst = [(x0, y0), (x1, y1), (x2, y2), (x3, y3)]
    a = []
    b = []
    for (sx, sy), (dx, dy) in zip(src, dst):
        a.append([sx, sy, 1, 0, 0, 0, -dx*sx, -dx*sy]); b.append(dx)
        a.append([0, 0, 0, sx, sy, 1, -dy*sx, -dy*sy]); b.append(dy)
    # gaussian elimination
    n = 8
    m = [row[:] + [bv] for row, bv in zip(a, b)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(m[r][col]))
        m[col], m[piv] = m[piv], m[col]
        d = m[col][col]
        m[col] = [v/d for v in m[col]]
        for r in range(n):
            if r != col and m[r][col]:
                f = m[r][col]
                m[r] = [v - f*w for v, w in zip(m[r], m[col])]
    hcoef = [m[i][n] for i in range(n)] + [1.0]
    def map_pt(x, y):
        d = hcoef[6]*x + hcoef[7]*y + 1
        return ((hcoef[0]*x + hcoef[1]*y + hcoef[2]) / d,
                (hcoef[3]*x + hcoef[4]*y + hcoef[5]) / d)
    return map_pt


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    photo, out = sys.argv[1], sys.argv[2]
    gb_full = '--gb-full' in sys.argv
    w, h, ch, rows = read_png(photo)
    quad = find_panel(w, h, ch, rows)
    if gb_full:
        panel_w, panel_h = 160.0, 144.0
        ox, oy = 0.0, 0.0
    else:
        panel_w, panel_h = 240.0, 160.0
        ox, oy = 40.0, 8.0
    mp = homography(quad, panel_w, panel_h)
    buf = bytearray()
    for gy in range(144):
        for gx in range(160):
            px, py = mp(ox + gx + 0.5, oy + gy + 0.5)
            xi, yi = int(px), int(py)
            if 0 <= xi < w-1 and 0 <= yi < h-1:
                fx, fy = px - xi, py - yi
                c = []
                for k in range(3):
                    v = (rows[yi][xi*ch+k]*(1-fx)*(1-fy) +
                         rows[yi][(xi+1)*ch+k]*fx*(1-fy) +
                         rows[yi+1][xi*ch+k]*(1-fx)*fy +
                         rows[yi+1][(xi+1)*ch+k]*fx*fy)
                    c.append(int(v))
                buf += bytes(c)
            else:
                buf += b'\x80\x80\x80'
    with open(out, 'wb') as f:
        f.write(b'P6\n160 144\n255\n' + bytes(buf))
    print(f"warped {photo} -> {out} (panel quad {quad})")


if __name__ == '__main__':
    main()
