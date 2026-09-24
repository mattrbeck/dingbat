#!/usr/bin/env python3
"""Record dbsuite's own console tables: payloads run on the AGB SP over the
link rig (tools/hwlink), every cell asked three times, into sp-agb.json.

    python3 tests/roms/dbsuite/record.py                # every family
    python3 tests/roms/dbsuite/record.py switime halthb  # just these
    python3 tests/roms/dbsuite/record.py --show         # print the table

tools/hwlink/r0-agb.json holds the laws `nimble test_cyclelaws` freezes and
dingbat must pass; this file holds the rest of what dbsuite checks against
the console -- families dingbat may fail, and payloads that answer with a
block of memory as well as r0.  A cell is the r0 the payload returned
(8 hex digits), followed for a memory family by the words it left at
0x02008000.  A cell the console answered more than one way is kept with
every answer, joined by ' | ', and build.py turns it into a range or skips
it (see FAMILIES there).  Take the rig's lock first.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROMS = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(ROMS))
HWLINK = os.path.join(REPO, 'tools', 'hwlink')
TABLE_FILE = os.path.join(HERE, 'sp-agb.json')
sys.path.insert(0, HWLINK)


def src(name):
    local = os.path.join(HERE, 'payloads', name + '.s')
    return local if os.path.exists(local) else os.path.join(ROMS, 'payloads', name + '.s')


def dmasteal_args():
    out = [0]
    out += [n for n in (1, 2, 4, 8, 16, 32)]                     # IWRAM -> IWRAM, 16-bit
    out += [0x10000 | n for n in (1, 4, 16)]                      # 32-bit
    out += [(r << 8) | 4 for r in (1, 2, 3, 4)]                   # source EWRAM/VRAM/PRAM/OAM
    out += [0x10000 | (1 << 8) | 4, 0x10000 | (2 << 8) | 4]       # 32-bit from EWRAM, VRAM
    out += [(r << 12) | 4 for r in (1, 3, 4)]                     # to EWRAM/PRAM/OAM
    out += [0x10000 | (1 << 12) | 4]
    return out


# family -> (arguments, words of 0x02008000 kept per cell)
FAMILIES = {
    'switime': (list(range(23)), 0),
    'sweeptrig': ([f | (d << 8) for f in (0x0D, 0x2D, 0x1D, 0x3D, 0x01) for d in (30, 33, 37)]
                  + [0x0C | (d << 8) for d in (30, 33)], 0),
    'fifodma': ([v << 16 | 20 << 8 | n for v in (0, 1) for n in range(10, 31)]
                + [33 << 8 | n for n in range(20, 44)], 0),
    'dmasteal': (dmasteal_args(), 0),
    'timergeo': ([0 | 100 << 8] + [1 | line << 8 for line in range(100, 108)]
                 + [1 | 103 << 8 | e << 16 for e in range(0, 64, 4)], 0),
    'halthb': ([0], 15),
    'vdmageo': ([0], 15),
    'haltprobe': ([0, 1], 3),
    'vbwait': ([0, 0x100], 18),
    'psgfirst': ([0], 8),
}


def run_cell(code, arg, words, tries=4):
    from monitor import Monitor
    for attempt in range(tries):           # the adapter drops a word now and then
        try:
            with Monitor() as m:
                m.ping()
                r0 = m.run_payload(code, arg)
                mem = m.read_mem(0x02008000, words) if words else []
                if words and mem != m.read_mem(0x02008000, words):
                    raise IOError('the result block read back two ways')
                return ' '.join(f'{w:08X}' for w in [r0] + list(mem))
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(1.5)


def record(name, runs=3):
    from monitor import assemble
    args, words = FAMILIES[name]
    code = assemble(src(name), out_dir=os.path.join(HWLINK, '.payloadcmp'))
    seen = {a: {} for a in args}
    for _ in range(runs):                  # interleaved passes: drift shows as disagreement
        for a in args:
            t = run_cell(code, a, words)
            seen[a][t] = seen[a].get(t, 0) + 1
    for a in args:
        extra = 0
        while len(seen[a]) > 1 and extra < 6:
            t = run_cell(code, a, words)
            seen[a][t] = seen[a].get(t, 0) + 1
            extra += 1
        if len(seen[a]) > 1:
            print(f'  {name} {a:#x}: ' + ', '.join(f'{t} x{n}' for t, n in seen[a].items()),
                  file=sys.stderr, flush=True)
    return {f'{a:#x}': ' | '.join(sorted(seen[a])) for a in args}


def main(argv):
    names = [a for a in argv[1:] if not a.startswith('--')]
    table = json.load(open(TABLE_FILE)) if os.path.exists(TABLE_FILE) else {}
    if '--show' in argv:
        for name, cells in table.items():
            for a, t in cells.items():
                print(f'{name:10} {a:>10}  {t}')
        return 0
    for name in names or list(FAMILIES):
        table[name] = record(name)
        print(name, 'recorded', len(table[name]), 'cells', flush=True)
        json.dump(table, open(TABLE_FILE, 'w'), indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
