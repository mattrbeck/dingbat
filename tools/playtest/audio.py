"""Audio comparison for the playtest harness.

Every driver can write its raw output (`--audio`, s16le stereo at 32768 Hz)
for a whole [new] run. The emulators mix at different scales and filter
differently, so samples are never compared directly; instead each run is cut
into windows of WINDOW_FRAMES emulated frames (each emulator's own samples per
frame, so a small rate difference cannot drift the alignment), and each
window is reduced to

  - loudness: RMS of the mid signal, in dB, after removing the emulator's
    overall gain against the other (a median over windows both find audible);
  - shape: energy in log-spaced bands, normalised to sum 1 (what is playing,
    independent of volume);
  - width: side/mid energy ratio (panning).

A window differs between two emulators when the loudness moves more than
LOUD_DB, or the band shapes are further apart than SHAPE_DIST (half the L1
distance; 0 = identical, 1 = disjoint), or one is audible and the other
silent. As with screens, a subject's window only counts against it where the
two references agree with each other (otherwise the window is noise: music
started a frame apart, random sound effects).
"""
import json
import os
import wave

import numpy as np

RATE = 32768
WINDOW_FRAMES = 15          # quarter of a second
SILENT_DB = -55.0           # relative to full scale of the emulator's own peak level
LOUD_DB = 6.0
SHAPE_DIST = 0.35
WIDTH_DIFF = 0.25
EDGES = np.geomspace(60, 16000, 17)


def load(path):
    if not path or not os.path.exists(path) or os.path.getsize(path) < 4:
        return None
    a = np.fromfile(path, dtype='<i2')
    return a[: len(a) // 2 * 2].reshape(-1, 2).astype(np.float32)


def features(path, frames):
    """-> dict of per-window arrays, or None without audio."""
    a = load(path)
    if a is None or frames <= 0:
        return None
    per_frame = len(a) / frames
    n_win = frames // WINDOW_FRAMES
    span = int(per_frame * WINDOW_FRAMES)
    nfft = 1 << max(8, int(np.ceil(np.log2(max(span, 2)))))
    freqs = np.fft.rfftfreq(nfft, 1 / RATE)
    band_idx = np.digitize(freqs, EDGES) - 1
    rms, width, shape = [], [], []
    hann = np.hanning(span).astype(np.float32)
    for k in range(n_win):
        s = int(round(k * WINDOW_FRAMES * per_frame))
        seg = a[s:s + span]
        if len(seg) < span:
            seg = np.pad(seg, ((0, span - len(seg)), (0, 0)))
        mid = (seg[:, 0] + seg[:, 1]) * 0.5
        side = (seg[:, 0] - seg[:, 1]) * 0.5
        m = float(np.sqrt(np.mean(mid * mid)))
        sd = float(np.sqrt(np.mean(side * side)))
        rms.append(m)
        width.append(sd / (m + sd + 1e-9))
        spec = np.abs(np.fft.rfft((mid - mid.mean()) * hann, nfft)) ** 2
        bands = np.array([spec[band_idx == b].sum() for b in range(len(EDGES) - 1)])
        tot = bands.sum()
        shape.append(bands / tot if tot > 0 else bands)
    rms = np.array(rms)
    peak = float(np.percentile(rms, 99)) if len(rms) else 0.0
    return {'rms': rms, 'width': np.array(width), 'shape': np.array(shape), 'peak': peak,
            'per_frame': per_frame, 'frames': frames}


def _db(x):
    return 20 * np.log10(np.maximum(x, 1e-9))


def audible(f):
    if f is None or f['peak'] <= 0:
        return np.zeros(0, bool)
    return _db(f['rms']) - _db(f['peak']) > SILENT_DB


def window_diff(fa, fb):
    """Per-window boolean 'differs' plus the reasons, for two emulators."""
    n = min(len(fa['rms']), len(fb['rms']))
    if n == 0:
        return np.zeros(0, bool), {}
    aa, ab = audible(fa)[:n], audible(fb)[:n]
    both = aa & ab
    # each emulator's own gain: the median level difference where both play
    gain = float(np.median(_db(fa['rms'][:n][both]) - _db(fb['rms'][:n][both]))) if both.any() else 0.0
    loud = np.abs(_db(fa['rms'][:n]) - _db(fb['rms'][:n]) - gain)
    shape = 0.5 * np.abs(fa['shape'][:n] - fb['shape'][:n]).sum(axis=1)
    width = np.abs(fa['width'][:n] - fb['width'][:n])
    presence = aa != ab
    differs = presence | (both & ((loud > LOUD_DB) | (shape > SHAPE_DIST) | (width > WIDTH_DIFF)))
    return differs, {'presence': presence, 'loud': np.where(both, loud, 0), 'shape': np.where(both, shape, 0),
                     'width': np.where(both, width, 0), 'gain_db': gain}


def compare(feats, subjects, refs):
    """feats: name -> features. Returns per-subject verdicts plus a
    reference-vs-reference baseline."""
    out = {'subjects': {}, 'refs': {}}
    have = {n: f for n, f in feats.items() if f is not None}
    rr = [r for r in refs if r in have]
    ref_agree = None
    if len(rr) == 2:
        d, why = window_diff(have[rr[0]], have[rr[1]])
        ref_agree = ~d
        out['refs'] = {'pair': f'{rr[0]}~{rr[1]}', 'windows': int(len(d)), 'differ': int(d.sum()),
                       'gain_db': round(why.get('gain_db', 0), 1),
                       'audible': {r: float(audible(have[r]).mean()) if len(have[r]['rms']) else 0 for r in rr}}
    # a reference that stands alone: it differs from the other reference
    # where the default dingbat agrees with that other one
    if len(rr) == 2 and subjects and subjects[0] in have:
        s0 = subjects[0]
        out['refs']['odd'] = {}
        for r in rr:
            o = rr[1 - rr.index(r)]
            d_ro, why = window_diff(have[r], have[o])
            d_so, _ = window_diff(have[s0], have[o])
            n = min(len(d_ro), len(d_so))
            alone = d_ro[:n] & ~d_so[:n]
            runs = _runs(alone)
            longest = max((b - a for a, b in runs), default=0)
            vs = {o: {'_why': why}}
            out['refs']['odd'][r] = {
                'flagged_windows': int(alone.sum()), 'windows': n,
                'flagged_fraction': round(float(alone.mean()) if n else 0.0, 4),
                'longest_seconds': round(longest * WINDOW_FRAMES / 59.7275, 2),
                'runs': [{'start_frame': a * WINDOW_FRAMES, 'end_frame': b * WINDOW_FRAMES,
                          'kind': _kind(vs, a, b)} for a, b in runs[:8]],
                'status': ('DIFFERENT' if longest * WINDOW_FRAMES >= 120 or (n and alone.mean() > 0.10)
                           else 'MINOR' if alone.any() else 'SAME')}
    for s in subjects:
        if s not in have:
            out['subjects'][s] = {'status': 'NO AUDIO'}
            continue
        res = {'audible': float(audible(have[s]).mean()) if len(have[s]['rms']) else 0.0, 'vs': {}}
        flagged = None
        for r in rr:
            d, why = window_diff(have[s], have[r])
            res['vs'][r] = {'differ': int(d.sum()), 'windows': int(len(d)), 'gain_db': round(why.get('gain_db', 0), 1)}
            mask = d if ref_agree is None else d & ref_agree[:len(d)]
            # counts against the subject only where it differs from every reference
            flagged = mask if flagged is None else flagged[:len(mask)] & mask[:len(flagged)]
            res['vs'][r]['_why'] = why
        if flagged is None:
            out['subjects'][s] = {'status': 'NO REFERENCE'}
            continue
        n = len(flagged)
        runs = _runs(flagged)
        res['flagged_windows'] = int(flagged.sum())
        res['windows'] = n
        res['flagged_fraction'] = round(float(flagged.mean()) if n else 0.0, 4)
        res['runs'] = [{'start_frame': a * WINDOW_FRAMES, 'end_frame': b * WINDOW_FRAMES,
                        'kind': _kind(res['vs'], a, b)} for a, b in runs[:12]]
        longest = max((b - a for a, b in runs), default=0)
        res['longest_seconds'] = round(longest * WINDOW_FRAMES / 59.7275, 2)
        # a sustained difference (>= 2 s) or a large share is a finding;
        # a few isolated windows is a sound effect a frame apart
        res['status'] = ('DIFFERENT' if longest * WINDOW_FRAMES >= 120 or res['flagged_fraction'] > 0.10
                         else 'MINOR' if flagged.any() else 'SAME')
        for r in res['vs']:
            res['vs'][r].pop('_why', None)
        out['subjects'][s] = res
    return out


def _kind(vs, a, b):
    kinds = []
    for r, v in vs.items():
        why = v.get('_why') or {}
        if not why:
            continue
        sl = slice(a, b)
        if why['presence'][sl].any():
            kinds.append('silence/presence')
        if (why['loud'][sl] > LOUD_DB).any():
            kinds.append(f"level {float(why['loud'][sl].max()):.0f} dB")
        if (why['shape'][sl] > SHAPE_DIST).any():
            kinds.append(f"spectrum {float(why['shape'][sl].max()):.2f}")
        if (why['width'][sl] > WIDTH_DIFF).any():
            kinds.append('stereo width')
    return ', '.join(dict.fromkeys(kinds))


def _runs(mask):
    runs, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(mask)))
    runs.sort(key=lambda r: r[0] - r[1])
    return runs


def clip(path, frames, start_frame, end_frame, out_wav, pad_frames=30):
    """Writes the [start, end) frame span (plus padding) of a raw dump as a WAV."""
    a = load(path)
    if a is None:
        return None
    per_frame = len(a) / frames
    s = int(max(0, start_frame - pad_frames) * per_frame)
    e = int(min(frames, end_frame + pad_frames) * per_frame)
    seg = a[s:e]
    peak = float(np.abs(seg).max()) or 1.0
    # each clip normalised: the emulators mix at different scales
    pcm = (seg / peak * 20000).astype('<i2')
    with wave.open(out_wav, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    return out_wav


def save_features(f, path):
    if f is None:
        return
    np.savez_compressed(path, rms=f['rms'], width=f['width'], shape=f['shape'],
                        meta=np.array(json.dumps({'peak': f['peak'], 'per_frame': f['per_frame'],
                                                  'frames': f['frames']})))


def load_features(path):
    """save_features' file back as features (what a replayed run compares)."""
    if not path or not os.path.exists(path):
        return None
    z = np.load(path)
    meta = json.loads(str(z['meta']))
    return {'rms': z['rms'], 'width': z['width'], 'shape': z['shape'], 'peak': meta['peak'],
            'per_frame': meta['per_frame'], 'frames': meta['frames']}
