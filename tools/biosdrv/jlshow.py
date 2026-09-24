#!/usr/bin/env python3
"""jlist.gba: what each jump-list function wrote (before/after snapshots of
the MusicPlayerInfo/track/stream area and the SoundArea) and its cost.
  jlshow.py <real|hle> [entry ...]"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import OUT, load_marks, regions_of  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
rom = os.path.join(HERE, "jlist.gba")
tag = sys.argv[1]
only = {int(x, 0) for x in sys.argv[2:]}
regs = regions_of(rom)
m = load_marks(os.path.join(OUT, "jlist." + tag), regs)
names = {0x02010000: "mp", 0x02010100: "tr", 0x02010200: "cmd", 0x02010300: "voice",
         0x02010400: "tr2"}


def label(a):
    base = max(b for b in names if b <= a)
    return f"{names[base]}+{a - base:02X}"


out = []
for i in range(1, len(m)):
    if m[i][0] != 0xF1 or m[i - 1][0] != 0xF0:
        continue
    before, after = m[i - 1][3], m[i][3]
    res = struct.unpack_from("<4I", after[2], 0)
    e, variant = res[2], res[3]
    if only and e not in only:
        continue
    diffs = []
    for (base, n), x, y in zip(regs, before, after):
        if base in (0x02030000,) or n == 0x20:
            continue
        for j in range(n):
            if x[j] != y[j]:
                a = base + j
                lab = label(a) if a >= 0x02010000 and a < 0x02010600 else f"{a:08X}"
                diffs.append(f"{lab}:{x[j]:02X}>{y[j]:02X}")
    rg = struct.unpack_from("<8I", after[3], 0)
    print(f"e{e:2d} v{variant} {m[i][2] - m[i - 1][2]:5d}c r0-3 {rg[0]:08X} {rg[1]:08X} "
          f"{rg[2]:08X} {rg[3]:08X}  " + " ".join(diffs))
