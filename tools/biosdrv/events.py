#!/usr/bin/env python3
"""Every traced RAM/ROM access of the BIOS in a cycle window, in order
(stores, reads; BIOS-region reads left out).
  events.py <prefix> <t0> <t1>"""
import sys

prefix, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ev = []
for kind, path in (("st", ".mem.txt"), ("rd", ".memread.txt"), ("io", ".ioread.txt")):
    try:
        for line in open(prefix + path):
            p = line.split()
            t = int(p[1])
            if t0 <= t <= t1:
                a = int(p[3].split(":")[0], 16)
                if kind == "rd" and a < 0x02000000:
                    continue
                ev.append((t, kind, " ".join(p[2:])))
    except FileNotFoundError:
        pass
prev = None
for t, k, s in sorted(ev):
    print(f"{t - t0:7d} {'' if prev is None else '+%d' % (t - prev):>5} {k} {s}")
    prev = t
