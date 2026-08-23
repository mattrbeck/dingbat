#!/usr/bin/env python3
"""Sweep `channel_1_freq_change_timing`'s delay ladder past the end of its own
sixteen rungs, on every CGB revision, dingbat against the sameboy_ssdump
runner.

    tools/gbapu/ssladder.py [lo] [hi]        # rungs lo..hi-1, default 0..20

The ROM: each of sixteen blocks powers the APU off and on (which is
the only thing that resets a square channel's duty position), sets NR11 = $00
(duty 12.5%, so exactly one of eight steps is high), NR12 = $F8, NR13 = $FC,
triggers with NR14 = $87 -- frequency $7FC, i.e. a duty step every 4 M-cycles
-- waits, writes NR14 = $00 to drop the frequency to $0FC (a step every 1796
M-cycles, i.e. the channel freezes), and reads PCM12 twice, 2 and 23 M-cycles
after that write.  It stores `(read1 << 4) | read2`.  Blocks 0-7 run at single
speed; block 7 is followed by a `STOP` into double speed and blocks 8-15 run
there.

The wait is `call $7FFx`, and $7FFF is a lone `ret` with
plain $00 nops all the way back to $0878, so the call's low byte IS the delay:
target $7FFF - n runs n nops.  CALL1[k] holds block k's first delay (which moves
the NR14 write and both reads together, changing the write's phase against the
free-running duty counter) and CALL2[k] its second (which moves read2 alone,
tracing the channel's output as a function of time after the write).  The
shipped ladder is n = 0..7 single speed and n = 0..7 double speed.

Output: the high nibble is read1, 2 M-cycles after the write (can catch a duty
step in the act); the low nibble is read2, 21 M-cycles later, after the
channel has frozen (which duty index the freeze landed on). A high-nibble
difference is about what a read on a step sees (GbQuirks.pcm_read_edge_zero);
a low-nibble one is about whether the step happened at all
(GbQuirks.square_freq_backstep_halftick).

The patched ROMs are written to $TMPDIR, never to the shared ROM cache: the
runner reuses any file already present there by name.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CACHE = os.environ.get("DINGBAT_ROM_CACHE", "/tmp/dingbat-test-roms")
BASE = os.path.join(CACHE, "game-boy-test-roms/same-suite/apu/channel_1",
                    "channel_1_freq_change_timing-A.gb")
BOOT = os.environ.get("SAMEBOY_BOOTROMS",
                      os.path.expanduser("~/code/SameBoy/build/bin/BootROMs"))
TMP = os.environ.get("TMPDIR", "/tmp")

CALL1 = [0x5d9, 0x604, 0x62f, 0x65a, 0x685, 0x6b0, 0x6db, 0x706,
         0x737, 0x762, 0x78d, 0x7b8, 0x7e3, 0x80e, 0x839, 0x864]
CALL2 = [0x5e1, 0x60c, 0x637, 0x662, 0x68d, 0x6b8, 0x6e3, 0x70e,
         0x73f, 0x76a, 0x795, 0x7c0, 0x7eb, 0x816, 0x841, 0x86c]
BASE_S, BASE_D, BASE_2 = 0x7ff3, 0x7fd7, 0x7ff9   # the shipped rung-0 targets

MODELS = [("cgb0", "0"), ("cgbAB", "B"), ("cgbC", "C"),
          ("cgbD", "D"), ("cgbE", "E"), ("agb", "agb")]


def patch(path, n1, n2=0):
    rom = bytearray(open(BASE, "rb").read())
    for k in range(16):
        for calls, t in ((CALL1, (BASE_S if k < 8 else BASE_D) - n1),
                         (CALL2, BASE_2 - n2)):
            rom[calls[k] + 1] = t & 0xFF
            rom[calls[k] + 2] = (t >> 8) & 0xFF
    open(path, "wb").write(rom)


def run(path, model, sbmodel):
    d = subprocess.run([ROOT + "/tools/gbapu/ssdump", path, "400", model, "16"],
                       capture_output=True, text=True).stdout.strip()
    s = subprocess.run([ROOT + "/tools/gbfuzz/sameboy_ssdump", path, sbmodel,
                        BOOT, "400", "16"],
                       capture_output=True, text=True).stdout.strip()
    return d, s


def main():
    lo = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    hi = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    rows = {}
    path = os.path.join(TMP, "ssladder.gb")
    for n in range(lo, hi):
        patch(path, n)
        rows[n] = {m: run(path, m, sm) for m, sm in MODELS}
    hdr = "  n | " + " | ".join("%-9s" % m for m, _ in MODELS)
    bad = 0
    for slot, label in ((0, "SINGLE SPEED (block 0)"), (8, "DOUBLE SPEED (block 8)")):
        print("\n%s   cell = ding/sb, (read1<<4)|read2" % label)
        print(hdr)
        for n in sorted(rows):
            cells = []
            for m, _ in MODELS:
                d, s = rows[n][m]
                dv, sv = d[slot * 2:slot * 2 + 2], s[slot * 2:slot * 2 + 2]
                if dv != sv:
                    bad += 1
                cells.append("%s/%s%s" % (dv, sv, "  " if dv == sv else " !"))
            print("%3d | " % n + " | ".join("%-9s" % c for c in cells))
    print("\nding/sb mismatches: %d" % bad)


main()
