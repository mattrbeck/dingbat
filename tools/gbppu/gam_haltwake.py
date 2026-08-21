#!/usr/bin/env python3
"""Halted vs running mode-0 STAT wake, differentially, in dingbat AND SameBoy.

    tools/gbppu/gam_haltwake.py <wait_lines> <dmg|cgb>

Two programs identical except that one waits in a NOP sled and the other in
`HALT`. Both dispatch to the same handler, which prints TIMA (TAC = $05, one
tick per 16 T). Sweeping SCX walks the mode 3 -> 0 edge across the grid a dot
at a time, so a staircase that steps two SCX later is a wake two dots later.

This is GBMicrotest's `int_hblank_{nops,halt}_scx0..7` pair -- which ships both
arms and whose hardware answers disagree (61/62/62/62/62/63/63/63 running
against 62/62/62/63/63/63/63/64 halted) -- rebuilt in gambatte's output format
so the oracle can be asked too.

Measured 2026-08-21 on 65bcb71, DMG:

    W=0     nops ding 12 13 13 13 13 13 13 13   halt ding 12 13 13 13 ...
            nops samb 12 13 13 13 13 13 13 13   halt samb 13 13 13 13 ...
              -> line 0: running exact, halted 2 dots EARLY in dingbat
    W=1140  nops ding 2F 30 30 30 30 30 30 30   halt ding 2F 30 30 30 ...
            nops samb 2F 2F 2F 30 30 30 30 30   halt samb 2F 30 30 30 ...
              -> steady state: running 2 dots LATE, halted exact

Two 2-dot errors that cancel for a halted CPU on any line but the first after
an LCD enable. See M0_HALT_BLIND_DOTS in gb/ppu.nim.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gam_patchrun import ROOT, make, dingbat_values, sameboy_values

SRC = (ROOT + '/gambatte/enable_display/'
       'frame0_m0irq_count_scx2_1_dmg08_cgb04c_out90.gbc')


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    W = int(argv[1])
    dev = argv[2]
    scxs = list(range(8))

    rows = []
    for mode in ('nops', 'halt'):
        for scx in scxs:
            code = []
            code += [0x06, 0x91, 0xCD, 0x00, 0x74]   # ld b,$91 ; call $7400
            code += [0x3E, 0x00, 0xE0, 0x40]         # LCD off
            code += [0x3E, 0x05, 0xE0, 0x07]         # TAC := $05 (the ruler)
            code += [0xAF, 0xE0, 0x04]               # DIV := 0
            code += [0xAF, 0xE0, 0x05]               # TIMA := 0
            code += [0x3E, 0x91, 0xE0, 0x40]         # LCD on
            code += [0x00] * W
            code += [0x3E, scx, 0xE0, 0x43]
            code += [0x3E, 0x08, 0xE0, 0x41]         # STAT := mode-0 source
            code += [0x3E, 0x02, 0xE0, 0xFF]         # IE := STAT
            code += [0xAF, 0xE0, 0x0F]               # IF := 0
            code += [0xFB]                           # ei
            code += [0x76] if mode == 'halt' else [0x00] * 300
            code += [0xC3, 0x00, 0x70]
            pat = [(0x150, [0x00] * (0x6F00 - 0x150)),
                   (0x150, code),
                   (0x48, [0xF0, 0x05, 0xC3, 0x00, 0x70])]  # print TIMA
            rows.append((dev, make(SRC, pat,
                                   'hw_%s_w%d_scx%d.gbc' % (mode, W, scx))))

    db, sb = dingbat_values(rows), sameboy_values(rows)
    print('W=%d %s   scx : %s' % (W, dev, ' '.join('%2d' % s for s in scxs)))
    for j, mode in enumerate(('nops', 'halt')):
        o = j * 8
        print('  %-5s ding : %s' % (mode, ' '.join(db.get(o + i, '??')
                                                   for i in range(8))))
        print('  %-5s samb : %s' % (mode, ' '.join(sb.get(o + i, '??')
                                                   for i in range(8))))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
