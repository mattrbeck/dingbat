"""Build the core with a constant changed and show exactly what moves.

    python3 tools/knobsweep.py IRQ_ENTRY_EXTRA=1,2
    python3 tools/knobsweep.py DMA_LEAD_CYCLES=0,1,2 --suite
    python3 tools/knobsweep.py TIMER_STOP_DELAY=0 IRQ_ENTRY_EXTRA=2 --grid --suite
    python3 tools/knobsweep.py -d:obuslatchdbg --tables=breakram

Every `{.intdefine.}` / `{.booldefine.}` constant in src/ is a knob. Each
variant is built beside an untouched base build (nothing in
tools/playtest/bin or the repo root is swapped), then run through

  * the recorded console tables (tools/hwlink/tables.py), always;
  * the mGBA suite under the HLE and the real BIOS, with --suite.

and the report is the DIFFERENCE from base: which console cells a value
gains or loses, which suite rows flip. That is what a knob is for -- to learn
what a constant touches and whether a model's structure is right. A value
that turns a row green is not a measurement (docs/cycle-hunt-method.md): when
a change the console measured breaks many passing rows by the same amount,
the partner error is in what those rows share, and this report is how to see
what they share.

Without --grid the variants are one knob at a time; with it, the product.
"""
import itertools
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(HERE, '.knobsweep')
sys.path.insert(0, os.path.join(HERE, 'hwlink'))

SUITE_ROM = os.environ.get('KNOBSWEEP_SUITE_ROM', '/tmp/dingbat-test-roms/mgba-suite.gba')
BIOS = os.path.expanduser(os.environ.get('PLAYTEST_BIOS', '~/code/dingbat/tests/roms/gba_bios.bin'))

TARGETS = (('driver', 'tools/playtest/drivers/dingbat_driver.nim'),
           ('dingbat_test', 'tests/dingbat_test.nim'))


def tag_of(defines):
    return '_'.join(d.replace('-d:', '').replace('=', '-') for d in defines) or 'base'


def build(defines, want_suite):
    tag = tag_of(defines)
    where = os.path.join(OUT, tag)
    os.makedirs(where, exist_ok=True)
    for name, src in TARGETS:
        if name == 'dingbat_test' and not want_suite:
            continue
        cmd = ['nim', 'c', '-d:test_harness', '-d:release', '--path:src', '--hints:off',
               '--warnings:off', *defines, f'--nimcache:{where}/nimcache_{name}',
               f'-o:{where}/{name}', src]
        r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f'{tag}: {name} did not build\n{r.stdout[-2000:]}{r.stderr[-2000:]}')
    return tag


def table_cells(tag, rows):
    import tables
    os.environ['PLAYTEST_DINGBAT_DRIVER'] = os.path.join(OUT, tag, 'driver')
    try:
        got = tables.in_emulators(rows, names=('dingbat', 'dingbat-bios'))
    finally:
        del os.environ['PLAYTEST_DINGBAT_DRIVER']
    return {f'{emu}: {cid}': text for emu, cells in got.items() for cid, text in cells.items()}


def suite_rows(tag):
    """{'hle: Section / row #n': 'PASS' | 'FAIL ...'}"""
    out = {}
    for label, extra in (('hle', []), ('bios', [f'--bios={BIOS}'])):
        if extra and not os.path.exists(BIOS):
            continue
        r = subprocess.run([os.path.join(OUT, tag, 'dingbat_test'), SUITE_ROM, '--mode=mgba-suite',
                            '--timeout=36000', *extra], capture_output=True, cwd=os.path.join(OUT, tag))
        section, seen, last = '?', {}, None
        for line in r.stdout.decode('latin-1').splitlines():
            line = line.strip()
            if line.startswith('BEGIN: '):
                section = line[7:]
            elif line.startswith(('PASS: ', 'FAIL: ')):
                name = line[6:]
                seen[(section, name)] = n = seen.get((section, name), 0) + 1
                last = f'{label}: {section} / {name}' + (f' #{n}' if n > 1 else '')
                out[last] = line[:4]
            elif last and line.endswith(': FAIL') and ' Got ' in line:
                # "DMA0 16: Got 0x00001DB2 vs 0x0000FACE: FAIL"
                out[last] = 'FAIL ' + line[line.index('Got '):-6]
    return out


def delta(status, section=''):
    """'FAIL Got 805D vs 805C' -> 'FAIL by +1'. The suite prints hex with or
    without 0x, and its Misc source alone passes (expected, value)."""
    words = status.split()
    try:
        d = int(words[2], 16) - int(words[4], 16)
        return f'FAIL by {-d if section.startswith("Misc") else d:+d}'
    except (IndexError, ValueError):
        return status


def main(argv):
    flags = [a for a in argv[1:] if a.startswith('--')]
    raw = [a for a in argv[1:] if a.startswith('-d:')]
    knobs = [a for a in argv[1:] if '=' in a and not a.startswith('-')]
    want_suite = '--suite' in flags
    only = next((f.split('=')[1].split(',') for f in flags if f.startswith('--tables=')), None)
    if not knobs and not raw:
        print(__doc__)
        return 2
    if want_suite and not os.path.exists(SUITE_ROM):
        sys.exit(f'no suite ROM at {SUITE_ROM} (run ./dingbat_test_runner once, or set KNOBSWEEP_SUITE_ROM)')

    axes = [[f'-d:{k}={v}' for v in vs.split(',')] for k, vs in (kn.split('=') for kn in knobs)]
    if '--grid' in flags:
        variants = [list(combo) + raw for combo in itertools.product(*axes)]
    else:
        variants = [[d] + raw for axis in axes for d in axis] or [raw]
    variants = [[]] + variants

    print(f'building {len(variants)} variants ...', flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        tags = list(pool.map(lambda d: build(d, want_suite), variants))

    import tables
    rows = tables.rows(only=only)
    want = {f'{emu}: {cid}': w for emu in ('dingbat', 'dingbat-bios')
            for cid, w in tables.wanted(rows).items()}
    results = {}
    for tag in tags:
        print(f'running {tag} ...', flush=True)
        results[tag] = (table_cells(tag, rows), suite_rows(tag) if want_suite else {})

    base_cells, base_suite = results['base']
    good = lambda cells: sum(cells[c] == want[c] for c in want)
    print(f'\nbase: console cells {good(base_cells)}/{len(want)}'
          + (f', suite FAIL {sum(v != "PASS" for v in base_suite.values())}/{len(base_suite)}' if want_suite else ''))
    for tag in tags[1:]:
        cells, suite = results[tag]
        moved = [c for c in want if cells[c] != base_cells[c]]
        gained = [c for c in moved if cells[c] == want[c]]
        lost = [c for c in moved if base_cells[c] == want[c]]
        print(f'\n=== {tag}: console cells {good(cells)}/{len(want)} '
              f'({len(moved)} moved: +{len(gained)} -{len(lost)})')
        for c in moved:
            mark = '+' if c in gained else '-' if c in lost else ' '
            print(f'  {mark} {c:<58} {base_cells[c]:>14} -> {cells[c]:<14} console {want[c]}')
        if want_suite:
            flips = [r for r in base_suite if suite.get(r) != base_suite[r]]
            fails = sum(v != 'PASS' for v in suite.values())
            print(f'  suite FAIL {fails}/{len(suite)} ({len(flips)} rows flipped)')
            # grouped by section and by HOW they moved: a uniform delta across
            # many rows is one cause, and what the rows share names it
            groups = {}
            for r in flips:
                groups.setdefault((r.split(' / ')[0], delta(suite.get(r, '?'), r.split(': ', 1)[1])), []).append(r.split(' / ', 1)[1])
            for (section, how), names in sorted(groups.items()):
                shown = ', '.join(names[:5]) + (f', ... {len(names) - 5} more' if len(names) > 5 else '')
                print(f'    {section}: {len(names)} rows now {how}: {shown}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
