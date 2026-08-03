#!/usr/bin/env python3
"""Cross-tabulate dingbat and docboy against gambatte's own expected values.

Usage:
    tools/gbdiff/gambatte_ab.py <roms.txt> <workdir> [--dev cgb|dmg]
                                [--frames "200,300"] [--boot DIR] [--jobs J]

For each ROM this runs both emulators, reads the on-screen hex result out of
the screenshot (see readout.py), and compares both against the expected value
encoded in the ROM's filename. The filename is the ground truth -- neither
emulator is. That makes the output a four-way verdict:

    BOTH_PASS    nothing to see
    DINGBAT_ONLY dingbat right, docboy wrong    -- a docboy bug; no action here
    DOCBOY_ONLY  docboy right, dingbat wrong    -- the valuable column: correct
                 behaviour is demonstrably reachable, so investigate dingbat
    BOTH_FAIL    neither matches hardware. If the ROM belongs to a _1/_2/_3
                 bracketing family and the two emulators give the family's
                 two different answers, they BRACKET the hardware transition
                 point and neither can be used to correct the other.

`--frames` takes two frame numbers; a row is only scored if the reading is the
same at both, so a ROM whose display is still settling is reported UNSTABLE
rather than scored on a half-drawn screen.

Device rows and expected values follow the bundle's own
gambatte/game-boy-test-roms-howto.md rules, the same ones
tests/dingbat_test_runner.nim applies, so a verdict here is directly
comparable with tests/results_gambatte.md.
"""

import argparse
import os
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DINGBAT = os.path.join(REPO, "tools", "gbfuzz", "dingbat_gb_nav")
sys.path.insert(0, HERE)


def expected_for(fname, dev):
    """Expected hex string for `dev` ("dmg"/"cgb"), or None if not a row.

    gambatte's precedence: a shared `dmg08_cgb04c_out` tag scores both
    devices; otherwise `dmg08_out` and `cgb04c_out` are read separately. The
    value is the leading run of hex digits after the tag, stopping at the
    first character that is not 0-9/a-f.
    """
    stem = os.path.splitext(fname)[0]
    if "dmg08_cgb04c_out" in stem:
        marker = "dmg08_cgb04c_out"
    elif dev == "dmg":
        marker = "dmg08_out" if "dmg08_out" in stem else None
    else:
        if "cgb04c_out" in stem:
            marker = "cgb04c_out"
        elif "dmg08_out" not in stem and "_out" in stem:
            marker = "_out"
        else:
            marker = None
    if not marker or marker not in stem:
        return None
    tail = stem[stem.find(marker) + len(marker):]
    if tail.startswith("audio0") or tail.startswith("audio1"):
        return None
    m = re.match(r"[0-9a-fA-F]+", tail)
    return m.group(0).upper() if m else None


from readout import glyphs as readout  # noqa: E402  (needs HERE on sys.path)


def one(rom, args, slot):
    fname = os.path.basename(rom)
    exp = expected_for(fname, args.dev)
    if exp is None:
        return (rom, args.dev, "-", "-", "-", "NOROW")

    docboy = os.path.join(HERE, "docboy_gb_runner_" + args.dev)
    frames = [int(f) for f in args.frames.split(",")]
    shots = ",".join(str(f) for f in frames)

    got = {}
    for who, exe in (("dingbat", DINGBAT), ("docboy", docboy)):
        d = os.path.join(args.workdir, "w%d" % slot, who)
        os.makedirs(os.path.join(d, "roms"), exist_ok=True)
        for stale in os.listdir(os.path.join(d, "roms")):
            os.unlink(os.path.join(d, "roms", stale))
        link = os.path.join(d, "roms", fname)
        os.symlink(rom, link)
        pre = os.path.join(d, "shot")
        for stale in os.listdir(d):
            if stale.startswith("shot."):
                os.unlink(os.path.join(d, stale))
        env = dict(os.environ, TMPDIR=d)
        try:
            p = subprocess.run([exe, link, args.boot, pre, "", shots], cwd=d, env=env,
                               timeout=args.timeout, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return (rom, args.dev, exp, "TIMEOUT", "TIMEOUT", "ERROR")
        if p.returncode != 0:
            return (rom, args.dev, exp, "ERR", "ERR", "ERROR")
        vals = []
        for f in frames:
            ppm = "%s.f%04d.ppm" % (pre, f)
            if not os.path.exists(ppm):
                return (rom, args.dev, exp, "NOSHOT", "NOSHOT", "ERROR")
            vals.append(readout(ppm, len(exp)))
        # Only score a reading the display has settled on.
        got[who] = vals[0] if len(set(vals)) == 1 else "UNSTABLE"

    d_ok = got["dingbat"] == exp
    b_ok = got["docboy"] == exp
    if "UNSTABLE" in (got["dingbat"], got["docboy"]):
        verdict = "UNSTABLE"
    elif d_ok and b_ok:
        verdict = "BOTH_PASS"
    elif d_ok:
        verdict = "DINGBAT_ONLY"
    elif b_ok:
        verdict = "DOCBOY_ONLY"
    else:
        verdict = "BOTH_FAIL"
    return (rom, args.dev, exp, got["dingbat"], got["docboy"], verdict)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("roms")
    ap.add_argument("workdir")
    ap.add_argument("--dev", default="cgb", choices=["cgb", "dmg"])
    ap.add_argument("--frames", default="200,300")
    ap.add_argument("--boot", default="/tmp/gbdiff-work/boot")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    os.makedirs(args.workdir, exist_ok=True)
    roms = []
    with open(args.roms) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                roms.append(line)

    free = list(range(args.jobs))
    lock = threading.Lock()

    def with_slot(rom):
        with lock:
            slot = free.pop()
        try:
            return one(rom, args, slot)
        finally:
            with lock:
                free.append(slot)

    results = [None] * len(roms)
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(with_slot, r): i for i, r in enumerate(roms)}
        done = 0
        for fut, i in futs.items():
            results[i] = fut.result()
            done += 1
            if done % 50 == 0:
                print("  %d/%d" % (done, len(roms)), file=sys.stderr, flush=True)

    tsv = os.path.join(args.workdir, "gambatte_ab.tsv")
    with open(tsv, "w") as f:
        f.write("rom\tdev\texpected\tdingbat\tdocboy\tverdict\n")
        for r in results:
            if r[5] == "NOROW":
                continue
            f.write("%s\t%s\t%s\t%s\t%s\t%s\n"
                    % (os.path.relpath(r[0]), r[1], r[2], r[3], r[4], r[5]))

    counts = {}
    for r in results:
        counts[r[5]] = counts.get(r[5], 0) + 1
    print("\n".join("%-14s %d" % kv for kv in sorted(counts.items())), file=sys.stderr)
    print(tsv, file=sys.stderr)


main()
