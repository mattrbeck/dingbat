#!/usr/bin/env python3
"""Per-call effect listing from a traced run (BD_MEMTRACE/BD_MEMREAD/BD_IOREAD):
for each 0xF0..0xF1 window, the I/O writes, the BIOS's RAM stores (runs of
equal-stride stores summarised) and optionally its RAM reads. BIOS stack
traffic (0x03007E00-0x03007FEF) is left out.
  calltrace.py <rom.gba> <prefix> [first_call] [last_call] [--reads]"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import regions_of, load_marks
rom = os.path.abspath(sys.argv[1]); prefix = sys.argv[2]
args = [a for a in sys.argv[3:] if not a.startswith("--")]
reads = "--reads" in sys.argv
marks = load_marks(prefix, regions_of(rom))
windows = []
for i, (m, f, c, s) in enumerate(marks):
    if m == 0xF1 and i > 0 and marks[i - 1][0] == 0xF0:
        windows.append((marks[i - 1][2], c, i))
lo = int(args[0]) if args else 0
hi = int(args[1]) if len(args) > 1 else len(windows)
def load(path):
    out = []
    if not os.path.exists(path): return out
    for line in open(path):
        p = line.split()
        out.append((int(p[1]), line.rstrip()))
    return out
io = load(prefix + ".io.txt"); mem = load(prefix + ".mem.txt")
rd = load(prefix + ".memread.txt") if reads else []
def stack(line):
    a = int(line.split()[3].split(":")[0], 16)
    return 0x03007E00 <= a < 0x03007FF0
def summarise(lines):
    out = []; run = []
    def flush():
        if not run: return
        if len(run) <= 3: out.extend(l for _, l in run)
        else: out.append(f"{run[0][1]}  ... {len(run)} stores to {run[-1][1].split()[3]}")
        run.clear()
    prev = None
    for c, l in lines:
        a, rest = l.split()[3].split(":")
        a = int(a, 16); w, v = rest.split("=")
        if run and prev is not None and a - prev == int(w) and v == run[-1][1].split()[3].split("=")[1]:
            run.append((c, l)); prev = a; continue
        flush(); run.append((c, l)); prev = a
    flush()
    return out
for k, (t0, t1, idx) in enumerate(windows):
    if k < lo or k >= hi: continue
    print(f"== call {k} (mark #{idx}) {t1 - t0} cycles, t0={t0}")
    for c, l in io:
        if t0 <= c <= t1 and "FF0=" not in l: print(f"  io  +{c - t0:6d} {l.split(None, 2)[2]}")
    for l in summarise([(c, l) for c, l in mem if t0 <= c <= t1 and not stack(l)]):
        c = int(l.split()[1]); print(f"  st  +{c - t0:6d} {l.split(None, 2)[2]}")
    for c, l in rd:
        if t0 <= c <= t1 and not stack(l) and int(l.split()[3].split(":")[0], 16) >= 0x02000000:
            print(f"  rd  +{c - t0:6d} {l.split(None, 2)[2]}")
