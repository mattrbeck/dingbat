#!/usr/bin/env python3
"""Read (and instrument) wilbertpol's `acceptance/gpu/stat_write_if`.

The ROM is 85 independent subtests driven from one table.  Each entry is

    LD D,<pre> ; LD E,<post> ; LD H,<expected IF & 2> ; CALL <sync routine>

and each sync routine does the same thing: wait for vblank, take the LCD off,
write STAT = D, put the LCD back on, wait for a fixed LY, spin until the PPU
*enters* one particular mode, clear IF, write STAT = E, and check whether that
write raised the STAT interrupt flag.  So the ROM asks, 85 times, "does writing
this STAT value while sitting at the top of this mode set IF bit 1?".

It reports only the FIRST failure ("TEST #n FAILED" on screen).  `--patch`
replaces every `CP H ; RET Z ; JP <fail>` with `CP H ; CALL <report> ; RET`,
where <report> sends `.` or `X` to the serial port, so `dingbat_test
--mode serial` prints the whole 85-character verdict string in one run and the
per-subtest table below lines up with it one for one.

    statwif.py <rom.gb>                 # the table
    statwif.py <rom.gb> --patch out.gb
"""
import sys

ENABLE = {0x00: "-", 0x08: "m0", 0x10: "m1", 0x20: "m2", 0x40: "lyc"}


def routines(b):
    """Every sync routine: addr -> (LY waited for, mode entered)."""
    out = {}
    for r in set(t[3] for t in table(b)):
        ly = md = None
        for i in range(r, r + 0x50):
            if b[i] == 0xF0 and b[i + 1] == 0x44 and b[i + 2] == 0xFE and ly is None and i > r + 8:
                ly = b[i + 3]
            if b[i] == 0xE6 and b[i + 1] == 0x03 and b[i + 2] == 0xFE and md is None:
                md = b[i + 3]
        out[r] = (ly, md)
    return out


def table(b):
    """The subtest table: (pc, pre, post, call, expect)."""
    out = []
    i = 0x150
    while i < 0x1000 - 9:
        if b[i] == 0x16 and b[i + 2] == 0x1E and b[i + 4] == 0x26 and b[i + 6] == 0xCD:
            out.append((i, b[i + 1], b[i + 3], b[i + 7] | (b[i + 8] << 8), b[i + 5]))
            i += 9
        else:
            i += 1
    return out


def dump(path):
    b = open(path, "rb").read()
    t = table(b)
    r = routines(b)
    print(f"{path}: {len(t)} subtests")
    print("  #   pre     write   at            expect")
    for n, (pc, pre, post, call, exp) in enumerate(t, 1):
        ly, md = r[call]
        print(f"  {n:<3} {ENABLE.get(pre, hex(pre)):<7} {ENABLE.get(post, hex(post)):<7} "
              f"mode {md} of LY ${ly:02X}   {'IF' if exp else '--'}")


def patch(path, out):
    b = bytearray(open(path, "rb").read())
    # free space after the body, for the reporter
    end = len(b)
    while b[end - 1] == 0xFF:
        end -= 1
    rep = (end + 0x10) & ~0x0F
    assert all(x == 0xFF for x in b[rep:rep + 0x10]), "no room for the reporter"
    b[rep:rep + 11] = bytes([
        0x28, 0x04,        # jr z,ok
        0x3E, 0x58,        # ld a,'X'
        0x18, 0x02,        # jr send
        0x3E, 0x2E,        # ok: ld a,'.'
        0xE0, 0x01,        # send: ldh ($ff01),a
        0xC9,              # ret
    ])
    n = 0
    for i in range(0x150, 0x4000 - 5):
        # CP H ; RET Z ; JP nn  -> CP H ; CALL report ; RET
        if b[i] == 0xBC and b[i + 1] == 0xC8 and b[i + 2] == 0xC3:
            b[i + 1] = 0xCD
            b[i + 2] = rep & 0xFF
            b[i + 3] = rep >> 8
            b[i + 4] = 0xC9
            n += 1
    open(out, "wb").write(bytes(b))
    print(f"patched {path} -> {out}: {n} checks report to serial, reporter at ${rep:04X}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[2] == "--patch":
        patch(sys.argv[1], sys.argv[3])
    else:
        dump(sys.argv[1])
