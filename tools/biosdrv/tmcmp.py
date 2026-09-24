#!/usr/bin/env python3
"""A probe's own timer measurement (RESULT[5], Timers 2+3 cascaded around
each call) on the HLE vs the real BIOS, keyed by RESULT[2..3].
  tmcmp.py <rom.gba> [frames] [--norun]"""
import os
import struct
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


def res(tag):
    out = {}
    for m, f, c, s in load_marks(os.path.join(OUT, name + "." + tag), regions_of(rom)):
        if 0x10 <= m < 0x50:
            r = struct.unpack_from("<6I", s[2], 0)
            out[(r[2], r[3])] = r[5]
    return out


h, r = res("hle"), res("real")
for k in sorted(r):
    if k in h:
        print(k, "hle", h[k], "real", r[k], "%+d" % (h[k] - r[k]))
