#!/usr/bin/env python3
"""Builds and reads prefetchbench.gba (prefetchbench.s says what it times).

    python3 prefetchbench.py             build
    python3 prefetchbench.py compare     build, then run it in every emulator
                                         the playtest harness knows and print
                                         the cycle counts side by side

The ROM times instruction patterns fetched from the cartridge, which is the
one thing the link cable cannot reach: the prefetcher only affects opcodes
fetched from the gamepak, and a multiboot payload runs from RAM. So this is
a flashcart ROM, and `compare` is the emulator half of the same question.

Requires arm-none-eabi-{as,ld,objcopy} and gbafix, like the other ROMs here.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

SUBJECTS = ['arm nops', 'arm loop', 'arm nops+load', 'arm multiplies',
            'thumb nops', 'thumb loop', 'thumb nops+load', 'thumb multiplies']
WAITS = ['3/1 pf-ON', '3/1 pf-off', '4/2 pf-ON', '4/2 pf-off']
RESULTS = 0x02000000
MARKER = 0x02000FFC


def build():
    obj = os.path.join(HERE, 'prefetchbench.o')
    elf = os.path.join(HERE, 'prefetchbench.elf')
    out = os.path.join(HERE, 'prefetchbench.gba')
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-o', obj,
                    os.path.join(HERE, 'prefetchbench.s')], check=True)
    subprocess.run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', elf, obj],
                   check=True)
    subprocess.run(['arm-none-eabi-objcopy', '-O', 'binary', elf, out],
                   check=True)
    data = bytearray(open(out, 'rb').read())
    while len(data) % 16:
        data.append(0)
    open(out, 'wb').write(bytes(data))
    romfix.gba_logo(out)
    for scratch in (obj, elf):
        os.remove(scratch)
    print(f'{out} {len(data)} bytes')
    return out


def compare(rom, names=('dingbat', 'mgba')):
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import emu as emulib
    scratch = os.path.join(HERE, '.prefetchbench-run')
    counts = {}
    for name in names:
        e = emulib.Emulator(name, rom, os.path.join(scratch, name))
        e.run(8)
        if int(e.cmd(f'peek {MARKER:08X} 4').strip()[:8], 16) == 0:
            print(f'{name}: never reached the end marker')
        raw = e.cmd(f'peek {RESULTS:08X} {len(SUBJECTS) * len(WAITS) * 4}').strip()
        counts[name] = [int.from_bytes(bytes.fromhex(raw[i * 8:i * 8 + 8]), 'little')
                        for i in range(len(SUBJECTS) * len(WAITS))]
        e.kill()
    head = ''.join(f'{n:>10}' for n in names)
    print(f'{"subject":20}{"waits":12}{head}   disagree')
    for s, subject in enumerate(SUBJECTS):
        for w, wait in enumerate(WAITS):
            row = [counts[n][s * len(WAITS) + w] for n in names]
            mark = '  <<<' if len(set(row)) > 1 else ''
            print(f'{subject:20}{wait:12}' + ''.join(f'{v:10}' for v in row) + mark)
    return counts


if __name__ == '__main__':
    path = build()
    if len(sys.argv) > 1 and sys.argv[1] == 'compare':
        compare(path)
