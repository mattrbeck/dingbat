#!/usr/bin/env python3
"""Show a mix probe run pass by pass: counter, channels, and every pcmBuffer
slot that changed since the previous pass.
  mixshow.py <rom.gba> <real|hle> [channels] [bytes per slot]"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import OUT, load_marks, regions_of  # noqa: E402

rom = os.path.abspath(sys.argv[1])
tag = sys.argv[2]
nch = int(sys.argv[3]) if len(sys.argv) > 3 else 1
nb = int(sys.argv[4]) if len(sys.argv) > 4 else 32
prefix = os.path.join(OUT, os.path.splitext(os.path.basename(rom))[0] + "." + tag)
marks = load_marks(prefix, regions_of(rom))
prev = None
for x in marks:
    if x[0] != 0x20:
        continue
    a = x[3][0]
    f = struct.unpack_from("<I", x[3][2], 0)[0]
    spv = struct.unpack_from("<I", a, 0x10)[0]
    per = a[0xB]
    print("frame", f, "cnt", a[4], "per", per, "spv", spv)
    for c in range(nch):
        print("  ch%d" % c, a[0x50 + c * 64:0x90 + c * 64].hex(" ", 4))
    if prev is not None:
        for s in range(per):
            lo, hi = s * spv, s * spv + spv
            A = a[0x350 + lo:0x350 + hi]
            Bb = a[0x980 + lo:0x980 + hi]
            if A != prev[0x350 + lo:0x350 + hi] or Bb != prev[0x980 + lo:0x980 + hi]:
                print("   slot", s, "A", A[:nb].hex(" "), "\n          B", Bb[:nb].hex(" "))
    prev = a
