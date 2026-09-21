"""The recorded console tables, as one list of rows.

breakram-agb.json and r0-agb.json are what an AGB SP answered; breakram.py
and r0table.py record them. This module is what everything downstream reads
them through -- `--check`, tools/knobsweep.py, and tools/hwlink/lawrom.py,
which freezes them into the ROMs `nimble test_cyclelaws` runs without a
console or a cross-assembler.

A Row is one payload under one mode over a list of arguments; a cell's id is
`<row name> <argument label>`.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp

EMULATORS = ('dingbat', 'dingbat-bios', 'mgba')
BREAKRAM_FILE = os.path.join(HERE, 'breakram-agb.json')
R0_FILE = os.path.join(HERE, 'r0-agb.json')


def source(name):
    return os.path.join(payloadcmp.ROMS, 'payloads', name + '.s')


class Row:
    def __init__(self, payload, name, args, labels, show, want):
        self.payload = payload          # 'breakram', 'dmaphase', ...
        self.name = name                # 'breakram --stamp', 'dmaphase'
        self.args = args                # the words the payload is called with
        self.labels = labels            # how the table names each: '3', '0x10'
        self.show = show                # word -> the cell's text
        self.want = want                # the console's text per argument

    def cell_ids(self):
        return [f'{self.name} {label}' for label in self.labels]


def rows(only=None):
    """Every recorded row; `only` filters by payload name."""
    import breakram
    out = []
    if os.path.exists(BREAKRAM_FILE):
        for flags, cells in json.load(open(BREAKRAM_FILE)).items():
            mode = breakram.mode_of(flags.split())
            ks = [int(k) for k in cells]
            out.append(Row('breakram', ('breakram ' + flags).strip(),
                           [mode | k for k in ks], [str(k) for k in ks],
                           (lambda v, mode=mode: breakram.show(v, mode)),
                           [cells[str(k)] for k in ks]))
    if os.path.exists(R0_FILE):
        for name, cells in json.load(open(R0_FILE)).items():
            out.append(Row(name, name, [int(a, 0) for a in cells], list(cells),
                           (lambda v: f'{v:08X}'), list(cells.values())))
    return [r for r in out if not only or r.payload in only]


def by_payload(rs):
    groups = {}
    for r in rs:
        groups.setdefault(r.payload, []).append(r)
    return groups


def frames_for(count):
    return 60 + 8 * count


def in_emulators(rs, names=EMULATORS):
    """{emulator: {cell id: text}} for the rows given. One ROM and one boot
    per payload: every page parks itself on a line before it measures, so a
    cell does not care what ran before it (lawrom.py checks that it is so)."""
    got = {n: {} for n in names}
    for payload, group in by_payload(rs).items():
        args = [a for r in group for a in r.args]
        rom = payloadcmp.build_wrapper(source(payload), args)
        words = payloadcmp.in_emulators(rom, len(args), names=names, frames=frames_for(len(args)))
        for n in names:
            i = 0
            for r in group:
                for cid, _ in zip(r.cell_ids(), r.args):
                    got[n][cid] = r.show(words[n][i])
                    i += 1
    return got


def wanted(rs):
    return {cid: w for r in rs for cid, w in zip(r.cell_ids(), r.want)}


def check(rs, names=EMULATORS, quiet=('mgba',)):
    """Print each emulator's score against the console; return the mismatching
    cell ids per emulator."""
    want = wanted(rs)
    got = in_emulators(rs, names)
    wrong = {n: [c for c in want if got[n][c] != want[c]] for n in names}
    for n in names:
        if n in quiet:
            continue
        for c in wrong[n]:
            print(f'  {n:<13}{c:<48} {got[n][c]}  (console {want[c]})')
    for n in names:
        print(f'{n:<13} {len(want) - len(wrong[n])}/{len(want)} cells match the console')
    return wrong
