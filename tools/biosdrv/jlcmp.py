#!/usr/bin/env python3
"""jlist.gba (or jlist2.gba) on the HLE vs the real BIOS: per jump-list
entry and state, the call's cycle difference and the bytes its
after-snapshots disagree on.
  jlcmp.py [jlist2] [--norun]      (runs both first)"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import BIOS, OUT, load_marks, regions_of, run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = next((a for a in sys.argv[1:] if not a.startswith("-")), "jlist")
rom = os.path.join(HERE, NAME + ".gba")
if "--norun" not in sys.argv:
    run(rom, 300, "hle", "hle")
    run(rom, 300, BIOS, "real")
regs = regions_of(rom)


def calls(tag):
    m = load_marks(os.path.join(OUT, NAME + "." + tag), regs)
    out = {}
    for i in range(1, len(m)):
        if m[i][0] != 0xF1 or m[i - 1][0] != 0xF0:
            continue
        res = struct.unpack_from("<4I", m[i][3][2], 0)
        out[(res[2], res[3])] = (m[i][2] - m[i - 1][2], m[i][3])
    return out


h = calls("hle")
r = calls("real")
by_entry = {}
for key in sorted(r):
    if key not in h:
        continue
    (ch, sh), (cr, sr) = h[key], r[key]
    diffs = []
    for (base, n), x, y in zip(regs, sh, sr):
        if base == 0x02030000 or n == 0x20:
            continue
        for j in range(n):
            if x[j] != y[j]:
                diffs.append(f"{base + j:08X}:{x[j]:02X}/{y[j]:02X}")
    e, v = key
    print(f"e{e:2d} v{v} cycles hle {ch} real {cr} ({ch - cr:+d})"
          + (f"  {len(diffs)} bytes differ: " + " ".join(diffs[:8]) if diffs else ""))
