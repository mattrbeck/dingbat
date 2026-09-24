#!/usr/bin/env python3
"""Print a probe run's marker snapshots: SoundArea header, RESULT readback.
  show.py <rom.gba> <real|hle> [first_mark] [last_mark]"""
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import regions_of, load_marks, OUT
rom = os.path.abspath(sys.argv[1]); tag = sys.argv[2]
regs = regions_of(rom)
prefix = os.path.join(OUT, os.path.splitext(os.path.basename(rom))[0] + "." + tag)
marks = load_marks(prefix, regs)
lo = int(sys.argv[3]) if len(sys.argv) > 3 else 0
hi = int(sys.argv[4]) if len(sys.argv) > 4 else len(marks)
prev = None
for i, (m, f, c, s) in enumerate(marks):
    if i < lo or i >= hi: continue
    if m == 0xF0 or m == 0xF1:
        if m == 0xF1: print(f"#{i} call {c - prev} cycles")
        prev = c; continue
    area, bios, res, regs_ = s[0], s[1], s[2], s[3]
    w = struct.unpack_from("<16I", res, 0)
    print(f"#{i} mark {m:02X} f{f} c{c} SCNT {w[0]:08X} X/BIAS {w[1]:08X} DMA {w[2]:08X} TM0 {w[3]:08X} TM1 {w[4]:08X} VC {w[5]} regs " + " ".join(f"{x:08X}" for x in w[8:16]))
    print("    hdr " + area[:0x50].hex(" ", 4))
    print("    7FF0 " + bios.hex(" ", 4))
