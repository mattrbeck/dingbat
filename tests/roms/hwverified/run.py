#!/usr/bin/env python3
"""Runs the hwverified proof ROMs against dingbat and scores each one by
its own verdict pixel.

Every ROM in this directory self-judges: it compares its measured bytes
against baked-in hardware-verified expectations and paints a 4x4 block
in the bottom-right corner of the mode-3 framebuffer — GREEN if every
checked cell matched, RED if any mismatched.  The block is painted only
after all experiments complete, so a hang reads as inconclusive (the
corner stays white), never as a pass.  This script samples pixel
(239,159) of a `--mode=screenshot --color` PPM per ROM.

Usage: python3 tests/roms/hwverified/run.py   (from the repo root, or
anywhere — it finds dingbat_test next to the repo root).  Exits 0 iff
all ROMs PASS.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

ROMS = ["msrtbit", "psrmask", "thumbcmp", "ldmuser", "pcwb", "bxdecode",
        "irqwin", "dmabyte", "capdma", "sweep", "iomap"]

TIMEOUT_FRAMES = 600   # sweep's capped poll rows are the slowest (~1 emulated s)


def verdict_pixel(ppm_path):
    with open(ppm_path, "rb") as f:
        data = f.read()
    # P6 <w> <h> 255\n then binary RGB
    header, _, rest = data.partition(b"255\n")
    dims = header.split()
    w, h = int(dims[1]), int(dims[2])
    off = ((h - 1) * w + (w - 1)) * 3
    return tuple(rest[off:off + 3])


def classify(rgb):
    r, g, b = rgb
    if g > 200 and r < 80 and b < 80:
        return "PASS"
    if r > 200 and g < 80 and b < 80:
        return "FAIL"
    return "INCONCLUSIVE"


def main():
    harness = os.path.join(ROOT, "dingbat_test")
    if not os.path.exists(harness):
        sys.exit("dingbat_test not found — run `nimble test_build` first")
    failures = 0
    for name in ROMS:
        rom = os.path.join(HERE, name + ".gba")
        ppm = os.path.join(tempfile.gettempdir(), f"hwverified_{name}.ppm")
        proc = subprocess.run(
            [harness, rom, "--mode=screenshot", "--color", "--nosave",
             f"--timeout={TIMEOUT_FRAMES}", f"--screenshot={ppm}"],
            cwd=ROOT, capture_output=True)
        if proc.returncode != 0 or not os.path.exists(ppm):
            status, detail = "INCONCLUSIVE", f"harness exit {proc.returncode}"
        else:
            rgb = verdict_pixel(ppm)
            status, detail = classify(rgb), f"pixel(239,159)={rgb}"
            os.remove(ppm)
        if status != "PASS":
            failures += 1
        print(f"{name:9s} {status:12s} {detail}")
    print(f"{len(ROMS) - failures}/{len(ROMS)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
