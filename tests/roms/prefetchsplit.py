#!/usr/bin/env python3
"""Builds and reads prefetchsplit.gba (prefetchsplit.s says what each case
measures and what each rule predicts).

    python3 prefetchsplit.py                build
    python3 prefetchsplit.py run            build, run it in dingbat
                                            (../../dingbat_test) and print
    python3 prefetchsplit.py decode FILE    decode a .sav off the flashcart

A flashcart ROM: every case runs from the gamepak with the prefetcher on,
which the link rig cannot reach.

Requires arm-none-eabi-{as,ld,objcopy} and gbafix, like the other ROMs here.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

WORDS = 17
MARKER = 0x600D0003
NAMES = ['A1 ARM bx -> Thumb, target = head', 'A2 ... target = head + 4',
         'A3 ARM bx -> ARM, target = head', 'A4 ... target = head + 4',
         'B1 misaligned: 1st I/O load', 'B1 2nd I/O load', 'B1 PC & 3',
         'B2 aligned: 1st I/O load', 'B2 2nd I/O load', 'B2 PC & 3',
         'C1 bounday_test_1 across 0x08020000', 'C2 ... across nothing',
         'C3 ARM nops across 0x08040000, pf on', 'C4 ... across nothing',
         'C5 ARM nops across 0x08040000, pf off', 'C6 ... across nothing']


def build():
    obj = os.path.join(HERE, 'prefetchsplit.o')
    elf = os.path.join(HERE, 'prefetchsplit.elf')
    out = os.path.join(HERE, 'prefetchsplit.gba')
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', HERE,
                    '-o', obj, os.path.join(HERE, 'prefetchsplit.s')],
                   check=True)
    subprocess.run(['arm-none-eabi-ld', '-Ttext=0x08000000', '-o', elf, obj],
                   check=True)
    subprocess.run(['arm-none-eabi-objcopy', '-O', 'binary', elf, out],
                   check=True)
    data = bytearray(open(out, 'rb').read())
    data[0xA0:0xAC] = b'PFSPLIT\0\0\0\0\0'
    data[0xAC:0xB0] = b'APFE'
    data[0xB0:0xB2] = b'01'
    data[0xB2] = 0x96
    data[0xBD] = (-(sum(data[0xA0:0xBD]) + 0x19)) & 0xFF
    while len(data) % 16:
        data.append(0)
    open(out, 'wb').write(bytes(data))
    romfix.gba_logo(out)
    for scratch in (obj, elf):
        os.remove(scratch)
    print(f'{out} {len(data)} bytes')
    return out


def table(named):
    names = list(named)
    print(f'{"case":42}' + ''.join(f'{n:>12}' for n in names))
    for i, label in enumerate(NAMES):
        row = [named[n][i] for n in names]
        print(f'{label:42}' + ''.join(f'{v:12}' for v in row))
    print('\ndifferences -- the rules predict A 2 2, B 4 (PC&3 2/0), C1-C2 8;'
          '\nGBATEK predicts C3-C4 = C5-C6 = 2, which dingbat does not model:')
    for n in names:
        w = named[n]
        print(f'  {n}: A2-A1 {w[1] - w[0]}  A4-A3 {w[3] - w[2]}  '
              f'B {(w[5] - w[4]) - (w[8] - w[7])} (PC&3 {w[6]}/{w[9]})  '
              f'C1-C2 {w[10] - w[11]}  C3-C4 {w[12] - w[13]}  '
              f'C5-C6 {w[14] - w[15]}')


def words_of(data):
    return [int.from_bytes(data[i * 4:i * 4 + 4], 'little')
            for i in range(WORDS)]


def run(rom):
    """dingbat's reading: the SRAM copy lands in the harness's .sav."""
    sav = os.path.splitext(rom)[0] + '.sav'
    if os.path.exists(sav):
        os.remove(sav)
    subprocess.run([os.path.join(REPO, 'dingbat_test'), rom, '--mode=screenshot',
                    '--timeout=30', '--screenshot=/dev/null'],
                   capture_output=True)
    if not os.path.exists(sav):
        sys.exit('dingbat wrote no .sav')
    data = open(sav, 'rb').read()
    os.remove(sav)
    w = words_of(data)
    if w[-1] != MARKER:
        print(f'no end marker (last word {w[-1]:08X}): not a finished run')
    table({'dingbat': w})


def decode(path):
    w = words_of(open(path, 'rb').read())
    if w[-1] != MARKER:
        print(f'no end marker in {path}: not a finished run')
    table({'hardware': w})


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'decode':
        decode(sys.argv[2])
    else:
        path = build()
        if len(sys.argv) > 1 and sys.argv[1] == 'run':
            run(path)
