#!/usr/bin/env python3
"""The OBJ penalty table, in dots, against hardware.

GBMicrotest's `ppu_spritex_vs_scx.gb` is 306 assertions (one object at OAM
X = 0..16 crossed with SCX = 0..8, two per cell bracketing the end of mode 3
to one M-cycle), but it stops at the first failing assertion and never writes
the $FF82 verdict byte, so the runner cannot say which cell failed.

This gets the whole table out instead: it patches a sibling ROM
(`ppu_sprite0_scx3_b.gb`, whose prologue is one `load_sprite` and one SCX
write at fixed offsets) to put a single object at (Y=16, X) with a given SCX,
runs the `-d:gb_m3_len` build, and takes line 0's mode-3 length. The penalty
is that length minus the same build's length with the object parked off
screen, so any constant offset in the mode 3 edge cancels.

  nim c -d:test_harness -d:release -d:gb_m3_len --path:src \\
    -o:dt_m3len tests/dingbat_test.nim
  python3 tools/gbppu/objtab.py ./dt_m3len

Prints one row per OAM X, marking every cell that disagrees with hardware with
a `*`, and the mismatch count. Hardware is `6 + max(0, 5 - ((X + SCX) mod 8))`
for X >= 1 and a flat 11 for X = 0 -- Pan Docs' algorithm plus Pan Docs' X = 0
exception -- transcribed from the ROM's own `cp` operands.

$DINGBAT_ROM_CACHE overrides the ROM directory, as elsewhere in this kit.
"""
import os, re, subprocess, sys

CACHE = os.environ.get("DINGBAT_ROM_CACHE", "/tmp/dingbat-test-roms")
SRC = os.path.join(CACHE, "game-boy-test-roms/gbmicrotest/ppu_sprite0_scx3_b.gb")
BIN = sys.argv[1] if len(sys.argv) > 1 else "./dt_m3len"

# Immediate-operand offsets in that ROM's prologue: `ld a,imm` before each of
# the four `ldi (hl),a` that fill OAM entry 0, then the SCX write.
OFF_Y, OFF_X, OFF_SCX = 0x158, 0x15B, 0x164

base = bytearray(open(SRC, "rb").read())
work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "objtab_%d.gb" % os.getpid())

def m3len(y, x, scx):
    b = bytearray(base)
    b[OFF_Y] = y; b[OFF_X] = x; b[OFF_SCX] = scx
    open(work, "wb").write(b)
    out = subprocess.run([BIN, work, "--mode=microtest", "--timeout=2", "--nosave"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"M3LEN ly=(\d+) len=(\d+)", line)
        if m and int(m.group(1)) == 0:
            return int(m.group(2))
    sys.exit("no M3LEN for ly=0 -- is %s built with -d:gb_m3_len?" % BIN)

def hardware(x, scx):
    return 11 if x == 0 else 11 - min(5, (x + scx) % 8)

def main():
    print("     SCX:  " + "  ".join("%2d" % s for s in range(9)))
    bad = 0
    for x in range(17):
        row = []
        for scx in range(9):
            got = m3len(16, x, scx) - m3len(0, 0, scx)
            exp = hardware(x, scx)
            if got != exp: bad += 1
            row.append("%2d%s" % (got, " " if got == exp else "*"))
        print("X=%2d      " % x + " ".join(row))
    os.remove(work)
    print("mismatched cells: %d/153" % bad)
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
