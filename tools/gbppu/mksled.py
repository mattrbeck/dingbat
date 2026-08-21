#!/usr/bin/env python3
"""Cut a NOP-sled family out of ANY GBMicrotest ROM, with a probe of your own.

    tools/gbppu/mksled.py <src.gb> <tail_hex> <tailbytes_hex> <k0..k1> <outdir> <stem>

GBMicrotest's shipped families (`line_153_ly_{a..f}`, `line_153_lyc0_stat_timing_{a..n}`,
`oam_int_if_edge_{a..d}`) are one ROM with one extra NOP per member, so they
bracket an edge to one M-cycle but only where the author happened to stop and
only with the probe the author happened to write.  This splices YOUR probe in at
`tail + k` for every k in the range, leaves the rest of the sled as NOPs, and
fixes the header checksum.  `--mode=microtest` reports `$FF80` whatever the
ROM's own compare does, so a probe that just stores A is enough:

    e0 80  ldh ($FF80),a      ; whatever you want reported
    3e 01  ld a,$01
    e0 81  ldh ($FF81),a
    3e 01  ld a,$01
    e0 82  ldh ($FF82),a      ; verdict = PASS so the harness prints it
    18 fe  jr  $-2

Two probes that paid for themselves on 2026-08-21, both cut from
`line_153_lyc0_stat_timing_c` at $01CC so they share one clock:

  READ the STAT flag          f0 41 <store A>          k 16 -> 17, both emulators
  CATCH the IF rising edge    af e0 0f f0 0f <store A> a 3-M window: $E2 in, $E0 out
  RULE the dispatch           3e 02 e0 ff af e0 0f fb af <400 x 3c> <store A>

The third is the sharpest of the three and needs no sled at all: `ei` with IF
just cleared, then a run of `inc a`, and a handler at $0048 that stores A.  The
byte it reports IS the M-cycle the interrupt was dispatched on, at 1-M-cycle
resolution, with no aperture to cancel -- dingbat read $09 against SameBoy's
$08 there, and that one byte is the whole of `LYC_SRC_RELATCH_LEAD`.

Run both sides with `tools/gbfuzz/sameboy_microtest <bootdir> <rom> 15 dmg` and
`./dingbat_test <rom> --mode=microtest --timeout=2 --nosave`.
"""
import os
import sys


def main() -> int:
    if len(sys.argv) != 7:
        print(__doc__)
        return 2
    src, tail_s, tb_s, ks_s, outdir, stem = sys.argv[1:7]
    tail = int(tail_s, 16)
    tb = bytes.fromhex(tb_s.replace('_', '').replace(' ', ''))
    a, b = ks_s.split('..')
    base = bytearray(open(src, 'rb').read())
    os.makedirs(outdir, exist_ok=True)
    for k in range(int(a), int(b) + 1):
        out = bytearray(base)
        # Blank the sled ahead of the probe as well as behind it: the original
        # body from `tail` on is dead once the probe stops.
        for i in range(tail, min(tail + k + len(tb) + 64, len(out))):
            out[i] = 0
        out[tail + k:tail + k + len(tb)] = tb
        s = 0
        for i in range(0x134, 0x14D):
            s = (s - out[i] - 1) & 0xFF
        out[0x14D] = s
        path = os.path.join(outdir, "%s_k%d.gb" % (stem, k))
        open(path, 'wb').write(bytes(out))
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
