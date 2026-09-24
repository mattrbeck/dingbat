#!/usr/bin/env python3
"""Sound-register writes inside each bracketed call (0xF0 -> 0xF1), HLE vs
the real BIOS: every write's cycle offset from the call's start, and the
calls where the two lists differ.
  iotime.py <rom.gba> [frames] [--norun] [--all]"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import BIOS, OUT, load_marks, regions_of, run  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("-")]
rom = os.path.abspath(args[0])
frames = int(args[1]) if len(args) > 1 else 300
name = os.path.splitext(os.path.basename(rom))[0]
if "--norun" not in sys.argv:
    run(rom, frames, "hle", "hle")
    run(rom, frames, BIOS, "real")
REGS = ("080", "082", "084", "089", "0BC", "0C0", "0C6", "0C8", "0CC", "0D2", "100", "102")


def calls(tag):
    m = load_marks(os.path.join(OUT, name + "." + tag), regions_of(rom))
    wins = [(m[i - 1][2], m[i][2]) for i in range(1, len(m))
            if m[i][0] == 0xF1 and m[i - 1][0] == 0xF0]
    io = []
    for line in open(os.path.join(OUT, name + "." + tag + ".io.txt")):
        p = line.split()
        if p[4][:3] in REGS:
            io.append((int(p[1]), p[4]))
    out = []
    for s, t in wins:
        out.append((t - s, [(c - s, w) for c, w in io if s <= c <= t]))
    return out


h = calls("hle")
r = calls("real")
bad = 0
for k, ((th, wh), (tr, wr)) in enumerate(zip(h, r)):
    if wh != wr or th != tr or "--all" in sys.argv:
        bad += wh != wr or th != tr
        print(f"call {k}: hle {th} real {tr}")
        print("   hle ", wh[:16])
        print("   real", wr[:16])
print(f"{bad} of {min(len(h), len(r))} calls differ")
