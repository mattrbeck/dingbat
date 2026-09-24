#!/usr/bin/env python3
"""jlist_stk.gba / jlist2_stk.gba on the HLE vs the real BIOS: the words each
jump-list call left on the stack below the caller's sp (bd_callfn_stk's
capture: sp-64 .. sp-4) and r6-r11 after it, per call where they differ.
  jlstk.py [jlist_stk|jlist2_stk] [--norun] [--all]"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import BIOS, OUT, load_marks, regions_of, run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = next((a for a in sys.argv[1:] if not a.startswith("-")), "jlist_stk")
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
        # RESULT lands in the next marker's snapshot (copied after the call)
        res = struct.unpack_from("<30I", m[i + 1][3][2], 0) if i + 1 < len(m) else None
        if res is None:
            continue
        out[(res[2], res[3])] = res[8:30]
    return out


h = calls("hle")
r = calls("real")
bad = 0
for key in sorted(r):
    if key not in h:
        continue
    x, y = h[key], r[key]
    if x != y or "--all" in sys.argv:
        bad += x != y
        e, v = key
        diff = [f"sp-{64 - 4 * i}:{x[i]:08X}/{y[i]:08X}" for i in range(16) if x[i] != y[i]]
        regd = [f"r{6 + i}:{x[16 + i]:08X}/{y[16 + i]:08X}" for i in range(6) if x[16 + i] != y[16 + i]]
        print(f"e{e:2d} v{v}: " + " ".join(diff + regd))
print(f"{bad} of {len(r)} calls differ")
