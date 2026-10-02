#!/usr/bin/env python3
"""Build the invariant ROMs tests/cyclelaws_test.nim runs (needs arm-none-eabi).

    python3 tests/roms/invariants/build.py

These hold the core to laws that need no console reading: two runs of a
payload that differ only in something the console cannot see must answer
alike. Each ROM is tests/roms/payloadrun.s around one payload and its
argument list, the way tools/hwlink/lawrom.py freezes the recorded tables;
the ROMs are committed (our own code, a few KB each).
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(REPO, 'tools', 'hwlink'))
import payloadcmp

# dmairqarm: a timer interrupt raised k cycles into a DMA3 burst, with an idle
# sound DMA armed (odd entries) or not (even), then the same with the TM0
# acknowledge after the burst. Arguments come in (not armed, armed) pairs.
KS = (4, 20, 40, 60, 80, 100, 120, 140, 160, 180, 190, 200, 210, 220, 240)
DMAIRQARM = [(ack << 17) | (armed << 16) | (0x10000 - k)
             for ack in (0, 1) for k in KS for armed in (0, 1)]

ROMS = {'dmairqarm': DMAIRQARM}


def main():
    for name, args in ROMS.items():
        src = os.path.join(REPO, 'tests', 'roms', 'payloads', name + '.s')
        rom = payloadcmp.build_wrapper(src, args)
        shutil.copyfile(rom, os.path.join(HERE, name + '.gba'))
        print(f'{name}.gba: {len(args)} arguments')


if __name__ == '__main__':
    main()
