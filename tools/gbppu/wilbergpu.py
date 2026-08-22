#!/usr/bin/env python3
"""Read (and instrument) a wilbertpol mooneye `acceptance/gpu` ROM.

These ROMs are all the same shape:

  * a preamble that sets LYC/STAT, then, once per measurement, re-syncs the PPU
    from scratch (`wait LY==$90; LCDC bit7 off; nop; on; IF=0; wait LY==1`),
    burns N NOPs, and stores ONE register read to `$C0xx`;
  * a tail that packs those bytes into AF/BC/DE/HL, spills them to `$C000..$C007`
    (`ld sp,$c008` + four PUSHes, so the frame reads F A C B E D L H), writes the
    EXPECTED byte for each slot to `$C009..$C010` in the same order, and jumps
    into the print routine in bank 0's library at `$48xx`.

So the ROM carries its own expected values and its own per-sample NOP counts,
and neither needs a disassembly listing to recover.  `--dump` prints them.

`--patch out.gb` rewrites the final `jp $48xx` (everything after it is $FF
padding) with a loop that sends the measured bytes to the serial port as ASCII
hex, so `dingbat_test --mode serial` reads them out.  The patch sits strictly
after every measurement, so it cannot change what the ROM measures -- which
means the SAME patched file can be handed to a SameBoy runner that dumps the
WRAM slots and the two sides are answering about one identical ROM.
"""
import sys


def find_tail(b):
    """Return the address of the final `jp $48xx` in the test body."""
    best = None
    for i in range(0x150, 0x4000 - 3):
        if b[i] == 0xC3 and b[i + 2] == 0x48:
            # the test body's last instruction: only $FF padding after it
            if all(x == 0xFF for x in b[i + 3:i + 3 + 16]):
                best = i
    if best is None:
        raise SystemExit("no trailing `jp $48xx` found")
    return best


def scan(b):
    """Recover the measurement stores, the register packing and the expected array."""
    tail = find_tail(b)
    stores = []          # (pc, port, slot) -- `ldh a,($ffPP)` then `ld ($c0SS),a`
    i = 0x150
    while i < tail:
        if b[i] == 0xF0 and b[i + 2] == 0xEA and b[i + 4] == 0xC0:
            stores.append((i, b[i + 1], b[i + 3]))
            i += 5
            continue
        i += 1
    # NOP run immediately before each store = that sample's delay
    delays = []
    for pc, port, slot in stores:
        j = pc - 1
        n = 0
        while b[j] == 0x00:
            n += 1
            j -= 1
        delays.append(n)
    # expected array: `ld a,$VV` / `ld ($c0SS),a` for SS in $09..$10, in the tail
    exp = {}
    i = tail - 0x200
    while i < tail:
        if b[i] == 0x3E and b[i + 2] == 0xEA and b[i + 4] == 0xC0 and 0x09 <= b[i + 3] <= 0x10:
            exp[b[i + 3]] = b[i + 1]
            i += 5
            continue
        i += 1
    return tail, stores, delays, exp


# $C000..$C007 hold F A C B E D L H (see the PUSH order in the tail).
FRAME = ["F", "A", "C", "B", "E", "D", "L", "H"]


def dump(path):
    b = open(path, "rb").read()
    tail, stores, delays, exp = scan(b)
    print(f"{path}")
    print(f"  tail jp at ${tail:04X}")
    print("  samples (in program order):")
    for (pc, port, slot), n in zip(stores, delays):
        print(f"    ${pc:04X}  read $FF{port:02X} -> $C0{slot:02X}   after {n} NOPs")
    print("  expected frame $C000..$C007 =", " ".join(
        f"{FRAME[k - 9]}:{exp.get(k, 0xFF):02X}" for k in range(0x09, 0x11)))


# The serial-hex dumper that replaces the tail `jp`.  Assembled by hand; `base`
# is the address it is placed at (the `jp`'s own address).
def patch_bytes(base, first_slot, count):
    hexnib = base + 0x15
    return bytes([
        0x21, first_slot, 0xC0,              # ld hl,$c0SS
        0x0E, count,                         # ld c,count
        0x2A,                                # loop: ld a,(hl+)
        0xF5,                                # push af
        0xCB, 0x37,                          # swap a
        0xCD, hexnib & 0xFF, hexnib >> 8,    # call hexnib
        0xF1,                                # pop af
        0xCD, hexnib & 0xFF, hexnib >> 8,    # call hexnib
        0x0D,                                # dec c
        0x20, 0xF2,                          # jr nz,loop
        0x18, 0xFE,                          # jr $ (park)
        0xE6, 0x0F,                          # hexnib: and $0f
        0xFE, 0x0A,                          # cp $0a
        0x38, 0x02,                          # jr c,+2
        0xC6, 0x07,                          # add a,$07
        0xC6, 0x30,                          # add a,$30
        0xE0, 0x01,                          # ldh ($ff01),a
        0xC9,                                # ret
    ])


def patch(path, out):
    b = bytearray(open(path, "rb").read())
    tail, stores, delays, exp = scan(b)
    # Always the whole scratch window: some ROMs fill slots the `ldh`/`ld`
    # scan cannot see (ly_lyc_write counts LYC interrupts in its handler and
    # stores the total straight from B), and dumping a fixed range keeps the
    # SameBoy side comparable without a per-ROM address.
    first, count = 0x14, 12
    code = patch_bytes(tail, first, count)
    assert all(x == 0xFF for x in b[tail + 3:tail + len(code)]), "patch would clobber code"
    b[tail:tail + len(code)] = code
    open(out, "wb").write(bytes(b))
    print(f"patched {path} -> {out}: dumps $C0{first:02X}..$C0{first + count - 1:02X} "
          f"as {count * 2} ASCII hex chars over serial")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[2] == "--patch":
        patch(sys.argv[1], sys.argv[3])
    else:
        dump(sys.argv[1])
