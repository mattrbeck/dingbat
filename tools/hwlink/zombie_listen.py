"""Measure tests/roms/payloads/zombie.s from a recording of the console's speaker.

    python3 zombie_listen.py record [seconds]   # mic -> zombie.wav while the payload runs
    python3 zombie_listen.py analyse take.wav   # any recording (or an emulator dump)

zombie.s plays channel 2 at 1024 Hz in fixed segments (0.5 s silence, then
0.4 s each: volume 8, 12, 8 -> four NR22 writes, 8 -> one 0x88 write, 7). The
1024 Hz amplitude of every segment is compared with the volume-8 reference in
the same take, so microphone gain and room do not matter, only the ratios:
3b = 8 (ratio 1.0) is the GB table, 3b = 12 (ratio 1.5) is the old GBA rule;
4b = 7 (0.875) is the control both agree on. Then channel 4 at shift 14
(silent if the LFSR is frozen, the GB rule) against shift 13 (clicks in both).
"""
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SEGMENTS = ['1 ref 8', '2 ref 12', '3a 8', '3b 4x 0x80', '4a 8', '4b 0x88', '5 ref 7']
EXPECT = {'1 ref 8': 8, '2 ref 12': 12, '3a 8': 8, '4a 8': 8, '4b 0x88': 7, '5 ref 7': 7}


def load(path):
    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
    return a.reshape(-1, ch).mean(axis=1), rate


def tone(x, rate, f=1024.0):
    """Amplitude of the f component (a projection, so noise elsewhere is ignored)."""
    t = np.arange(len(x)) / rate
    return 2 * abs(np.mean(x * np.exp(-2j * np.pi * f * t)))


def analyse(path):
    x, rate = load(path)
    # the first onset of the 1024 Hz tone: 10 ms windows
    win = rate // 100
    level = [tone(x[i:i + win], rate) for i in range(0, len(x) - win, win)]
    floor = np.median(level[:20]) if len(level) > 20 else 0
    thr = max(level) * 0.25
    onset = next(i for i, v in enumerate(level) if v > thr and v > 4 * floor) * win
    seg = int(0.4 * rate)
    amps = {}
    for k, name in enumerate(SEGMENTS):
        a = onset + k * seg
        amps[name] = tone(x[a + seg // 5:a + seg * 4 // 5], rate)
    ref = amps['1 ref 8']
    print(f'{os.path.basename(path)}: onset at {onset / rate:.2f} s')
    for name in SEGMENTS:
        r = amps[name] / ref
        exp = EXPECT.get(name)
        note = f'expect {exp / 8:.3f}' if exp else 'GB table 1.000 / old GBA rule 1.500'
        print(f'  {name:12s} ratio to vol 8: {r:.3f}  (~volume {8 * r:4.1f})   {note}')
    r = amps['3b 4x 0x80'] / amps['3a 8']
    print(f'  verdict: 3b/3a = {r:.3f} ->',
          'GB table (no change)' if abs(r - 1.0) < abs(r - 1.5) else 'old GBA rule (+1 a write)')
    # noise: steps are edges, so measure the first difference's energy
    def clicks(a, b):
        d = np.diff(x[a:b]); return float(np.sqrt(np.mean(d ** 2)))
    quiet = max(clicks(max(0, onset - int(0.4 * rate)), onset - int(0.05 * rate)), 1.0)
    s14 = clicks(onset + 7 * seg + seg // 5, onset + 9 * seg)
    s13 = clicks(onset + 9 * seg + seg // 5, onset + 11 * seg)
    print(f'  noise: edge energy vs silence -- shift 14: {s14 / quiet:.2f}x, shift 13 (control): {s13 / quiet:.2f}x')
    print('  verdict: shift 14', 'frozen (GB rule)' if s14 - 1.0 < 0.2 * (s13 - 1.0) else 'steps (old GBA rule)')


def record(seconds):
    out = os.path.join(HERE, 'zombie.wav')
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
