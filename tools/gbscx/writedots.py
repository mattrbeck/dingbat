#!/usr/bin/env python3
"""Turn a scx_during_m3 STAT handler into the M-cycle of each SCX write.

The family is one ROM with the writes moved, so the only thing that separates
its members is WHEN each `LD (C),A` retires. Counting that from the bytes is
exact and needs no emulator: the handler is straight-line, `LD (C),A` is 2
M-cycles, `LD A,d8` is 2, `POP HL` is 3 and `NOP` is 1, and the count starts
from the first M-cycle of the handler at $1000.

    tools/gbscx/writedots.py <dir>              # every ROM in one directory

The printed M-cycle is "M-cycles from the top of $1000 to the END of the write",
which is the cycle the store becomes visible to the PPU.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from disasm import decode  # noqa: E402

# M-cycles per opcode, for the handful the handlers use.
MC = {0x00: 1, 0xE2: 2, 0x3E: 2, 0xE1: 3, 0xC3: 4, 0xC9: 4, 0xD9: 4,
      0xFB: 1, 0x18: 3, 0x00 | 0: 1}


def writes(path, limit=0x400):
    rom = open(path, 'rb').read()
    pc = 0x1000
    t = 0
    out = []
    while pc < 0x1000 + limit:
        op = rom[pc]
        ln, txt = decode(rom, pc)
        if op not in MC:
            break
        t += MC[op]
        if op == 0xE2:                     # LD (C),A -- C is rSCX throughout
            out.append(t)
        if op in (0xC9, 0xD9, 0xC3, 0x18):
            break
        pc += ln
    return out


def main():
    d = sys.argv[1]
    roms = sorted(f for f in os.listdir(d) if f.endswith(('.gb', '.gbc')))
    for f in roms:
        w = writes(os.path.join(d, f))
        print('%-34s %s' % (f, ' '.join('%d' % v for v in w[:4])))


if __name__ == '__main__':
    main()
