#!/usr/bin/env python3
"""GBMicrotest's int_hblank_nops / hblank_int, rebuilt so SameBoy can answer.

    tools/gbppu/gam_dispatch.py <wait_lines> <dmg|cgb> [scx,list]

Counts `INC A` until the mode-0 STAT interrupt DISPATCHES -- not until IF reads
back, which is a different sample point (gb/interrupts.nim: a `$FF0F` read
latches 2 T into its own M-cycle, the dispatch sees the whole of it). Sweeping
SCX walks the mode 3 -> 0 edge across the M-cycle grid a dot at a time, so the
step positions locate the dispatch to the dot.

`wait_lines` is NOPs between the LCD enable and arming the source: 0 measures
the first line after the enable, 114 the second, 1140 the eleventh.

Measured 2026-08-21 on 65bcb71, DMG (CGB identical):

    W=0     ding 29 2A 2A 2A 2A 2B 2B 2B   steps at SCX 1 and 5
            samb 29 2A 2A 2A 2A 2B 2B 2B   the same -- and the same shape as
                                           GBMicrotest int_hblank_nops_scx*
    W=114   ding 29 2A 2A 2A 2A 2B 2B 2B
    /228    samb 29 29 29 2A 2A 2A 2A 2B   steps at 3 and 7 -- dingbat is 2
    /342                                   dots LATE, and this is the shape
    /1140                                  GBMicrotest hblank_int_scx* wants

So the first line after an LCD enable is exact and every later one is 2 dots
late, on every line tested, on both devices. See M0_HALT_BLIND_DOTS in
gb/ppu.nim for what that is half of.
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
    scxs = ([int(x) for x in argv[3].split(',')] if len(argv) > 3
            else list(range(8)))

    rows = []
    for scx in scxs:
        code = []
        code += [0x06, 0x91, 0xCD, 0x00, 0x74]     # ld b,$91 ; call $7400
        code += [0x3E, 0x00, 0xE0, 0x40]           # LCD off
        code += [0x3E, 0x91, 0xE0, 0x40]           # LCD on
        code += [0x00] * W
        code += [0x3E, scx, 0xE0, 0x43]            # ld a,scx ; ldh ($ff43),a
        code += [0x3E, 0x08, 0xE0, 0x41]           # STAT := mode-0 source
        code += [0x3E, 0x02, 0xE0, 0xFF]           # IE := STAT
        code += [0xAF, 0xE0, 0x0F]                 # IF := 0
        code += [0xFB, 0xAF]                       # ei ; xor a
        code += [0x3C] * 300                       # inc a ...
        code += [0xC3, 0x00, 0x70]
        pat = [(0x150, [0x00] * (0x6F00 - 0x150)),
               (0x150, code),
               (0x48, [0xC3, 0x00, 0x70])]         # STAT vector -> print A
        rows.append((dev, make(SRC, pat, 'disp_w%d_scx%d.gbc' % (W, scx))))

    db, sb = dingbat_values(rows), sameboy_values(rows)
    print('W=%d %s  scx : %s' % (W, dev, ' '.join('%2d' % s for s in scxs)))
    print('           ding : %s' % ' '.join(db.get(i, '??')
                                            for i in range(len(rows))))
    print('           samb : %s' % ' '.join(sb.get(i, '??')
                                            for i in range(len(rows))))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
