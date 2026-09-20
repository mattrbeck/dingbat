"""Slide an H-blank DMA across code fetched from an empty cartridge slot.

    python3 slotdma.py [--emulators-only] [--runs=N] [--control] [--waitcnt=N] [K0 K1]

tests/roms/payloads/slotdma.s explains the excursion. This runs it for every
sled length K0..K1 (default 0..41, 14 to a call) on the console and in both
emulators, and prints per k:

    T  TM0 at the landing pad, less k  -- what the excursion plus the DMA cost
    D  TM1 as the DMA's own write froze it -- when the DMA ran

A flat D is a grant that waits for nothing; a D that ramps and snaps is one
that waits for the gamepak access in flight. A T that steps by more than the
DMA's own length is a burst the DMA broke.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp
import slotexec

SOURCE = os.path.join(payloadcmp.ROMS, 'payloads', 'slotdma.s')
RESULTS = 0x02008000
TRIALS = 14


def decode(words):
    raw = b''.join(w.to_bytes(4, 'little') for w in words)
    out = []
    for i in range(TRIALS):
        r = raw[i * 16:i * 16 + 16]
        t, d, cnt = (int.from_bytes(r[a:a + 2], 'little') for a in (0, 2, 4))
        r0, lr = (int.from_bytes(r[a:a + 4], 'little') for a in (8, 12))
        out.append((t, d, cnt, r0, lr))
    return out


HOP = 0


def show(v, k):
    t, d, cnt, r0, lr = v
    if t == 0xFFFF:
        return 'WATCHDOG'
    s = f'{t - k:>4} {d if not cnt & 0x80 else "----":>4}'
    if HOP:                              # what the single opcode loaded
        s += f' {r0:08X}'
    return s


def main(argv):
    flags = [a for a in argv[1:] if a.startswith('--')]
    nums = [int(a, 0) for a in argv[1:] if not a.startswith('--')]
    k0, k1 = (nums + [0, 41])[:2] if len(nums) < 2 else nums[:2]
    runs = next((int(f.split('=')[1]) for f in flags if f.startswith('--runs=')), 3)
    waitcnt = next((int(f.split('=')[1], 0) for f in flags if f.startswith('--waitcnt=')), 0)
    global HOP
    HOP = next((int(f.split('=')[1]) for f in flags if f.startswith('--hop=')), 0)
    delay = next((int(f.split('=')[1]) for f in flags if f.startswith('--delay=')), 0)
    mode = ((0x100 if '--control' in flags else 0) | (0x200 if '--nodma' in flags else 0)
            | (HOP << 10) | (delay << 12) | (waitcnt << 16))
    rows = slotexec.table_of(SOURCE)
    bases = list(range(k0, k1 + 1, TRIALS))
    args = [mode | b for b in bases]

    got = {}
    for arg in args:                     # the block is overwritten per call
        rom = payloadcmp.build_wrapper(SOURCE, [arg])
        slotexec.plant(rom, rows)
        for name, words in payloadcmp.in_emulators(
                rom, 0, block=(RESULTS, TRIALS * 4), frames=40).items():
            got.setdefault(name, {})[arg] = [decode(words)]
    if '--emulators-only' not in flags:
        from monitor import Monitor, assemble
        code = assemble(SOURCE, out_dir=payloadcmp.SCRATCH)
        for arg in args:
            for _ in range(runs):
                for attempt in range(3):     # the adapter drops a word now and
                    try:                     # then; a re-run costs half a second
                        with Monitor() as m:
                            m.ping()
                            m.run_payload(code, arg)
                            block = decode(m.read_mem(RESULTS, TRIALS * 4))
                        break
                    except Exception:
                        if attempt == 2:
                            raise
                        time.sleep(1.5)
                got.setdefault('hardware', {}).setdefault(arg, []).append(block)

    names = [n for n in ('hardware', 'dingbat', 'mgba') if n in got]
    print(f'{"k":>3}  ' + ''.join(f'{n + " T-k    D":<26}' for n in names))
    for arg, base in zip(args, bases):
        for i in range(TRIALS):
            k = base + i
            if k > k1:
                break
            cells = []
            for n in names:
                seen = sorted({show(r[i], k) for r in got[n][arg]})
                cells.append(' | '.join(seen))
            mark = '' if len(set(cells)) == 1 else '  <<<'
            print(f'{k:>3}  ' + ''.join(f'{c:<26}' for c in cells) + mark)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
