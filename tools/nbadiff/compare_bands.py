#!/usr/bin/env python3
"""Band-energy comparison of GBA audio dumps (dingbat vs dingbat, dingbat vs
a NanoBoyAdvance core-mixer dump).

Inputs (32768 Hz stereo, all optional beyond the first):
    *.s16   dingbat DINGBAT_GBA_AUDIO_DUMP — s16le at DAC scale +/-512 (/512 to
            normalize; the dump taps get_sample BEFORE the *32 output scaling)
    *.f32   NBA_AUDIO_DUMP (a local patch to NanoBoyAdvance) — f32le already
            normalized (+/-1.0 = full DAC)

Prints Welch band powers per file over a chosen window. Two dingbat runs of the
same ROM/frames are deterministic and sample-aligned, so `--diff a b` writes
their exact difference and its RMS. Cross-emulator alignment is not attempted
(undriven boots drift apart); compare band statistics of matching passages.

    --wav out.wav FILE      render a window of FILE to a listenable WAV
    --start S --dur D       analysis window (default 30 s + 20 s)
"""
import argparse
import wave
import numpy as np

RATE = 32768


def load(path):
    if path.endswith('.f32'):
        return np.fromfile(path, dtype='<f4').reshape(-1, 2).astype(np.float64)
    return np.fromfile(path, dtype='<i2').reshape(-1, 2).astype(np.float64) / 512.0


def band_table(x, label):
    mono = x.mean(axis=1)
    nseg = 8192
    win = np.hanning(nseg)
    acc = np.zeros(nseg // 2 + 1)
    cnt = 0
    for s in range(0, len(mono) - nseg, nseg // 2):
        seg = (mono[s:s + nseg] - mono[s:s + nseg].mean()) * win
        acc += np.abs(np.fft.rfft(seg)) ** 2
        cnt += 1
    psd = acc / max(cnt, 1)
    freqs = np.fft.rfftfreq(nseg, 1 / RATE)

    def db(lo, hi):
        m = (freqs >= lo) & (freqs < hi)
        return 10 * np.log10(psd[m].mean() + 1e-30)

    print(f'{label:<28} rms={np.sqrt((mono**2).mean()):.4f}  '
          f'0-2k {db(0,2000):6.1f} | 2-5k {db(2000,5000):6.1f} | 5-8k {db(5000,8000):6.1f} | '
          f'8-10.5k {db(8000,10500):6.1f} | 10.5-16.4k {db(10500,16384):6.1f} dB')


def write_wav(path, x):
    q = np.clip(x * 32767, -32768, 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(q.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+')
    ap.add_argument('--start', type=float, default=30.0)
    ap.add_argument('--dur', type=float, default=20.0)
    ap.add_argument('--diff', nargs=2, metavar=('A', 'B'),
                    help='write A-B (sample-aligned dingbat runs) to diff.wav')
    ap.add_argument('--wav', nargs=2, metavar=('OUT', 'FILE'), action='append', default=[])
    args = ap.parse_args()
    s = int(args.start * RATE)
    e = s + int(args.dur * RATE)
    for f in args.files:
        band_table(load(f)[s:e], f)
    if args.diff:
        a, b = load(args.diff[0]), load(args.diff[1])
        n = min(len(a), len(b))
        d = a[:n] - b[:n]
        band_table(d[s:e], 'DIFF (injected noise)')
        write_wav('diff.wav', d[s:e])
        print('wrote diff.wav')
    for out, f in args.wav:
        write_wav(out, load(f)[s:e])
        print(f'wrote {out}')


main()
