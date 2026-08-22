#!/usr/bin/env python3
"""Sweep the LYC-write M-cycle in a wilbertpol `ly_lyc*_write` ROM.

Each of those ROMs is several independent sleds of the shape

    EI ; <N NOPs> ; LDH ($FF45),A [; LDH A,($FF41) ; LD ($C0tt),A]
       ; <M NOPs> ; LD A,B ; LD ($C0ss),A

where B counts LYC STAT interrupts taken since the `EI`.  The two sleds that
share a question differ by exactly one NOP, which brackets the M-cycle the
write lands on -- but a pair only says "between these two", and the ROM ships
only the two.  This slides the store (with the STAT read some sleds glue to
it, so their relative phase is preserved) through its own NOP field without
changing the field's length, so the answer can be read as a staircase and the
transition M-cycle located outright, on either emulator.

    lycwsled.py <rom.gb>                       # list the sleds
    lycwsled.py <rom.gb> <sled> <delta> <out.gb>

`delta` is in M-cycles relative to the shipped position (each instruction in
the block is one M-cycle wide either way, so this is a pure translation).
"""
import sys


def sleds(b):
    """Locate the sleds: (ei, block_start, block, field_lo, field_hi, slot).

    The field is everything between the `EI` and the `LD A,B` that reads the
    counter; the block is the non-NOP run inside it -- the LYC store, plus the
    STAT read some sleds put immediately after it.  Sliding the whole block is
    what keeps those two in the relative position the ROM built them in.
    """
    out = []
    i = 0x150
    while i < 0x4000 - 8:
        if b[i] == 0xFB:                            # EI
            j = i + 1
            while b[j] == 0x00:
                j += 1
            if b[j] == 0xE0 and b[j + 1] == 0x45:   # LDH ($FF45),A
                end = -1
                for t in range(j, min(j + 24, len(b) - 4)):
                    if b[t] == 0x78 and b[t + 1] == 0xEA and b[t + 3] == 0xC0:
                        end = t                     # LD A,B ; LD ($C0ss),A
                        break
                if end >= 0:
                    e = end
                    while e > j and b[e - 1] == 0x00:
                        e -= 1
                    out.append((i, j, bytes(b[j:e]), i + 1, end, b[end + 2]))
        i += 1
    return out


def patch(path, which, delta, out, probe=None):
    b = bytearray(open(path, "rb").read())
    s = sleds(b)
    if which >= len(s):
        raise SystemExit(f"{path} has {len(s)} sleds")
    ei, wpc, blk, lo, hi, slot = s[which]
    if probe is not None:
        # Locate an EDGE instead of racing a write against it: drop the sled's
        # own LYC store, turn the `EI` into a NOP so no handler can clear what
        # is being watched, and slide a bare `LDH A,($FFxx) ; LD ($C01F),A`
        # through the same field on the same grid.  Same M-cycle count either
        # way (EI and NOP are both one), so the sync is untouched.
        b[ei] = 0x00
        blk = bytes([0xF0, probe, 0xEA, 0x1F, 0xC0])
    pos = wpc + delta
    if pos < lo or pos + len(blk) > hi:
        raise SystemExit(f"delta {delta} leaves the NOP field ${lo:04X}..${hi:04X}")
    for i in range(lo, hi):
        b[i] = 0x00
    b[pos:pos + len(blk)] = blk
    open(out, "wb").write(bytes(b))
    return ei, wpc, blk, lo, hi, slot, pos - lo


if __name__ == "__main__":
    if len(sys.argv) == 2:
        b = open(sys.argv[1], "rb").read()
        for i, (ei, wpc, blk, lo, hi, slot) in enumerate(sleds(b)):
            print(f"sled {i}: EI ${ei:04X}  block ${wpc:04X} ({len(blk)}B) after "
                  f"{wpc - lo} NOPs -> $C0{slot:02X}  (field ${lo:04X}..${hi:04X})")
    else:
        rom, which, delta, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
        probe = int(sys.argv[6], 16) if len(sys.argv) > 6 and sys.argv[5] == "--probe" else None
        ei, wpc, blk, lo, hi, slot, k = patch(rom, which, delta, out, probe)
        print(f"sled {which}: block now at NOP {k} (was {wpc - lo}) "
              f"-> $C0{slot:02X}  {out}")
