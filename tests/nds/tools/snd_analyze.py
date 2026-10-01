#!/usr/bin/env python3
"""Measure a WAV dump of snd_suite.nds (tests/nds/src/snd_suite) against
GBATEK "DS Sound", and decode its readback words from a screenshot.

    snd_analyze.py OUT.wav [--png SHOT.png] [--json OUT.json]

Works on any sample rate (dingbat writes 32728 Hz; other emulators resample
to their own), so it measures what survives resampling: levels (RMS
relative to section 1's PCM16 reference tone), fundamental frequencies,
duty (mean level), envelopes, DC, and for noise the LFSR sequence by
correlation after resampling back to 32728.5 Hz.

The timeline mirrors arm7.c: LEAD frames, then each section is `steps`
steps of 8 frames plus one silent step. Time zero is the first onset (the
PCM16 tone of section 1, left speaker), corrected for its 3-sample start
delay.

needs numpy.
"""
import argparse, json, math, struct, sys, wave, zlib
import numpy as np

FRAME = 355 * 263 * 6 / 33513982      # seconds per video frame
STEP = 8
OUT_RATE = 33513982 / 1024
SECTIONS = [  # (name, steps), as arm7.c's main()
    ("levels", 3), ("adpcm", 4), ("duty", 8), ("psg_chans", 5), ("noise", 4),
    ("repeat", 4), ("hold", 3), ("div", 4), ("vol", 5), ("pan", 5),
    ("master", 5), ("select", 8), ("echo", 6), ("timer", 4), ("bias", 5),
    ("sixteen", 4), ("start_timing", 3),
]
R32 = 16756991 / 524                  # T32K sample rate
SINE_RMS = 0x6000 / 0x8000 / math.sqrt(2)   # full-pan PCM16 sine, 0.5303


def load_wav(path):
    w = wave.open(path)
    n, ch, rate, sw = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
    raw = w.readframes(n)
    if sw == 2:
        d = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768
    elif sw == 4:
        d = np.frombuffer(raw, dtype='<i4').astype(np.float64) / 2**31
    else:
        raise SystemExit("unsupported sample width %d" % sw)
    d = d.reshape(-1, ch)
    if ch == 1:
        d = np.repeat(d, 2, axis=1)
    return d[:, :2], rate


def read_png(path):
    """RGB(A) 8-bit PNG -> (w, h, rows[y][x] = (r, g, b))."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat = 8, b''
    while pos < len(data):
        ln, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        if kind == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
        elif kind == b'IDAT':
            idat += body
        pos += 12 + ln
    bpp = {2: 3, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(w)])
        prev = line
    return w, h, rows


READBACKS = [  # (index, what, GBATEK expectation or None)
    (1, "SOUND0CNT just after start (one-shot PCM8)", 0x9040007F),
    (2, "SOUND0CNT after writing 7FFFFFFFh", 0x7F7F837F),
    (3, "busy time PCM8 64 smp @TMR C000h (cycles)", 66 * 32768),
    (4, "busy time ADPCM 32 smp (cycles)", 42 * 32768),
    (19, "busy time PCM16 8 smp (cycles)", 10 * 32768),
    (5, "PSG ch8 'one-shot' after 10 frames", 0xF340007F),
    (6, "PNT+LEN=3 one-shot after 10 frames (hang)", 0xB040007F),
    (21, "SOUND0CNT after one-shot end", 0x1040007F),
    (7, "SOUNDCNT after writing FFFFh", 0xBF7F),
    (8, "SOUNDBIAS after writing FFFFh", 0x3FF),
    (9, "SNDCAPCNT after writing 7F7Fh", 0x0F0F),
    (10, "SNDCAP0DAD after writing FFFFFFFFh", 0x07FFFFFC),
    (11, "SOUND5SAD readback (W only)", None),
    (12, "capture L mixer PCM16, ch0 DC 4000h pan 0", 0x40004000),
    (18, "SNDCAP0CNT after one-shot capture", 0x04),
    (13, "capture L mixer, 2 x 6000h (clip)", 0x7FFF7FFF),
    (14, "capture PCM8 of -4080h (round to zero)", 0xC0C0C0C0),
    (15, "capture ch0 src: -2000h & ch1 -1000h (both-negative bug)", 0x80008000),
    (16, "capture ch0 src: -2000h, ch1 +1000h", 0xE000E000),
    (17, "capture ch0+ch1 add: 6000h+6000h (overflow bug)", 0xC000C000),
    (20, "capture L mixer, nothing playing", 0),
]


def decode_png(path):
    w, h, rows = read_png(path)
    words = []
    for r in range(24):
        v = 0
        for b in range(32):
            px = rows[r * 8 + 4][b * 8 + 4]
            v = (v << 1) | (1 if min(px) > 200 else 0)
        words.append(v)
    return words


def rms(x):
    return float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0


def fundamental(x, rate, fmin=20):
    x = x - x.mean()
    if np.std(x) < 1e-4:
        return 0.0
    n = len(x)
    s = np.abs(np.fft.rfft(x * np.hanning(n), 8 * n))
    f = np.fft.rfftfreq(8 * n, 1 / rate)
    s[f < fmin] = 0
    k = int(np.argmax(s))
    return float(f[k])


def find_onset(d, rate):
    base = np.median(d[: int(rate * 0.2)], axis=0)
    dev = np.max(np.abs(d - base), axis=1)
    i = int(np.argmax(dev > 0.02))
    return i - 3 * rate / R32


def resample_to(x, rate, out_rate):
    n = int(len(x) * out_rate / rate)
    t = np.arange(n) * rate / out_rate
    return np.interp(t, np.arange(len(x)), x)


def lfsr_bits(n, hold=1):
    x, out = 0x7FFF, []
    while len(out) < n:
        c = x & 1
        x >>= 1
        if c:
            x ^= 0x6000
        out.extend([-1.0 if c else 1.0] * hold)
    return np.array(out[:n])


def analyze(d, rate):
    onset = find_onset(d, rate)
    scale = None
    res = {"rate": rate, "onset_s": onset / rate}

    def step_win(sec_start, k, a=1.0, b=7.0):
        s0 = onset + (sec_start + (k * STEP + a) * FRAME) * rate
        s1 = onset + (sec_start + (k * STEP + b) * FRAME) * rate
        return d[int(s0):int(s1)]

    sec_start = 0.0
    for name, steps in SECTIONS:
        res[name] = {"start_s": sec_start}
        r = res[name]
        if name == "levels":
            ws = [step_win(sec_start, k) for k in range(3)]
            scale = rms(ws[0][:, 0]) / SINE_RMS
            res["scale"] = scale
            r["rms"] = [[rms(w[:, 0]) / scale, rms(w[:, 1]) / scale] for w in ws]
            r["freq"] = [fundamental(w[:, 0] + w[:, 1], rate) for w in ws]
            r["expect_rms"] = [[SINE_RMS, 0], [0, SINE_RMS], [SINE_RMS / 2, SINE_RMS / 2]]
            r["expect_freq"] = R32 / 32
        elif name == "adpcm":
            w = step_win(sec_start, 0, 1, 31)[:, 0] / scale
            r["freq"] = fundamental(w, rate)
            r["min_max"] = [float(w.min()), float(w.max())]
            r["expect"] = {"freq": R32 / 512, "min_max": [-0x3000 / 0x10000, 0x3000 / 0x10000]}
        elif name == "duty":
            r["mean"], r["rms"], r["freq"] = [], [], []
            for k in range(8):
                w = step_win(sec_start, k)[:, 0] / scale
                r["mean"].append(float(w.mean()))
                r["rms"].append(rms(w))
                r["freq"].append(fundamental(w, rate))
            r["expect_mean"] = [0.5 * (2 * (k + 1) / 8 - 1) if k < 7 else -0.5 for k in range(8)]
            r["expect_freq"] = 16756991 / 2095 / 8
        elif name == "psg_chans":
            r["freq"] = [fundamental(step_win(sec_start, k)[:, 0], rate) for k in range(5)]
            r["rms"] = [rms(step_win(sec_start, k)[:, 0]) / scale for k in range(5)]
            r["expect_freq"] = [16756991 / (16756991 // (8 * 500 * (k + 2))) / 8 for k in range(5)]
            r["expect_rms"] = 0.5
        elif name == "noise":
            out = []
            for k, hold in ((0, 1), (2, 4)):
                w = step_win(sec_start, k, 0.5, 2 * STEP - 0.5)[:, 0]
                x = resample_to(w, rate, OUT_RATE) if rate != round(OUT_RATE) else w
                x = x - x.mean()
                ref = lfsr_bits(len(x) + 4096, hold)
                # best lag of the expected sequence inside the window
                n = len(x)
                c = np.fft.irfft(np.fft.rfft(ref, 2 * len(ref)) * np.conj(np.fft.rfft(x, 2 * len(ref))))
                lag = int(np.argmax(c[: 4096]))
                seg = ref[lag:lag + n]
                corr = float(np.corrcoef(seg, x)[0, 1])
                out.append({"lfsr_corr": corr, "rms": rms(w) / scale, "lag": lag})
            r["ch14_ch15"] = out
            r["expect"] = "lfsr_corr ~1 (sequence from X=7FFFh), rms 0.5"
        elif name == "repeat":
            r["modes"] = []
            for m in range(4):
                a = step_win(sec_start, m, 0.1, 0.9)[:, 0] / scale
                b = step_win(sec_start, m, 2.0, 7.5)[:, 0] / scale
                r["modes"].append({"first_ms_rms": rms(a), "later_rms": rms(b)})
            r["expect"] = "first 0.265; later: mode1 0.133 (loops LEN part), mode2 0; modes 0/3 not documented"
        elif name == "hold":
            r["after_end_mean"] = []
            for k in range(3):
                a = step_win(sec_start, k, 4.3, 4.9)[:, 0] / scale
                b = step_win(sec_start, k, 6.0, 7.5)[:, 0] / scale
                r["after_end_mean"].append([float(a.mean()), float(b.mean())])
            r["expect"] = [[0.25, 0.25], [0, 0], [0.25, 0]]
        elif name in ("div", "vol", "pan", "master"):
            n = steps
            ws = [step_win(sec_start, k) for k in range(n)]
            if name == "pan":
                r["rms"] = [[rms(w[:, 0]) / scale, rms(w[:, 1]) / scale] for w in ws]
                pans = [0, 32, 64, 96, 128]
                r["expect"] = [[SINE_RMS * (128 - p) / 128, SINE_RMS * p / 128] for p in pans]
            else:
                r["rms"] = [rms(w[:, 0]) / scale for w in ws]
                f = {"div": [1, .5, .25, 1 / 16], "vol": [1, 96 / 128, .5, .25, 1 / 128],
                     "master": [1, 96 / 128, .5, .25, 0]}[name]
                r["expect"] = [SINE_RMS / 2 * v for v in f]
        elif name == "select":
            fr = [16756991 / 1048 / 32, R32 / 32, 16756991 / 349 / 32]
            r["levels_LR_at_500_1000_1500"] = []
            for k in range(8):
                w = step_win(sec_start, k)
                r["levels_LR_at_500_1000_1500"].append(
                    [[round(rms_tone(w[:, c], rate, f) / scale, 3) for f in fr] for c in (0, 1)])
            h, f1 = SINE_RMS / 2, SINE_RMS
            r["expect"] = [
                [[h, f1, 0], [h, 0, f1]], [[0, f1, 0], [0, 0, f1]], [[0, 0, 0], [0, 0, 0]],
                [[0, f1, 0], [0, 0, f1]], [[h, 0, 0], [h, 0, f1]], [[h, f1, 0], [h, 0, 0]],
                [[h, 0, 0], [h, 0, 0]], [[0, f1, 0], [h, 0, 0]]]
        elif name == "echo":
            x = step_win(sec_start, 0, 0.0, 6 * STEP)[:, 0] / scale
            xr = step_win(sec_start, 0, 0.0, 6 * STEP)[:, 1] / scale
            win = int(rate * 0.004)
            env = np.array([rms(x[i:i + win]) for i in range(0, len(x) - win, win)])
            envr = np.array([rms(xr[i:i + win]) for i in range(0, len(xr) - win, win)])
            bursts, i = [], 0
            while i < len(env):
                if env[i] > 0.01:
                    j = i
                    while j < len(env) and env[j] > 0.01 * 0.5:
                        j += 1
                    bursts.append((i * 0.004, float(env[i:j].max())))
                    i = j + 3
                else:
                    i += 1
            r["bursts_L"] = [(round(t, 4), round(v, 4)) for t, v in bursts[:6]]
            r["peak_R"] = float(envr.max())
            r["expect"] = "L bursts every 128.08 ms (4096 / 31979 Hz) at 0.265, 0.133, 0.066 ...; R one burst 0.265"
        elif name == "timer":
            r["freq"], r["rms"] = [], []
            for k in range(4):
                w = step_win(sec_start, k, 0.5, 7.5)[:, 0] / scale
                r["freq"].append(fundamental(w, rate, fmin=10))
                r["rms"].append(rms(w - w.mean()))
            r["expect"] = {"freq": [16756991 / 65536 / 8, 16756991 / 1024 / 8, 16756991 / 64 / 32,
                                    "47605 Hz tone (14877 Hz if point-sampled at 32728.5)"],
                           "rms": [0.5, 0.5, SINE_RMS / 2, "?"]}
        elif name == "bias":
            r["mean_per_frame"] = []
            for k in range(5 * STEP):
                s0 = onset + (sec_start + (k + 0.3) * FRAME) * rate
                s1 = onset + (sec_start + (k + 0.7) * FRAME) * rate
                w = d[int(s0):int(s1), 0]
                r["mean_per_frame"].append(round(float(w.mean()) / scale * 0x200, 1))
            r["expect"] = "bias-200h in 10-bit units: 0 -> -512 (frame 16) -> 0 (frame 32), then 0 (master off)"
        elif name == "sixteen":
            w = step_win(sec_start, 0, 1, 31)
            r["levels_L"] = [round(rms_tone(w[:, 0], rate, 16756991 / (16756991 // (32 * 250 * (i + 1))) / 32) / scale, 4)
                             for i in range(16)]
            r["expect"] = "even ch: L %.4f, odd ch: L %.4f" % (SINE_RMS * 8 / 128 * 96 / 128, SINE_RMS * 8 / 128 * 32 / 128)
        elif name == "start_timing":
            P = 0x8000 / 16756991 * rate          # test channel sample period, in samples
            r["P_samples"] = P
            r["steps"] = []
            for k, what in enumerate(("pcm16 staircase", "psg duty 7", "adpcm")):
                w = step_win(sec_start, k, -0.5, 7.5) / scale
                L, R = w[:, 0], w[:, 1]
                on_r = first_edge(L, +1, 0.1)
                off_r = last_edge(L, -1, 0.1)
                on_t = first_edge(np.abs(R), +1, 0.015)
                e = {"what": what}
                if on_r is not None and on_t is not None:
                    e["start_delay_P"] = (on_t - on_r) / P
                if k != 1 and on_t is not None and off_r is not None:
                    e["busy_clear_after_onset_P"] = (off_r - on_t) / P
                r["steps"].append(e)
            r["expect"] = ("GBATEK: start delay PCM 3, PSG 1, ADPCM 11 sample periods; busy clears at the "
                           "begin of the last sample: 15 P (16 samples), 23 P (ADPCM 24 samples) after onset")
        sec_start += (steps + 1) * STEP * FRAME
    return res


def first_edge(x, sign, thr, k=3):
    d = (x[k:] - x[:-k]) * sign
    i = np.nonzero(d > thr)[0]
    return None if len(i) == 0 else int(i[0]) + k / 2


def last_edge(x, sign, thr, k=3):
    d = (x[k:] - x[:-k]) * sign
    i = np.nonzero(d > thr)[0]
    return None if len(i) == 0 else int(i[-1]) + k / 2


def rms_tone(x, rate, f):
    x = x - x.mean()
    n = len(x)
    win = np.hanning(n)
    s = np.fft.rfft(x * win)
    k = f * n / rate
    lo, hi = max(int(round(k)) - 3, 1), min(int(round(k)) + 4, len(s))
    p = np.sum(np.abs(s[lo:hi]) ** 2)
    # Parseval with the Hann window's energy
    return float(np.sqrt(2 * p / (n * np.sum(win ** 2))))


def rounded(v):
    if isinstance(v, float):
        return round(v, 4)
    if isinstance(v, dict):
        return {k: rounded(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [rounded(x) for x in v]
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--png")
    ap.add_argument("--json")
    a = ap.parse_args()
    d, rate = load_wav(a.wav)
    res = analyze(d, rate)
    if a.png:
        words = decode_png(a.png)
        res["readbacks"] = {}
        for i, what, exp in READBACKS:
            v = words[i]
            ok = "" if exp is None else ("ok" if v == exp else "DIFF (GBATEK %08X)" % exp)
            res["readbacks"][str(i)] = v
            print("RES[%2d] %08X  %-55s %s" % (i, v, what, ok))
        print("RES[ 0] %08X  %s" % (words[0], "done" if words[0] == 0x54444E53 else "NOT DONE"))
    for k, v in res.items():
        if k == "readbacks":
            continue
        print(k, json.dumps(rounded(v)))
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
