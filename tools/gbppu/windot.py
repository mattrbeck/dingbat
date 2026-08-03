#!/usr/bin/env python3
"""Put a gambatte window family's register-write DOT next to its expected value.

    nim c -d:test_harness -d:release -d:gb_win_trace --path:src \
      -o:dt_win tests/dingbat_test.nim
    DT=./dt_win python3 tools/gbppu/windot.py 'window/arg/late_wy_FFto2_ly2_*'

Every row of a gambatte window family is the same ROM with one register write
moved by one M-cycle, so the family brackets the dot the PPU samples that
register on -- but only if you can see which dot each ROM's write actually
lands on. `-d:gb_win_trace` prints that (WY/WX/LCDC writes, window starts,
mode 3 ends, all with the dot within the line); this script runs one ROM per
device, filters the trace to the visible lines, and prints the last few lines
of it next to the filename's `_out<hex>` expectation and dingbat's verdict.

Reading it: a family whose expectations flip between two consecutive write dots
puts the sampling point between them, and repeating that across the family's
WX / SCX variants solves for it -- which is how the window-start equality in
fifo_ppu.nim was placed. Env: PAT (trace filter regex, default `^(WY|WX|LCDC)`),
TAIL (trace lines per row, default 2), GAMROOT, DT.
"""
import glob, os, re, subprocess, sys

ROOT = os.environ.get("GAMROOT",
    "/tmp/dingbat-test-roms/game-boy-test-roms/gambatte")
DT = os.environ.get("DT", "./dt_win")
PAT = os.environ.get("PAT", "^(WY|WX|LCDC)")
TAIL = int(os.environ.get("TAIL", "2"))
HEX = set("0123456789abcdefABCDEF")


def expected(fname, dev):
    """The `_out<hex>` this device is scored against, or None. Mirrors
    build_gambatte_rows in tests/dingbat_test_runner.nim."""
    stem = os.path.splitext(fname)[0]
    if "dmg08_cgb04c_out" in stem:
        mm = {"dmg": "dmg08_cgb04c_out", "cgb": "dmg08_cgb04c_out"}
    elif "dmg08_out" in stem:
        mm = {"dmg": "dmg08_out"}
        if "cgb04c_out" in stem: mm["cgb"] = "cgb04c_out"
    elif "_out" in stem:
        mm = {"cgb": "_out"}
    else:
        return None
    if dev not in mm: return None
    tail = fname[fname.find(mm[dev]) + len(mm[dev]):]
    out = ""
    for c in tail:
        if c in HEX: out += c
        else: break
    return out.upper() or None


def main():
    for path in sorted(glob.glob(os.path.join(ROOT, sys.argv[1]))):
        if not path.endswith((".gb", ".gbc")): continue
        fn = os.path.basename(path)
        for dev in ("dmg", "cgb"):
            exp = expected(fn, dev)
            if exp is None: continue
            with open("/tmp/windot.tsv", "w") as f:
                f.write("%s\thex\t%s\t%s\n" % (dev, exp, path))
            r = subprocess.run([DT, "--mode=gambatte", "--list=/tmp/windot.tsv"],
                               capture_output=True, text=True)
            all_lines = (r.stdout + r.stderr).splitlines()
            # mode=1 is V-Blank: every one of these ROMs sets its registers up
            # there, and those writes are never the one the family is moving.
            trace = [l for l in all_lines
                     if re.search(PAT, l) and " mode=1" not in l]
            got = [l for l in all_lines if l.startswith("GAM ")]
            print("%-58s %s exp=%s | %s" % (
                fn[:58], dev, exp,
                got[0].split(" ", 2)[2].strip() if got else "?"))
            for l in trace[-TAIL:]: print("      ", l)


main()
