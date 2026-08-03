#!/usr/bin/env python3
"""Score the Mealybug Tearoom PPU rows (greyscale, whole-frame) with a chosen
harness binary -- the same comparison dingbat_test_runner does, standalone so a
single-suite A/B does not cost a full runner pass.

  python3 tools/gbppu/mbscore.py [./dingbat_test]
"""
import glob, os, subprocess, sys, zlib, struct

H = (sys.argv[1] if len(sys.argv) > 1 else "./dingbat_test")
D = "/tmp/dingbat-test-roms/game-boy-test-roms/mealybug-tearoom-tests/ppu"

def read_png_grey(path):
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
    px = []
    for y in range(h):
        row = out[y*stride:(y+1)*stride]
        for x in range(w):
            if bd == 8:
                if ct == 3: px.append(plte[row[x]*3])
                else: px.append(row[x*ch])
            else:
                per = 8 // bd
                v = (row[x//per] >> (8 - bd*(x % per + 1))) & ((1 << bd) - 1)
                px.append(plte[v*3] if ct == 3 else v * (255 // ((1 << bd) - 1)))
    return px

def read_ppm_grey(path):
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
    i += 1
    body = d[i:]
    return [body[k*3] for k in range(len(body)//3)]

def main():
    tot = 0
    for rom in sorted(glob.glob(D + "/*.gb")):
        n = os.path.basename(rom)[:-3]
        png = os.path.join(D, n + "_dmg_blob.png")
        if not os.path.exists(png): continue
        ppm = "/tmp/mb_%s.ppm" % n
        subprocess.run([H, rom, "--mode=screenshot", "--timeout=120",
                        "--screenshot=" + ppm], capture_output=True)
        a = read_ppm_grey(ppm); e = read_png_grey(png)
        os.remove(ppm)
        same = sum(1 for x, y in zip(a, e) if x == y)
        tot += same
        print("%-42s %6.1f%% (%d/%d)" % (n, 100.0*same/len(e), same, len(e)))
    print("TOTAL matching pixels: %d" % tot)

if __name__ == "__main__":
    main()
