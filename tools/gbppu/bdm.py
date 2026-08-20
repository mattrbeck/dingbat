#!/usr/bin/env python3
"""Run a ROM in Beaten Dying Moon Simple and capture its screen.

BDM is Matt Currie's emulator — the same author as mealybug-tearoom-tests,
cgb-acid2 and cgb-acid-hell — and it selects the SoC directly (`-dev dmgC`,
`-dev mgb`, `-dev cgbE`, ...), which makes it the only third opinion in reach
for the per-revision questions this tree keeps running into. SameBoy is the
other, and the two disagreeing is itself information.

WHAT THIS CAN AND CANNOT DO, measured 2026-08-20:

  * BDM Simple has NO screenshot option, NO headless mode, and NO frame limit.
    `strings` on the binary shows exactly five flags (-scale, -soft,
    -disable_high_dpi, -turbo, -ignore_boot_roms) plus the device selectors.
  * It prints NOTHING to stdout except errors like "ROM not found". Serial
    output is not echoed: verified with blargg/instr_timing (which writes text
    to serial) and a mooneye ROM (which sends the Fibonacci bytes) — both
    silent.
  * So the SCREEN is the only channel, and reading it needs macOS Screen
    Recording permission for whatever process runs this script. Without it
    `screencapture` fails with "could not create image from display" and this
    harness says so rather than writing an empty file.

Grant it under System Settings -> Privacy & Security -> Screen Recording, for
the terminal (or Claude Code) that runs this. Until then, run BDM by hand and
photograph the window — the ROM and device arguments below are the same either
way.

Usage:
    bdm.py <rom> [-dev DEV] [-wait SECONDS] [-out FILE] [-scale N] [-full]

`-wait` is how long to let the ROM run before capturing; BDM never exits on its
own, so the process is always killed on that deadline. `-turbo` is always on, so
a few seconds of wall clock is a great many emulated frames.

By default the capture is cropped to BDM's window if it can be located, and
`-full` keeps the whole screen instead.
"""
import argparse, os, signal, subprocess, sys, time

BDM = "/Users/matt/code/dingbat/reference/bdms"

DEVICES = ("dmg0", "dmgA", "dmgB", "dmgC", "mgb", "sgb", "sgb2",
           "cgb0", "cgbA", "cgbB", "cgbC", "cgbD", "cgbE", "agb0",
           "pokemon_stadium_2")


def window_bounds(pid):
    """BDM's window rect via CoreGraphics, or None. Used only to crop."""
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
    # start_new_session so the whole process group can be killed: BDM ignores
    # a plain terminate once SDL has the window.
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
