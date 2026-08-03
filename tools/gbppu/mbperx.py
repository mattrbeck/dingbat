#!/usr/bin/env python3
"""Per-OBJ-X dot error against a Mealybug reference.

The m3_* ROMs sweep the object's OAM X down the screen (one X per band of
lines), so one reference frame is a staircase over X: the horizontal shift that
best aligns each band is that X's error in dots. Needs a harness built with
-d:gb_m3_len for the per-line OBJ list.

  python3 tools/gbppu/mbperx.py <rom-name> <traced-harness> [<render-harness>]
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mbscore import read_png_grey, read_ppm_grey  # noqa: E402

D = "/tmp/dingbat-test-roms/game-boy-test-roms/mealybug-tearoom-tests/ppu"
name = sys.argv[1]
TH = sys.argv[2]
RH = sys.argv[3] if len(sys.argv) > 3 else TH
rom = os.path.join(D, name + ".gb")
ppm = "/tmp/mbperx.ppm"
r = subprocess.run([TH, rom, "--mode=screenshot", "--timeout=120",
                    "--screenshot=" + ppm], capture_output=True, text=True)
objs = {}
for line in r.stdout.splitlines():
    if line.startswith("M3IN "):
        f = dict(kv.split("=", 1) for kv in line.split()[1:])
        objs[int(f["ly"])] = f.get("objx", "")     # last frame wins
if RH != TH:
    subprocess.run([RH, rom, "--mode=screenshot", "--timeout=120",
                    "--screenshot=" + ppm], capture_output=True)
a = read_ppm_grey(ppm); e = read_png_grey(rom.replace(".gb", "_dmg_blob.png"))
W, H = 160, 144
print("%-4s %-16s %6s %6s" % ("ly", "objx", "shift", "exact"))
for y in range(H):
    ar = a[y*W:(y+1)*W]; er = e[y*W:(y+1)*W]
    best = None
    for s in range(-16, 17):
        m = sum(1 for x in range(W)
                if not (0 <= x - s < W) or ar[x - s] == er[x])
        if best is None or m > best[1]: best = (s, m)
    print("%-4d %-16s %+6d %6s" % (y, objs.get(y, "?"), best[0], best[1] == W))
