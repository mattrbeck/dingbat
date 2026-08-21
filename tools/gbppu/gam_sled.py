#!/usr/bin/env python3
"""Sled one probe across the dots after an LCD enable, in dingbat AND SameBoy.

    tools/gbppu/gam_sled.py <kmin> <kmax> <scx,list> <dmg|cgb> <probe,list>
                            [if-clear M-cycle]

`k` is CPU M-cycles from the `LDH ($41),A` that arms the STAT source; the probe
reads one register and jumps to the printer, so the first `k` whose answer
flips is the boundary, bracketed to one M-cycle. Sweeping SCX walks the mode
3 -> 0 edge across the M-cycle grid a dot at a time, so the STEP POSITIONS in
SCX locate it to the dot, and a shift of the step by two SCX values is a shift
of the edge by two dots.

  probe if   : ldh a,($ff0f)   E0 -> E2 at the mode-0 STAT source's rise
  probe stat : ldh a,($ff41)   8B -> 88 at the readable mode flag's 3 -> 0
  probe vram : ld a,($9000)    FF -> 00 when the mode-3 VRAM lock lifts
  probe oam  : ld a,($fe00)    FF -> 00 when the mode-3 OAM lock lifts
  probe ly   : ldh a,($ff44)   00 -> 01 at the line 0 -> 1 advance

The optional last argument inserts `xor a ; ldh ($ff0f),a` at that M-cycle, so
`if` can be swept on a later line than the one that first raised the flag
(e.g. `... 156 166 0,1,2,3,4,5,6,7 dmg if 120` is line 1).

Measured 2026-08-21 on 65bcb71; see M0_HALT_BLIND_DOTS in gb/ppu.nim.
"""
import sys
import os
import collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gam_patchrun import ROOT, make, dingbat_values, sameboy_values

SRC = (ROOT + '/gambatte/enable_display/'
       'frame0_m0irq_count_scx2_1_dmg08_cgb04c_out90.gbc')
SLED0 = 0x16C          # first NOP after that ROM's own `ldh ($ff41),a`
BODY_END = 0x6F00      # everything to here is NOP padding in every such ROM

PROBES = {
    'if':   [0xF0, 0x0F, 0xC3, 0x00, 0x70],
    'stat': [0xF0, 0x41, 0xC3, 0x00, 0x70],
    'vram': [0xFA, 0x00, 0x90, 0xC3, 0x00, 0x70],
    'oam':  [0xFA, 0x00, 0xFE, 0xC3, 0x00, 0x70],
    'ly':   [0xF0, 0x44, 0xC3, 0x00, 0x70],
}


def main(argv):
    if len(argv) < 6:
        print(__doc__)
        return 2
    kmin, kmax = int(argv[1]), int(argv[2])
    scxs = [int(x) for x in argv[3].split(',')]
    dev = argv[4]
    probes = argv[5].split(',')
    clear_at = int(argv[6]) if len(argv) > 6 else -1

    rows, tags = [], []
    for pr in probes:
        for scx in scxs:
            for k in range(kmin, kmax + 1):
                pat = [(SLED0, [0x00] * (BODY_END - SLED0)), (0x151, [scx])]
                if clear_at >= 0:
                    # xor a ; ldh ($ff0f),a -- 3 bytes but 4 M-cycles, so
                    # everything after it sits one M-cycle later than its byte
                    # offset says.
                    pat.append((SLED0 + clear_at, [0xAF, 0xE0, 0x0F]))
                    pat.append((SLED0 + k - 1, PROBES[pr]))
                else:
                    pat.append((SLED0 + k, PROBES[pr]))
                rows.append((dev, make(SRC, pat,
                                       'sled_%s_scx%d_k%d.gbc' % (pr, scx, k))))
                tags.append((pr, scx, k))

    db = dingbat_values(rows)
    sb = sameboy_values(rows)
    d = collections.defaultdict(dict)
    for i, (pr, scx, k) in enumerate(tags):
        d[(pr, scx)][k] = (db.get(i, '??'), sb.get(i, '??'))
    for key in sorted(d):
        ks = sorted(d[key])
        print('%-5s scx %d  ding %s' %
              (key[0], key[1], ' '.join(d[key][k][0] for k in ks)))
        print('%-5s scx %d  samb %s' %
              ('', key[1], ' '.join(d[key][k][1] for k in ks)))
    print('k =', ' '.join('%2d' % k for k in range(kmin, kmax + 1)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
