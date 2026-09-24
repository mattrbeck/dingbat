"""Freeze the recorded console tables into ROMs a test can run anywhere.

    python3 lawrom.py            # rebuild tests/roms/cyclelaws/
    python3 lawrom.py --verify   # are the committed ROMs what the sources build?

`breakram.py --check` and `r0table.py --check` need a cross-assembler and the
playtest drivers, so they only ever ran when somebody thought to. This writes
one cartridge ROM per payload -- the payload, every recorded argument, and
tests/roms/payloadrun.s around them -- plus laws.json: each cell's id, how to
read its word, and what the AGB SP answered. tests/cyclelaws_test.nim
(`nimble test_cyclelaws`, in CI) boots each ROM in the core and compares.
A change that passes the mGBA suite by moving a cycle the console has
measured fails there.

Re-run after recording a table or editing a recorded payload; the ROMs and
laws.json are committed (they are our own code, a few KB each).

A cell the HLE cannot match by construction is listed in HLE_EXCEPTIONS with
the reason and pinned to what the HLE does answer; under the real BIOS it is
held to the console like any other.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp
import tables

OUT = os.path.join(payloadcmp.ROMS, 'cyclelaws')

# Cells the HLE BIOS may answer differently, {id: (hle_want, why)}. Empty
# since the HLE's Halt parks in its stub BIOS (hle_bios.hle_halt): wakeirq
# 0x0's return address used to be the one exception.
HLE_EXCEPTIONS = {}


def kind_of(row, arg):
    if row.payload != 'breakram':
        return 'hex'
    return 'edge' if arg >> 24 else 'stamp' if arg & 0x200 else 'loop'


def build():
    """[(payload, ROM bytes, its laws.json entry)]"""
    out = []
    for payload, group in tables.by_payload(tables.rows()).items():
        args = [a for r in group for a in r.args]
        data = bytearray(open(payloadcmp.build_wrapper(tables.source(payload), args), 'rb').read())
        # build_wrapper stamps the header logo so a console or another
        # emulator's BIOS will boot the ROM. That is Nintendo's data and stays
        # out of git; the core boots these past the BIOS and never reads it.
        data[0x04:0xA0] = bytes(0x9C)
        data = bytes(data)
        cells = []
        for r in group:
            for cid, arg, want in zip(r.cell_ids(), r.args, r.want):
                cell = {'id': cid, 'kind': kind_of(r, arg), 'want': want}
                if cid in HLE_EXCEPTIONS:
                    cell['hle_want'], cell['hle_why'] = HLE_EXCEPTIONS[cid]
                cells.append(cell)
        out.append((payload, data, {'payload': payload, 'rom': payload + '.gba',
                                    'sha1': hashlib.sha1(data).hexdigest(),
                                    'frames': tables.frames_for(len(args)), 'cells': cells}))
    return out


def main(argv):
    verify = '--verify' in argv
    os.makedirs(OUT, exist_ok=True)
    built = build()
    stale = []
    for payload, data, _ in built:
        path = os.path.join(OUT, payload + '.gba')
        if not verify:
            open(path, 'wb').write(data)
        elif not os.path.exists(path) or open(path, 'rb').read() != data:
            stale.append(payload + '.gba')
    laws = [entry for _, _, entry in built]
    text = json.dumps(laws, indent=1) + '\n'
    path = os.path.join(OUT, 'laws.json')
    if verify:
        if not os.path.exists(path) or open(path).read() != text:
            stale.append('laws.json')
        print('stale: ' + ', '.join(stale) if stale else 'tests/roms/cyclelaws is current')
        return 1 if stale else 0
    open(path, 'w').write(text)
    print(f'{len(laws)} ROMs, {sum(len(l["cells"]) for l in laws)} cells -> {os.path.relpath(OUT)}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
