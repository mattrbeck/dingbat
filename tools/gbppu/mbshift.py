#!/usr/bin/env python3
"""How far LEFT/RIGHT is our frame from a Mealybug reference, per scanline?

A mid-mode-3 write's effect lands at a pixel column, so a wrong mode-3 penalty
shows up as a whole-line horizontal shift. Prints, per line, the shift s in
-16..16 that maximises the match (and whether that shift makes the line exact),
which turns a "% of pixels" score into a dot count.

  python3 tools/gbppu/mbshift.py <rom-name> [harness]
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mbscore import read_png_grey, read_ppm_grey  # noqa: E402

D = "/tmp/dingbat-test-roms/game-boy-test-roms/mealybug-tearoom-tests/ppu"
name = sys.argv[1]
H = sys.argv[2] if len(sys.argv) > 2 else "./dingbat_test"
rom = os.path.join(D, name + ".gb")
ppm = "/tmp/mbshift.ppm"
subprocess.run([H, rom, "--mode=screenshot", "--timeout=120",
                "--screenshot=" + ppm], capture_output=True)
a = read_ppm_grey(ppm); e = read_png_grey(rom.replace(".gb", "_dmg_blob.png"))
W, Hh = 160, 144
hist = {}
for y in range(Hh):
    ar = a[y*W:(y+1)*W]; er = e[y*W:(y+1)*W]
    best = None
    for s in range(-16, 17):
        m = 0
        for x in range(W):
            xs = x - s
            if 0 <= xs < W and ar[xs] == er[x]: m += 1
            elif not (0 <= xs < W): m += 1     # off-edge: don't penalise
        if best is None or m > best[1]: best = (s, m)
    s, m = best
    hist.setdefault((s, m == W), []).append(y)
    if y < 8 or m != W:
        pass
for (s, exact), ys in sorted(hist.items()):
    print("shift=%+3d exact=%-5s lines=%3d  e.g. %s" %
          (s, exact, len(ys), ys[:8]))
