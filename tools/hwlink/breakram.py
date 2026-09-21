"""Sweep tests/roms/payloads/breakram.s over its entry sled, console and
emulators side by side.

    python3 breakram.py                  # IWRAM loop, k = 0..23
    python3 breakram.py --ewram 0 59     # EWRAM loop
    python3 breakram.py --stale=1        # one never-matching dispatcher entry
    python3 breakram.py --stamp          # T = the DMA's own write, from the entry
    python3 breakram.py --vcount=30 --edge=200 28 40   # a DISPSTAT edge
    python3 breakram.py --emulators-only --runs=3

    python3 breakram.py --record         # the whole table, console -> breakram-agb.json
    python3 breakram.py --check          # the emulators against that file

Loop cells are `reads@line`: how many loads the loop made before the DMA's
word showed up, and VCOUNT when it left; `-` = never caught, `WD` = watchdog.
Stamp cells are `T=<TM0> <reads>`. Edge cells are DISPSTAT's low three bits
(V-count match, H-blank, V-blank) and VCOUNT. The console is asked `--runs`
times per k and every distinct answer is shown.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp

SOURCE = os.path.join(payloadcmp.ROMS, 'payloads', 'breakram.s')
EMULATORS = ('dingbat', 'dingbat-bios', 'mgba')
TABLE_FILE = os.path.join(HERE, 'breakram-agb.json')

# the recorded table: (flags, first k, last k)
TABLE = [
    ('', 0, 12),
    ('--stale=1', 0, 12),
    ('--ewram', 0, 29),
    ('--stamp', 0, 2),
    ('--stamp --vcount=160', 0, 2),
    ('--stamp --vcount=30', 0, 2),
    ('--stamp --dma0 --vcount=30', 0, 2),
    ('--stamp --vdma --vcount=159', 0, 2),
    ('--stamp --hblank --vcount=30', 0, 2),
    ('--vcount=30 --edge=200', 28, 40),
    ('--running --vcount=30 --edge=212', 18, 30),
    ('--vcount=30 --edge=255', 28, 40),
    ('--vcount=159 --edge=255', 28, 40),
    ('--nodma --hblank --vcount=30 --edge=12', 34, 46),
    ('--hblank --vcount=30 --edge=12', 32, 44),
]


def mode_of(flags):
    def value(name, default=None):
        return next((int(f.split('=')[1], 0) for f in flags if f.startswith(name + '=')), default)
    mode = (0x100 if '--ewram' in flags else 0) | (0x200 if '--stamp' in flags else 0)
    mode |= (value('--stale', 0) & 1) << 12
    vcount = value('--vcount')
    if vcount is not None:
        mode |= 0x400 | (vcount << 16)
    if '--dma0' in flags:
        mode |= 0x800
    if '--nodma' in flags:
        mode |= 0x80
    if '--running' in flags:
        mode |= 0x4000
    if '--hblank' in flags:
        mode |= 0x6000
    if '--hblank-halted' in flags:
        mode |= 0x2400
    if '--vdma' in flags:
        mode |= 0x8000
    coarse = value('--edge', 0)
    return mode | (coarse << 24)


def show(v, mode):
    if v == 0xFFFFFFFF:
        return 'WD'
    if mode >> 24:
        return f'{v & 7:03b} v{v >> 8}'
    if mode & 0x200:
        reads = v & 0xFFFF
        return f'T={v >> 16} ' + ('-' if reads >= 0x4000 else str(reads))
    reads, line = v >> 8, v & 0xFF
    return '-' if reads >= 0x4000 else f'{reads}@{line}'


def in_emulators(mode, ks):
    args = [mode | k for k in ks]
    rom = payloadcmp.build_wrapper(SOURCE, args)
    got = payloadcmp.in_emulators(rom, len(args), names=EMULATORS, frames=30 + 4 * len(args))
    return {name: [show(w, mode) for w in words] for name, words in got.items()}


def on_console(mode, ks, runs):
    from monitor import assemble
    import rig
    code = assemble(SOURCE, out_dir=payloadcmp.SCRATCH)
    cells = rig.ask(code, [mode | k for k in ks], runs=runs, show=lambda v: show(v, mode))
    return [c.text for c in cells]


def table(got, ks):
    names = [n for n in ('hardware',) + EMULATORS if n in got]
    print(f'{"k":>3}  ' + ''.join(f'{n:<16}' for n in names))
    for i, k in enumerate(ks):
        cells = [got[n][i] for n in names]
        mark = '' if len(set(cells)) == 1 else '  <<<'
        print(f'{k:>3}  ' + ''.join(f'{c:<16}' for c in cells) + mark)


def main(argv):
    flags = [a for a in argv[1:] if a.startswith('--')]
    nums = [int(a, 0) for a in argv[1:] if not a.startswith('--')]
    runs = next((int(f.split('=')[1]) for f in flags if f.startswith('--runs=')), 2)

    if '--record' in flags:
        out = {}
        for row, k0, k1 in TABLE:
            ks = list(range(k0, k1 + 1))
            out[row] = dict(zip(map(str, ks), on_console(mode_of(row.split()), ks, runs)))
            print(row or '(loop)', out[row], flush=True)
            json.dump(out, open(TABLE_FILE, 'w'), indent=1)
        return 0
    if '--check' in flags:
        import tables
        wrong = tables.check(tables.rows(only=('breakram',)))
        return 1 if wrong['dingbat'] or wrong['dingbat-bios'] else 0

    k0, k1 = (nums + [0, 23])[:2] if len(nums) < 2 else nums[:2]
    ks = list(range(k0, k1 + 1))
    mode = mode_of(flags)
    got = in_emulators(mode, ks)
    if '--emulators-only' not in flags:
        got['hardware'] = on_console(mode, ks, runs)
    table(got, ks)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
