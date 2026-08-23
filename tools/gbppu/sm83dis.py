#!/usr/bin/env python3
"""Minimal SM83 disassembler, enough to read a gambatte test ROM's main body.

    tools/gbppu/sm83dis.py <rom> [start_hex] [len]

Enough for the straight-line preambles of the speed-switch / lcd_offset ROMs;
no coverage of illegal opcodes.
"""
import sys

R = ["b", "c", "d", "e", "h", "l", "(hl)", "a"]
RP = ["bc", "de", "hl", "sp"]
RP2 = ["bc", "de", "hl", "af"]
CC = ["nz", "z", "nc", "c"]
ALU = ["add a,", "adc a,", "sub", "sbc a,", "and", "xor", "or", "cp"]
CBOPS = ["rlc", "rrc", "rl", "rr", "sla", "sra", "swap", "srl"]


def dis(b, pc):
    """Return (text, length) for the instruction at b[pc]."""
    o = b[pc]
    d8 = lambda: b[pc + 1]
    d16 = lambda: b[pc + 1] | (b[pc + 2] << 8)
    s8 = lambda: b[pc + 1] - 256 if b[pc + 1] > 127 else b[pc + 1]
    x, y, z = o >> 6, (o >> 3) & 7, o & 7
    if o == 0x00: return "nop", 1
    if o == 0x10: return "STOP", 2
    if o == 0x76: return "halt", 1
    if o == 0xCB:
        c = b[pc + 1]
        cx, cy, cz = c >> 6, (c >> 3) & 7, c & 7
        if cx == 0: return "%s %s" % (CBOPS[cy], R[cz]), 2
        return "%s %d,%s" % (["", "bit", "res", "set"][cx], cy, R[cz]), 2
    if x == 1: return "ld %s,%s" % (R[y], R[z]), 1
    if x == 2: return "%s %s" % (ALU[y], R[z]), 1
    if x == 0:
        if z == 0:
            if o == 0x08: return "ld ($%04x),sp" % d16(), 3
            if o == 0x18: return "jr $%04x" % (pc + 2 + s8()), 2
            return "jr %s,$%04x" % (CC[y - 4], pc + 2 + s8()), 2
        if z == 1:
            if y & 1: return "add hl,%s" % RP[y >> 1], 1
            return "ld %s,$%04x" % (RP[y >> 1], d16()), 3
        if z == 2:
            tgt = ["(bc)", "(de)", "(hl+)", "(hl-)"][y >> 1]
            return ("ld a,%s" % tgt if y & 1 else "ld %s,a" % tgt), 1
        if z == 3: return "%s %s" % ("dec" if y & 1 else "inc", RP[y >> 1]), 1
        if z == 4: return "inc %s" % R[y], 1
        if z == 5: return "dec %s" % R[y], 1
        if z == 6: return "ld %s,$%02x" % (R[y], d8()), 2
        return ["rlca", "rrca", "rla", "rra", "daa", "cpl", "scf", "ccf"][y], 1
    # x == 3
    if o == 0xE0: return "ldh ($ff%02x),a" % d8(), 2
    if o == 0xF0: return "ldh a,($ff%02x)" % d8(), 2
    if o == 0xE2: return "ldh (c),a", 1
    if o == 0xF2: return "ldh a,(c)", 1
    if o == 0xEA: return "ld ($%04x),a" % d16(), 3
    if o == 0xFA: return "ld a,($%04x)" % d16(), 3
    if o == 0xE8: return "add sp,%d" % s8(), 2
    if o == 0xF8: return "ld hl,sp%+d" % s8(), 2
    if o == 0xF9: return "ld sp,hl", 1
    if o == 0xE9: return "jp hl", 1
    if o == 0xC3: return "jp $%04x" % d16(), 3
    if o == 0xCD: return "call $%04x" % d16(), 3
    if o == 0xC9: return "ret", 1
    if o == 0xD9: return "reti", 1
    if o == 0xF3: return "di", 1
    if o == 0xFB: return "ei", 1
    if z == 0 and y < 4: return "ret %s" % CC[y], 1
    if z == 2 and y < 4: return "jp %s,$%04x" % (CC[y], d16()), 3
    if z == 4 and y < 4: return "call %s,$%04x" % (CC[y], d16()), 3
    if z == 1 and not (y & 1): return "pop %s" % RP2[y >> 1], 1
    if z == 5 and not (y & 1): return "push %s" % RP2[y >> 1], 1
    if z == 6: return "%s $%02x" % (ALU[y], d8()), 2
    if z == 7: return "rst $%02x" % (y * 8), 1
    return "db $%02x" % o, 1


def main():
    b = open(sys.argv[1], "rb").read()
    pc = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x150
    end = pc + (int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x80)
    while pc < min(end, len(b)):
        t, n = dis(b, pc)
        print("%04x  %-14s %s" % (pc, " ".join("%02x" % c for c in b[pc:pc + n]), t))
        pc += n


if __name__ == "__main__":
    main()
