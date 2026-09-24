#!/usr/bin/env python3
"""regs.gba: the registers every driver SWI path leaves, real vs HLE."""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import OUT, load_marks, regions_of  # noqa: E402

rom = os.path.join(os.path.dirname(os.path.abspath(__file__)), "regs.gba")
names = ["Init", "Mode0", "ModeF", "ModeRate", "VSdec", "VSreset", "ChClr", "VSOff",
         "VSOn", "Main", "lk VS", "lk ChClr", "lk VSOff", "lk Mode", "lk Main"]
out = {}
for tag in ("real", "hle"):
    m = [x for x in load_marks(os.path.join(OUT, "regs." + tag), regions_of(rom))
         if 0x10 <= x[0] < 0x40]
    out[tag] = [struct.unpack_from("<8I", x[3][3]) for x in m]
for i, n in enumerate(names):
    r = out["real"][i]
    h = out["hle"][i]
    flag = "" if r[:5] == h[:5] else "  <-- DIFF"
    print(f"{n:9s} real r0-3,r12 {[hex(v) for v in r[:5]]}{flag}")
    if flag:
        print(f"          hle           {[hex(v) for v in h[:5]]}")
