"""Measure tests/roms/payloads/zombie.s from a recording of the console's speaker.

    python3 zombie_listen.py record [seconds]   # mic -> .payloadcmp/zombie.wav while it runs
    python3 zombie_listen.py analyse take.wav   # any recording (or an emulator dump)

zombie.s plays a sync tone, three noise segments (shift 13, 14, 13) and short
channel 2 tones at 1000.5 Hz separated by silence (schedule in its header).
Everything is compared within the take, so microphone gain cancels: the
1000.5 Hz amplitude of each tone against the volume-8 references (Z3b = 8
is the GB table, 12 the rule the GBA used to apply; Z5b = 7 is the control),
and the noise segments' click energy against the silence around them (N2
near silence = LFSR frozen, the GB rule; N1 and N3 are controls).

The first take (2026-09-30) showed a recording path that suppresses a tone
held for more than a second, so the probe never holds one and every
comparison is between neighbours.
"""
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
F = 131072 / 131                  # f = 1917


def load(path):
    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
    return a.reshape(-1, ch).mean(axis=1), rate


def tone(x, rate, a, b):
    s = x[a:b]
    t = (np.arange(len(s)) + a) / rate
    return 2 * abs(np.mean(s * np.exp(-2j * np.pi * F * t)))


def clicks(x, a, b):
    d = np.diff(x[a:b])
    return float(np.sqrt(np.mean(d ** 2)))


def ac_rms(x, a, b):
    s = x[a:b]
    return float(np.sqrt(np.mean((s - s.mean()) ** 2))) if len(s) else 0.0


def runs(x, rate):
    """Tonal runs (start, length in s): 50 ms windows where the 1000.5 Hz
    projection dominates the window's RMS (a noise burst projects too, but is
    mostly not that frequency)."""
    win = rate // 20
    floor = np.median([ac_rms(x, i, i + win) for i in range(0, len(x) - win, win)])
    flags = []
    for i in range(0, len(x) - win, win):
        r = ac_rms(x, i, i + win) + 1e-9
        flags.append(tone(x, rate, i, i + win) / r > 0.25 and r > 2 * floor + 1)
    # one weak window does not split a tone
    for k in range(1, len(flags) - 1):
        if flags[k - 1] and flags[k + 1]: flags[k] = True
    out, cur = [], None
    for k, ok in enumerate(flags + [False]):
        if ok and cur is None: cur = k
        if not ok and cur is not None:
            out.append((cur * win / rate, (k - cur) * win / rate)); cur = None
    return out


def analyse(path):
    x, rate = load(path)
    # Anchor on the Z tones (0.25, 0.25, 0.5, 0.25, 0.5, 0.25 s): the sync
    # tone can be missed by a late recording start.
    rs = [r for r in runs(x, rate) if r[1] >= 0.15]
    want = [0.25, 0.25, 0.5, 0.25, 0.5, 0.25]
    z1 = None
    for k in range(len(rs) - 5):
        if all(abs(rs[k + j][1] - want[j]) <= 0.12 for j in range(6)):
            z1 = rs[k][0]
    if z1 is None:
        print(f'{os.path.basename(path)}: the Z tone pattern is not in this recording'); return
    sync = z1 - 5.00
    T = lambda s: int((sync + s) * rate)
    def mid(s, d):                          # the middle 60% of a segment
        return T(s + 0.2 * d), T(s + 0.8 * d)
    print(f'{os.path.basename(path)}: Z1 at {z1:.2f} s, so the sync tone at {sync:.2f} s')
    # noise: a trigger loads the LFSR with 0x7FFF, so its output holds for
    # the 15 steps until the first 0 reaches bit 0 -- 234 ms at shift 13 and,
    # on the old GBA rule, 470 ms at shift 14 -- and then varies. Compare the
    # loudest 50 ms of 0.55..1.15 s into each segment, past that start-up.
    def onset(s):
        a, b = T(s + 0.55), T(s + 1.15)       # past the LFSR start-up (below)
        if a < 0: return None
        w = rate // 20
        return max(ac_rms(x, i, i + w) for i in range(a, b - w, w // 2))
    gap = max(np.median([ac_rms(x, *mid(s, 0.3)) for s in (1.70, 3.20, 4.70) if T(s) >= 0]), 1.0)
    n = {name: onset(s) for name, s in (('N1 shift 13', 0.50), ('N2 shift 14', 2.00), ('N3 shift 13', 3.50))}
    print('  noise onset loudness re the gaps: ' +
          ', '.join(f'{k} {"(before the recording)" if v is None else f"{v / gap:.1f}x"}' for k, v in n.items()))
    ctl = [v for k, v in n.items() if v is not None and 'shift 13' in k]
    if not ctl or n['N2 shift 14'] is None or min(ctl) / gap < 3:
        print('  noise verdict: none -- no shift-13 control stands above the gaps')
    else:
        print('  noise verdict: shift 14', 'frozen (GB rule)' if n['N2 shift 14'] < 0.25 * min(ctl)
              else 'steps (old GBA rule)')
    seg = {'Z1 ref 8': (5.00, .25), 'Z2 ref 12': (5.50, .25), 'Z3a 8': (6.00, .25),
           'Z3b 4x 0x80': (6.25, .25), 'Z4 ref 8': (6.75, .25), 'Z5a 8': (7.25, .25),
           'Z5b 0x88': (7.50, .25), 'Z6 ref 7': (8.00, .25)}
    amp = {k: tone(x, rate, *mid(*v)) for k, v in seg.items()}
    ref = np.mean([amp['Z1 ref 8'], amp['Z4 ref 8']])
    for k in seg:
        print(f'  {k:12s} ~volume {8 * amp[k] / ref:5.2f}')
    z3 = amp['Z3b 4x 0x80'] / amp['Z3a 8']
    z5 = amp['Z5b 0x88'] / amp['Z5a 8']
    lin = amp['Z2 ref 12'] / amp['Z1 ref 8']
    print(f'  check: Z2/Z1 = {lin:.3f} (want 1.500); control Z5b/Z5a = {z5:.3f} (want 0.875)')
    if abs(lin - 1.5) > 0.15 or abs(z5 - 0.875) > 0.1:
        print('  zombie verdict: none -- the levels in this take are not linear (checks above)')
    else:
        print(f'  zombie verdict: Z3b/Z3a = {z3:.3f} ->',
              'GB table (no change)' if abs(z3 - 1.0) < abs(z3 - 1.5) else 'old GBA rule (+1 a write)')


def record(seconds):
    os.makedirs(os.path.join(HERE, '.payloadcmp'), exist_ok=True)
    out = os.path.join(HERE, '.payloadcmp', 'zombie.wav')
    rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'avfoundation',
                            '-i', ':0', '-t', str(seconds), '-ac', '1', '-ar', '48000', out])
    import time
    time.sleep(1.5)                         # the microphone takes a moment to open
    sys.path.insert(0, HERE)
    from monitor import Monitor, assemble
    code = assemble(os.path.join(HERE, '..', '..', 'tests', 'roms', 'payloads', 'zombie.s'), out_dir='/tmp')
    with Monitor() as m:
        m.ping()
        call = m.call                       # the payload plays ~9 s; calls wait 10 s
        m.call = lambda address, arg=0, timeout=20.0: call(address, arg, timeout)
        print('payload answered', hex(m.run_payload(code, 0)))
    rec.wait()
    analyse(out)


if __name__ == '__main__':
    if sys.argv[1] == 'record':
        record(int(sys.argv[2]) if len(sys.argv) > 2 else 14)
    else:
        for p in sys.argv[2:]:
            analyse(p)
