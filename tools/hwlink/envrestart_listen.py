"""Read tests/roms/payloads/envrestart.s off the console's speaker, or an emulator's output.

    python3 envrestart_listen.py record            # Mac mic -> .payloadcmp/envrestart.wav, then analyse
    python3 envrestart_listen.py emu [names...]    # the playtest emulators' audio dumps (tools/playtest/emu.py names), analysed
    python3 envrestart_listen.py analyse x.wav     # any recording

Every note ends in a ~200 ms steady level (the envelope frozen by a period-0
write) followed by a sharp stop, so notes are found by their ends and read
over the last 170..30 ms before each: a capture that drops audio in small
gaps (the Mac's, ~10%) loses samples, not level. Levels become volumes
through a line through the origin fitted to each channel's ref notes.

The question is B0 - A at each phase: 0 if a trigger discards the extra
envelope clock an NRx2 write armed, 1 if it survives (dingbat before the
fix). B20 - A is the control (the clock fires before the trigger).
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
PAYLOAD = os.path.join(REPO, 'tests', 'roms', 'payloads', 'envrestart.s')
SLOT = 0.5625

# (channel, kind, NRx2, phase) in the payload's order
NOTES = (
    [(2, 'R', 0x80, 0)] + [(2, k, 0x09, 0) for k in ('A', 'B0', 'B20')] +
    [(2, 'R', 0x40, 0)] + [(2, k, 0x09, 1) for k in ('A', 'B0', 'B20')] +
    [(2, 'R', 0x60, 0)] + [(2, k, 0x09, 2) for k in ('A', 'B0', 'B20')] +
    [(2, 'R', 0xA0, 0)] + [(2, k, 0x09, 3) for k in ('A', 'B0', 'B20')] +
    [(2, 'R', 0x80, 0), (2, 'A', 0x0A, 1), (2, 'B0', 0x0A, 1), (2, 'A', 0x0A, 3),
     (2, 'B0', 0x0A, 3), (2, 'R', 0x60, 0)])
for ch in (1, 4):
    NOTES += ([(ch, 'R', 0x80, 0), (ch, 'A', 0x09, 0), (ch, 'B0', 0x09, 0),
               (ch, 'A', 0x09, 1), (ch, 'B0', 0x09, 1), (ch, 'R', 0x40, 0),
               (ch, 'A', 0x09, 2), (ch, 'B0', 0x09, 2), (ch, 'A', 0x09, 3),
               (ch, 'B0', 0x09, 3), (ch, 'R', 0xA0, 0)])


def load(path):
    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
    return a.reshape(-1, ch).mean(axis=1), rate


def bandpass(x, rate, lo=250.0, hi=8000.0):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / rate)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, len(x))


def segments(y, rate):
    """(start, end) sample pairs of the sounding stretches."""
    hop = rate // 200                       # 5 ms
    env = np.sqrt(np.array([np.mean(y[i:i + hop] ** 2) for i in range(0, len(y) - hop, hop)]))
    floor = np.percentile(env, 10) + 1e-9
    loud = np.percentile(env, 90)
    on = env > max(4 * floor, 0.12 * loud)
    # bridge gaps under 30 ms (a dropped buffer, a quiet duty edge)
    k = 0
    while k < len(on):
        if not on[k]:
            j = k
            while j < len(on) and not on[j]: j += 1
            if 0 < k and j < len(on) and j - k <= 6: on[k:j] = True
            k = j
        else:
            k += 1
    out, cur = [], None
    for k, v in enumerate(list(on) + [False]):
        if v and cur is None: cur = k
        if not v and cur is not None:
            if (k - cur) * hop >= 0.12 * rate: out.append((cur * hop, k * hop))
            cur = None
    return out, floor


def analyse(path, quiet=False):
    x, rate = load(path)
    y = bandpass(x - x.mean(), rate)
    segs, floor = segments(y, rate)
    # the sync tone is the first segment of at least 0.4 s
    k0 = next((k for k, (a, b) in enumerate(segs) if (b - a) >= 0.4 * rate), None)
    if k0 is None:
        print(f'{os.path.basename(path)}: no sync tone'); return None
    notes = segs[k0 + 1:]
    if len(notes) != len(NOTES):
        print(f'{os.path.basename(path)}: {len(notes)} notes found, {len(NOTES)} expected:',
              [(round(a / rate, 2), round((b - a) / rate, 2)) for a, b in notes]); return None
    ends = np.array([b for a, b in notes]) / rate
    f = float(np.median(np.diff(ends))) / SLOT
    def lv(end):
        a, b = int(end - 0.17 * f * rate), int(end - 0.03 * f * rate)
        p = np.mean(y[a:b] ** 2) - floor ** 2
        return float(np.sqrt(max(p, 0.0)))
    amp = [lv(b) for a, b in notes]
    if not quiet:
        print(f'{os.path.basename(path)}: {len(notes)} notes; the recording runs at {f:.3f}x the console\'s time')
    vols = {}
    ok = True
    for ch in (2, 1, 4):
        refs = [(n[2] >> 4, amp[i]) for i, n in enumerate(NOTES) if n[0] == ch and n[1] == 'R']
        v = np.array([r[0] for r in refs], float); a = np.array([r[1] for r in refs])
        s = float(np.sum(v * a) / np.sum(v * v))
        err = np.abs(a / s - v) / v
        if not quiet:
            print(f'  ch{ch}: refs ' + ', '.join(f'{int(vv)}->{aa / s:.2f}' for vv, aa in zip(v, a)) +
                  f'  (worst {100 * err.max():.1f}%)')
        if err.max() > 0.10: ok = False
        for i, n in enumerate(NOTES):
            if n[0] == ch: vols[i] = amp[i] / s
    rows = []
    for i, n in enumerate(NOTES):
        ch, kind, val, ph = n
        if kind != 'A': continue
        b0 = next(j for j in range(i + 1, len(NOTES)) if NOTES[j][1] == 'B0')
        b20 = i + 2 if i + 2 < len(NOTES) and NOTES[i + 2][1] == 'B20' else None
        rows.append((ch, val, ph, vols[i], vols[b0], vols[b20] if b20 else None))
    if not quiet:
        print('  ch NRx2 phase     A     B0    B20    B0-A   B20-A')
        for ch, val, ph, a, b0, b20 in rows:
            print(f'  {ch}  {val:02X}    {ph}    {a:5.2f}  {b0:5.2f}  ' +
                  (f'{b20:5.2f}' if b20 is not None else '   - ') +
                  f'   {b0 - a:+5.2f}  ' + (f'{b20 - a:+5.2f}' if b20 is not None else ''))
        # period 1 only: a period-2 row's lead shows at half the phases
        d = [r[4] - r[3] for r in rows if r[1] == 0x09]
        print(f'  B0 - A (period 1): mean {np.mean(d):+.2f}, each ' + ' '.join(f'{v:+.1f}' for v in d))
        if not ok:
            print('  verdict: none -- the refs are not linear enough to read whole volumes')
        else:
            near = [round(v) for v in d]
            print('  verdict:', 'the extra clock SURVIVES the trigger' if all(v == 1 for v in near) else
                  'the trigger DISCARDS the extra clock' if all(v == 0 for v in near) else
                  f'mixed ({near})')
    return rows


def emu(names):
    sys.path.insert(0, HERE)
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import payloadcmp
    import emu as emulib
    rom = payloadcmp.build_wrapper(PAYLOAD, [0])
    for name in names:
        raw = os.path.join(SCRATCH, f'envrestart-{name}.raw')
        e = emulib.Emulator(name, rom, os.path.join(SCRATCH, 'run', name), audio=raw)
        e.run(60 * 30)
        e.quit()
        data = open(raw, 'rb').read()
        out = os.path.join(SCRATCH, f'envrestart-{name}.wav')
        w = wave.open(out, 'wb')
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(32768)
        w.writeframes(data)
        w.close()
        print(f'== {name}')
        analyse(out)


def record(seconds=30):
    sys.path.insert(0, HERE)
    from zombie_listen import mic
    from monitor import Monitor, assemble
    os.makedirs(SCRATCH, exist_ok=True)
    out = os.path.join(SCRATCH, 'envrestart.wav')
    idx, name = mic()
    print(f'recording from [{idx}] {name}')
    rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
                            '-thread_queue_size', '8192', '-f', 'avfoundation',
                            '-i', f':{idx}', '-t', str(seconds), '-ac', '1', '-ar', '48000', out])
    time.sleep(1.5)                         # the microphone takes a moment to open
    code = assemble(PAYLOAD, out_dir='/tmp')
    with Monitor() as m:
        m.ping()
        call = m.call                       # the payload plays ~26 s; calls wait 10 s
        m.call = lambda address, arg=0, timeout=45.0: call(address, arg, timeout)
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
