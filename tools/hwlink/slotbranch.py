"""Does a branch into the gamepak wait for a committed prefetch? Three ways.

    python3 slotbranch.py [--emulators-only] [--runs=N] [WAITCNT ...]
    python3 slotbranch.py --tally --source=PATH [--runs=N]

--tally runs any payload built like slotbranch.s (payloads/slotldm.s) and
prints, per table row, how often each time came back over the runs and both
passes, beside dingbat's: for rows the console answers more than one way.

tests/roms/payloads/slotbranch.s explains the trial: one load fetched from an
empty cartridge slot, then the BL-suffix float branching either straight home
(the control) or to a second hop in the slot, `bx r6` at 0x08008E60. The
column that matters is `rom-home`, the extra cost of the gamepak branch
target, per load: dingbat adds one cycle where the branch's nonsequential
fetch starts in the final cycle of a halfword the prefetcher has started
(at WAITCNT 0x4000, S = 3: loads with d = data + internal cycles = 4 or 7).
Default WAITCNT 0x4000, the only prefetch-on setting known to be safe on an
empty slot; other values are for the emulators (--emulators-only) only.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp
import slotexec

SOURCE = os.path.join(payloadcmp.ROMS, 'payloads', 'slotbranch.s')
RESULTS = 0x02008000


def rows_of(source):
    """(trials, planted): the trial table's (address, comment) rows, and every
    gamepak address the emulator image needs (trials plus the second hop)."""
    text = open(source).read().split('table:')[1]
    trials_text, _, plant_text = text.partition('plant:')
    pat = r'\s*\.word\s+(0x0[89A-D][0-9A-Fa-f]{6}),.*?@\s*(.*)'
    trials = [(int(m.group(1), 16), m.group(2).strip())
              for m in (re.match(pat, l) for l in trials_text.splitlines()) if m]
    extra = [(int(m.group(1), 16), m.group(2).strip())
             for m in (re.match(pat, l) for l in plant_text.splitlines()) if m]
    return trials, trials + extra


def tally(source, runs):
    from collections import Counter
    from monitor import Monitor, assemble
    trials, planted = rows_of(source)
    n = len(trials) * 2
    rom = payloadcmp.build_wrapper(source, [0x4000])
    slotexec.plant(rom, planted)
    emu = payloadcmp.in_emulators(rom, 0, block=(RESULTS, n * 2), frames=40)
    ding = slotexec.halfwords(emu['dingbat'], n)
    code = assemble(source, out_dir=payloadcmp.SCRATCH)
    seen = [Counter() for _ in trials]
    for _ in range(runs):
        with Monitor() as m:
            m.ping()
            m.run_payload(code, 0x4000)
            got = slotexec.halfwords(m.read_mem(RESULTS, n * 2), n)
        for i, (t, _, _) in enumerate(got):
            seen[i % len(trials)][t] += 1
    for i, (addr, label) in enumerate(trials):
        print(f'{i:>3} dingbat {ding[i][0]:>5}  console {dict(sorted(seen[i].items()))}   {label}')
    return 0


def main(argv):
    emulators_only = '--emulators-only' in argv
    runs = 3
    rest = []
    source = None
    for a in argv[1:]:
        if a.startswith('--runs='):
            runs = int(a.split('=')[1])
        elif a.startswith('--source='):
            source = a.split('=', 1)[1]
        elif not a.startswith('--'):
            rest.append(a)
    if '--tally' in argv:
        return tally(source or SOURCE, runs)
    waitcnts = [int(a, 0) for a in rest] or [0x4000]
    if not emulators_only and any(w != 0x4000 for w in waitcnts):
        print('refusing: only WAITCNT 0x4000 is known safe on the console '
              '(use --emulators-only for others)')
        return 2
    trials, planted = rows_of(SOURCE)
    n = len(trials) * 2
    words = n * 2
    for waitcnt in waitcnts:
        rom = payloadcmp.build_wrapper(SOURCE, [waitcnt])
        slotexec.plant(rom, planted)
        got = {k: slotexec.halfwords(v, n) for k, v in payloadcmp.in_emulators(
            rom, 0, block=(RESULTS, words), frames=20).items()}
        stable = True
        if not emulators_only:
            from monitor import Monitor, assemble
            code = assemble(SOURCE, out_dir=payloadcmp.SCRATCH)
            seen = []
            for _ in range(runs):
                with Monitor() as m:
                    m.ping()
                    m.run_payload(code, waitcnt)
                    seen.append(slotexec.halfwords(m.read_mem(RESULTS, words), n))
            got['hardware'] = seen[0]
            stable = all(s == seen[0] for s in seen)
        names = [k for k in ('hardware', 'dingbat', 'mgba') if k in got]
        print(f'\nWAITCNT {waitcnt:#06x}' + ('' if emulators_only else
              f'   hardware: {runs} runs, ' + ('identical' if stable else 'VARYING')))

        def cell(k, i):
            t, _, lr = got[k][i]
            twice = got[k][i] == got[k][i + len(trials)]
            ok = lr == trials[i][0] + 5 and t != 0xFFFF
            return t if ok and twice else None

        print(f'{"":>3} ' + ''.join(f'{k + " home/rom/diff":>24}' for k in names) + '   load')
        for i in range(0, len(trials), 2):
            cells = []
            diffs = []
            for k in names:
                h, r = cell(k, i), cell(k, i + 1)
                if h is None or r is None:
                    cells.append(f'{"BAD":>24}')
                    diffs.append(None)
                else:
                    cells.append(f'{h:>10}{r:>7}{r - h:>7}')
                    diffs.append(r - h)
            mark = ' <<<' if len(set(diffs)) > 1 else ''
            print(f'{i // 2:>3} ' + ''.join(cells) + '   ' + trials[i][1] + mark)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
