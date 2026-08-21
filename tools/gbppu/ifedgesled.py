#!/usr/bin/env python3
"""Manufacture the missing members of a GBMicrotest IF-edge family.

    tools/gbppu/ifedgesled.py <rom.gb> <tail_hex> <k0,k1,...> <outdir>

GBMicrotest's `oam_int_if_edge_{a,b,c,d}` are four copies of one ROM whose
`xor a ; ldh ($FF0F),a ; ldh a,($FF0F)` block sits at four different offsets in
a NOP sled -- +0, +1, +3 and +4 M-cycles.  The block clears IF and reads it back
three M-cycles later, so a read of `$E2` means a STAT source's RISING edge fell
inside that window and `$E0` means it did not.  Four members bracket the edge
two-sidedly; the whole sled locates it outright.

Everything from the block to the end of the ROM is position independent (only
relative jumps and absolute `ld hl,$8000`), and the header is untouched, so a
member is made by inserting `k` NOPs in front of the block and shifting the
rest down.  `$FF80` carries the value read whether the ROM's own compare passes
or fails, so `--mode=microtest` reports it either way:

    ./dingbat_test <out>/oam_int_if_edge_a_k3.gb --mode=microtest --timeout=60

Measured 2026-08-20 (tail 0x233, k = 0..8), `$E2` window per device:

    hardware (from the four shipped members)   k = 1, 2, 3
    dingbat, DMG                               k = 2, 3, 4     <- one M late
    dingbat, CGB (STAT_M2_LEAD_CGB = 1)        k = 1, 2, 3     <- exact

See STAT_M2_LEAD in gb/ppu.nim for what that measures and what it is blocked on.
"""
import os
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    rom, tail_s, ks_s, outdir = sys.argv[1:]
    tail = int(tail_s, 16)
    ks = [int(x) for x in ks_s.split(",")]
    src = bytearray(open(rom, "rb").read())
    body = bytes(src[tail:])
    os.makedirs(outdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(rom))[0]
    for k in ks:
        out = bytearray(src)
        out[tail:tail + k] = b"\x00" * k
        out[tail + k:] = body[:len(out) - tail - k]
        path = os.path.join(outdir, f"{stem}_k{k}.gb")
        open(path, "wb").write(bytes(out))
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
