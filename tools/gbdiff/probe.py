#!/usr/bin/env python3
"""Reduce one divergence: shoot a frame window in both emulators and classify.

Usage:
    tools/gbdiff/probe.py <rom> <frame> [--window N] [--boot DIR]
                          [--out DIR] [--script S] [--png]

Shoots frames [frame-N .. frame+N] in both emulators and prints a matrix of
which dingbat frame equals which docboy frame. That single question --
"is dingbat's frame F equal to docboy's frame F, or to one of its neighbours?"
-- separates the two failure modes that look identical in a raw diff:

  * PHASE: dingbat frame F matches docboy frame F+k for a constant k. The two
    emulators render the same thing, one is just running ahead. This is a
    frame-pacing question (when does a frame boundary fall, especially across
    an LCD off/on transition), not a rendering one.
  * CONTENT: no offset matches. The emulators genuinely draw different pixels,
    and the diff bounding box says where.

Anything reported as CONTENT is a candidate real bug -- in either emulator.
Adjudicate it from Pan Docs and the test ROM's own bracketing family, never by
assuming the oracle is right.
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DINGBAT = os.path.join(REPO, "tools", "gbfuzz", "dingbat_gb_nav")


def is_cgb(rom):
    with open(rom, "rb") as f:
        return (f.read(0x150)[0x143] & 0x80) != 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("frame", type=int)
    ap.add_argument("--window", type=int, default=3)
    ap.add_argument("--boot", default="/tmp/gbdiff-work/boot")
    ap.add_argument("--out", default="/tmp/gbdiff-work/probe")
    ap.add_argument("--script", default="")
    ap.add_argument("--png", action="store_true")
    args = ap.parse_args()

    model = "cgb" if is_cgb(args.rom) else "dmg"
    docboy = os.path.join(HERE, "docboy_gb_runner_" + model)

    lo = max(0, args.frame - args.window)
    hi = args.frame + args.window
    shots = ",".join(str(f) for f in range(lo, hi + 1))

    name = os.path.basename(args.rom)
    pre = {}
    for who, exe in (("dingbat", DINGBAT), ("docboy", docboy)):
        d = os.path.join(args.out, who)
        os.makedirs(os.path.join(d, "roms"), exist_ok=True)
        link = os.path.join(d, "roms", name)
        # Fresh symlink and no stale battery save, as in sweep.py.
        for stale in os.listdir(os.path.join(d, "roms")):
            os.unlink(os.path.join(d, "roms", stale))
        os.symlink(os.path.abspath(args.rom), link)
        pre[who] = os.path.join(d, "shot")
        env = dict(os.environ, TMPDIR=d)
        subprocess.run([exe, link, args.boot, pre[who], args.script, shots],
                       cwd=d, env=env, check=True, stdout=subprocess.DEVNULL)

    def load(who, f):
        p = "%s.f%04d.ppm" % (pre[who], f)
        return open(p, "rb").read() if os.path.exists(p) else None

    ding = {f: load("dingbat", f) for f in range(lo, hi + 1)}
    doc = {f: load("docboy", f) for f in range(lo, hi + 1)}

    print("%s  frame %d  (%s)" % (name, args.frame, model))
    print("\n    dingbat frame -> matching docboy frames")
    offsets = {}
    for f in range(lo, hi + 1):
        if ding[f] is None:
            continue
        hits = [g for g in range(lo, hi + 1) if doc[g] is not None and doc[g] == ding[f]]
        print("      f%-6d %s" % (f, ("== docboy " + ", ".join("f%d" % g for g in hits))
                                  if hits else "(no match in window)"))
        for g in hits:
            offsets[g - f] = offsets.get(g - f, 0) + 1

    n = hi - lo + 1
    if offsets:
        k, hits = max(offsets.items(), key=lambda kv: kv[1])
        if k == 0 and hits == n:
            print("\n  VERDICT: identical across the whole window")
        elif hits >= max(2, n - 2 * abs(k)):
            print("\n  VERDICT: PHASE -- dingbat frame F == docboy frame F%+d (%d/%d frames)"
                  % (k, hits, n))
            print("  A frame-pacing difference, not a rendering one.")
        else:
            print("\n  VERDICT: CONTENT (only %d partial matches, no consistent offset)" % hits)
    else:
        print("\n  VERDICT: CONTENT -- no frame in the window matches any other")

    a = "%s.f%04d.ppm" % (pre["dingbat"], args.frame)
    b = "%s.f%04d.ppm" % (pre["docboy"], args.frame)
    print()
    cmd = [sys.executable, os.path.join(HERE, "ppmdiff.py"), a, b]
    if args.png:
        cmd += ["--png", os.path.join(args.out, "diff.f%04d.png" % args.frame)]
    subprocess.run(cmd)
    print("\n  dingbat: %s\n  docboy:  %s" % (a, b))


main()
