# gbapu — measurement kit for the SameSuite APU sub-suite

`tools/gbppu` turns a PPU pass/fail row into a dot count. These do the same for
the APU: they turn a SameSuite APU row into **the ROM's own result bytes**, on a
chosen silicon revision, beside SameBoy's.

Every SameSuite APU ROM writes its measurements as raw bytes from `$C000`
upwards and only then renders them as a hex grid, and it keeps its verdict in
`$CFFE` (`$50` = every comparison matched so far, `$46` = one did not). So the
whole test is readable out of WRAM, at byte resolution, without decoding the
screen and without knowing where that ROM's expected table lives.

## Build

    nim c -d:release --path:src --hints:off -o:tools/gbapu/ssdump tools/gbapu/ssdump.nim
    # SameBoy side: tools/gbfuzz/build.sh (needs SameBoy's `make bootroms`
    # output, which has the cgb0 and agb boot ROMs the two-file bootdir lacks)

## Which machine is this row's question about?

    tools/gbapu/ssgrid.py

70 ROMs x 6 revisions, dingbat and SameBoy side by side, plus per-revision
totals and a disagreement list. This is the instrument that says a row is being
scored on the wrong silicon rather than failing — `same-suite/apu/README.md`
states that CPU-CGB-C fails most of the channel 1/2/4 tests (the PCM12/PCM34
read-on-a-change glitch) and that CPU-CGB-E passes all of them, and this grid
is that paragraph measured. It is why `build_samesuite_apu_tests` defaults the
sub-suite to `cgbE`.

## What cycle does a behaviour turn on?

    tools/gbapu/ssladder.py 0 20

`channel_1_freq_change_timing` is a delay ladder whose two waits are
`call $7FFx` into a field of nops, so patching one byte per block moves a read
by one M-cycle. Sweeping past the shipped sixteen rungs turns a single odd cell
into a staircase with a visible edge, and running it on all six revisions shows
which revisions move that edge. `GbQuirks.pcm_read_edge_zero` and
`GbQuirks.square_freq_backstep_halftick` were both derived this way; see
docs/gb-failure-triage.md, "SameSuite APU is 70/70".

## The one caveat, and it is not the usual one

SameBoy has no skip-boot API, so `sameboy_ssdump` plays the boot ROM while
dingbat skips it. For these ROMs that is **not** a constant time offset: it
leaves the two on different APU tick phases at the moment the test starts, which
on `channel_1_duty` shifts SameBoy's whole staircase two cells. Compare
**verdicts** (`ssgrid.py`), or compare a ladder **differentially** (`ssladder.py`
— patch the ROM and ask whether the answer moves the way the model predicts).
A raw buffer mismatch is not evidence of a behavioural disagreement.
