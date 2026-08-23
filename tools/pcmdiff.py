#!/usr/bin/env python3
"""Compare two raw s16le stereo PCM dumps.

Reads the format dingbat's audio dumps write -- interleaved little-endian
signed 16-bit L,R frames, no header:

    DINGBAT_GB_AUDIO_DUMP=<path>   GB core        (32768 Hz)
    DINGBAT_AUDIO_DUMP=<path>      GBA core       (32768 Hz)
    GBFUZZ_PCM=<path>              tools/gbfuzz/sameboy_runner (32768 Hz)

Default mode is the strict gate: byte equality, and when that fails, where and
how badly. Two dingbat builds must produce bit-identical audio for the same
ROM and frame count, so any difference is a behaviour change (the audio
equivalent of a byte-identical screenshot check).

--correlate is the loose gate for comparing against a different emulator,
where bit equality is impossible (a different mixer, and clocks that drift
tens of ms apart over 50 s, so sample-level cross-correlation is only printed
as a diagnostic). The gate is the Pearson correlation of the per-100ms RMS
envelope: insensitive to waveform shape and phase drift, still catches wrong
tempo, a track only one side plays, and channel dropouts. It cannot certify
sample accuracy.

numpy is used when importable, purely for speed; there is a stdlib fallback.

Exit status: 0 pass, 1 differ/fail, 2 usage or IO error.
"""

import argparse
import array
import math
import sys

try:
    import numpy as _np
except ImportError:
    _np = None

BYTES_PER_FRAME = 4  # 2 channels * int16


def read_pcm(path):
    """Return (interleaved int16 samples, trailing bytes past the last frame).

    The sample container is a numpy int16 array when numpy is available, else
    an array.array('h'); both index and slice the same way for our purposes.
    """
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        sys.stderr.write("pcmdiff: %s\n" % e)
        sys.exit(2)
    odd = len(raw) % BYTES_PER_FRAME
    if odd:
        raw = raw[:len(raw) - odd]
    if _np is not None:
        return _np.frombuffer(raw, dtype="<i2"), odd
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    return a, odd


def fmt_time(frames, rate):
    if rate <= 0:
        return "?"
    s = frames / float(rate)
    return "%d:%06.3f" % (int(s // 60), s % 60)


def describe(tag, path, nsamp, odd, rate):
    nf = nsamp // 2
    print("%s: %s" % (tag, path))
    print("   %d bytes, %d stereo frames, %s"
          % (nf * BYTES_PER_FRAME, nf, fmt_time(nf, rate)))
    if odd:
        print("   note: %d trailing byte(s) past the last whole frame "
              "(ignored)" % odd)
    return nf


# ---------------------------------------------------------------- strict mode

def strict(a, b, args, odd_a, odd_b):
    fa = describe("A", args.a, len(a), odd_a, args.rate)
    fb = describe("B", args.b, len(b), odd_b, args.rate)

    n = min(len(a), len(b))
    nf = n // 2
    if fa != fb:
        print("length differs: %+d stereo frames (%+d bytes); comparing the "
              "common %d-frame prefix"
              % (fb - fa, (fb - fa) * BYTES_PER_FRAME, nf))
    if n == 0:
        print("RESULT: no common data to compare")
        return 1

    if _np is not None:
        x = a[:n].astype(_np.int32)
        y = b[:n].astype(_np.int32)
        d = x - y
        nz = _np.flatnonzero(d)
        ndiff = int(nz.size)
        if ndiff:
            first = int(nz[0])
            ad = _np.abs(d)
            maxidx = int(_np.argmax(ad))
            maxdiff = int(ad[maxidx])
            rmsd = math.sqrt(float(_np.mean(d.astype(_np.float64) ** 2)))
        else:
            first = maxidx = -1
            maxdiff = 0
            rmsd = 0.0
    else:
        first = maxidx = -1
        ndiff = maxdiff = 0
        sumsq = 0
        for i in range(n):
            d = a[i] - b[i]
            if d:
                if first < 0:
                    first = i
                ndiff += 1
                ad = -d if d < 0 else d
                if ad > maxdiff:
                    maxdiff, maxidx = ad, i
                sumsq += d * d
        rmsd = math.sqrt(sumsq / n) if ndiff else 0.0

    if ndiff == 0 and fa == fb:
        print("RESULT: IDENTICAL (%d stereo frames, %d bytes)"
              % (fa, fa * BYTES_PER_FRAME))
        return 0
    if ndiff == 0:
        print("the common %d-frame prefix is identical; only the lengths "
              "differ" % nf)
        print("RESULT: DIFFER (length only)")
        return 1

    ch = "L" if first % 2 == 0 else "R"
    print("first differing sample: index %d (stereo frame %d, %s channel, "
          "t=%s)" % (first, first // 2, ch, fmt_time(first // 2, args.rate)))
    print("  A=%d  B=%d" % (a[first], b[first]))
    print("differing samples: %d / %d (%.4f%%)"
          % (ndiff, n, 100.0 * ndiff / n))
    print("max abs difference: %d at sample %d (stereo frame %d, t=%s)"
          % (maxdiff, maxidx, maxidx // 2, fmt_time(maxidx // 2, args.rate)))
    print("RMS difference: %.3f (%.4f%% of full scale)"
          % (rmsd, 100.0 * rmsd / 32768.0))
    print("RESULT: DIFFER")
    return 1


# ------------------------------------------------------------- correlate mode

def _rms(seq):
    if _np is not None:
        if seq.size == 0:
            return 0.0
        return float(_np.sqrt(_np.mean(seq.astype(_np.float64) ** 2)))
    if not len(seq):
        return 0.0
    return math.sqrt(sum(float(v) * v for v in seq) / len(seq))


def _xcorr(x, y, lag):
    """Normalized cross-correlation of x against y shifted by `lag` frames."""
    xs, ys = (0, lag) if lag >= 0 else (-lag, 0)
    n = min(len(x) - xs, len(y) - ys)
    if n <= 0:
        return 0.0
    if _np is not None:
        xv = x[xs:xs + n].astype(_np.float64)
        yv = y[ys:ys + n].astype(_np.float64)
        sx = float(xv @ xv)
        sy = float(yv @ yv)
        if sx == 0.0 or sy == 0.0:
            return 0.0
        return float(xv @ yv) / math.sqrt(sx * sy)
    num = sx = sy = 0.0
    for i in range(n):
        xv = float(x[xs + i])
        yv = float(y[ys + i])
        num += xv * yv
        sx += xv * xv
        sy += yv * yv
    if sx == 0.0 or sy == 0.0:
        return 0.0
    return num / math.sqrt(sx * sy)


def _best_lag(x, y, lag_max):
    """Coarse-then-fine lag sweep, so a wide search stays affordable."""
    step = max(1, lag_max // 128)
    best, best_lag = -2.0, 0
    for lag in range(-lag_max, lag_max + 1, step):
        c = _xcorr(x, y, lag)
        if c > best:
            best, best_lag = c, lag
    if step > 1:
        for lag in range(best_lag - step, best_lag + step + 1):
            c = _xcorr(x, y, lag)
            if c > best:
                best, best_lag = c, lag
    return best, best_lag


def _pearson(x, y):
    """Centred correlation of two equal-length series. Centring matters: the
    uncentred cosine of two all-positive RMS envelopes is high for any pair
    of audio files and cannot discriminate.
    """
    n = min(len(x), len(y))
    if n == 0:
        return 0.0
    if _np is not None:
        xv = _np.asarray(x[:n], dtype=_np.float64)
        yv = _np.asarray(y[:n], dtype=_np.float64)
        xv = xv - xv.mean()
        yv = yv - yv.mean()
        d = math.sqrt(float(xv @ xv) * float(yv @ yv))
        return float(xv @ yv) / d if d else 0.0
    mx = sum(x[:n]) / n
    my = sum(y[:n]) / n
    num = sx = sy = 0.0
    for i in range(n):
        dx, dy = x[i] - mx, y[i] - my
        num += dx * dy
        sx += dx * dx
        sy += dy * dy
    d = math.sqrt(sx * sy)
    return num / d if d else 0.0


def _mean(seq):
    if _np is not None:
        return float(seq.mean()) if seq.size else 0.0
    return (sum(seq) / len(seq)) if len(seq) else 0.0


def _center(seq):
    if _np is not None:
        v = seq.astype(_np.float64)
        return v - v.mean()
    m = _mean(seq)
    return array.array("d", (v - m for v in seq))


def _negate(seq):
    if _np is not None:
        return -seq
    return array.array("d", (-v for v in seq))


def correlate(a, b, args):
    fa = describe("A", args.a, len(a), 0, args.rate)
    fb = describe("B", args.b, len(b), 0, args.rate)
    nf = min(fa, fb)
    if fa != fb:
        print("length differs: %+d stereo frames (%+.2f ms); using the common "
              "%d-frame prefix"
              % (fb - fa, 1000.0 * (fb - fa) / args.rate, nf))
    if nf == 0:
        print("RESULT: no common data to compare")
        return 1

    a = a[:2 * nf]
    b = b[:2 * nf]

    print("\nlevel:")
    ra, rb = _rms(a), _rms(b)
    ma, mb = _mean(a), _mean(b)
    print("  overall rms:  A=%9.1f  B=%9.1f  B/A=%s"
          % (ra, rb, ("%.3f" % (rb / ra)) if ra else "-"))
    print("  dc offset:    A=%+9.1f  B=%+9.1f" % (ma, mb))
    print("  (a constant B/A ratio is a gain difference, not an error; the two "
          "cores scale\n   and DC-bias their DAC mixes differently)")

    # Waveform correlation: informational only. Reported because a total
    # collapse here still means something, but it is deliberately NOT the gate
    # -- see the note printed below. DC is removed first, otherwise the two
    # cores' very different DC biases dominate the result.
    chans = {"L": (a[0::2], b[0::2]), "R": (a[1::2], b[1::2])}
    win = min(nf, args.corr_frames)
    off = max(0, min(args.corr_offset, nf - win))
    print("\nwaveform correlation over %d frames (%s) from frame %d, "
          "dc removed, lag search +/-%d frames:"
          % (win, fmt_time(win, args.rate), off, args.max_lag))
    inverted = 0
    for name in ("L", "R"):
        xa, xb = chans[name]
        x = _center(xa[off:off + win])
        y = _center(xb[off:off + win])
        zero = _xcorr(x, y, 0)
        best, lag = _best_lag(x, y, args.max_lag)
        nbest, nlag = _best_lag(x, _negate(y), args.max_lag)
        if nbest > best:
            inverted += 1
            best, lag = -nbest, nlag
        print("  %s: xcorr@0=%+.4f   best=%+.4f @ lag %+d frames (%+.2f ms)"
              % (name, zero, best, lag, 1000.0 * lag / args.rate))
    if inverted:
        print("  B is polarity-inverted relative to A on %d of 2 channels: the"
              % inverted)
        print("  best match is at a negative correlation. dingbat's DAC mix and")
        print("  SameBoy's have opposite sign, which is expected and harmless;")
        print("  read the magnitudes, not the signs.")

    # RMS envelope: this is the gate. A 100 ms window is long enough to be
    # insensitive to the sample-shape differences between two emulators and to
    # tens of ms of phase drift, and short enough to localise a dropout.
    wlen = max(1, int(args.rate * args.window_ms / 1000.0))
    nwin = nf // wlen
    print("\nper-%dms RMS envelope, %d windows:" % (args.window_ms, nwin))
    env_a, env_b, ac_a, ac_b = [], [], [], []
    for w in range(nwin):
        s, e = w * wlen * 2, (w + 1) * wlen * 2
        wa, wb = a[s:e], b[s:e]
        env_a.append(_rms(wa))
        env_b.append(_rms(wb))
        if _np is not None:
            ac_a.append(_rms(wa.astype(_np.float64) - wa.mean()))
            ac_b.append(_rms(wb.astype(_np.float64) - wb.mean()))
        else:
            mwa = sum(wa) / len(wa)
            mwb = sum(wb) / len(wb)
            ac_a.append(math.sqrt(sum((v - mwa) ** 2 for v in wa) / len(wa)))
            ac_b.append(math.sqrt(sum((v - mwb) ** 2 for v in wb) / len(wb)))
    if args.show_windows:
        print("  %8s %10s %10s %8s %10s %10s"
              % ("t", "rmsA", "rmsB", "B/A", "acA", "acB"))
        for i in range(nwin):
            print("  %8s %10.1f %10.1f %8s %10.1f %10.1f"
                  % (fmt_time(i * wlen, args.rate), env_a[i], env_b[i],
                     ("%.3f" % (env_b[i] / env_a[i])) if env_a[i] else "-",
                     ac_a[i], ac_b[i]))
    env_corr = _pearson(env_a, env_b)
    ac_corr = _pearson(ac_a, ac_b)
    silent_a = sum(1 for v in ac_a if v < args.silence)
    silent_b = sum(1 for v in ac_b if v < args.silence)
    print("  envelope pearson:     %+.4f  (total rms per window)" % env_corr)
    print("  ac envelope pearson:  %+.4f  (dc removed per window)" % ac_corr)
    print("  near-silent windows (ac rms < %g): A=%d  B=%d  of %d"
          % (args.silence, silent_a, silent_b, nwin))
    if abs(silent_a - silent_b) > max(2, nwin // 100):
        print("  WARNING: silence pattern differs by %d windows -- possible "
              "channel dropout, or one side is playing a track the other is "
              "not" % abs(silent_a - silent_b))

    # A ROM that never makes a sound has a constant envelope on both sides, so
    # Pearson is 0/0 and would read as a failure. Agreeing that there is no
    # audio is a pass, and the only thing worth checking is that both agree.
    both_silent = (silent_a >= nwin - 1) and (silent_b >= nwin - 1)
    if both_silent:
        print("  both sides are silent for the whole run (no AC content); the"
              " envelope\n  correlation is undefined and is not used")
        ok = True
    else:
        ok = env_corr >= args.min_env_corr
    print("\ngate: envelope pearson >= %.3f%s"
          % (args.min_env_corr,
             " (waived: both silent)" if both_silent else ""))
    print("note: the waveform figures above are diagnostic only. Two different")
    print("      emulators cannot agree sample-for-sample -- SameBoy")
    print("      band-limits each channel and models DAC charge/discharge,")
    print("      dingbat emits the raw DAC mix -- and their clocks drift by")
    print("      tens of ms over a minute, so xcorr@0 is not meaningful here.")
    print("      For a real regression gate, dump from two dingbat builds and")
    print("      use the default byte-equality mode instead.")
    print("RESULT: %s (envelope pearson %+.4f, ac %+.4f)"
          % ("PASS" if ok else "FAIL", env_corr, ac_corr))
    return 0 if ok else 1


def main():
    p = argparse.ArgumentParser(
        description="Compare two raw s16le stereo PCM dumps.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("a", help="first .pcm (raw s16le stereo)")
    p.add_argument("b", help="second .pcm (raw s16le stereo)")
    p.add_argument("--rate", type=int, default=32768,
                   help="sample rate, used for timestamps (default 32768)")
    p.add_argument("--correlate", action="store_true",
                   help="cross-emulator mode: cross-correlation and RMS "
                        "envelope instead of byte equality")
    p.add_argument("--window-ms", type=int, default=100,
                   help="RMS envelope window, ms (default 100)")
    p.add_argument("--show-windows", action="store_true",
                   help="print every RMS window, not just the summary")
    p.add_argument("--corr-frames", type=int, default=32768 * 4,
                   help="frames used for the waveform correlation "
                        "(default 4 s worth)")
    p.add_argument("--corr-offset", type=int, default=0,
                   help="frame offset of the correlation window")
    p.add_argument("--max-lag", type=int, default=1024,
                   help="widest lag searched, in frames (default 1024)")
    p.add_argument("--min-env-corr", type=float, default=0.7,
                   help="--correlate pass threshold for the envelope pearson "
                        "correlation (default 0.7; measured 0.87 for the same "
                        "ROM across dingbat and SameBoy, <=0.11 for different "
                        "ROMs)")
    p.add_argument("--silence", type=float, default=1.0,
                   help="a window whose DC-removed RMS is below this counts "
                        "as silent")
    args = p.parse_args()

    a, odd_a = read_pcm(args.a)
    b, odd_b = read_pcm(args.b)
    if args.correlate:
        return correlate(a, b, args)
    return strict(a, b, args, odd_a, odd_b)


if __name__ == "__main__":
    sys.exit(main())
