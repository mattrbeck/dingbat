"""Read the NRx2 rewrite table off the console's speaker (tests/roms/payloads/nrx2table.s).

    python3 nrx2table_listen.py record          # Mac mic -> .payloadcmp/nrx2table.wav, then analyse
    python3 nrx2table_listen.py analyse x.wav   # any recording (or an emulator dump)

Every note is read against itself: its level 70-140 ms in (before the write
at 150 ms) and 210-320 ms in (after it), each the mean of independent 10 ms
1000.5 Hz projections, at the note's own onset and the take's own time scale
(the Mac's capture drops ~11% of the audio in small gaps; zombie.s's fourth
take). Levels become volumes through a straight line fitted to the reference
notes (6, 8, 10, 12) of the same take, whose fit is printed as the check.

Each case is predicted two ways from its measured `before`:
  CGB   the GB core's table (SameSuite, CGB E)
  AGB?  the same with a period-0 envelope never "still updating" -- the one
        reading of zombie.s's 0x88 cell (6, where the CGB gives 7)
"""
import os
import subprocess
import sys
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from zombie_listen import load, level, runs, mic   # noqa: E402

# name, old NR22, new NR22, writes -- nrx2table.s's table, played three times
TABLE = [('R8', 0x80, 0, 0), ('C1', 0x80, 0x88, 1), ('R12', 0xC0, 0, 0), ('C2', 0x60, 0x68, 1),
         ('R6', 0x60, 0, 0), ('C3', 0x68, 0x68, 1), ('R10', 0xA0, 0, 0), ('C4', 0x68, 0x60, 1),
         ('C5', 0x80, 0x80, 4), ('C6', 0x87, 0x88, 1), ('C7', 0x6F, 0x68, 1)]
ROUNDS = 3
NOTE, WRITE = 0.60, 0.15                 # note spacing, write offset (s)


def predict(before, old, new, writes, p0_updating):
    """The volume after `writes` NRx2 writes of `new` over a playing note that
    was triggered with `old` and is at `before` (common/psg_channels.nim
    write_nrx2). `p0_updating`: whether a period-0 envelope counts as still
    updating (the CGB: yes, a fresh trigger)."""
    vol, period, add = before, old & 7, bool(old & 8)
    updating = True if period else p0_updating
    for _ in range(writes):
        new_add, new_period = bool(new & 8), new & 7
        if new_add:
            d = 1 if period == 0 and updating else (2 if not add else 0)
        elif new_period != 0 and period == 0:
            d = 1 if add else -1
        else:
            d = 0
        vol = (vol + d) & 15
        if new_add != add:
            vol = (16 - vol) & 15
        period, add = new_period, new_add
    return vol


def analyse(path):
    x, rate = load(path)
    rs = runs(x, rate)
    sync = next((r for r in rs if r[1] >= 0.4), None)
    if sync is None:
        print(f'{os.path.basename(path)}: no sync tone'); return
    notes = [r for r in rs if r[0] > sync[0] + 0.3 and r[1] >= 0.2]
    want = len(TABLE) * ROUNDS
    if len(notes) != want:
        print(f'{os.path.basename(path)}: {len(notes)} notes found, {want} expected:',
              [(round(a, 2), round(b, 2)) for a, b in notes]); return
    on = [n[0] for n in notes]
    f = float(np.median(np.diff(on))) / NOTE
    print(f'{os.path.basename(path)}: {want} notes; the recording runs at {f:.3f}x the console\'s time')
    def lv(t0, a, b):
        return level(x, rate, int((t0 + f * a) * rate), int((t0 + f * b) * rate))
    meas = []
    for k, t0 in enumerate(on):
        name, old, new, writes = TABLE[k % len(TABLE)]
        moving = old & 7                   # an old envelope still stepping
        before = lv(t0, 0.10, 0.145) if moving else lv(t0, 0.07, 0.14)
        after = lv(t0, 0.21, 0.32)
        meas.append((name, old, new, writes, before, after))
    # volume scale from the references: amplitude = s * volume
    pts = [(int(m[0][1:]), a) for m in meas if m[0].startswith('R') for a in (m[4], m[5])]
    v, a = np.array([p[0] for p in pts], float), np.array([p[1] for p in pts])
    s = float(np.sum(v * a) / np.sum(v * v))
    err = np.abs(a / s - v) / v
    print(f'  check: references read within {100 * err.max():.1f}% (mean {100 * err.mean():.1f}%) '
          f'of volumes 6 / 8 / 10 / 12')
    # a microphone reads a held note to a few percent (the first SP take:
    # 16.0-17.4 per volume step); a reading is taken as the nearer prediction
    if err.max() > 0.10:
        print('  verdict: none -- this take is not linear enough to read whole volumes')
        return
    print('  case  old->new  writes   before  after   CGB  AGB?   (each round)')
    tally = {}
    for name, old, new, writes, b, aft in meas:
        if name.startswith('R'):
            continue
        bv, av = b / s, aft / s
        # a period-0 note starts at its NR22 volume; an old period-7 one has
        # moved, so its start is read
        bi = old >> 4 if not old & 7 else int(round(bv))
        if not old & 7:
            av = bi * aft / b              # within one note: gain drift cancels
        cgb = predict(bi, old, new, writes, True)
        agb = predict(bi, old, new, writes, False)
        near = min((abs(av - cgb), 'CGB'), (abs(av - agb), 'AGB?'))
        tag = ('both' if cgb == agb and abs(av - cgb) <= 0.75 else
               near[1] if near[0] <= 0.75 and cgb != agb else 'neither')
        tally.setdefault(name, []).append(tag)
        print(f'  {name}    {old:02X}->{new:02X}   x{writes}     {bv:5.2f}  {av:5.2f}   {cgb:3d}  {agb:3d}   {tag}')
    print('  summary:')
    for name, tags in tally.items():
        print(f'    {name}: {", ".join(tags)}')


def record(seconds=26):
    os.makedirs(os.path.join(HERE, '.payloadcmp'), exist_ok=True)
    out = os.path.join(HERE, '.payloadcmp', 'nrx2table.wav')
    idx, name = mic()
    print(f'recording from [{idx}] {name}')
    rec = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
                            '-thread_queue_size', '8192', '-f', 'avfoundation',
                            '-i', f':{idx}', '-t', str(seconds), '-ac', '1', '-ar', '48000', out])
    time.sleep(1.5)                         # the microphone takes a moment to open
    from monitor import Monitor, assemble
    code = assemble(os.path.join(HERE, '..', '..', 'tests', 'roms', 'payloads', 'nrx2table.s'),
                    out_dir='/tmp')
    with Monitor() as m:
        m.ping()
        call = m.call                       # the payload plays ~22 s; calls wait 10 s
        m.call = lambda address, arg=0, timeout=40.0: call(address, arg, timeout)
        print('payload answered', hex(m.run_payload(code, 0)))
    rec.wait()
    print(f'recorded {wave.open(out).getnframes() / 48000:.2f} s of {seconds}')
    analyse(out)


if __name__ == '__main__':
    if sys.argv[1] == 'record':
        record()
    else:
        for p in sys.argv[2:]:
            analyse(p)
