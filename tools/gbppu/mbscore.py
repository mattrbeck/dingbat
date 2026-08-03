#!/usr/bin/env python3
"""Score the Mealybug Tearoom PPU rows (whole-frame) with a chosen harness
binary -- the same comparison dingbat_test_runner does, standalone so a
single-suite A/B does not cost a full runner pass.

  python3 tools/gbppu/mbscore.py [./dingbat_test] [dmg|cgb]

`cgb` runs the same DMG carts on CGB hardware (--cgb --color) against the
suite's own `_cgb_c.png` references, which is CGB DMG-compatibility mode: CGB
timing, a DMG picture, and the boot ROM's fallback compatibility palette. Seven
of the ROMs (the `*2.gb` variants) ship a CGB reference and no DMG one, so the
two devices do not cover the same row set.
"""
import glob, os, subprocess, sys, zlib, struct

H = (sys.argv[1] if len(sys.argv) > 1 else "./dingbat_test")
DEV = (sys.argv[2] if len(sys.argv) > 2 else "dmg").lower()
D = "/tmp/dingbat-test-roms/game-boy-test-roms/mealybug-tearoom-tests/ppu"

def _png_planes(path):
    """(w, h, bitdepth, colourtype, PLTE, unfiltered rows) for a PNG."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    i = 8; idat = b""; w = h = bd = ct = None; plte = None
    while i < len(d):
        ln = struct.unpack(">I", d[i:i+4])[0]; typ = d[i+4:i+8]; data = d[i+8:i+8+ln]
        if typ == b"IHDR": w, h, bd, ct = struct.unpack(">IIBB", data[:10])
        elif typ == b"PLTE": plte = data
        elif typ == b"IDAT": idat += data
        i += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0:1, 2:3, 3:1, 4:2, 6:4}[ct]
    bpp = max(1, ch * bd // 8)
    stride = (w * ch * bd + 7) // 8
    out = bytearray(); prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line; prev = line
    return w, h, bd, ct, plte, out, stride, ch

def _png_index(row, x, bd, ct, ch):
    if bd == 8:
        return row[x*ch] if ct != 3 else row[x]
    per = 8 // bd
    return (row[x//per] >> (8 - bd*(x % per + 1))) & ((1 << bd) - 1)

def read_png_grey(path):
    w, h, bd, ct, plte, out, stride, ch = _png_planes(path)
    px = []
    for y in range(h):
        row = out[y*stride:(y+1)*stride]
        for x in range(w):
            v = _png_index(row, x, bd, ct, ch)
            if ct == 3: px.append(plte[v*3])
            elif bd == 8: px.append(v)
            else: px.append(v * (255 // ((1 << bd) - 1)))
    return px

def read_png_rgb(path):
    """Flat [r,g,b, r,g,b, ...], to compare against a colour PPM."""
    w, h, bd, ct, plte, out, stride, ch = _png_planes(path)
    px = []
    for y in range(h):
        row = out[y*stride:(y+1)*stride]
        for x in range(w):
            if ct == 3:
                v = _png_index(row, x, bd, ct, ch)
                px += [plte[v*3], plte[v*3+1], plte[v*3+2]]
            elif ct in (2, 6):
                px += [row[x*ch], row[x*ch+1], row[x*ch+2]]
            else:
                v = _png_index(row, x, bd, ct, ch)
                if bd != 8: v = v * (255 // ((1 << bd) - 1))
                px += [v, v, v]
    return px

def _ppm_body(path):
    d = open(path, "rb").read()
    parts = []; i = 0
    while len(parts) < 4:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b"#":
            while d[i:i+1] != b"\n": i += 1
            continue
        j = i
        while not d[j:j+1].isspace(): j += 1
        parts.append(d[i:j]); i = j
    return d[i+1:]

def read_ppm_grey(path):
    body = _ppm_body(path)
    return [body[k*3] for k in range(len(body)//3)]

def read_ppm_rgb(path):
    return list(_ppm_body(path))

def main():
    tot = 0
    for rom in sorted(glob.glob(D + "/*.gb")):
        n = os.path.basename(rom)[:-3]
        suffix = "_cgb_c" if DEV == "cgb" else "_dmg_blob"
        png = os.path.join(D, n + suffix + ".png")
        if not os.path.exists(png): continue
        ppm = "/tmp/mb_%s_%s.ppm" % (n, DEV)
        argv = [H, rom, "--mode=screenshot", "--timeout=120",
                "--screenshot=" + ppm, "--nosave"]
        if DEV == "cgb": argv += ["--cgb", "--color"]
        subprocess.run(argv, capture_output=True)
        if DEV == "cgb":
            a = read_ppm_rgb(ppm); e = read_png_rgb(png)
        else:
            a = read_ppm_grey(ppm); e = read_png_grey(png)
        os.remove(ppm)
        same = sum(1 for x, y in zip(a, e) if x == y)
        tot += same
        print("%-42s %6.1f%% (%d/%d)" % (n, 100.0*same/len(e), same, len(e)))
    print("TOTAL matching pixels: %d" % tot)

if __name__ == "__main__":
    main()
