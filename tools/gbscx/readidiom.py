#!/usr/bin/env python3
"""Find every instruction in a ROM that reads $FF41 (STAT), and say WHICH IDIOM.

Round 4's question is whether the three suites that disagree about the STAT mode
field read it with different instructions. The four forms differ in machine
length and in which M-cycle performs the IO read, so if hardware's field report
has any per-instruction structure this is where it would show:

    LDH A,($41)     F0 41       2 bytes, 3 M-cycles, read on M3
    LD  A,($FF41)   FA 41 FF    3 bytes, 4 M-cycles, read on M4
    LD  A,(C)       F2          1 byte,  2 M-cycles, read on M2   (C = $41)
    LD  A,(HL)      7E          1 byte,  2 M-cycles, read on M2   (HL = $FF41)
    BIT n,(HL)      CB 4x       2 bytes, 3 M-cycles, read on M3

    tools/gbscx/readidiom.py <rom>...

`LD A,(C)`, `LD A,(HL)` and `BIT n,(HL)` are only reported when a nearby
instruction can be seen loading the register pair with $FF41 / $41, since those
opcodes are common on any other address.
"""
import sys
import os


def scan(path):
    m = open(path, 'rb').read()
    hits = []
    # Track the last few loads of C and HL so the register-indirect forms can be
    # attributed to $FF41 rather than reported for every LD A,(HL) in the ROM.
    c_is_41 = hl_is_ff41 = False
    i = 0
    while i < len(m):
        op = m[i]
        if op == 0x0E:                                   # LD C,d8
            c_is_41 = (i + 1 < len(m) and m[i + 1] == 0x41); i += 2; continue
        if op == 0x21:                                   # LD HL,d16
            hl_is_ff41 = (i + 2 < len(m) and m[i + 1] == 0x41
                          and m[i + 2] == 0xFF); i += 3; continue
        if op == 0xF0 and i + 1 < len(m) and m[i + 1] == 0x41:
            hits.append((i, 'LDH A,($41)', 3, 3)); i += 2; continue
        if op == 0xFA and i + 2 < len(m) and m[i + 1] == 0x41 and m[i + 2] == 0xFF:
            hits.append((i, 'LD A,($FF41)', 4, 4)); i += 3; continue
        if op == 0xF2 and c_is_41:
            hits.append((i, 'LD A,(C)', 2, 2)); i += 1; continue
        if op == 0x7E and hl_is_ff41:
            hits.append((i, 'LD A,(HL)', 2, 2)); i += 1; continue
        if op == 0xCB and i + 1 < len(m) and 0x40 <= m[i + 1] < 0x80 \
           and (m[i + 1] & 7) == 6 and hl_is_ff41:
            hits.append((i, 'BIT %d,(HL)' % ((m[i + 1] >> 3) & 7), 3, 3))
            i += 2; continue
        i += 1
    return hits


def main():
    for p in sys.argv[1:]:
        hits = scan(p)
        forms = sorted({h[1] for h in hits})
        print('%-46s %s' % (os.path.basename(p),
                            ', '.join(forms) if forms else '(no direct STAT read found)'))
        for off, form, mc, rd in hits[:6]:
            print('      $%04X  %-14s %d M-cycles, IO read on M%d' % (off, form, mc, rd))


if __name__ == '__main__':
    main()
