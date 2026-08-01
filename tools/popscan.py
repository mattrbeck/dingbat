#!/usr/bin/env python3
"""Find and count audible *pops* in a raw s16le stereo PCM dump.

Reads the same format tools/pcmdiff.py does -- interleaved little-endian
signed 16-bit L,R frames, no header, 32768 Hz by default:

    DINGBAT_GB_AUDIO_DUMP=<path>   dingbat GB core
    GBFUZZ_PCM=<path>              tools/gbfuzz/sameboy_runner

WHY NOT A RAW SAMPLE-DELTA THRESHOLD
------------------------------------
A Game Boy square wave IS a sequence of full-scale sample-to-sample jumps: at
a 32768 Hz sample-and-hold of an un-band-limited DAC mix, ordinary music has
|delta| at full scale thousands of times a second. Counting large deltas
therefore measures how much square wave is playing, not how much popping.
It also cannot be compared against SameBoy, which band-limits each channel
and so has small deltas everywhere by construction.

WHAT A POP ACTUALLY IS
----------------------
The artefact is a step in the signal's *local mean* -- the DC level. A square
wave oscillates about a stable mean, so the mean is flat while a note plays
and no matter how loud it is. But a Game Boy channel's DAC does not idle at
the middle of its range: an enabled channel emitting digital 0 sits at the
bottom rail, while a disabled channel contributes nothing at all. So every
channel enable, disable, DAC on and DAC off shifts the mix's DC level by a
constant, instantly. Real hardware puts a DC-blocking capacitor after the
mixer, which turns that step into a decaying transient and removes the
sustained offset; an emulator without one passes the raw step through, and a
step in the DC level is exactly what a speaker reproduces as a click.

So the measurement here is: track the local mean over a short window, and
count the places where it moves further than a threshold in one window. That
is insensitive to waveform shape, frequency, phase and volume, and it is
directly comparable between two emulators.

METRICS
-------
  dc_steps      count of window-to-window local-mean jumps above --dc-thresh
  dc_range      peak-to-peak excursion of the local mean over the whole run
  dc_rms        RMS of the local mean (a healthy DC-blocked signal is ~0)
  max_dc_step   largest single jump, with its timestamp
  d1_pXX        percentiles of |sample delta|, for reference only

--json prints one line of JSON, for driving `git bisect run` off a number.

Exit status: 0 always in report mode; with --max-dc-steps N, 1 when the count
exceeds N (so it can be used as a bisect predicate), 2 on IO/usage error.
"""

import argparse
import json
import math
import sys

try:
    import numpy as np
except ImportError:
    sys.stderr.write("popscan: numpy is required\n")
    sys.exit(2)

BYTES_PER_FRAME = 4


def read_pcm(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        sys.stderr.write("popscan: %s\n" % e)
        sys.exit(2)
    odd = len(raw) % BYTES_PER_FRAME
    if odd:
        raw = raw[:len(raw) - odd]
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    return a.reshape(-1, 2)


def fmt_time(frame, rate):
    s = frame / float(rate)
    return "%d:%06.3f" % (int(s // 60), s % 60)


def analyse(x, rate, win, dc_thresh, skip):
    """x: (nframes, 2) float64. Returns a dict of metrics for one channel pair."""
    nf = x.shape[0]
    # Drop the first `skip` frames: both emulators come up with the APU in a
    # transient state and the very first samples are not comparable.
    if skip and nf > skip:
        x = x[skip:]
        nf = x.shape[0]
    nwin = nf // win
    if nwin < 3:
        return None
    trimmed = x[:nwin * win]
    # Local mean per window, per channel: this is the DC trajectory.
    means = trimmed.reshape(nwin, win, 2).mean(axis=1)     # (nwin, 2)
    # Mono-sum the two channels for the headline figure but keep both, since a
    # channel that is panned hard to one side pops on one side only.
    out = {}
    for ci, cname in ((0, "L"), (1, "R")):
        m = means[:, ci]
        d = np.abs(np.diff(m))
        idx = np.flatnonzero(d > dc_thresh)
        order = np.argsort(-d[idx])[:20] if idx.size else np.array([], dtype=int)
        top = [(float(d[idx[k]]), int((idx[k] + 1) * win) + skip)
               for k in order]
        out[cname] = {
            "dc_steps": int(idx.size),
            # Total variation of the DC trajectory, per second: how far the DC
            # level travels in total. Threshold-free, so it is the better
            # number to drive a bisect off -- it moves smoothly rather than
            # falling off a cliff when steps sit near --dc-thresh.
            "dc_tv_per_s": float(d.sum()) / (nf / float(rate)),
            "dc_range": float(m.max() - m.min()),
            "dc_rms": float(math.sqrt(float((m ** 2).mean()))),
            "dc_mean": float(m.mean()),
            "max_dc_step": float(d.max()) if d.size else 0.0,
            "max_dc_step_frame": int((int(np.argmax(d)) + 1) * win) + skip
                                 if d.size else 0,
            "top": top,
        }
    sig = trimmed[:, 0]
    d1 = np.abs(np.diff(sig))
    out["_common"] = {
        "frames": int(nf),
        "seconds": nf / float(rate),
        "rms": float(math.sqrt(float((trimmed ** 2).mean()))),
        "d1_p50": float(np.percentile(d1, 50)) if d1.size else 0.0,
        "d1_p99": float(np.percentile(d1, 99)) if d1.size else 0.0,
        "d1_max": float(d1.max()) if d1.size else 0.0,
        "window": win,
        "window_ms": 1000.0 * win / rate,
        "dc_thresh": dc_thresh,
    }
    return out


def main():
    p = argparse.ArgumentParser(
        description="Find DC-step pops in a raw s16le stereo PCM dump.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("pcm", help="raw s16le stereo PCM")
    p.add_argument("--rate", type=int, default=32768)
    p.add_argument("--window", type=int, default=1024,
                   help="local-mean window in frames (default 1024 ~= 31 ms). "
                        "This has to be long enough to average musical content "
                        "away: a 31 ms window rejects everything above ~32 Hz, "
                        "which is below the lowest note a Game Boy plays, so "
                        "what is left in the local mean is DC and only DC. A "
                        "short window (say 2 ms) instead tracks the waveform "
                        "itself and just measures how much music is playing.")
    p.add_argument("--dc-thresh", type=float, default=2000.0,
                   help="a window-to-window local-mean jump above this counts "
                        "as a pop (default 2000 of 32768 full scale ~= 6%%)")
    p.add_argument("--skip", type=int, default=0,
                   help="ignore this many leading frames (power-on transient)")
    p.add_argument("--json", action="store_true",
                   help="print one line of JSON instead of a report")
    p.add_argument("--max-dc-steps", type=int, default=None,
                   help="exit 1 if the L-channel dc_steps count exceeds this "
                        "(bisect predicate)")
    args = p.parse_args()

    x = read_pcm(args.pcm)
    r = analyse(x, args.rate, args.window, args.dc_thresh, args.skip)
    if r is None:
        sys.stderr.write("popscan: too little data\n")
        return 2

    c = r["_common"]
    if args.json:
        flat = {"path": args.pcm}
        flat.update(c)
        for ch in ("L", "R"):
            for k, v in r[ch].items():
                if k != "top":
                    flat["%s_%s" % (ch.lower(), k)] = v
        print(json.dumps(flat, sort_keys=True))
    else:
        print("file:   %s" % args.pcm)
        print("length: %d frames, %.3f s at %d Hz   rms=%.1f"
              % (c["frames"], c["seconds"], args.rate, c["rms"]))
        print("local mean over %d-frame (%.2f ms) windows; a jump > %.0f counts"
              " as a pop" % (c["window"], c["window_ms"], c["dc_thresh"]))
        print()
        for ch in ("L", "R"):
            d = r[ch]
            print("  %s: dc_steps=%-6d  per_sec=%-7.2f  dc_tv/s=%-9.1f "
                  "dc_range=%-8.1f dc_mean=%+.1f"
                  % (ch, d["dc_steps"], d["dc_steps"] / c["seconds"],
                     d["dc_tv_per_s"], d["dc_range"], d["dc_mean"]))
            print("     max jump %.1f at %s"
                  % (d["max_dc_step"],
                     fmt_time(d["max_dc_step_frame"], args.rate)))
        print()
        print("  |sample delta| p50=%.0f p99=%.0f max=%.0f  (reference only --"
              " square waves make these large by nature)"
              % (c["d1_p50"], c["d1_p99"], c["d1_max"]))
        top = r["L"]["top"]
        if top:
            print("\n  largest L-channel DC jumps:")
            for mag, fr in top[:12]:
                print("    %8.1f  at %s" % (mag, fmt_time(fr, args.rate)))

    if args.max_dc_steps is not None:
        return 1 if r["L"]["dc_steps"] > args.max_dc_steps else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
