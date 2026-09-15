#!/usr/bin/env python3
"""Per-title timing analysis of MP2K HLE captures (tools/mp2ksweep/capture.sh).

A title directory holds, per build tag T: wT.hle.wav and wT.real.wav (the HLE
render and the game's own FIFO stream over the same span, 32768 Hz s16
stereo), jT.json (the sweep's JSON line), pT.txt (the pass dump, when the
build is -d:mp2kwav with DINGBAT_PASSDUMP) and name.txt (the ROM name).

Usage:
  wavs.py segments  <tags> <titledir...> [--seg 16384]
      lag and correlation of each build's HLE against its own reference, per
      half-second segment (positive = HLE late)
  wavs.py buildlag  <tagA> <tagB> <titledir> [--seg 16384]
      lag of build B's HLE output against build A's, aligned by their
      identical reference streams (does the render itself drift?)
  wavs.py framelag  <tag> <titledir> [--every 30]
      per pass: placement error against the slot's FIFO pop, and the content
      lag of a 2048-sample window starting at the frame
  wavs.py passes    <tag> <titledir...>
      placement error (placed - pop, output samples) per half-second segment,
      and whether the pass's first ring store is the model's slot start
  wavs.py calib     <tag> <titledir...>
      fits the pop-to-output delay: for steady segments, placement error minus
      waveform lag, in DMA periods (2 periods less half a sample is the model)

Pass dump columns: pass, placed capture index, pop index of the first ring
store's byte, pop index of the model's slot start, kind (N level control,
S slot timing, R replacement), then key=value diagnostics.
"""
import argparse, json, os, wave
import numpy as np


def rd(p):
    w = wave.open(p)
    return np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float64).reshape(-1, 2).sum(1)


def name(d):
    try:
        return open(os.path.join(d, 'name.txt')).read().strip()
    except OSError:
        return os.path.basename(d.rstrip('/'))


def jline(d, tag):
    try:
        return json.loads([l for l in open(os.path.join(d, f"j{tag}.json")) if l.startswith('{')][-1])
    except (OSError, IndexError):
        return {}


def best_lag(a, b, span):
    """Lag of a against b (positive = a late) and its normalised correlation."""
    n = len(a)
    a = a - a.mean(); b = b - b.mean()
    den = np.sqrt(np.dot(a, a) * np.dot(b, b))
    if den <= 0:
        return None
    cc = np.correlate(a, b, 'full')[n - 1 - span:n + span]
    k = int(np.argmax(cc))
    return k - span, cc[k] / den, cc, k


def cmd_segments(a):
    tags = a.tags.split(',')
    for d in a.dirs:
        print(f"## {name(d)}  " + " ".join(f"{t}={jline(d, t).get('xcorr0', float('nan')):.3f}" for t in tags))
        for t in tags:
            p = os.path.join(d, f"w{t}.hle.wav")
            if not os.path.exists(p):
                continue
            h, r = rd(p), rd(os.path.join(d, f"w{t}.real.wav"))
            out = []
            for i in range(0, min(len(h), len(r)) - a.seg, a.seg):
                x, y = h[i:i + a.seg], r[i:i + a.seg]
                if np.dot(x - x.mean(), x - x.mean()) < 1e3 or np.dot(y - y.mean(), y - y.mean()) < 1e3:
                    out.append("   .    "); continue
                l, c, _, _ = best_lag(x, y, 40)
                out.append(f"{l:+3d}:{c:.2f}".ljust(8))
            print(f"{t:>4} " + " ".join(out))


def cmd_buildlag(a):
    d = a.dir
    ra, rb = rd(os.path.join(d, f"w{a.tagA}.real.wav")), rd(os.path.join(d, f"w{a.tagB}.real.wav"))
    ha, hb = rd(os.path.join(d, f"w{a.tagA}.hle.wav")), rd(os.path.join(d, f"w{a.tagB}.hle.wav"))
    seg = 8192; mid = len(ra) // 2; x = ra[mid:mid + seg]
    best = None
    for off in range(-9000, 9001):
        j = mid + off
        if 0 <= j and j + seg <= len(rb):
            dd = np.abs(rb[j:j + seg] - x).sum()
            if best is None or dd < best[1]:
                best = (off, dd)
    off = best[0]
    print(f"{name(d)}: reference offset {off} (residual {best[1]:.0f}; 0 = identical streams)")
    out = []
    for i in range(0, len(ha) - a.seg, a.seg):
        j = i + off
        if j < 20 or j + a.seg + 20 > len(hb):
            out.append("."); continue
        x = ha[i:i + a.seg] - ha[i:i + a.seg].mean()
        if np.dot(x, x) < 1e6:
            out.append("."); continue
        cs = []
        for l in range(-8, 9):
            y = hb[j + l:j + l + a.seg]; y = y - y.mean()
            cs.append(np.dot(x, y) / np.sqrt(np.dot(x, x) * np.dot(y, y) + 1e-9))
        k = int(np.argmax(cs))
        out.append(f"{k - 8:+d}:{cs[k]:.3f}")
    print(" ".join(out))


def passrows(d, tag):
    return [l.split() for l in open(os.path.join(d, f"p{tag}.txt"))]


def cmd_framelag(a):
    d = a.dir
    h, r = rd(os.path.join(d, f"w{a.tag}.hle.wav")), rd(os.path.join(d, f"w{a.tag}.real.wav"))
    W, L = 2048, 10
    out = []
    for x in passrows(d, a.tag)[::a.every]:
        p, rp = int(x[1]), int(x[2])
        if rp < 0 or p < L or p + W + L >= min(len(h), len(r)):
            continue
        s = h[p:p + W] - h[p:p + W].mean()
        best = None
        for l in range(-L, L + 1):
            b = r[p - l:p - l + W]; b = b - b.mean()
            c = np.dot(s, b) / (np.sqrt(np.dot(s, s) * np.dot(b, b)) + 1e-9)
            if best is None or c > best[1]:
                best = (l, c)
        out.append(f"{x[0]}:err{p - rp}:lag{best[0]}:{best[1]:.2f}")
    print(name(d)); print(" ".join(out))


def cmd_passes(a):
    for d in a.dirs:
        rows = passrows(d, a.tag)
        j = jline(d, a.tag)
        segs = {}
        for x in rows:
            segs.setdefault(int(x[1]) // 16384, []).append(x)
        out = []
        for s in sorted(segs):
            e = sorted(int(x[1]) - int(x[2]) for x in segs[s] if int(x[2]) >= 0)
            kinds = ''.join(sorted(set(x[4] for x in segs[s])))
            out.append(f"{s}:{e[len(e) // 2]}[{e[0]},{e[-1]}]{kinds}" if e else f"{s}:-")
        differ = sum(1 for x in rows if x[2] != x[3])
        print(f"## {name(d)} {j.get('pcm_rate')} Hz xcorr0 {j.get('xcorr0', float('nan')):.3f}: "
              f"{len(rows)} passes, {differ} whose first ring store is not the model's slot start")
        print(" ".join(out))


def cmd_calib(a):
    seg = 16384
    byrate = {}
    for d in a.dirs:
        j = jline(d, a.tag); rate = j.get('pcm_rate')
        if not rate or not os.path.exists(os.path.join(d, f"p{a.tag}.txt")):
            continue
        h, r = rd(os.path.join(d, f"w{a.tag}.hle.wav")), rd(os.path.join(d, f"w{a.tag}.real.wav"))
        segs = {}
        for x in passrows(d, a.tag):
            if int(x[2]) >= 0:
                segs.setdefault(int(x[1]) // seg, []).append(int(x[1]) - int(x[2]))
        vals = []
        for s, es in segs.items():
            i = s * seg
            if len(es) < 20 or max(es) - min(es) > 1 or i + seg > min(len(h), len(r)):
                continue
            x, y = h[i:i + seg], r[i:i + seg]
            if np.dot(x - x.mean(), x - x.mean()) < 1e6 or np.dot(y - y.mean(), y - y.mean()) < 1e6:
                continue
            res = best_lag(x, y, 20)
            if res is None:
                continue
            l, c, cc, k = res
            if c < 0.97 or k == 0 or k == 40:
                continue
            y0, y1, y2 = cc[k - 1], cc[k], cc[k + 1]
            vals.append(np.mean(es) - (l + 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)))
        if vals:
            per = 32768.0 / rate
            v = float(np.median(vals))
            byrate.setdefault(rate, []).append(v / per)
            print(f"{rate:6d} Hz {len(vals):2d} segments: {v:5.2f} samples = {v / per:4.2f} periods  {name(d)}")
    for k in sorted(byrate):
        print(k, np.round(byrate[k], 2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('segments'); p.add_argument('tags'); p.add_argument('dirs', nargs='+')
    p.add_argument('--seg', type=int, default=16384); p.set_defaults(f=cmd_segments)
    p = sub.add_parser('buildlag'); p.add_argument('tagA'); p.add_argument('tagB'); p.add_argument('dir')
    p.add_argument('--seg', type=int, default=16384); p.set_defaults(f=cmd_buildlag)
    p = sub.add_parser('framelag'); p.add_argument('tag'); p.add_argument('dir')
    p.add_argument('--every', type=int, default=30); p.set_defaults(f=cmd_framelag)
    p = sub.add_parser('passes'); p.add_argument('tag'); p.add_argument('dirs', nargs='+'); p.set_defaults(f=cmd_passes)
    p = sub.add_parser('calib'); p.add_argument('tag'); p.add_argument('dirs', nargs='+'); p.set_defaults(f=cmd_calib)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
