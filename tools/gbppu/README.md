# gbppu — measurement kit for the GB mode-3 pipeline

Instruments for the mid-scanline-timing suites, so one family can be scored in seconds
and a pass/fail row becomes a dot count. None is a correctness oracle on its own.

Assumes `nimble test_build` from the repo root and a populated `$DINGBAT_ROM_CACHE`
(default `/tmp/dingbat-test-roms`). Trace builds below are
`nim c -d:test_harness -d:release --path:src -d:<flag> -o:<bin> tests/dingbat_test.nim`.

## Scoring gambatte

    tools/gbppu/gamscore.sh sprites              # one or more subdirectories; rows in /tmp/gamout.txt
    tools/gbppu/gamall.sh /tmp/g_before           # whole suite, sharded, ~6 s
    diff <(cut -f1,2 /tmp/g_before.txt) <(cut -f1,2 /tmp/g_after.txt)

`gamlist.py` builds the `--list=` TSV the batched `--mode=gambatte` harness takes,
mirroring `build_gambatte_rows` in `tests/dingbat_test_runner.nim`. Neither touches
`tests/results*.md`. Score one family to see whether a change worked; score the whole
suite to see what else it moved.

    python3 tools/gbppu/famflip.py /tmp/g_base.txt 'window/late_disable*'

One line per family per device: the expected sequence over the `_1/_2/_3…` steps, what
this build produced, and where they differ. A step is one CPU M-cycle, so the difference
is the error in M-cycles, DMG and CGB side by side; a family whose devices flip on
different steps has genuinely per-model behaviour.

    tools/gbppu/sssweep.sh <outprefix> "<defines>" [subdir ...]   # one build per define set
    tools/gbppu/cgbsweep.sh scy2 /tmp/g_base.txt -d:CGB_SCY_LATENCY=2
    tools/gbppu/cgbsweep.sh zero <baseline>                        # control: must reproduce the baseline

`sssweep.sh` writes a row file in `gamall.sh`'s shape (~12 s for the four speed-switch
subdirectories, ~25 s for all 5005 rows), keyed off `<outprefix>` so two sessions can
sweep at once. `cgbsweep.sh` forces every `CGB_*_LATENCY` constant (see `CGB_WX_LATENCY`
in `gb/gb.nim`) to 0 first, so the flags on the line are the whole setting, and prints
only the subdirectories that moved. Score mealybug's CGB rows in the same loop; the two
instruments disagree about SCY and only both say why:

    MBROOT=$DINGBAT_ROM_CACHE/game-boy-test-roms/mealybug-tearoom-tests/ppu \
      python3 tools/gbppu/mbscore.py ./dingbat_test cgb

## Mealybug as a dot ruler

    python3 tools/gbppu/mbscore.py [./dingbat_test] [dmg|cgb]   # per-row %, the runner's comparison
    python3 tools/gbppu/mbshift.py m3_scy_change               # per-line best horizontal shift
    python3 tools/gbppu/mbperx.py m3_scy_change ./dt_m3len     # + each line's OBJ list

A mid-mode-3 write lands at a pixel column, so a wrong penalty is a horizontal shift of
that line. `cgb` runs the DMG carts on CGB hardware against the `_cgb_c` references
(DMG-compatibility mode), which brackets the `CGB_*_LATENCY` constants from a second
direction. BGP/OBP are applied at the shifter and carry their own write-phase residual, so
read the LCDC/SCY rows, not the palette ones, when measuring the fetcher.

An `m3_*` ROM's OAM table is `Y = 16 + 8k, X = k`: each 8-line band carries one object
whose X advances down the screen, and the object is the ruler (`m3_scy_change2.asm`:
"Sprites are positioned to cause the write to occur on different T-cycles of the
background tile fetch"). A whole-frame percentage averages eighteen measurements; score
per band, and read the bands whose object has no OBJ wait term first. To make a band
quantitative with no oracle but the ROM: NOP out the mid-mode-3 writes and screenshot
(the tile map at the register's power-on value, a glyph table indexed by tile and row);
`-d:gb_m3_trace -d:GB_TRACE_LY=-1` prints the dot each write landed on and the dots of
the fetcher's three VRAM reads; predict the frame, shift the read dots by delta, score
against the reference. Resolution is 2 dots (the spacing of the fetcher's reads).

## Mode-3 length and the OBJ penalty

    nim c ... -d:gb_m3_len -o:dt_m3len tests/dingbat_test.nim
    tools/gbppu/m3sweep.sh dmg <rom.gbc>...
    python3 tools/gbppu/objtab.py ./dt_m3len          # GBMicrotest ppu_spritex_vs_scx, 153 cells
    python3 tools/gbppu/objtab2.py ./dt_m3len 140 172 # the same over any OAM X range

`-d:gb_m3_len` prints, per drawn scanline, the inputs Pan Docs' "Mode 3 length" names
(SCX, WX/WY, LCDC, the OBJ X list in fetch order) and the measured duration. `m3oracle.py`
re-computes it from the rules and prints the delta; `objsweep.sh` sweeps the two
OBJ-penalty terms against a gambatte subdirectory.

`ppu_spritex_vs_scx.gb` is 153 cells of "how many dots does one object at OAM X cost at
this SCX", which the runner cannot score (it never writes `$FF82` and stops at the first
failing assertion). `objtab.py` patches a sibling ROM's OAM/SCX prologue and reads line 0's
mode-3 length, differenced against the same build's no-object line so the constant
mode-3-edge offset cancels. Nonzero exit if any cell disagrees. `objtab2.py` covers
X = 17..167 against Pan Docs' periodic formula; X = 167 is the one object whose trigger
pixel is the last, the only case that can walk the shifter past `m3_retire_lx`
(`OBJ_TAIL_WALK_REFUND` in `fifo_ppu.nim`).

`STAT_READ_LAG` is a strict local maximum at its shipping value for `sprites` (both
neighbours lose rows; `vram_m3` and `oam_access` do not move at any value), and the two
OBJ-penalty alternatives that move `NspritesPrLine_m3stat` are refused by `objtab.py`.
What remains in those families is a sub-M-cycle error in the mode 3 → 0 edge as the CPU
reads it (`docs/gb-failure-triage.md`).

    ./dt_m3len <rom> --mode screenshot --frames 140 --screenshot /dev/null --dmg --nosave 2>&1 \
      | grep -E '^M3(IN|LEN)' > /tmp/m3.log
    python3 tools/gbppu/wpsprites.py <rom> /tmp/m3.log <scx>

wilbertpol's `intr_2_mode0_timing_sprites{,_nops,_scx1..4_nops}` are ~129 measurements
each (an OAM list, a fixed SCX, a nop sled) and stop at the first failing index.
`wpsprites.py` reads the whole table out of the ROM, crosses it with an `M3IN`/`M3LEN` log,
fits the nops-to-dots offset once, and scores every cell against its 4-dot bracket.

## Halt wake and the mode-0 edge

    python3 tools/gbppu/hbprobe.py <hblank_ly_scx_timing-C.gb> <scx> <N> out.gb

`hblank_ly_scx_timing-{C,GS}` halt with only the mode-0 STAT source armed, wake, burn a
sled and read LY — 32 yes/no questions. `hbprobe.py` keeps the ROM's sync/halt path and
replaces the body with one cell (one SCX, one sled length `N`, always dump), so sweeping
`N` reads the LY-increment boundary directly on both devices. Every arm is
`k = K - floor((SCX + r) / 4)`, so the only free parameter is where in the M-cycle the
wake lands (`M0_HALT_BLIND_DOTS` / `CGB_M0_HALT_BLIND_DOTS` in `ppu.nim`).

    nim c ... -d:gb_halt_trace -o:dt_halt tests/dingbat_test.nim

`HALTWAKE` lines: LY, dot, mode, `IF`, `IME` at every halt exit — the one thing
`gb_irq_trace` (dispatch) cannot show for the `IME = 0` members of gambatte's `halt/`
families. It also identifies ROMs anchored to a single halt: `strikethrough` takes one
wake a frame at LY 67, daid's `speed_switch_timing_{ly,stat}` one each at LY 144.
`CGB_HALT_PPU_LEAD` (`gb/gb.nim`) and `SPEED_SWITCH_STALL_T` (`gb/memory.nim`) were
measured with it.

    tools/gbppu/daidswitch.sh [<dingbat_test>]

daid's `speed_switch_timing_{div,ly,stat}` and both `strikethrough` frames as wrong-pixel
counts, ~20 s — the pixel witnesses for any speed-switch or halt-phase change. Uses
`pngdiff.py` (reference PNG vs `--screenshot` PPM, masked to 0xF8 per channel), useful on
its own for any one-row comparison.

## Windows

    tools/gbppu/mtscore.sh win                                    # GBMicrotest win0_a/_b .. win15_b
    nim c ... -d:gb_win_trace -o:dt_win tests/dingbat_test.nim
    DT=./dt_win python3 tools/gbppu/windot.py 'window/arg/late_wy_FFto2_ly2_*'
    tools/gbppu/reactsweep.sh                                      # WIN_REACT_PHASE 0..7

The `win*_a/_b` pairs bracket the end of mode 3 per WX (the mode-3-length half of a
window change; gambatte's families are the register-sampling half). `-d:gb_win_trace`
prints every WY/WX/LCDC write with its line and dot, each `WINSTART`, each per-frame
`WYLATCH` and each mode-3 end; `windot.py` puts that beside the filename's expected value
per device. If the write dot and the window-start dot match on both devices, whatever
decides the row is not in this file (`late_wy_FFto2_ly2_3` diverges a frame earlier, in
the ROM's vblank wait). A gambatte window family is one write moved one M-cycle at a time,
so the dot turns the family into an equation for the sampling dot — that is how
`83 + WX + (SCX and 7)` fell out of `late_wy_*`. `reactsweep.sh` re-pins
`WIN_REACT_PHASE` against the mealybug rows that see the window's re-trigger edge; re-run
it whenever the shifter's window rules or the fetcher's phase move, because the fetcher
parks on `fsPushPixel` and a phase is not portable between two points in the dot. `WINHIT`
(under `-d:gb_m3_trace`) prints one line per dot the WX equality is reached, with fetcher
position and FIFO depth.

## Interrupt flags: set, dispatched, read

`-d:gb_stat_read_trace` (STAT source rose), `-d:gb_irq_trace` (CPU vectored),
`-d:gb_if_trace` (`IFREAD` per `$FF0F` read, with dot and byte) turn a gambatte `_ifw` /
`_late_retrigger` / `lcdirq_precedence` row into three dots on one line. That is how
`IRQ_SAMPLE_T` (`gb/cpu.nim`) was bracketed. For the `*_m3stat_{1,2}` pairs (one NOP
apart), pair `-d:gb_m3_len` with `-d:gb_stat_read_trace` to get the read's
`cycle_counter` beside the line's mode-3 length, independent of how STAT reports it.

## The bytes behind a pixel

    nim c ... -d:gb_m3_trace -d:gb_px_trace -d:GB_TRACE_LY=-1 -o:dt_px tests/dingbat_test.nim
    python3 tools/gbppu/tdselcells.py ./dt_px
    python3 tools/gbppu/tdselphase.py ./dt_px

`-d:gb_px_trace` prints one line per pipeline event: tile-map read (`FTILE`), each
bitplane read with address and byte (`FDATA`), the eight pixels entering the BG FIFO with
their `lx` (`PUSH`), an object's bitplanes as merged (`SPR`), every emitted pixel with the
FIFO entries and LCDC behind it (`PX`). With `-d:gb_m3_trace`'s `LATCH`/`LCDC`/`SCX`/`SCY`
lines, a one-pixel diff becomes a wrong byte with an address: invert the reference through
the palette the trace names. `FDATA` also carries every candidate byte a read could have
returned (`uns`/`sgn`, `latch`, `prevd`/`prevu`), so "which rule does hardware use" is an
offline replay with no rebuild between hypotheses.

`tdselcells.py` is that replay packaged over the four CGB `m3_lcdc_tile_sel*` references
and `cgb-acid-hell`: one cell per glitched bitplane read whose bits the reference pins,
every candidate substitution source and trigger spelling scored over the set. It is the
instrument behind `CGB_TDSEL_GLITCH` and `CGB_TDSEL_IDX_DOTS` (`gb/gb.nim`); ~40% of the
corpus is under an object or in a flat palette, invisible to a whole-frame percentage. Read
the self-check column first: nonzero on the mealybug frames means the parser drifted (the
`PUSH` `lx` is the first pixel's own `lx`); nonzero on `cgb-acid-hell` alone is the row's
residual. `tdselphase.py` asks the prior question — whether hardware disturbed a read at
all — bucketed by `delta = read dot − the dot the last LCDC.4 change went live` and by
where the change fell in the fetch cycle (`mapoff`). Empty buckets mean the corpus is
silent there; `cgb-acid-hell` carries 16 pinned reads at `mapoff = none` whose attribution
is unsound, which is why `tdselcells.py` builds cells from glitched reads only.

## AGE as a table of measurements

    ./dingbat_test <rom> --mode=screenshot --timeout=600 --nosave [--dmg|--cgb] [--model=<tok>] --screenshot=/tmp/f.ppm
    python3 tools/gbppu/agetable.py /tmp/f.ppm    # which cells disagree
    python3 tools/gbppu/agecells.py /tmp/f.ppm    # + the values
    python3 tools/gbppu/agediff.py <rom> /tmp/f.ppm  # + what hardware wanted

The mooneye protocol collapses each AGE ROM to one bit, but every AGE ROM draws its
result: a table of bytes with disagreeing cells inverted. A cell is the index of the first
mismatching byte in a run (`compact_results` in `src/_include/utilities.inc`; `$FF` if all
matched), the run being the ROM's `BYTES_PER_LINE` named samples from its `EXPECTED_*`
table, so a failing cell names which timed sample went wrong and its neighbours bracket it
to the M-cycle. `agediff.py` recovers the expected array from the ROM itself. Render with
`--mode=screenshot`, not `--bb-breakpoint` (which stops the ROM before it draws). Sources:
`github.com/c-sp/age-test-roms`.

Overwriting a ROM's expected array with candidate bytes makes it a 1-of-N readout of what
the emulator measured; fix the header checksum at `$014D` and nothing else.

## GBMicrotest questions through a gambatte ROM body

    export SAMEBOY_GAMBATTE=~/code/dingbat/tools/gbfuzz/sameboy_gambatte
    export SAMEBOY_BOOT=<dir with dmg_boot.bin / cgb_boot.bin>
    python3 tools/gbppu/gam_dispatch.py 0 dmg      # INC A until the mode-0 STAT IRQ dispatches, per SCX, N lines after LCD-on
    python3 tools/gbppu/gam_haltwake.py 0 dmg      # the same wake taken halted vs running
    python3 tools/gbppu/gam_sled.py 42 52 0,1,2,3,4,5,6,7 cgb stat,vram   # one register read at an exact M-cycle

gambatte ROMs are NOP padding with a `wait for LY == B` helper at `$7400` and the printer
at `$7000`, so any one is a blank program with a known output path; `gam_patchrun.py`
overwrites the body, re-checksums, and runs it through dingbat and
`tools/gbfuzz/sameboy_gambatte`. That lets a second emulator answer any GBMicrotest
question (which otherwise reports only in `$FF80`). The harnesses reproduce GBMicrotest's
own hardware staircases (`int_hblank_nops_scx0..7`, `hblank_int_scx0..7`). The steady-state
and LCD-on-line measurements both re-anchor on the ROM's own `LDH ($40),A`, so the
second emulator's boot-ROM phase offset cancels. Finding recorded with these: dingbat's
mode-0 edge is 2 dots late on lines after the first post-LCD-on line when running, and
2 dots early on the first line when halted, two errors that cancel in the halted steady
state (`M0_HALT_BLIND_DOTS` in `ppu.nim`).

## wilbertpol `acceptance/gpu` ROMs as measurements

    python3 tools/gbppu/wilbergpu.py <rom> [--patch out.gb]
    python3 tools/gbppu/statwif.py <rom> [--patch out.gb]
    python3 tools/gbppu/lycwsled.py <rom> [sled delta out.gb] [--probe $FFxx]

`wilbergpu.py` decodes the `ly_lyc*` shape (samples spilled to `$C000..$C007` as
F A C B E D L H, expected bytes at `$C009..$C010`) and `--patch` replaces the tail with a
serial dump of the raw measurements for `--mode serial`. `statwif.py` decodes
`stat_write_if`'s 85/105-entry table and `--patch` makes every subtest report `.`/`X`
instead of stopping at the first failure. `lycwsled.py` slides the `ly_lyc*_write` store
through its NOP field so the answer reads as a staircase; `--probe` swaps the store for a
bare register read to locate the edge rather than race it. `tools/gbfuzz/sameboy_wram`
dumps the same WRAM range from a second emulator for any model (`dmg mgb sgb sgb2 cgb0
cgba cgbb cgbc cgbd cgbe agb`); sweep the oracle over revisions, since sweeping dingbat's
can only find a mismatch it already models.

## Other

    python3 tools/gbppu/sm83dis.py <rom> [start_hex] [len_hex]   # enough SM83 to read a test ROM's body
    tools/gbppu/counters.sh /tmp/gb_ab <rom.gb>                   # retired instructions over a tools/gbgate pair
    tools/gbppu/blargg_canary.sh [<dingbat_test>] [<sameboy_runner>] [<bootdir>]

`sm83dis.py` is how `lcd_offset`'s `offsetN` numbering was read (`offset1` = 2 switches,
`offset2` = 4, `offset3` = 2 plus a NOP). `counters.sh` wraps `DINGBAT_BENCH_COUNTERS=1`
around both slots of a `tools/gbgate` build; `docs/gb_oam_dma_cost.md` is the authority
(fps cannot resolve this path; `cycles=` must match between arms; check the build's exit
code, since a failed `nim c` leaves the previous binary in place). One extra branch in
`tick_shifter` is +1.7%. `blargg_canary.sh` compares all eleven `blargg/cpu_instrs` frames
at frame 1200 against `tools/gbfuzz/sameboy_runner`, real CGB boot ROM both sides — the
gate after a GB timing change (`tests/README.md`).
