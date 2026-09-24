"""Loader for jlist2.gba runs: (entry, k, before, after, cycles) per call,
before/after = the 0x02010000 region and the SoundArea."""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import OUT, load_marks, regions_of  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def load(tag, name="jlist2"):
    rom = os.path.join(HERE, name + ".gba")
    regs = regions_of(rom)
    m = load_marks(os.path.join(OUT, name + "." + tag), regs)
    out = []
    for i in range(1, len(m)):
        if m[i][0] != 0xF1 or m[i - 1][0] != 0xF0:
            continue
        res = struct.unpack_from("<4I", m[i][3][2], 0)
        before = {"area": m[i - 1][3][0], "ew": m[i - 1][3][4]}
        after = {"area": m[i][3][0], "ew": m[i][3][4]}
        out.append((res[2], res[3], before, after, m[i][2] - m[i - 1][2]))
    return out
