"""Read probe (d) by finding the BARS, not by trusting band boundaries.

Each band paints one bar eight rows tall, separated from its neighbours by a
blank line, so the bars are the frame's only dark blobs. Detecting them is
self-aligning: a warp that is a couple of rows out vertically still yields
sixteen blobs in the right order, whereas fixed band windows start catching
the neighbour's bar. Each blob's own median luminance is then classified
against the levels the frame actually contains (background and the darkest
blob), not against assumed DMG greys, which is what makes this work on a
photograph of a backlit screen."""
import sys
sys.path.insert(0, 'tools/gbprobe')
import photowarp as P

W, H = 160, 144


def blobs(path):
    if path.endswith('.ppm'):          # an emulator frame: no registration needed
        d = open(path, 'rb').read()
        body = d.split(b'\n', 3)[3]
    else:
        body, _ = P.warp(path, do_refine=True)
    lum = [[(body[(y*W+x)*3]*77 + body[(y*W+x)*3+1]*151 + body[(y*W+x)*3+2]*28) >> 8
            for x in range(W)] for y in range(H)]
    flat = sorted(v for r in lum for v in r)
    bg = flat[len(flat)*3//4]
    dark = flat[len(flat)//100]
    thr = bg - (bg - dark) * 0.35
    seen = [[False]*W for _ in range(H)]
    out = []
    for y0 in range(H):
        for x0 in range(W):
            if seen[y0][x0] or lum[y0][x0] >= thr:
                continue
            stack, cells = [(x0, y0)], []
            while stack:
                x, y = stack.pop()
                if x < 0 or y < 0 or x >= W or y >= H or seen[y][x]:
                    continue
                if lum[y][x] >= thr:
                    continue
                seen[y][x] = True
                cells.append((x, y))
                stack += [(x+1, y), (x-1, y), (x, y+1), (x, y-1)]
            xs = [c[0] for c in cells]
            ys = [c[1] for c in cells]
            if len(cells) < 12 or max(ys)-min(ys) < 3 or max(xs)-min(xs) < 2:
                continue
            vals = sorted(lum[y][x] for x, y in cells)
            out.append({'y': min(ys), 'y1': max(ys), 'x': min(xs), 'x1': max(xs),
                        'med': vals[len(vals)//2], 'n': len(cells)})
    out.sort(key=lambda b: b['y'])
    return out, bg, dark


bl, bg, dark = blobs(sys.argv[1])
print(f'{len(bl)} bars found   background={bg}  darkest={dark}')
if not bl:
    raise SystemExit(1)
# The frame's own levels: white = bg, black = the darkest bar. Index 2 (dark
# grey) sits one third of the way up from black on an identity palette.
blackest = min(b['med'] for b in bl)
step = (bg - blackest) / 3.0
print('level guides: idx3=%d idx2=%d idx1=%d idx0=%d' %
      (blackest, blackest + step, blackest + 2*step, bg))
seq = ''
for i, b in enumerate(bl):
    k = round((b['med'] - blackest) / step) if step else 0
    ch = {0: '#', 1: '2', 2: '1', 3: '.'}.get(max(0, min(3, k)), '?')
    seq += ch
    print(f'  bar {i:2d}  y={b["y"]:3d}-{b["y1"]:3d}  x={b["x"]:3d}-{b["x1"]:3d}  '
          f'med={b["med"]:3d}  -> {ch}')
print('sequence:', seq)
