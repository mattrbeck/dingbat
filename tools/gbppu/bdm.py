#!/usr/bin/env python3
"""Run a ROM in Beaten Dying Moon Simple (BDM) and capture its screen.

BDM selects the SoC directly (-dev dmgC, mgb, cgbE, ...), which makes it a
per-revision reference. It has no screenshot or headless mode and echoes
nothing (not even serial), so the screen is the only channel: `screencapture`
needs macOS Screen Recording permission for the process running this script.

Usage:
    bdm.py <rom> [-dev DEV] [-wait SECONDS] [-out FILE] [-scale N] [-full]
The BDM binary is $BDM (default <repo>/reference/bdms).

`-wait` is how long to let the ROM run before capturing; BDM never exits on
its own, so it is always killed on that deadline (-turbo is always on). The
capture is cropped to BDM's window when it can be located; `-full` keeps the
whole screen.
"""
import argparse, os, signal, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BDM = os.environ.get("BDM", os.path.join(ROOT, "reference", "bdms"))

DEVICES = ("dmg0", "dmgA", "dmgB", "dmgC", "mgb", "sgb", "sgb2",
           "cgb0", "cgbA", "cgbB", "cgbC", "cgbD", "cgbE", "agb0",
           "pokemon_stadium_2")


def window_bounds(pid):
    """BDM's window rect via CoreGraphics, or None."""
    try:
        import Quartz
    except Exception:
        return None
    for w in Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerPID") == pid:
            b = w.get("kCGWindowBounds")
            if b and b["Width"] > 100:
                return (int(b["X"]), int(b["Y"]), int(b["Width"]), int(b["Height"]))
    return None


def run(rom, dev="dmgC", wait=4.0, out="bdm.png", scale=3, full=False):
    if not os.path.exists(BDM):
        sys.exit("BDM not found at %s" % BDM)
    if not os.path.exists(rom):
        sys.exit("ROM not found: %s" % rom)
    if dev not in DEVICES:
        sys.exit("unknown -dev %r; one of: %s" % (dev, ", ".join(DEVICES)))

    cmd = [BDM, "-dev", dev, "-turbo", "-scale", str(scale), os.path.abspath(rom)]
    # Process group, so the kill below reaches BDM once SDL owns the window.
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         cwd=os.path.dirname(BDM), start_new_session=True)
    time.sleep(wait)

    rect = None if full else window_bounds(p.pid)
    args = ["screencapture", "-x", "-o"]
    if rect:
        args += ["-R", "%d,%d,%d,%d" % rect]
    args.append(out)
    cap = subprocess.run(args, capture_output=True)

    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    stdout = p.communicate()[0].decode("utf-8", "replace")

    if stdout.strip():
        print("BDM said: %s" % stdout.strip()[:400])
    if cap.returncode != 0:
        msg = cap.stderr.decode().strip() or "(no message)"
        print("SCREEN CAPTURE FAILED: %s" % msg)
        print("  This is almost always macOS Screen Recording permission.")
        print("  System Settings -> Privacy & Security -> Screen Recording,")
        print("  add the terminal running this, then restart it.")
        print("  BDM itself ran fine; only reading its window is blocked.")
        return None
    print("wrote %s%s" % (out, "" if rect else "  (full screen; window not located)"))
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("-dev", default="dmgC")
    ap.add_argument("-wait", type=float, default=4.0)
    ap.add_argument("-out", default="bdm.png")
    ap.add_argument("-scale", type=int, default=3)
    ap.add_argument("-full", action="store_true")
    a = ap.parse_args()
    run(a.rom, a.dev, a.wait, a.out, a.scale, a.full)
