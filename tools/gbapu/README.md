# gbapu — measurement kit for the SameSuite APU sub-suite

Turns a SameSuite APU row into the ROM's own result bytes on a chosen silicon revision.
Every SameSuite APU ROM writes its measurements as raw bytes from `$C000` upwards and
keeps its verdict in `$CFFE` (`$50` = every comparison matched, `$46` = one did not), so
the whole test is readable out of WRAM at byte resolution.

## Build

    nim c -d:release --path:src --hints:off -o:tools/gbapu/ssdump tools/gbapu/ssdump.nim
    # second-emulator side: tools/gbfuzz/build.sh (links SameBoy's libcore; needs its
    # `make bootroms` output for the cgb0 and agb boot ROMs)

## Tools

    tools/gbapu/ssgrid.py        # 70 ROMs x 6 revisions, dingbat and the oracle side by side, with disagreements
    tools/gbapu/ssladder.py 0 20 # sweep a delay ladder past its shipped rungs, on all six revisions

`ssgrid.py` says whether a row is scored on the wrong silicon rather than failing — the
suite's `apu/README.md` states that CPU-CGB-C fails most channel 1/2/4 tests (the
PCM12/PCM34 read-on-a-change glitch) and CPU-CGB-E passes all, and the grid is that
paragraph measured. It is why `build_samesuite_apu_tests` defaults the sub-suite to `cgbE`.

`ssladder.py` patches `channel_1_freq_change_timing`'s two `call $7FFx` waits one byte
per block, moving a read by one M-cycle per rung, so a single odd cell becomes a staircase
with a visible edge and the revisions that move it show. `GbQuirks.pcm_read_edge_zero` and
`GbQuirks.square_freq_backstep_halftick` were derived this way.

## Caveat

The second emulator has no skip-boot API, so it plays the boot ROM while dingbat skips
it; for these ROMs that is not a constant offset but a different APU tick phase at test
start. Compare verdicts (`ssgrid.py`) or compare a ladder differentially (`ssladder.py`).
A raw buffer mismatch is not evidence of a behavioural disagreement.
