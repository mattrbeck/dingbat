#!/usr/bin/env python3
"""Score dingbat's measured mode-3 length against Pan Docs' "Mode 3 length"
rules (Rendering.md: SCX%8, the 6-dot window setup, and the OBJ penalty
algorithm).  Reads the `-d:gb_m3_len` trace on stdin, prints one row per
distinct (inputs -> measured, predicted, delta).

  tools/m3len.sh dmg <rom> | python3 tools/m3oracle.py
"""
import sys, re, collections

def predict(scx, objx, wx, wy, lcdc, ly):
    n = 172 + (scx & 7)
    win = (lcdc & 0x20) != 0 and ly >= wy and wx <= 166
    if win:
        n += 6
    seen = set()
    for x in objx:
        if x == 0:
            n += 11
            continue
        sx = x - 8                      # screen X of "The Pixel"
        tile = (sx + scx) >> 3
        t = (sx + scx) & 7
        pen = 6
        if tile not in seen:
            seen.add(tile)
            pen += max(0, 7 - t - 2)
        n += pen
    return n

def main():
    cur = None
    rows = collections.OrderedDict()
    for line in sys.stdin:
        if line.startswith("M3IN "):
            f = dict(kv.split("=", 1) for kv in line.split()[1:])
            objx = [int(v) for v in f["objx"].split(",") if v]
            cur = (int(f["ly"]), int(f["scx"]), int(f["wx"]), int(f["wy"]),
                   int(f["lcdc"], 16), tuple(objx))
        elif line.startswith("M3LEN ") and cur is not None:
            f = dict(kv.split("=", 1) for kv in line.split()[1:])
            ly, scx, wx, wy, lcdc, objx = cur
            meas = int(f["len"])
            pred = predict(scx, list(objx), wx, wy, lcdc, ly)
            key = (scx, wx, wy, lcdc, objx, meas, pred)
            rows.setdefault(key, [0, []])
            rows[key][0] += 1
            if len(rows[key][1]) < 3: rows[key][1].append(ly)
            cur = None
    for (scx, wx, wy, lcdc, objx, meas, pred), (n, lys) in rows.items():
        d = meas - pred
        print("n=%-4d ly=%-14s scx=%d wx=%-3d wy=%-3d lcdc=%02X obj=%-28s "
              "meas=%-4d pred=%-4d delta=%+d" %
              (n, ",".join(map(str, lys)), scx, wx, wy, lcdc,
               ",".join(map(str, objx)), meas, pred, d))

main()
