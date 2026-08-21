#!/usr/bin/env python3
"""Every SameSuite APU ROM x every CGB revision + AGB, dingbat beside SameBoy.

    tools/gbapu/ssgrid.py            # the 70 x 6 grid, then a disagreement list
    tools/gbapu/ssgrid.py ding       # dingbat only (no SameBoy build needed)

`.` = the ROM's own `$CFFE` says PASS, `X` = FAIL.  Reading the verdict byte
rather than diffing result buffers is what makes SameBoy usable here at all:
SameBoy plays the boot ROM and dingbat skips it, which leaves the two on
different APU tick phases, and on some of these ROMs that shifts the whole
staircase by a cell or two without either emulator being wrong.

This is the instrument that decides which MACHINE a row should be scored on.
`same-suite/apu/README.md` states the answer -- CGB-C fails most of the
channel 1/2/4 tests because of the PCM12/PCM34 read glitch, CGB-E passes all of
them -- and this grid is that paragraph, measured.  It is why
`build_samesuite_apu_tests` defaults the sub-suite to cgbE.

Baseline, 2026-08-21: dingbat forced to one revision scores 46/70 at cgb0 and
cgbAB, 42/70 at cgbC, 63/70 at cgbD, cgbE and agb; with the filename tokens and
the cgbE default, 70/70.  375 of the 420 dingbat/SameBoy verdicts agree; the 45
that do not are listed at GbQuirks.pcm_read_edge_zero in gb.nim.
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
