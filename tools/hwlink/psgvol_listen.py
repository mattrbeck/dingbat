"""Read tests/roms/payloads/psgvol.s off the console's speaker, or an emulator's output.

    python3 psgvol_listen.py record            # Mac mic -> .payloadcmp/psgvol.wav, then analyse
    python3 psgvol_listen.py emu [names...]    # the playtest emulators' audio dumps (tools/playtest/emu.py names), analysed
    python3 psgvol_listen.py analyse x.wav     # any recording

Every tone is 1024 Hz; each is read as the mean of independent 10 ms
1024 Hz projections over its middle 60%, found by its own onset and end (a
capture that drops audio in small gaps loses samples, not level). The
master-volume tones are read against P7 of the same round, the DirectSound
tones against it too.
"""
import os
import subprocess
import sys
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRATCH = os.path.join(HERE, '.payloadcmp')
PAYLOAD = os.path.join(REPO, 'tests', 'roms', 'payloads', 'psgvol.s')
F = 1024.0
ROUND = ['P7', 'P3', 'P0', 'P1', 'P5', 'P7b', 'D100', 'D50', 'P7c', 'D100b']
ROUNDS = 2


def load(path):
    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
    return a.reshape(-1, ch).mean(axis=1), rate


def proj(x, rate, a, b):
    s = x[a:b]
    t = (np.arange(len(s)) + a) / rate
    return 2 * abs(np.mean(s * np.exp(-2j * np.pi * F * t)))


def level(x, rate, a, b):
    w = rate // 100
    v = [proj(x, rate, i, i + w) for i in range(a, b - w + 1, w)]
    return float(np.mean(v)) if v else 0.0


def segments(x, rate):
    """(start, end) of stretches where the 1024 Hz projection stands clear
    of the quietest 10% of 20 ms windows."""
    w = rate // 50
    lv = np.array([proj(x, rate, i, i + w) for i in range(0, len(x) - w, w)])
    floor = np.percentile(lv, 10) + 1e-9
    on = lv > 4 * floor
    for k in range(1, len(on) - 1):              # one weak window does not split
        if on[k - 1] and on[k + 1]: on[k] = True
    out, cur = [], None
    for k, v in enumerate(list(on) + [False]):
        if v and cur is None: cur = k
        if not v and cur is not None:
            if (k - cur) * w >= 0.15 * rate: out.append((cur * w, k * w))
            cur = None
    return out, floor


def analyse(path):
    x, rate = load(path)
    x = x - x.mean()
    segs, floor = segments(x, rate)
    k0 = next((k for k, (a, b) in enumerate(segs) if b - a >= 0.4 * rate), None)
    if k0 is None:
        print(f'{os.path.basename(path)}: no sync tone'); return
    tones = segs[k0 + 1:]
    names = ROUND * ROUNDS
    if len(tones) == len(names) - ROUNDS:
        names = [n for n in names if n != 'P0']
        p0 = 'silent (not found)'
    elif len(tones) == len(names):
        p0 = None
    else:
        print(f'{os.path.basename(path)}: {len(tones)} tones, want {len(names)} or {len(names) - ROUNDS}:',
              [(round(a / rate, 2), round((b - a) / rate, 2)) for a, b in tones]); return
    lv = []
    for a, b in tones:
        d = b - a
        lv.append(level(x, rate, a + int(0.2 * d), a + int(0.8 * d)))
    print(f'{os.path.basename(path)}: {len(tones)} tones')
    per = len(names) // ROUNDS
    ratios = {}
    for r in range(ROUNDS):
        got = dict(zip(names[r * per:(r + 1) * per], lv[r * per:(r + 1) * per]))
        ref = np.mean([got['P7'], got['P7b'], got['P7c']])
        print(f'  round {r + 1}: P7 drift ' + ' '.join(f'{got[k] / ref:.3f}' for k in ('P7', 'P7b', 'P7c')))
        for k, v in got.items():
            if k.startswith('P7'): continue
            ratios.setdefault(k.rstrip('b'), []).append(v / ref)
    pred = {'P3': (3 / 7, 4 / 8), 'P0': (0.0, 1 / 8), 'P1': (1 / 7, 2 / 8), 'P5': (5 / 7, 6 / 8)}
    print('  tone   / P7 (each round)      V/8    (V+1)/8')
    for k, v in ratios.items():
        p = pred.get(k)
        print(f'  {k:5s}  ' + ' '.join(f'{u:6.3f}' for u in v) +
              (f'        {p[0]:.3f}   {p[1]:.3f}' if p else ''))
    if p0: print(f'  P0: {p0}')
    votes = []
    for k, (a, b) in pred.items():
        if k in ratios:
            m = float(np.mean(ratios[k]))
            votes.append('V/8' if abs(m - a) < abs(m - b) else '(V+1)/8')
    if p0: votes.append('V/8')
    print('  verdict:', votes[0] if votes and len(set(votes)) == 1 else f'mixed {votes}')
    if 'D100' in ratios:
        d = float(np.mean(ratios['D100']))
        print(f'  DirectSound 100% / PSG (one channel, volume 15, master 7, PSG 100%): {d:.3f} '
              f'({20 * np.log10(d):+.2f} dB); D50 / D100 {np.mean(ratios["D50"]) / d:.3f}')


def emu(names):
    sys.path.insert(0, HERE)
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import payloadcmp
    import emu as emulib
    rom = payloadcmp.build_wrapper(PAYLOAD, [0])
    for name in names:
        raw = os.path.join(SCRATCH, f'psgvol-{name}.raw')
        e = emulib.Emulator(name, rom, os.path.join(SCRATCH, 'run', name), audio=raw)
        e.run(60 * 18)
        e.quit()
        out = os.path.join(SCRATCH, f'psgvol-{name}.wav')
        w = wave.open(out, 'wb')
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(32768)
        w.writeframes(open(raw, 'rb').read())
        w.close()
        print(f'== {name}')
        analyse(out)


def record(seconds=20):
    sys.path.insert(0, HERE)
    from zombie_listen import mic
    from monitor import Monitor, assemble
    os.makedirs(SCRATCH, exist_ok=True)
    out = os.path.join(SCRATCH, 'psgvol.wav')
    idx, name = mic()
    print(f'recording from [{idx}] {name}')
    rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
                            '-thread_queue_size', '8192', '-f', 'avfoundation',
                            '-i', f':{idx}', '-t', str(seconds), '-ac', '1', '-ar', '48000', out])
    time.sleep(1.5)
    code = assemble(PAYLOAD, out_dir='/tmp')
    with Monitor() as m:
        m.ping()
        call = m.call                       # the payload plays ~14 s; calls wait 10 s
        m.call = lambda address, arg=0, timeout=30.0: call(address, arg, timeout)
        print('payload answered', hex(m.run_payload(code, 0)))
    rec.wait()
    print(f'recorded {wave.open(out).getnframes() / 48000:.2f} s of {seconds}')
    analyse(out)


if __name__ == '__main__':
    if sys.argv[1] == 'record':
        record()
    elif sys.argv[1] == 'emu':
        emu(sys.argv[2:] or ['dingbat', 'mgba'])
    else:
        for p in sys.argv[2:]:
            analyse(p)
