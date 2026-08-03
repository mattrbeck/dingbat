#!/usr/bin/env python3
"""Differential sweep: dingbat vs docboy, frame-by-frame, over a ROM list.

Usage:
    tools/gbdiff/sweep.py <roms.txt> <workdir> [--frames N] [--step S]
                          [--boot DIR] [--jobs J] [--timeout SEC]
                          [--script SCRIPT] [--keep-ppm]

`roms.txt` is one absolute ROM path per line (`#` comments allowed); paths may
contain spaces. Each ROM is run once in each emulator with screenshots every
`--step` frames up to `--frames`, and the PPMs are compared byte-for-byte.

Output is `<workdir>/results.tsv`:

    rom <TAB> model <TAB> status <TAB> first-diff-frame <TAB> diff-pixels

with status one of IDENTICAL, DIVERGE, TIMEOUT, ERROR, SKIP.

This is an *oracle* comparison, not a regression gate: a DIVERGE means the two
emulators disagree, not that either is wrong. Adjudicate with the test ROM's
own bracketing family and Pan Docs -- never by assuming the other emulator is
right. See README.md.

Hygiene, all of it learned the hard way on this project (see tools/gbgate):
  * ROMs are symlinked into a per-emulator directory, never copied, and each
    emulator gets its own. dingbat derives the .sav path from the ROM path, so
    a battery-backed game writes its save next to the *symlink*; separate
    directories keep one run's saves out of the other's, and both are deleted
    before every ROM so a sweep cannot carry state between titles.
  * Each child gets its own TMPDIR.
  * The ROM list is read line-by-line, so a name with a space cannot truncate
    the sweep.
  * Children are run with a timeout and killed by process group, so a hung
    ROM cannot wedge the harness.
"""

import argparse
import os
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DINGBAT = os.path.join(REPO, "tools", "gbfuzz", "dingbat_gb_nav")


def is_cgb(rom):
    """Cartridge CGB flag, the rule every runner in this repo uses."""
    with open(rom, "rb") as f:
        hdr = f.read(0x150)
    if len(hdr) < 0x150:
        return None
    return (hdr[0x143] & 0x80) != 0


def run(cmd, cwd, tmpdir, timeout):
    env = dict(os.environ)
    env["TMPDIR"] = tmpdir
    try:
        p = subprocess.run(
            cmd, cwd=cwd, env=env, timeout=timeout,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            start_new_session=True)
        return p.returncode, p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return "timeout", ""


def sweep_one(rom, args, shots, slot):
    """Run both emulators over one ROM. `slot` isolates parallel workers."""
    name = os.path.basename(rom)
    cgb = is_cgb(rom)
    if cgb is None:
        return (rom, "?", "SKIP", -1, 0, "rom too small")

    model = "cgb" if cgb else "dmg"
    docboy = os.path.join(HERE, "docboy_gb_runner_" + model)
    if not os.path.exists(docboy):
        return (rom, model, "ERROR", -1, 0, "no runner, run build.sh")

    base = os.path.join(args.workdir, "w%d" % slot)
    out = {}
    for who in ("dingbat", "docboy"):
        d = os.path.join(base, who)
        os.makedirs(os.path.join(d, "roms"), exist_ok=True)
        os.makedirs(os.path.join(d, "tmp"), exist_ok=True)
        # Fresh symlink + no stale battery save: see the module docstring.
        for stale in os.listdir(os.path.join(d, "roms")):
            os.unlink(os.path.join(d, "roms", stale))
        link = os.path.join(d, "roms", name)
        os.symlink(rom, link)
        out[who] = (d, link)

    shotlist = ",".join(str(s) for s in shots)
    prefix = {}
    for who, exe in (("dingbat", DINGBAT), ("docboy", docboy)):
        d, link = out[who]
        pre = os.path.join(d, "shot")
        prefix[who] = pre
        for stale in os.listdir(d):
            if stale.startswith("shot."):
                os.unlink(os.path.join(d, stale))
        rc, err = run([exe, link, args.boot, pre, args.script, shotlist],
                      d, os.path.join(d, "tmp"), args.timeout)
        if rc == "timeout":
            return (rom, model, "TIMEOUT", -1, 0, who)
        if rc != 0:
            return (rom, model, "ERROR", -1, 0, "%s rc=%s %s" % (who, rc, err.strip()[:120]))

    first, npix = -1, 0
    for s in shots:
        fa = "%s.f%04d.ppm" % (prefix["dingbat"], s)
        fb = "%s.f%04d.ppm" % (prefix["docboy"], s)
        if not (os.path.exists(fa) and os.path.exists(fb)):
            return (rom, model, "ERROR", -1, 0, "missing shot f%04d" % s)
        a = open(fa, "rb").read()
        b = open(fb, "rb").read()
        if a != b:
            first = s
            body_a, body_b = a[15:], b[15:]
            npix = sum(1 for i in range(0, min(len(body_a), len(body_b)), 3)
                       if body_a[i:i + 3] != body_b[i:i + 3])
            break

    if args.keep_ppm and first >= 0:
        keep = os.path.join(args.workdir, "diffs", name)
        os.makedirs(keep, exist_ok=True)
        for who in ("dingbat", "docboy"):
            shutil.copy("%s.f%04d.ppm" % (prefix[who], first),
                        os.path.join(keep, "%s.f%04d.ppm" % (who, first)))

    if first < 0:
        return (rom, model, "IDENTICAL", -1, 0, "")
    return (rom, model, "DIVERGE", first, npix, "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("roms")
    ap.add_argument("workdir")
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--step", type=int, default=30)
    ap.add_argument("--boot", default="/tmp/gbdiff-work/boot")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--script", default="")
    ap.add_argument("--keep-ppm", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.workdir, exist_ok=True)
    roms = []
    with open(args.roms) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                roms.append(line)

    shots = list(range(args.step, args.frames + 1, args.step))
    print("%d ROMs, shots every %d up to %d (%d per ROM)"
          % (len(roms), args.step, args.frames, len(shots)), file=sys.stderr)

    # Each concurrent worker needs its own scratch directory, and a thread pool
    # gives no guarantee about which task lands on which thread -- indexing
    # slots by ROM number would let two live tasks share one directory and
    # overwrite each other's screenshots. Hand slots out from a free list
    # instead, so a slot is held for exactly the duration of one ROM.
    free_slots = list(range(args.jobs))
    slot_lock = threading.Lock()

    def with_slot(rom):
        with slot_lock:
            slot = free_slots.pop()
        try:
            return sweep_one(rom, args, shots, slot)
        finally:
            with slot_lock:
                free_slots.append(slot)

    results = [None] * len(roms)
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(with_slot, r): i for i, r in enumerate(roms)}
        done = 0
        for fut, i in futs.items():
            results[i] = fut.result()
            done += 1
            r = results[i]
            print("[%d/%d] %-52s %-4s %-10s %s"
                  % (done, len(roms), os.path.basename(r[0])[:52], r[1], r[2],
                     ("f%04d %d px" % (r[3], r[4])) if r[2] == "DIVERGE" else r[5]),
                  file=sys.stderr, flush=True)

    tsv = os.path.join(args.workdir, "results.tsv")
    with open(tsv, "w") as f:
        for r in results:
            f.write("%s\t%s\t%s\t%d\t%d\t%s\n" % r)
    counts = {}
    for r in results:
        counts[r[2]] = counts.get(r[2], 0) + 1
    print("\n" + "  ".join("%s=%d" % kv for kv in sorted(counts.items())), file=sys.stderr)
    print(tsv, file=sys.stderr)


main()
