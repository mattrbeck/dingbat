#!/usr/bin/env python3
"""Every SameSuite APU ROM x every CGB revision + AGB, dingbat beside the
sameboy_ssdump runner.

    tools/gbapu/ssgrid.py            # the 70 x 6 grid, then a disagreement list
    tools/gbapu/ssgrid.py ding       # dingbat only (no SameBoy build needed)

`.` = the ROM's own `$CFFE` says PASS, `X` = FAIL. The verdict byte is
compared rather than the result buffers: the runner plays the boot ROM and
dingbat skips it, so the two start on different APU tick phases and some
staircases shift by a cell without either being wrong.

same-suite/apu/README.md: CGB-C fails most channel 1/2/4 tests (PCM12/PCM34
read glitch), CGB-E passes all; `build_samesuite_apu_tests` defaults to cgbE.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CACHE = os.environ.get("DINGBAT_ROM_CACHE", "/tmp/dingbat-test-roms")
APU = os.path.join(CACHE, "game-boy-test-roms/same-suite/apu")
BOOT = os.environ.get("SAMEBOY_BOOTROMS",
                      os.path.expanduser("~/code/SameBoy/build/bin/BootROMs"))
MODELS = [("cgb0", "0"), ("cgbAB", "B"), ("cgbC", "C"),
          ("cgbD", "D"), ("cgbE", "E"), ("agb", "agb")]
VERDICT = {"50": ".", "46": "X"}      # $CFFE, set by the ROM's compare loop


def verdict(out):
    return VERDICT.get(out[0x1FFC:0x1FFE], "?")


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    roms = sorted(glob.glob(APU + "/**/*.gb", recursive=True))
    if not roms:
        sys.exit("no ROMs under " + APU)
    print("%-46s %s" % ("", "  ".join("%-7s" % m for m, _ in MODELS)))
    dis, npass = [], [0] * len(MODELS)
    for p in roms:
        name = os.path.relpath(p, APU)[:-3]
        cells, verds = [], []
        for i, (m, sm) in enumerate(MODELS):
            d = s = "-"
            if which != "sb":
                d = verdict(subprocess.run(
                    [ROOT + "/tools/gbapu/ssdump", p, "400", m, "4096"],
                    capture_output=True, text=True).stdout.strip())
                if d == ".":
                    npass[i] += 1
            if which != "ding":
                s = verdict(subprocess.run(
                    [ROOT + "/tools/gbfuzz/sameboy_ssdump", p, sm, BOOT, "400", "4096"],
                    capture_output=True, text=True).stdout.strip())
            cells.append("d%s s%s " % (d, s))
            verds.append((m, d, s))
        print("%-46s %s" % (name, "  ".join(cells)))
        bad = [m for m, d, s in verds if "-" not in (d, s) and d != s]
        if bad:
            dis.append((name, bad))
    print("\ndingbat forced to one revision: " +
          ", ".join("%s %d/%d" % (m, npass[i], len(roms))
                    for i, (m, _) in enumerate(MODELS)))
    if which == "both":
        print("dingbat/SameBoy disagreements: %d ROMs" % len(dis))
        for n, b in dis:
            print("   %-44s %s" % (n, " ".join(b)))


main()
