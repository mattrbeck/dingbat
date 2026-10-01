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


def analyse(path):
    x, rate = load(path)
    win = rate // 100
    lv = [tone(x, rate, i, i + win) for i in range(0, len(x) - win, win)]
    on = next(i for i, v in enumerate(lv) if v > 0.3 * max(lv)) * win
    T = lambda s: on + int(s * rate)
    def mid(s, d):                          # the middle 60% of a segment
        return T(s + 0.2 * d), T(s + 0.8 * d)
    print(f'{os.path.basename(path)}: sync onset at {on / rate:.2f} s')
    quiet = np.mean([clicks(x, *mid(1.10, 0.3)), clicks(x, *mid(2.00, 0.3)), clicks(x, *mid(2.90, 0.3))])
    quiet = max(quiet, 1.0)
    n = [clicks(x, *mid(s, 0.6)) / quiet for s in (0.50, 1.40, 2.30)]
    print(f'  noise click energy re the gaps: N1 shift 13 {n[0]:.2f}x, N2 shift 14 {n[1]:.2f}x, '
          f'N3 shift 13 {n[2]:.2f}x')
    ctl = min(n[0], n[2])
    if ctl < 2:
        print('  noise verdict: none -- the shift-13 controls are not above the gaps')
    else:
        print('  noise verdict: shift 14',
              'frozen (GB rule)' if n[1] - 1 < 0.2 * (ctl - 1) else 'steps (old GBA rule)')
    seg = {'Z1 ref 8': (3.20, .25), 'Z2 ref 12': (3.70, .25), 'Z3a 8': (4.20, .25),
           'Z3b 4x 0x80': (4.45, .25), 'Z4 ref 8': (4.95, .25), 'Z5a 8': (5.45, .25),
           'Z5b 0x88': (5.70, .25), 'Z6 ref 7': (6.20, .25)}
    amp = {k: tone(x, rate, *mid(*v)) for k, v in seg.items()}
    ref = np.mean([amp['Z1 ref 8'], amp['Z4 ref 8']])
    for k in seg:
        print(f'  {k:12s} ~volume {8 * amp[k] / ref:5.2f}')
    z3 = amp['Z3b 4x 0x80'] / amp['Z3a 8']
    z5 = amp['Z5b 0x88'] / amp['Z5a 8']
    lin = amp['Z2 ref 12'] / amp['Z1 ref 8']
    print(f'  check: Z2/Z1 = {lin:.3f} (want 1.500); control Z5b/Z5a = {z5:.3f} (want 0.875)')
    print(f'  zombie verdict: Z3b/Z3a = {z3:.3f} ->',
          'GB table (no change)' if abs(z3 - 1.0) < abs(z3 - 1.5) else 'old GBA rule (+1 a write)')


def record(seconds):
    os.makedirs(os.path.join(HERE, '.payloadcmp'), exist_ok=True)
    out = os.path.join(HERE, '.payloadcmp', 'zombie.wav')
    rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'avfoundation',
                            '-i', ':0', '-t', str(seconds), '-ac', '1', '-ar', '48000', out])
    sys.path.insert(0, HERE)
    from monitor import Monitor, assemble
    code = assemble(os.path.join(HERE, '..', '..', 'tests', 'roms', 'payloads', 'zombie.s'), out_dir='/tmp')
    with Monitor() as m:
        m.ping()
        print('payload answered', hex(m.run_payload(code, 0)))
    rec.wait()
    analyse(out)


if __name__ == '__main__':
    if sys.argv[1] == 'record':
        record(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    else:
        for p in sys.argv[2:]:
            analyse(p)
