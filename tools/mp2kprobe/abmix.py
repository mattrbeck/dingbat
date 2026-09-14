"""Alternating A/B listening file from two sample-aligned final-output dumps
of the same deterministic run (s16le stereo 32768 Hz), joined by equal-power
crossfades every `seg` seconds; plus both full tracks and a schedule line.

usage: abmix.py <name> <a.s16> <b.s16> <outdir> [seg_s=6] [xfade_ms=40]
                [scale=1] [labelA=hardware] [labelB=hle]
`scale` multiplies the dump (32 for DINGBAT_GBA_AUDIO_DUMP's 10-bit DAC sum,
1 for DINGBAT_GBA_AUDIO_DUMP_FINE=1's emitted value). Track A plays first.
"""
import sys, os, wave
from collections import Counter
import numpy as np

name, a_p, b_p, outdir = sys.argv[1:5]
seg = float(sys.argv[5]) if len(sys.argv) > 5 else 6.0
xf_ms = float(sys.argv[6]) if len(sys.argv) > 6 else 40.0
scale = float(sys.argv[7]) if len(sys.argv) > 7 else 1.0
labelA = sys.argv[8] if len(sys.argv) > 8 else "hardware"
labelB = sys.argv[9] if len(sys.argv) > 9 else "hle"
RATE = 32768

def load(p):
    return np.fromfile(p, dtype='<i2').astype(np.float64).reshape(-1, 2) * scale

A = load(a_p); B = load(b_p)
n = min(len(A), len(B)); A = A[:n]; B = B[:n]

# DC-block both (one-pole high-pass, ~5 Hz): the hardware path carries the
# driver's per-voice floor as a DC offset that the reverb comb amplifies (up
# to ~40 DAC steps), the HLE does not, and a real GBA's output is AC-coupled
# anyway. Without this every join would thump.
def dcblock(x, fc=5.0):
    r = 1.0 - 2.0 * np.pi * fc / RATE
    y = np.empty_like(x); px = np.zeros(x.shape[1]); py = np.zeros(x.shape[1])
    for i in range(len(x)):
        py = x[i] - px + r * py; px = x[i]; y[i] = py
    return y
A = dcblock(A); B = dcblock(B)

# Residual lag: modal best lag over 2 s windows (votes clustered ±2 so a
# periodic tone's alias one period away cannot split the true peak). B is
# shifted by it so the joins are in phase; the number is reported.
sa = A.sum(axis=1); sb = B.sum(axis=1)
W = 2 * RATE; votes = Counter(); c0s = []
for s0 in range(RATE, n - W - 128, W):
    x = sa[s0+64:s0+64+W]; x = x - x.mean()
    if x.std() < 20: continue
    best = (-2.0, 0)
    for L in range(-64, 65):
        y = sb[s0+64+L:s0+64+L+W]; y = y - y.mean()
        if y.std() < 1: continue
        c = float((x*y).sum() / np.sqrt((x*x).sum() * (y*y).sum()))
        if L == 0: c0s.append(c)
        if c > best[0]: best = (c, L)
    votes[best[1]] += 1
lag = max(votes, key=lambda L: sum(v for l, v in votes.items() if abs(l - L) <= 2)) if votes else 0
corr0 = float(np.median(c0s)) if c0s else 0.0
if lag != 0:
    sh = np.zeros_like(B)
    if lag < 0: sh[-lag:] = B[:lag]
    else: sh[:-lag] = B[lag:]
    B = sh

# Loudness: median over 1 s windows of the RMS ratio B/A.
_r = []
for s0 in range(0, n - RATE, RATE):
    ra = np.sqrt((A[s0:s0+RATE]**2).mean()); rb = np.sqrt((B[s0:s0+RATE]**2).mean())
    if ra > 100: _r.append(rb / ra)
loud_db = 20 * np.log10(np.median(_r)) if _r else 0.0

# Skip the boot silence: start at the first 0.5 s window with signal.
win = RATE // 2; start = 0
peak = max(1.0, np.abs(A[:, 0]).max())
for i in range(0, n - win, win):
    if np.sqrt((A[i:i+win, 0]**2).mean()) > 0.02 * peak:
        start = i; break
A = A[start:]; B = B[start:]; n = len(A)

seg_n = int(seg * RATE); xf = int(xf_ms * RATE / 1000)
out = np.zeros_like(A)
src = [A, B]; cur = 0; pos = 0; schedule = []
while pos < n:
    end = min(pos + seg_n, n)
    out[pos:end] = src[cur][pos:end]
    schedule.append((labelA if cur == 0 else labelB, pos / RATE))
    if end < n:
        a0 = max(0, end - xf // 2); a1 = min(n, a0 + xf)
        k = np.linspace(0, 1, a1 - a0)
        g_out = np.cos(k * np.pi / 2)[:, None]; g_in = np.sin(k * np.pi / 2)[:, None]
        out[a0:a1] = src[cur][a0:a1] * g_out + src[1 - cur][a0:a1] * g_in
        cur = 1 - cur
    pos = end

def save(p, arr):
    w = wave.open(p, 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes(np.clip(arr, -32768, 32767).astype('<i2').tobytes()); w.close()

os.makedirs(outdir, exist_ok=True)
save(os.path.join(outdir, f"{name}.alternating.wav"), out)
save(os.path.join(outdir, f"{name}.{labelA}.wav"), A)
save(os.path.join(outdir, f"{name}.{labelB}.wav"), B)
sched = " | ".join(f"{s} {t:.0f}s" for s, t in schedule)
print(f"{name}: {n/RATE:.1f}s, {labelB} shifted by {-lag:+d} samples (corr@0 before {corr0:.3f}), loudness {labelB}/{labelA} {loud_db:+.2f} dB; {sched}")
