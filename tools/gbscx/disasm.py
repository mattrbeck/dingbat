#!/usr/bin/env python3
"""A linear SM83 disassembler, written for reading gambatte's test ROMs.

The suites' ROMs are the primary source for every derivation in this tree --
the filename carries the expected value but only the code says what was
measured -- and until now they were read by hand out of a hex dump. This is a
plain linear sweep from a start address, which is all these ROMs need: they are
straight-line NOP slides with no data interleaved in the code.

    tools/gbscx/disasm.py <rom> [start] [count]      # default 0x150, 200 insns

Hardware register addresses in the $FF00-$FF7F page are named, because in this
family "which dot did the ROM write SCX on" is the entire question.
"""
import sys

R8 = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
R16 = ["BC", "DE", "HL", "SP"]
R16S = ["BC", "DE", "HL", "AF"]
CC = ["NZ", "Z", "NC", "C"]
ALU = ["ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP "]
CB = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL"]

IO = {
    0x00: "rP1", 0x01: "rSB", 0x02: "rSC", 0x04: "rDIV", 0x05: "rTIMA",
    0x06: "rTMA", 0x07: "rTAC", 0x0F: "rIF",
    0x10: "rNR10", 0x11: "rNR11", 0x12: "rNR12", 0x13: "rNR13", 0x14: "rNR14",
    0x24: "rNR50", 0x25: "rNR51", 0x26: "rNR52",
    0x40: "rLCDC", 0x41: "rSTAT", 0x42: "rSCY", 0x43: "rSCX", 0x44: "rLY",
    0x45: "rLYC", 0x46: "rDMA", 0x47: "rBGP", 0x48: "rOBP0", 0x49: "rOBP1",
    0x4A: "rWY", 0x4B: "rWX", 0x4C: "rKEY0", 0x4D: "rKEY1", 0x4F: "rVBK",
    0x51: "rHDMA1", 0x52: "rHDMA2", 0x53: "rHDMA3", 0x54: "rHDMA4",
    0x55: "rHDMA5", 0x56: "rRP", 0x68: "rBCPS", 0x69: "rBCPD",
    0x6A: "rOCPS", 0x6B: "rOCPD", 0x70: "rSVBK", 0xFF: "rIE",
}


def io(n):
    return IO.get(n, "$FF%02X" % n)


def a16(lo, hi):
    v = lo | hi << 8
    if 0xFF00 <= v <= 0xFFFF:
        return io(v & 0xFF)
    return "$%04X" % v


def decode(m, pc):
    """Returns (length, text). `m` is the whole ROM image."""
    op = m[pc]
    d8 = m[pc + 1] if pc + 1 < len(m) else 0
    d16 = a16(d8, m[pc + 2] if pc + 2 < len(m) else 0)
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1

    if op == 0x00: return 1, "NOP"
    if op == 0x10: return 2, "STOP"
    if op == 0x76: return 1, "HALT"
    if op == 0xF3: return 1, "DI"
    if op == 0xFB: return 1, "EI"
    if op == 0x08: return 3, "LD (%s),SP" % d16
    if op == 0xCB:
        c = m[pc + 1]
        cy, cz = (c >> 3) & 7, c & 7
        if c < 0x40: return 2, "%s %s" % (CB[cy], R8[cz])
        return 2, "%s %d,%s" % (["BIT", "RES", "SET"][(c >> 6) - 1], cy, R8[cz])

    if x == 0:
        if z == 0:
            if y == 3: return 2, "JR $%02X" % d8
            if y >= 4: return 2, "JR %s,$%02X" % (CC[y - 4], d8)
        if z == 1:
            if q == 0: return 3, "LD %s,%s" % (R16[p], d16)
            return 1, "ADD HL,%s" % R16[p]
        if z == 2:
            t = ["(BC)", "(DE)", "(HL+)", "(HL-)"][p]
            return 1, ("LD A,%s" % t) if q else ("LD %s,A" % t)
        if z == 3: return 1, "%s %s" % ("DEC" if q else "INC", R16[p])
        if z == 4: return 1, "INC %s" % R8[y]
        if z == 5: return 1, "DEC %s" % R8[y]
        if z == 6: return 2, "LD %s,$%02X" % (R8[y], d8)
        if z == 7:
            return 1, ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"][y]
    if x == 1: return 1, "LD %s,%s" % (R8[y], R8[z])
    if x == 2: return 1, "%s%s" % (ALU[y], R8[z])
    if x == 3:
        if z == 0:
            if y < 4: return 1, "RET %s" % CC[y]
            if y == 4: return 2, "LDH (%s),A" % io(d8)
            if y == 5: return 2, "ADD SP,$%02X" % d8
            if y == 6: return 2, "LDH A,(%s)" % io(d8)
            return 2, "LD HL,SP+$%02X" % d8
        if z == 1:
            if q == 0: return 1, "POP %s" % R16S[p]
            return 1, ["RET", "RETI", "JP HL", "LD SP,HL"][p]
        if z == 2:
            if y < 4: return 3, "JP %s,%s" % (CC[y], d16)
            if y == 4: return 1, "LD (C),A"
            if y == 5: return 3, "LD (%s),A" % d16
            if y == 6: return 1, "LD A,(C)"
            return 3, "LD A,(%s)" % d16
        if z == 3 and y == 0: return 3, "JP %s" % d16
        if z == 4 and y < 4: return 3, "CALL %s,%s" % (CC[y], d16)
        if z == 5:
            if q == 0: return 1, "PUSH %s" % R16S[p]
            if p == 0: return 3, "CALL %s" % d16
        if z == 6: return 2, "%s$%02X" % (ALU[y], d8)
        if z == 7: return 1, "RST $%02X" % (y * 8)
    return 1, "DB $%02X" % op


def main():
    rom = open(sys.argv[1], "rb").read()
    pc = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x150
    n = int(sys.argv[3], 0) if len(sys.argv) > 3 else 200
    run = 0
    runpc = pc
    for _ in range(n):
        if pc >= len(rom):
            break
        ln, txt = decode(rom, pc)
        if txt == "NOP":
            if run == 0:
                runpc = pc
            run += 1
            pc += 1
            continue
        if run:
            print("%04X  %d x NOP" % (runpc, run))
            run = 0
        print("%04X  %-22s ; %s" % (pc, txt,
                                    " ".join("%02X" % b for b in rom[pc:pc + ln])))
        pc += ln
    if run:
        print("%04X  %d x NOP" % (runpc, run))


if __name__ == "__main__":
    main()
