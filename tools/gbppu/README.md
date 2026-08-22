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

    tools/gbppu/cgbsweep.sh scy2 /tmp/g_base.txt -d:CGB_SCY_LATENCY=2

One build and one whole-suite score per setting of the `CGB_*_LATENCY`
constants (see `CGB_WX_LATENCY` in `gb/gb.nim`), printing only the
subdirectories that moved against a baseline row file. Every constant is
forced to 0 first, so the flags on the command line are the whole setting and
`tools/gbppu/cgbsweep.sh zero <baseline>` is the control — it must reproduce
the baseline row for row, which is what says the mechanism is free when it is
off. ~40 s per cell.

Score the mealybug CGB rows for the same build in the same loop — the two
instruments disagree about SCY, and only reading both says why:

    MBROOT=$DINGBAT_ROM_CACHE/game-boy-test-roms/mealybug-tearoom-tests/ppu \
      python3 tools/gbppu/mbscore.py ./dingbat_test cgb

## Reading an m3_* frame as eighteen measurements, not one

A mealybug `m3_*` ROM's OAM table is `Y = 16 + 8k, X = k`, so each 8-line band
of the reference carries one object whose X advances down the screen — and the
object is the RULER, not scenery (`m3_scy_change2.asm`: "Sprites are positioned
to cause the write to occur on different T-cycles of the background tile
fetch"). A whole-frame percentage averages eighteen different measurements of
the fetch phase together, which is exactly how a wrong constant gets fitted.
Score per band instead, and read the bands whose object has no OBJ wait term
first — those are the ones where the ruler is clean.

The decode that makes a band quantitative needs no oracle but the ROM:

1. Copy the ROM with its mid-mode-3 register writes NOPped out and screenshot
   it. That frame is the tile map at the register's power-on value, i.e. a
   glyph table indexed by (tile, row).
2. `-d:gb_m3_trace -d:GB_TRACE_LY=-1` prints, for every line, the dot each
   write landed on and the dot of each of the fetcher's three VRAM reads
   (`OBJTRIG` adds the object trigger and its penalty terms).
3. Predict the frame from those two, shift the read dots by delta, and score
   against the reference. The delta that fits is the phase error in dots, per
   band, with a resolution of 2 dots (the spacing of the fetcher's reads).

That is how the OBJ-fetch phase residual at `tick_sprite_fetcher` was measured
and how `CGB_SCY_LATENCY` was separated from it.

## The OBJ penalty table, in dots, against hardware

    nim c -d:test_harness -d:release -d:gb_m3_len --path:src \
      -o:dt_m3len tests/dingbat_test.nim
    python3 tools/gbppu/objtab.py ./dt_m3len

`ppu_spritex_vs_scx.gb` is 153 cells of "how many dots does one object at OAM X
cost at this SCX", two assertions each, and the runner cannot score it: it never
writes `$FF82`, it stops at the first failing assertion, and it reports by
storing `$55`/`$FF` into VRAM `$8000` in a loop — so on screen it is eighteen
black lines and says nothing about WHICH cell failed. `objtab.py` gets the whole
table out instead, by patching a sibling ROM's OAM/SCX prologue and reading
line 0's mode-3 length out of `-d:gb_m3_len`. It differences against the same
build's no-object line, so the constant offset the mode-3 edge carries cancels
and only the per-object cost is compared — which matters, because that offset is
real and separate (GBMicrotest's `ppu_sprite0_scx*` rows have NO object in OAM
at all — `load_sprite 0 0 0 0 0` puts it at Y = 0, off the top — and they put
this tree's mode-0 STAT flag 3 dots late on their own).

Exit status is nonzero if any cell disagrees. This is the instrument that
settled the OBJ fetch phase; a whole-frame mealybug percentage cannot, because
it averages eighteen different measurements together.

### The RIGHT edge of that table, which `objtab.py` never reached

    python3 tools/gbppu/objtab2.py ./dt_m3len 140 172

`ppu_spritex_vs_scx` sweeps OAM X = 0..16 only, so X = 17..167 was scored by
nothing. `objtab2.py` is the same measurement over any X range, against Pan
Docs' own periodic formula. It found the table exact from X = 140 to X = 166 and
**one dot long at X = 167 on all nine SCX** — the object whose trigger pixel is
the LAST one, which is the only thing that can make the shifter walk past
`m3_retire_lx` and so get charged for the tail burst twice. See
`OBJ_TAIL_WALK_REFUND` in `fifo_ppu.nim`.

## wilbertpol's sprite ROMs at cell resolution

    ./dt_m3len <rom> --mode screenshot --frames 140 --screenshot /dev/null \
      --dmg --nosave 2>&1 | grep -E '^M3(IN|LEN)' > /tmp/m3.log
    python3 tools/gbppu/wpsprites.py <rom> /tmp/m3.log <scx>

`intr_2_mode0_timing_sprites{,_nops,_scx1..4_nops}` are ~129 independent
measurements each — an OAM list of 1..10 objects, a fixed SCX, and a nop sled
tuned so mode 0 arrives on the first STAT poll and not the second — and the ROM
stops at the first failing one and prints its index **in hex**. `wpsprites.py`
reads the whole table out of the ROM and crosses it against an `M3IN`/`M3LEN`
log keyed on the object-X list, fitting the nops-to-dots offset once over the
table and scoring every cell against the 4-dot bracket it implies. That turned
one boolean into 129 datapoints and left exactly one disagreeing cell.

## The halted mode-0 wake, bracketed to the M-cycle per SCX

    python3 tools/gbppu/hbprobe.py <hblank_ly_scx_timing-C.gb> <scx> <N> out.gb

`hblank_ly_scx_timing-{C,GS}` halt with only the mode-0 STAT source armed, wake,
burn a fixed sled and read LY — 32 fixed yes/no questions that stop at the first
miss. `hbprobe.py` keeps the ROM's own sync/halt path and failure dump and
replaces the body with ONE cell: one SCX, one sled length `N`, always dump. So
sweeping `N` reads the LY-increment boundary directly, and the DMG and CGB grids
become two comparable staircases instead of two pass/fail verdicts. Every arm is
a clean `k = K - floor((SCX + r) / 4)`, so the only free parameter is where in
the M-cycle the wake lands — which is what showed the mode-0 halt blind window
to be a DMG rule (`M0_HALT_BLIND_DOTS` / `CGB_M0_HALT_BLIND_DOTS` in `ppu.nim`).

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

## Where an interrupt flag was set, and where the CPU read it

`-d:gb_stat_read_trace` says when a STAT source rose, `-d:gb_irq_trace` when the
CPU vectored off one, and `-d:gb_if_trace` — the third leg — one `IFREAD` line
per CPU read of `$FF0F`, with the PPU dot and the byte. Together they turn a
gambatte `_ifw` / `_late_retrigger` / `lcdirq_precedence` row into three dots on
one line: the edge, the dispatch, and the read the ROM scores. That is how
`IRQ_SAMPLE_T` (`gb/cpu.nim`) was bracketed, and how the `ly0` rows were shown
NOT to be that constant.

## The dot a halt ended on

    nim c -d:test_harness -d:release -d:gb_halt_trace --path:src \
      -o:dt_halt tests/dingbat_test.nim

`-d:gb_halt_trace` prints one `HALTWAKE` line per halt EXIT — the LY, the PPU
dot, the mode, `IF` and `IME`. It is the fourth leg of the group above and the
one none of the other three report: `gb_irq_trace` prints the *dispatch*, which
the `IME = 0` members of gambatte's `halt/` families never reach, and a halt
that ends without vectoring leaves no other mark at all.

Every `halt/` row's expected value is a function of that dot plus a fixed number
of M-cycles, so printing it turns the family into an equation. It is also what
identifies which ROMs are *anchored* to a halt without looking like it:
`strikethrough` takes one wake a frame at LY 67 and daid's
`speed_switch_timing_{ly,stat}` take exactly one each in the whole run, at
LY 144 — in both cases the entire frame's phase hangs off that single line of
output, which is why they move when nothing else does. `CGB_HALT_PPU_LEAD`
(`gb/gb.nim`) and the halt paragraph at `SPEED_SWITCH_STALL_T` (`gb/memory.nim`)
were both measured with it.

## Reading a STAT-bracketed row

The gambatte `*_m3stat_{1,2}` pairs differ by exactly one NOP, so they bracket
the end of mode 3 to one M-cycle — but the verdict also goes through the STAT
read model. Pair `-d:gb_m3_len` with `-d:gb_stat_read_trace` to get the read's
`cycle_counter` next to the line's mode-3 length; the row then says which dot
the boundary has to fall on, independent of how STAT reports it.

**This paragraph used to end by saying that separation showed the residual
`sprites` failures to be the STAT-read lag rather than the OBJ penalty. That
claim is FALSE and was measured out on 2026-08-03.** One build per cell, whole
suite: `sprites` scores **393 at `STAT_READ_LAG=3` (shipping), 354 at 2 and 245
at 4** — a strict local maximum, pinned hard from both sides, so no value of L
recovers any of its 83 failing rows. `vram_m3` (35) and `oam_access` (52) do not
move by a single row at any L either.

The OBJ penalty is not the cause either, and that half was checked the same day:
in `sprites/NspritesPrLine_m3stat` every object sits at `(X + SCX) mod 8 == 0`,
`-d:gb_m3_len` gives `len = 172 + 11N` exactly (Pan Docs' `6 + max(0, 5 - 0)`),
and the two alternatives that move the family's per-N pass set — `OBJ_WAIT_SUB=2`
and `OBJ_FETCH_DOTS=7`, which produce byte-identical tables — are refused by
hardware: `objtab.py` against `ppu_spritex_vs_scx` is 0/153 shipping and 99/153
at `OBJ_WAIT_SUB=4`.

With both excluded, what is left is a **constant sub-M-cycle error in the
mode 3 → 0 edge as the CPU reads it back**, which is a third independent witness
for the same 2 dots that `M3_END_EARLY`, `LCD_ON_HEAD_START` and
`LCD_ON_LINE0_TRIM` are each refused for. See `docs/gb-failure-triage.md`.

## Mealybug as a dot ruler

    python3 tools/gbppu/mbscore.py [./dingbat_test] [dmg|cgb]   # per-row %,
                                             # same comparison as the runner
    python3 tools/gbppu/mbshift.py m3_scy_change        # per-line best shift
    python3 tools/gbppu/mbperx.py m3_scy_change ./dt_m3len

A mid-mode-3 write lands at a pixel column, so a wrong penalty is a horizontal
shift of that line. `mbscore.py`'s second argument picks the device: `cgb` runs
the same DMG carts on CGB hardware against the suite's own `_cgb_c` references,
which is DMG-compatibility mode and the tree's only mid-mode-3 CGB oracle
outside gambatte — it is what brackets the `CGB_*_LATENCY` constants from a
second direction (see the sweep table at `CGB_SCY_LATENCY` in `gb/gb.nim`).
`mbshift.py` reports the shift that best aligns each line;
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
in the dot even when the two look one step apart. Re-run it if the FETCHER's
phase moves too — moving the post-push idle from the head of the cycle to the
tail (2026-08-03) took the answer from 5 to 7, and at 7 all three ROMs are
pixel-exact where 5 never got any of them there.

## blargg canary

    tools/gbppu/blargg_canary.sh [<dingbat_test>] [<sameboy_runner>] [<bootdir>]

All eleven `blargg/cpu_instrs` frames against SameBoy at frame 1200, real CGB
boot ROM both sides. `tests/README.md` explains why this, and not a glyph
check, is the gate after a GB timing change. Needs `sameboy_runner` from
`tools/gbfuzz/build.sh` and a boot-ROM directory; neither is in the repo.

## The speed-switch pixel gate

    tools/gbppu/daidswitch.sh [<dingbat_test>]

daid's `speed_switch_timing_{div,ly,stat}` and both `strikethrough` frames as
wrong-pixel counts, ~20 s, against any binary. Those five are the pixel witnesses
that gate every speed-switch or halt-phase change — the only ones in the tree
that see the PPU's advance across a KEY1 switch, and the row `CGB_HALT_PPU_LEAD`
is held back by — and they are otherwise reachable only through a full runner
pass. It uses `pngdiff.py` (reference PNG vs `--screenshot` PPM, masked to 0xF8
per channel, pure stdlib), which is worth knowing about on its own for any
one-row screenshot comparison.

## One build per constant, scored

    tools/gbppu/sssweep.sh <outprefix> "<defines>" [subdir ...]
    tools/gbppu/sssweep.sh /tmp/x/a8 "-d:SPEED_SWITCH_PPU_EXTRA_DOTS=8"
    tools/gbppu/sssweep.sh /tmp/x/full "" '*'          # the whole suite

Builds one `dingbat_test` per define set, shards it, and writes a row file in
`gamall.sh`'s exact shape, so `famflip.py` and the usual `diff <(cut -f1,2 ...)`
recipe read it unchanged. ~12 s per point for the four speed-switch
subdirectories (the default), ~25 s for all 5005 rows. Everything is keyed off
`<outprefix>` — binary included — so two sessions can sweep at once, which
`gamscore.sh`'s fixed `/tmp` paths do not allow.

This is the loop for a constant only a handful of families can see: score the
families, not the total. Bucket 13's two constants were derived this way after a
whole-subdirectory total called the same sweep "flat".

## Reading a gambatte ROM

    python3 tools/gbppu/sm83dis.py <rom> [start_hex] [len_hex]

Enough SM83 to read a test ROM's straight-line body — which for the
`speedchange` and `lcd_offset` families IS the specification: how many
`LDH ($4D),A ; STOP` switches, in which direction, and what sits between them.
`lcd_offset`'s `offsetN` numbering was read off this and is not what the name
suggests (`offset1` = 2 switches, `offset2` = 4, `offset3` = 2 plus a NOP).

## The bytes behind a pixel

    nim c -d:test_harness -d:release -d:gb_m3_trace -d:gb_px_trace \
      -d:GB_TRACE_LY=-1 --path:src -o:dt_px tests/dingbat_test.nim

`-d:gb_px_trace` prints one line per pipeline *event* rather than per dot: the
tile-map read (`FTILE`), each bitplane read with its address and byte
(`FDATA`), the eight pixels entering the BG FIFO with the `lx` they will show
at (`PUSH`), an object's two bitplane bytes as they are merged (`SPR`), and
every emitted pixel with the FIFO entries and LCDC behind it (`PX`). Pair it
with `-d:gb_m3_trace`, whose `LATCH` line marks the start of each line's mode 3
and whose `LCDC`/`SCX`/`SCY` lines give the dot each register write landed on.

That combination is what makes a one-pixel diff solvable. `PUSH` plus the
reference frame gives the bitplane bytes **hardware** used for a tile -- invert
the reference through the palette the trace names, and a wrong pixel becomes a
wrong byte with an address next to it. `PX` plus the write dots gives the value
the mixer read against the dot the pixel left the FIFO, which is how the
mixer's own dot (`fifo_recompose_last`) was measured off
`m3_lcdc_obj_en_change`, and how the `cgb-acid-hell` residual in
`docs/gb-failure-triage.md` was identified as a bitplane read returning the
tile index.

`FDATA` also carries one column per **candidate** byte the read could have
returned — `uns`/`sgn` (the two addressing modes' bytes for this tile, row and
plane), `latch` (what the SET-glitch rule delivers), `prevd`/`prevu` (the
previous bitplane read's data, and the previous `$8000`-region one). Together
those turn "which rule does hardware use" into an offline replay: parse the last
frame, invert the reference through the palette, and score every candidate over
every glitched read at once, with no rebuild between hypotheses.

## The TILE_SEL arbitration corpus

    python3 tools/gbppu/tdselcells.py ./dt_px

is that replay, packaged: it runs the four CGB `m3_lcdc_tile_sel*` references
and `cgb-acid-hell`, rebuilds one CELL per glitched bitplane read whose bits the
reference pins, and scores every candidate substitution source and every trigger
spelling over the whole set. It is the instrument behind `CGB_TDSEL_GLITCH` and
`CGB_TDSEL_IDX_DOTS` in `gb/gb.nim`, and the reason to run it before touching
either is that a whole-frame percentage cannot see the cells under an object or
in a flat palette — those are ~40% of the corpus and they are where the wrong
rules hide.

Read the **self-check** column first: for every plane the reference pins fully,
dingbat's own byte is compared with the reconstructed one, and on a passing tree
all five frames report 0. A nonzero count on the four mealybug frames means the
parser drifted (the `PUSH` `lx` is the first pixel's own `lx`, and a one-pixel
error there mis-scores the whole corpus silently); a nonzero count on
`cgb-acid-hell` alone is the row's residual and is what "2 wrong pixels" looks
like from this side.

It needs no VRAM dump and no palette table — the `PX` lines plus dingbat's own
framebuffer give each palette's four colours, which is what inverts the
reference PNG. A palette whose entries collide simply leaves those bits
unpinned.

### The offset table: what a change does when it does NOT land on a read

    python3 tools/gbppu/tdselphase.py ./dt_px

asks the prior question, over the same five frames. `tdselcells.py` starts from
a glitched read and asks *which byte* hardware substituted; this starts from
EVERY pinned bitplane read and asks *whether hardware disturbed it at all*,
bucketed by `delta = read dot - the dot the last LCDC.4 change went live` (the
`chg` column of `FDATA`) and by where that change fell inside the fetch cycle
(`mapoff`, counted from the tile-map read, so the tile-map slot is 0 and the two
bitplane slots are 2 and 4 when the fetcher runs at pitch).

It exists because `CGB_HALT_PPU_LEAD` moves `cgb-acid-hell`'s write burst by 4
dots — off the bitplane reads and into the map slot — and the shipping rules
then fire on nothing, so "what does a change in the map slot do" has to be
answered from the mealybug references, which sweep exactly that offset across
their bands. The answer is the 2026-08-14 entry in `docs/gb-failure-triage.md`:
of 6352 mealybug reads with a change on their line, hardware disturbs the ones
at `delta = 0` and no others.

Two things to know before reading its output. The **row count per bucket is
load-bearing**: an empty bucket means the corpus is silent about that offset,
which for some of them is the whole finding. And `cgb-acid-hell` carries 16
pinned reads (lines 136..143, one tile column) whose push-to-pixel attribution
is unsound and which report a mismatch on a frame that is pixel-exact — they are
at `mapoff = none`, nowhere near the mechanism, and they are why `tdselcells.py`
builds cells from glitched reads only.

`WINHIT` (under `-d:gb_m3_trace`) is the matching instrument for the window's
re-trigger: one line per dot the WX equality is reached, with the fetcher
position and FIFO depth that decide whether the edge survives it. A mealybug
`m3_wx_*` frame carries exactly one per line, so the whole frame reads out as a
table.

## The AGE suite, as a table of measurements rather than a bit

    ./dingbat_test <rom> --mode=screenshot --timeout=600 --nosave \
        [--dmg|--cgb] [--model=<tok>] --screenshot=/tmp/f.ppm
    python3 tools/gbppu/agetable.py /tmp/f.ppm      # which cells disagree
    python3 tools/gbppu/agecells.py /tmp/f.ppm      # + the values, decoded
    python3 tools/gbppu/agediff.py <rom> /tmp/f.ppm # + what hardware wanted

c-sp's AGE ROMs are scored through the mooneye protocol, which collapses each to
one bit — and 50 of the 89 rows report that bit as `FAIL`, which is why the suite
sat unread. But every AGE ROM **draws its own result**: a `TEST FAILED!` banner
over a table of bytes, one row per eight, each disagreeing cell drawn inverted.

**A cell is not a measurement, it is the INDEX OF THE FIRST MISMATCHING BYTE in a
run of them** (`compact_results` in the suite's `src/_include/utilities.inc`:
`$FF` if all N matched, else the index of the first that did not). N is the ROM's
`BYTES_PER_LINE` — 12 for `stat-mode`, `oam-*` and `vram-*`, 8 for
`stat-mode-window` — and each of those N is a named sample in the ROM's own
`EXPECTED_*` table ("read at the edge of line 1 mode 0", "line 152/153"). So a
failing cell already says *which* timed sample went wrong, and the neighbouring
cells bracket it to the M-cycle. A handful of ROMs (`ly`, `lcd-align-ly`,
`halt-m0-interrupt`) skip the compaction and print the raw measurements.

`agetable.py` needs no font: it reads the inversion from each cell's background
shade. `agecells.py` adds the values (5x7 glyph boxes at a fixed pitch; the font
is pinned in the file and the offset-label column doubles as a training set).
`agediff.py` adds the expected value, which is **in the ROM** — the array is the
only run of `len(table)` bytes that agrees with every non-inverted cell and
differs at every inverted one, which pins it uniquely on 45 of the 50 failing
arms.

Two things this changes. It turns 50 bits into ~620 datapoints, so a constant
sweep can be scored on AGE at cell resolution — the five-constant DMG STAT
re-spelling is "AGE unmoved" at pass/fail and **+42 cells with zero regressions**
here. And it makes the suite's paired `-cgbBC` / `-cgbE` ROMs readable as what
they are: the same measurement with two expected tables, one per silicon family.

Clone `github.com/c-sp/age-test-roms` for the sources — every ROM is a few dozen
lines of RGBDS with the devices it was verified on in a header comment.

## Asking SameBoy a GBMicrotest question — the oracle reaches further than it looks

    export SAMEBOY_GAMBATTE=~/code/dingbat/tools/gbfuzz/sameboy_gambatte
    export SAMEBOY_BOOT=<dir with dmg_boot.bin / cgb_boot.bin>

    python3 tools/gbppu/gam_dispatch.py 0    dmg          # line 0 after LCD-on
    python3 tools/gbppu/gam_dispatch.py 1140 dmg          # the steady state
    python3 tools/gbppu/gam_haltwake.py 0    dmg          # halted vs running
    python3 tools/gbppu/gam_sled.py 42 52 0,1,2,3,4,5,6,7 cgb stat,vram

`tools/gbfuzz/sameboy_gambatte` decodes the hex a gambatte ROM draws on screen,
so SameBoy can score any ROM in *that* format — and the gambatte ROMs are
mostly NOP padding with a `wait for LY == B` helper at `$7400` and the printer
at `$7000`, which makes any one of them a blank program with a known output
path. `gam_patchrun.py` overwrites the body, re-checksums the header and runs
the result through both emulators.

**If you are looking at a GBMicrotest row and have been told it "has no
oracle", this is the section you need.** GBMicrotest asks exactly the right
questions and answers them in `$FF80`, which no SameBoy runner in this tree
reads — so the round-brief oracle tables, which are built from the gambatte
suite, simply do not cover it. That is a property of the HARNESS, not of the
oracle: rebuild the ROM's measurement in gambatte's output format and SameBoy
answers it like any other row.

Verified by reproducing GBMicrotest's own hardware staircases exactly:
`gam_dispatch.py 0 dmg` prints `29 2A 2A 2A 2A 2B 2B 2B` (steps at SCX 1 and 5,
the shape of `int_hblank_nops_scx0..7`) and SameBoy at `W=114` prints
`29 29 29 2A 2A 2A 2A 2B` (steps at 3 and 7, the shape of `hblank_int_scx0..7`).
Two ROM families, two hardware answers, both reproduced from a gambatte ROM
body — so the oracle can now be pointed at anything GBMicrotest measures.

The three instruments:

* `gam_dispatch.py` — INC A until the mode-0 STAT interrupt **dispatches**,
  swept over SCX 0..7, N lines after an LCD enable. The step positions in SCX
  locate the edge to the dot (a staircase that steps two SCX later is an edge
  two dots later).
* `gam_haltwake.py` — the same wake taken by a **halted** CPU against a running
  one, differentially: two programs identical apart from `$76` versus a NOP
  sled, both printing TIMA from one handler.
* `gam_sled.py` — one register read (IF / STAT / VRAM / OAM / LY) at an exact
  M-cycle offset, for the boundaries that are not interrupts.

What they measured (2026-08-21, on `65bcb71`, both devices, all eight SCX):

|            | first line after an LCD enable | every later line |
|------------|--------------------------------|------------------|
| running    | exact                          | 2 dots LATE      |
| halted     | 2 dots EARLY                   | exact            |

Two independent 2-dot errors that cancel in the halted steady state — which is
where mooneye `hblank_ly_scx_timing-GS` and the gambatte `halt/*_m0stat_*`
families live, and why fixing either alone has always reddened the other. The
full write-up, and which of the two is built, is at `M0_HALT_BLIND_DOTS` in
`src/dingbat/gb/ppu.nim`.

**The oracle's caveat still applies** (see the round brief): SameBoy plays the
boot ROM where dingbat skips it, so absolute phase can differ by an M-cycle.
Everything above is immune to that because every ROM here re-anchors on its own
`LDH ($40),A` LCD enable, which restarts the PPU in both emulators.
