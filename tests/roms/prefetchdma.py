#!/usr/bin/env python3
"""Builds and reads prefetchdma.gba (prefetchdma.s says what it measures).

    python3 prefetchdma.py                build
    python3 prefetchdma.py compare        build, then run it in every emulator
                                          the playtest harness knows and print
                                          the three tables side by side
    python3 prefetchdma.py decode FILE    decode a raw 676-byte block: either a
                                          .sav off the flashcart or a dump from
                                          `python3 tools/hwlink/gblink.py report`

This is a flashcart ROM. Everything it measures needs code running from the
cartridge, which is precisely what the link rig -- a multiboot payload in
EWRAM, empty cart slot -- cannot reach. Hardware numbers still come back over
the link cable, though: the ROM streams its result block down SIO, so a
console running this from a cart with the adapter attached reports exactly.

Requires arm-none-eabi-{as,ld,objcopy}, like the other ROMs here.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

RESULTS = 0x02000000
WORDS = 393
MARKER = 0x600D0002

ITERS = 512
A_SUBJECTS = ['ROM  ldr[0x10000000]+ loop', 'ROM  ldr[IWRAM] loop',
              'ROM  no-load loop', 'IWRAM ldr[0x10000000]+ loop']
A_WAITS = ['3/1 pf-ON', '3/1 pf-off', '4/2 pf-ON', '4/2 pf-off']
B_CONFIGS = ['ROM code, pf-ON', 'ROM code, 4/2 pf-off (the suite)',
             'IWRAM code, pf-ON', 'IWRAM code, 4/2 pf-off']
B_COUNTS = [0, 1, 2, 4, 8, 16, 32]
C_CONFIGS = ['ROM code, 4/2 pf-off (the suite)', 'ROM code, 3/1 pf-ON',
             'IWRAM code, 4/2 pf-off']
C_SLEDS = 32
DMA_WORD = 0xDEAD0000
D_TRIALS = 16
C_BASE = 72
C_STRIDE = 3
D_BASE = C_BASE + len(C_CONFIGS) * C_SLEDS * C_STRIDE


def build():
    obj = os.path.join(HERE, 'prefetchdma.o')
    elf = os.path.join(HERE, 'prefetchdma.elf')
    out = os.path.join(HERE, 'prefetchdma.gba')
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-I', HERE,
                    '-o', obj, os.path.join(HERE, 'prefetchdma.s')], check=True)
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


def tables(named):
    """named: {label: [169 words]} -- print the three parts side by side."""
    names = list(named)
    head = ''.join(f'{n:>14}' for n in names)

    print('\nA. loop period, cycles for %d iterations (and per iteration)'
          % ITERS)
    print(f'{"subject":30}{"waits":12}{head}')
    for s, subject in enumerate(A_SUBJECTS):
        for w, wait in enumerate(A_WAITS):
            row = [named[n][s * 4 + w] for n in names]
            cells = ''.join(f'{v:8}{v / ITERS:6.2f}' for v in row)
            mark = '  <<<' if len(set(row)) > 1 else ''
            print(f'{subject:30}{wait:12}{cells}{mark}')

    print('\nB. what an H-blank DMA costs the loop: cycles, lines crossed,')
    print('   and the per-line cost against the same config with no DMA')
    print(f'{"config":22}{"N":>4}{head}')
    for c, config in enumerate(B_CONFIGS):
        base = {}
        for i, n in enumerate(B_COUNTS):
            off = 16 + (c * 7 + i) * 2
            row = [(named[k][off], named[k][off + 1]) for k in names]
            if n == 0:
                base = {k: named[k][off] for k in names}
                cells = ''.join(f'{cy:9}/{ln:<4}' for cy, ln in row)
                print(f'{config:22}{n:>4}{cells}   (baseline)')
                continue
            cells = ''
            for k, (cy, ln) in zip(names, row):
                per = (cy - base[k]) / ln if ln else float('nan')
                cells += f'{cy:9}/{ln:<4}'
            print(f'{config:22}{n:>4}{cells}')
            per = []
            for k, (cy, ln) in zip(names, row):
                per.append(f'{(cy - base[k]) / ln:13.2f}' if ln else
                           f'{"?":>13}')
            print(f'{"":22}{"":>4}' + ''.join(per) + '   per line')

    print('\nC. the post-DMA open-bus window, scanned a cycle at a time.')
    print('   Each cell is the cycle of the read and what it returned;')
    print('   %08X is the DMA\'s word, anything else is the opcode bus.'
          % DMA_WORD)
    for c, config in enumerate(C_CONFIGS):
        print(f'  {config}')
        for k in names:
            hits, span = [], []
            for sled in range(C_SLEDS):
                i = C_BASE + (c * C_SLEDS + sled) * C_STRIDE
                cyc, val = named[k][i], named[k][i + 1]
                nxt = named[k][i + 2]
                if nxt == DMA_WORD and val != DMA_WORD:
                    hits.append((sled, cyc))
                    span.append(cyc)
                    continue
                span.append(cyc)
                if val == DMA_WORD:
                    hits.append((sled, cyc))
            other = {named[k][C_BASE + (c * C_SLEDS + s) * C_STRIDE + j]
                     for s in range(C_SLEDS) for j in (1, 2)} - {DMA_WORD}
            where = (f'sleds {hits[0][0]}..{hits[-1][0]} '
                     f'(cycles {hits[0][1]}..{hits[-1][1]}), '
                     f'{len(hits)} of {C_SLEDS}') if hits else 'NEVER'
            print(f'    {k:>12}  window: {where}')
            print(f'    {"":>12}  scan spans cycles {min(span)}..{max(span)}; '
                  f'otherwise {" ".join(f"{v:08X}" for v in sorted(other))}')

    print('\nD. the suite\'s own loop and DMA, replicated in ROM: the break')
    print('   address at 16 entry phases (it is NOT expected to be 0x10002A94')
    print('   -- that constant is specific to the suite build\'s addresses)')
    print(f'{"phase":>7}' + ''.join(f'{n:>22}' for n in names))
    for t in range(D_TRIALS):
        i = D_BASE + t * 2
        cells = ''.join(f'{named[n][i]:>12X}{named[n][i + 1]:>10X}'
                        for n in names)
        print(f'{t:>7}{cells}')
    for n in names:
        vals = {named[n][D_BASE + t * 2] for t in range(D_TRIALS)}
        print(f'  {n}: {len(vals)} distinct break address(es) across the 16 '
              f'entry phases' + ('  <-- stable' if len(vals) == 1 else
                                 '  <-- SCATTERS'))


def compare(rom, names=('dingbat', 'mgba')):
    sys.path.insert(0, os.path.join(REPO, 'tools', 'playtest'))
    import emu as emulib
    scratch = os.path.join(HERE, '.prefetchdma-run')
    got = {}
    for name in names:
        e = emulib.Emulator(name, rom, os.path.join(scratch, name))
        e.run(400)
        raw = e.cmd(f'peek {RESULTS:08X} {WORDS * 4}').strip()
        words = [int.from_bytes(bytes.fromhex(raw[i * 8:i * 8 + 8]), 'little')
                 for i in range(WORDS)]
        e.kill()
        if words[-1] != MARKER:
            print(f'{name}: never reached the end marker '
                  f'(last word {words[-1]:08X}) -- numbers below are garbage')
        got[name] = words
    tables(got)
    return got


def decode(path):
    data = open(path, 'rb').read()
    words = [int.from_bytes(data[i * 4:i * 4 + 4], 'little')
             for i in range(WORDS)]
    if words[-1] != MARKER:
        # A .sav may be padded, or the block may sit at an offset in it.
        for start in range(0, max(1, len(data) - WORDS * 4), 4):
            cand = [int.from_bytes(data[start + i * 4:start + i * 4 + 4],
                                   'little') for i in range(WORDS)]
            if cand and cand[-1] == MARKER:
                words = cand
                print(f'found the block at offset {start}')
                break
        else:
            print(f'no end marker anywhere in {path}: not a finished run')
    tables({'hardware': words})


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'decode':
        decode(sys.argv[2])
    else:
        path = build()
        if len(sys.argv) > 1 and sys.argv[1] == 'compare':
            compare(path)
