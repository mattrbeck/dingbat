#!/usr/bin/env python3
"""Build a gambatte --list=<tsv> for a subset of the suite, mirroring
build_gambatte_rows in tests/dingbat_test_runner.nim.

  python3 tools/gamlist.py <subdir-glob>... > /tmp/gam.tsv
"""
import os, sys, glob

ROOT = os.environ.get("GAMROOT",
    "/tmp/dingbat-test-roms/game-boy-test-roms/gambatte")

HEX = set("0123456789abcdefABCDEF")

def hex_prefix(tail):
    out = ""
    for c in tail:
        if c in HEX: out += c
        else: break
    return out

def rows_for(rom):
    rel = os.path.relpath(rom, ROOT)
    fname = os.path.basename(rom)
    stem = os.path.splitext(fname)[0]
    dmg_marker = cgb_marker = ""
    if "dmg08_cgb04c_out" in stem:
        dmg_marker = cgb_marker = "dmg08_cgb04c_out"
    elif "dmg08_out" in stem:
        dmg_marker = "dmg08_out"
        if "cgb04c_out" in stem: cgb_marker = "cgb04c_out"
    elif "_out" in stem:
        cgb_marker = "_out"
    out = []
    for dev, marker in (("dmg", dmg_marker), ("cgb", cgb_marker)):
        if not marker: continue
        tail = fname[fname.find(marker) + len(marker):]
        if tail.startswith("audio0") or tail.startswith("audio1"): continue
        exp = hex_prefix(tail)
        if not exp: continue
        out.append((dev, "hex", exp.upper(), rom,
                    os.path.splitext(rel)[0] + " [" + dev + "]"))
    base = os.path.splitext(rom)[0]
    both = base + "_dmg08_cgb04c.png"
    png_for = []
    if os.path.exists(both):
        png_for = [("dmg", both), ("cgb", both)]
    else:
        if os.path.exists(base + "_dmg08.png"): png_for.append(("dmg", base + "_dmg08.png"))
        if os.path.exists(base + "_cgb04c.png"): png_for.append(("cgb", base + "_cgb04c.png"))
    for dev, png in png_for:
        out.append((dev, "png", png, rom,
                    os.path.splitext(rel)[0] + " [" + dev + ", png]"))
    return out

def main():
    pats = sys.argv[1:] or ["*"]
    roms = []
    for p in pats:
        for d in glob.glob(os.path.join(ROOT, p)):
            if os.path.isdir(d):
                for dp, _, fns in os.walk(d):
                    for fn in fns:
                        if fn.endswith((".gb", ".gbc")): roms.append(os.path.join(dp, fn))
            elif d.endswith((".gb", ".gbc")):
                roms.append(d)
    roms.sort()
    names = []
    lines = []
    for rom in roms:
        for dev, kind, exp, r, name in rows_for(rom):
            lines.append("\t".join([dev, kind, exp, r]))
            names.append(name)
    sys.stdout.write("\n".join(lines) + "\n")
    with open(os.environ.get("GAMNAMES", "/tmp/gamnames.txt"), "w") as f:
        f.write("\n".join(names) + "\n")

main()
