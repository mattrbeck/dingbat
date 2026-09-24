#!/usr/bin/env python3
"""Real-game acceptance: run each ROM on the HLE BIOS and on the real BIOS
image inside dingbat (tests/biosdrv_probe.nim) and compare the frames, the
bytes that reached the two sound FIFOs, and the SoundArea at the end.

  games.py <frames> <rom.gba> [...]

ROMs are read in place (symlink library ROMs into a scratch directory
first; biosdrv_probe never writes next to a ROM, it runs without saves).
Outputs: /tmp/bd/games/<name>.{hle,real}.*
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PROBE = os.environ.get("PROBE", os.path.join(ROOT, "biosdrv_probe"))
BIOS = os.environ.get("BIOS", "/Users/matt/code/dingbat/tests/roms/gba_bios.bin")
OUT = "/tmp/bd/games"


def run(rom, frames, bios, tag):
    os.makedirs(OUT, exist_ok=True)
    name = os.path.splitext(os.path.basename(rom))[0]
    prefix = os.path.join(OUT, name + "." + tag)
    env = dict(os.environ, BD_SWILOG="1")
    subprocess.run([PROBE, rom, prefix, str(frames), bios], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return prefix


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None if len(a) == len(b) else n


def main():
    frames = int(sys.argv[1])
    for rom in sys.argv[2:]:
        ph = run(rom, frames, "hle", "hle")
        pr = run(rom, frames, BIOS, "real")
        fh = open(ph + ".frames.txt").read().split("\n")
        fr = open(pr + ".frames.txt").read().split("\n")
        fd = first_diff(fh, fr)
        same = sum(1 for x, y in zip(fh, fr) if x == y)
        print(f"== {os.path.basename(rom)}")
        print(f"   frames: {same}/{min(len(fh), len(fr))} identical, first differing frame {fd}")
        for ch in "AB":
            a = open(ph + f".fifo{ch}.bin", "rb").read()
            b = open(pr + f".fifo{ch}.bin", "rb").read()
            d = first_diff(a, b)
            nz = sum(1 for x in b if x)
            print(f"   FIFO {ch}: hle {len(a)} real {len(b)} bytes ({nz} nonzero real), "
                  f"first difference at byte {d}")
        sa = [l.split()[3] for l in open(ph + ".swi.txt")]
        sb = [l.split()[3] for l in open(pr + ".swi.txt")]
        from collections import Counter
        print(f"   sound SWIs hle {dict(Counter(sa))} real {dict(Counter(sb))}")


if __name__ == "__main__":
    main()
