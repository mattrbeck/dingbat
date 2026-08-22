#!/usr/bin/env python3
"""objtab.py with a caller-chosen OAM-X range, for the RIGHT edge of the line.

objtab.py only ever swept X = 0..16 (that is the span GBMicrotest's
ppu_spritex_vs_scx asserts). wilbertpol's intr_2_mode0_timing_sprites* ROMs also
place objects at X = 160..169, i.e. the last on-screen tile and past it, and that
half of the table has never been scored.
"""
import os, re, subprocess, sys
CACHE = os.environ.get("DINGBAT_ROM_CACHE", "/tmp/dingbat-test-roms")
SRC = os.path.join(CACHE, "game-boy-test-roms/gbmicrotest/ppu_sprite0_scx3_b.gb")
BIN = sys.argv[1]
LO = int(sys.argv[2]); HI = int(sys.argv[3])
OFF_Y, OFF_X, OFF_SCX = 0x158, 0x15B, 0x164
base = bytearray(open(SRC, "rb").read())
work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "objtab2_%d.gb" % os.getpid())
def m3len(y, x, scx):
    b = bytearray(base); b[OFF_Y]=y; b[OFF_X]=x; b[OFF_SCX]=scx
    open(work,"wb").write(b)
    out = subprocess.run([BIN, work, "--mode=microtest", "--timeout=2", "--nosave"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"M3LEN ly=(\d+) len=(\d+)", line)
        if m and int(m.group(1))==0: return int(m.group(2))
    sys.exit("no M3LEN")
def hardware(x, scx):
    if x >= 168: return 0
    return 11 if x == 0 else 11 - min(5, (x + scx) % 8)
print("     SCX:  " + "  ".join("%2d" % s for s in range(9)))
bad=0
for x in range(LO, HI+1):
    row=[]
    for scx in range(9):
        got = m3len(16,x,scx) - m3len(0,0,scx)
        exp = hardware(x,scx)
        if got != exp: bad += 1
        row.append("%2d%s" % (got, " " if got==exp else "*"))
    print("X=%3d     " % x + " ".join(row))
os.remove(work)
print("mismatched cells: %d" % bad)
