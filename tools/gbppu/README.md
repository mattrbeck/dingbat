# gbppu — measurement kit for the GB mode-3 pipeline

Small instruments for the mid-scanline-timing suites, split out of the runner
so a single family can be scored in seconds instead of a whole suite pass.
None of them is a correctness oracle on its own; each turns a pass/fail row
into a **dot count**, which is what makes these families solvable.

Everything here assumes `nimble test_build` has been run from the repo root and
that `$DINGBAT_ROM_CACHE` (default `/tmp/dingbat-test-roms`) is populated.

## Scoring one gambatte subdirectory

    tools/gbppu/gamscore.sh sprites
    tools/gbppu/gamscore.sh bgtiledata bgtilemap scy

`gamlist.py` builds the `--list=` TSV the batched `--mode=gambatte` harness
takes, mirroring `build_gambatte_rows` in `tests/dingbat_test_runner.nim`
(device tags, `_out<hex>`, `x`-prefixed skips, reference PNGs). Per-row
verdicts land in `/tmp/gamout.txt`. This does **not** touch
`tests/results*.md`, so it is safe to run while iterating.

## Scoring the whole gambatte suite (~6 s)

    tools/gbppu/gamall.sh /tmp/g_before      # on main
    tools/gbppu/gamall.sh /tmp/g_after       # with the change
    diff <(cut -f1,2 /tmp/g_before.txt) <(cut -f1,2 /tmp/g_after.txt)

Sharded across processes like the runner does, one pass count per
subdirectory plus a per-row file. Scoring one family with `gamscore.sh` says
whether a change worked; this says what *else* it moved, which for a
mid-scanline change is the question that actually decides it.

## A family's flip point, per device

    python3 tools/gbppu/famflip.py /tmp/g_base.txt 'window/late_disable*'

Collapses a `gamall.sh` row file into one line per family per device: the
expected sequence over the family's `_1/_2/_3…` steps, what this build
produced, and where they differ. A step is one CPU M-cycle, so the step the
EXPECTED value flips on is the measurement and the step dingbat's flips on is
the error — in M-cycles, with the DMG and CGB rows side by side. That side-by
side is the point: a family whose two devices flip on different steps is one
of the ~42 `window` ROMs with genuinely per-model behaviour, and the sign of
the difference says which way the model has to move.

## Sweeping the CGB write latencies

    tools/gbppu/cgbsweep.sh scx2 /tmp/g_base.txt -d:CGB_SCROLL_LATENCY=2

One build and one whole-suite score per setting of the `CGB_*_LATENCY`
constants (see `CGB_WX_LATENCY` in `gb/gb.nim`), printing only the
subdirectories that moved against a baseline row file. Every constant is
forced to 0 first, so the flags on the command line are the whole setting and
`tools/gbppu/cgbsweep.sh zero <baseline>` is the control — it must reproduce
the baseline row for row, which is what says the mechanism is free when it is
off. ~40 s per cell.

## GBMicrotest without a runner pass

    tools/gbppu/mtscore.sh win

The `win0_a/_b` .. `win15_b` pairs bracket the end of mode 3 per WX, so they
are the mode-3-length half of a window change where gambatte's families are
the register-sampling half. The two disagree by about one dot at present (see
the fetch-phase note in `fifo_ppu.nim`), so score both before concluding.

## Which dot a window family's write lands on

    nim c -d:test_harness -d:release -d:gb_win_trace --path:src \
      -o:dt_win tests/dingbat_test.nim
    DT=./dt_win python3 tools/gbppu/windot.py 'window/arg/late_wy_FFto2_ly2_*'

`-d:gb_win_trace` prints every WY/WX/LCDC write with the line and the dot
inside it, plus each window start (`WINSTART`), each per-frame WY latch
(`WYLATCH`, the `LY == WY` level at the top of a line) and each mode 3 end.
`windot.py` puts that next to the filename's expected value per device.
Running one ROM under both devices and diffing the trace is how a window row
that differs per model gets attributed: if the write dot and the window-start
dot are the same on both, whatever decides the row is NOT in this file. (That
is the case for `window/arg/late_wy_FFto2_ly2_3`, where both devices write WY
on dot 93 of line 2 and start the window on dot 92 — the two runs diverge a
whole frame earlier, in how long the ROM's vblank wait takes.)
A gambatte window family is
one ROM with one write moved by one M-cycle, so seeing the dot turns the family
into an equation for the dot the PPU samples that register on — that is how
`83 + WX + (SCX and 7)` fell out of the `late_wy_*` families and placed the
window-start equality.

## Mode-3 length against Pan Docs

    nim c -d:test_harness -d:release -d:gb_m3_len --path:src \
      -o:dt_m3len tests/dingbat_test.nim
    tools/gbppu/m3sweep.sh dmg <rom.gbc>...

`-d:gb_m3_len` prints, per drawn scanline, the inputs Pan Docs' "Mode 3 length"
section says decide the duration (SCX, WX/WY, LCDC, the OBJ X list in fetch
order) and the measured duration. `m3oracle.py` re-computes it from the rules —
SCX%8, the 6-dot window setup, and the OBJ penalty algorithm — and prints the
delta, so a family reports its own error in dots rather than a verdict.
`objsweep.sh` sweeps the two OBJ-penalty terms against a gambatte subdirectory,
which is how those two constants were pinned.

## Reading a STAT-bracketed row

The gambatte `*_m3stat_{1,2}` pairs differ by exactly one NOP, so they bracket
the end of mode 3 to one M-cycle — but the verdict also goes through the STAT
read model. Pair `-d:gb_m3_len` with `-d:gb_stat_read_trace` to get the read's
`cycle_counter` next to the line's mode-3 length; the row then says which dot
the boundary has to fall on, independent of how STAT reports it. That
separation is what showed the residual `sprites` failures to be the STAT-read
lag (see `STAT_MODE_HOLD` in `src/dingbat/gb/ppu.nim`) and not the OBJ penalty.

## Mealybug as a dot ruler

    python3 tools/gbppu/mbscore.py [./dingbat_test]     # per-row %, same
                                                        # comparison as the runner
    python3 tools/gbppu/mbshift.py m3_scy_change        # per-line best shift
    python3 tools/gbppu/mbperx.py m3_scy_change ./dt_m3len

A mid-mode-3 write lands at a pixel column, so a wrong penalty is a horizontal
shift of that line. `mbshift.py` reports the shift that best aligns each line;
`mbperx.py` puts the line's OBJ list next to it, which matters because the
`m3_*` ROMs sweep the object's OAM X down the screen — one reference frame is a
staircase over X. Caveat: BGP/OBP are applied at the shifter and their write
phase carries its own residual (`m3_bgp_change` has no objects at all and is
87.3%), so read the LCDC/SCY rows, not the palette ones, when measuring the
fetcher.

## Retired instructions, not fps

    tools/gbgate/build.sh <ref-A> <ref-B> /tmp/gb_ab
    tools/gbppu/counters.sh /tmp/gb_ab <rom.gb>

Wraps `DINGBAT_BENCH_COUNTERS=1` around both slots of a `tools/gbgate` build
pair. `docs/gb_oam_dma_cost.md` is the authority: fps has a ~1.3% layout noise
floor and cannot resolve a change to this path, `cycles=` must match between
the arms or they did different work, and per-function sizes should be diffed
before believing a result. The mode 3 dot loop is tight enough that ONE extra
branch in `tick_shifter` is +1.7% — check any window/fetcher change here.

**Check the build's exit code.** `nim c` failing leaves the previous binary in
place, and a stale slot B reports the previous revision's numbers, which look
like a real result.

## Sweeping WIN_REACT_PHASE

    tools/gbppu/reactsweep.sh

Rebuilds `-d:WIN_REACT_PHASE=0..7` and scores the mealybug rows that see the
window's re-trigger edge, which is how that constant was pinned. Re-run it if
the shifter's window rules move dots: the fetcher does not advance one step per
dot (it parks on `fsPushPixel`), so a phase is not portable between two points
in the dot even when the two look one step apart.

## blargg canary

    tools/gbppu/blargg_canary.sh [<dingbat_test>] [<sameboy_runner>] [<bootdir>]

All eleven `blargg/cpu_instrs` frames against SameBoy at frame 1200, real CGB
boot ROM both sides. `tests/README.md` explains why this, and not a glyph
check, is the gate after a GB timing change. Needs `sameboy_runner` from
`tools/gbfuzz/build.sh` and a boot-ROM directory; neither is in the repo.
