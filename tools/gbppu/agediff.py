#!/usr/bin/env python3
"""AGE result table, EXPECTED vs GOT, per cell.

`agecells.py` decodes the values an AGE test ROM printed and which of them the
ROM drew inverted (= disagreeing with hardware).  That still leaves the more
useful half unknown: what hardware actually returns.  It is in the ROM.  Each of
these tests compares its measurements against a stored array of expected bytes,
and that array can be located without disassembling anything -- it is the only
place in the ROM where a run of len(table) bytes agrees with every cell the ROM
did NOT invert and differs at every cell it did.  In practice that pins it
uniquely.

    dingbat_test <rom> --mode=screenshot --timeout=600 --nosave \
        [--dmg|--cgb] [--model=<tok>] --screenshot=f.ppm
    tools/gbppu/agediff.py <rom.gb> f.ppm [--json]

Output is the table with `EE!GG` on every disagreeing cell (expected, got).
"""
import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import agecells


def find_expected(rom, got, bad):
    n = len(got)
    hits = []
    for off in range(len(rom) - n):
        if all(rom[off + i] == got[i] for i in range(n) if not bad[i]) and \
           all(rom[off + i] != got[i] for i in range(n) if bad[i]):
            hits.append(off)
    return hits


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        raise SystemExit("usage: agediff.py <rom.gb> <frame.ppm> [--json]")
    rom = open(args[0], "rb").read()
    cells = agecells.decode(args[1])
    got = [int(c["value"], 16) for c in cells]
    bad = [c["bad"] for c in cells]
    hits = find_expected(rom, got, bad)
    exp = [rom[hits[0] + i] for i in range(len(got))] if len(hits) == 1 else None

    if "--json" in sys.argv:
        print(json.dumps({"rom": args[0], "frame": args[1],
                          "table_offset": hits[0] if len(hits) == 1 else None,
                          "candidates": len(hits),
                          "cells": [{"offset": i, "got": got[i], "bad": bad[i],
                                     "exp": (exp[i] if exp else None)}
                                    for i in range(len(got))]}))
        return

    if len(hits) != 1:
        print(f"expected table NOT pinned ({len(hits)} candidates)")
    else:
        print(f"expected table at {hits[0]:#06x}")
    print(f"{len(got)} cells, {sum(bad)} mismatching")
    for r in range(len(got) // 8):
        out = []
        for c in range(8):
            i = r * 8 + c
            if bad[i]:
                out.append(f"{exp[i]:02X}!{got[i]:02X}" if exp else f"??!{got[i]:02X}")
            else:
                out.append(f"{got[i]:02X}   ")
        print(f"  {r*8:03X}  " + " ".join(out))


if __name__ == "__main__":
    main()
