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

## blargg canary

    tools/gbppu/blargg_canary.sh [<dingbat_test>] [<sameboy_runner>] [<bootdir>]

All eleven `blargg/cpu_instrs` frames against SameBoy at frame 1200, real CGB
boot ROM both sides. `tests/README.md` explains why this, and not a glyph
check, is the gate after a GB timing change. Needs `sameboy_runner` from
`tools/gbfuzz/build.sh` and a boot-ROM directory; neither is in the repo.
