#!/usr/bin/env python3
"""Builds and reads ewrombench.gba (ewrombench.s says what it times).

    python3 ewrombench.py                    build (tests/roms/ewrombench.gba)
    python3 ewrombench.py compare [EMU ...]  build, run it in the emulators
                                             (default dingbat mgba nba), print
                                             the cycle counts side by side

A flashcart ROM: the subjects are Thumb code fetched from the cartridge, at
WS0 3/1 and 4/2 with the prefetcher on and off. On the console the result
block streams over the link cable (tests/roms/linkreport.inc):
`python3 tools/hwlink/gblink.py report`. The image is padded with 0xFF to a
power of two (a flashcart that keeps whole blocks only hangs on a straddling
tail otherwise).
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

SUBJECTS = ['A 64 nops', 'B 16 ldr EWRAM', 'C 16 ldr EW+cmp', 'D 16 str EWRAM', 'E 16 ldrh EWRAM',
            'F 16 ldr IWRAM', 'G Banjo x8', 'H 16 ldr EW+3 nop', 'I Banjo x8 IWRAM']
WAITS = ['3/1 pf-ON', '3/1 pf-off', '4/2 pf-ON', '4/2 pf-off']
RESULTS = 0x02000000
MARKER = 0x02000FFC


def build():
    obj = os.path.join(HERE, 'ewrombench.o')
    elf = os.path.join(HERE, 'ewrombench.elf')
    out = os.path.join(HERE, 'ewrombench.gba')
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', HERE, '-o', obj,
                    os.path.join(HERE, 'ewrombench.s')], check=True)
    subprocess.run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', elf, obj], check=True)
    subprocess.run(['arm-none-eabi-objcopy', '-O', 'binary', elf, out], check=True)
    data = bytearray(open(out, 'rb').read())
    size = 1
    while size < len(data):
        size *= 2
    data += b'\xFF' * (size - len(data))
    open(out, 'wb').write(bytes(data))
    romfix.gba_logo(out)
    for scratch in (obj, elf):
        os.remove(scratch)
    print(f'{out} {len(data)} bytes')
    return out


def compare(rom, names=('dingbat', 'mgba', 'nba')):
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import emu as emulib
    scratch = os.path.join(HERE, '.ewrombench-run')
    counts = {}
    n = len(SUBJECTS) * len(WAITS)
    for name in names:
        e = emulib.Emulator(name, rom, os.path.join(scratch, name))
        e.run(8)
        if int(e.cmd(f'peek {MARKER:08X} 4').strip()[:8], 16) == 0:
            print(f'{name}: never reached the end marker')
        raw = e.cmd(f'peek {RESULTS:08X} {n * 4}').strip()
        counts[name] = [int.from_bytes(bytes.fromhex(raw[i * 8:i * 8 + 8]), 'little') for i in range(n)]
        e.kill()
    head = ''.join(f'{x:>10}' for x in names)
    print(f'{"subject":20}{"waits":12}{head}   disagree')
    for s, subject in enumerate(SUBJECTS):
        for w, wait in enumerate(WAITS):
            row = [counts[x][s * len(WAITS) + w] for x in names]
            mark = '  <<<' if len(set(row)) > 1 else ''
            print(f'{subject:20}{wait:12}' + ''.join(f'{v:10}' for v in row) + mark)
    return counts


if __name__ == '__main__':
    path = build()
    if len(sys.argv) > 1 and sys.argv[1] == 'compare':
        compare(path, tuple(sys.argv[2:]) or ('dingbat', 'mgba', 'nba'))
