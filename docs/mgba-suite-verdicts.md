# The mGBA suite's failing rows: per-row verdicts

Current state is the Summary in `tests/results_mgba_suite.md` (every
remaining failure is in "Misc. edge case"). This file says why each
remaining row fails and what would close it, and records the verdicts on
the rows that were closed so they are not re-derived.

## Reading the Misc section

`misc-edge.c` is the one suite file whose `doResult` call passes
`(expected, value)` where every other file passes `(value, expected)`, so
its raw lines print the ROM's constant as "Got" and dingbat's measurement
as "vs". `dingbat_test_runner.nim` un-swaps that section before writing the
table; read the table, not the raw log. The suite ROM is
`mgba-suite-auto/releases/latest`, and a newer ROM can change the test
count (the move from v1.0 removed ten rows).

Gate on the row **values** in `tests/results_mgba_suite.md`, not on pass
counts: a change that shifts the poll-loop phase can move every Flip row by
one skip quantum (±11) and regress two near-misses from 1 cycle out to 10
while every per-section count stays identical.

## `Hblank` and `Flip 1-6` — closed by pinning the compiler

These seven rows time code the compiler emits, and CI's ROM used to be built
by a different compiler than the one the constants were measured against.
The fork now pins that compiler and all eight `H-blank bit start` rows pass.

Neither `docker-build.sh` pinned a toolchain — upstream's still runs the
floating `devkitpro/devkitarm` tag — but Docker Hub's tags are dated, so
which compiler a build used is recoverable from when it ran. `latest` was
the `20260221` image from February until `20260610` replaced it on 10 June
2026. `mgba-emu/suite@a58437f` ("Update hblankBit test with modern gcc
values") and `@8c97f2c` were both committed on 31 May 2026, so their
constants were measured on a `20260221` build. The fork's ROM is built by
GitHub Actions on push, and its `latest` was `20260610`.

Building the fork's source in the suite's own Docker environment confirms
it: with `devkitpro/devkitarm:20260610` the ROM is byte-identical to the one
CI used to download (sha1 `00480cf1…`), and with `20260221` it is
`da6f5c69…` — the ROM CI downloads now.
Running dingbat against the two:

| Suite | on `:20260610` (the old ROM) | on `:20260221` (pinned) |
|---|---|---|
| Misc. edge case tests | 5/12 | **11/12** |
| every other suite | unchanged | unchanged |

On the `20260221` build all eight `H-blank bit start` rows pass and so does
`DMA Prefetch Read`; the only Misc row left is `DMA Prefetch Break` below.
The difference is codegen: after the second `Halt()` the newer gcc inserts
three one-cycle `movs` before the `ldrh` that reads TM0, where the older
build reads TM0 immediately — exactly the `Hblank` row's three cycles — and
the six `Flip` loops shift by 1 to 16 cycles each for the same reason.

`mattrbeck/mgba-suite-auto`'s `docker-build.sh` is therefore pinned to
`devkitpro/devkitarm:20260221`, and `MgbaSuiteSha1` tracks the ROM it builds
(`da6f5c69...`, byte-identical to a local build with the same image). Bump
that pin only alongside constants re-measured on hardware with the newer
toolchain.

## `DMA Prefetch Break` — the one real Misc failure

`out[0] = 0x10000000 + 4 x reads`: a 7-instruction Thumb ROM loop reads open
bus until one read returns an HBlank DMA's last value instead of the
prefetched opcode, so the count is a cycle measurement wearing an address.
`REG_WAITCNT` is 0 throughout (ROM N=5/S=3, prefetch off): libgba's crt0
never writes it, and the Timing suite's last write is zero.

The row is a lottery, not a stopwatch. The loop costs 36 cycles an iteration
and a scanline is 1232, so the DMA's landing point inside the loop walks
1232 mod 36 = 8 cycles per line, and the loop exits on the first line where
it lands somewhere the `ldmia` can see it. The exit line is therefore
whichever line first wins that lottery; the reachable read counts are spaced
a scanline apart (~34) and hardware's 2725 falls between two of them.
Moving the loop's phase by four cycles moved the exit nine lines.

The window itself is below the resolution the core dispatches at. On
hardware the DMA's word survives on the data bus only until the next
gamepak fetch, so the `ldmia` sees it when the transfer lands between that
instruction's own fetch and its data cycle — a slot a few cycles wide in the
middle of an instruction. Here a scheduler event can only land on an
instruction boundary, so the latch is armed for the whole of the following
instruction instead (`Bus.dma_open_bus_armed`, cleared in `cpu.tick`), which
is the adjacent slot, not the same one. Closing the row means dispatching a
DMA part-way through an instruction, not tuning a constant.

**Measured 2026-09-18, and the premise above is false** (docs/playtest-bugs.md
section 13). `obuswin.s` on an AGB SP: the window is not ended by the next
gamepak fetch — a single MUL, one instruction touching no bus at all, already
ends it — and it is not one instruction wide either. What ends it is the
CPU's next bus access of any kind, opcode fetches included, which is what this
file's own field comment says. More to the point, `obuswint.s` shows the latch
is **per-halfword**: two NOPs after a burst, Thumb code reads `DEAD6019`, half
the DMA word beside a freshly fetched opcode halfword. `read_open_bus_value`
answers with a predicate — the whole word or none of it — and no predicate of
that shape can return a half-and-half word at any bounds. Moving the
predicate's lower bound to what hardware measures for ARM code in IWRAM makes
every measured row right and costs `DMA Prefetch Read`, driving this row to
`0x00000000`; both bounds tried are tabulated in that section.

**The latch is not what this row turns on** (docs/playtest-bugs.md section
14). Modelling it as a register was tried and is the wrong target. What this
row turns on is *when the H-blank DMA's word reaches the bus*, and two sweeps
prove no window can fix that: across a 13x13 grid of bounds `Break` takes only
three values (`0x00000000`, `0x100024B8`, `0x10002540`), and disabling the
window to log the phase offset of all 16384 reads shows the reachable exit
counts are dense -- almost every integer is hit by some sub-instruction slot,
so matching 2725 by choosing one is fitting, not modelling. Both reference
emulators fail the row too; one returns dingbat's value bit for bit and the
other returns one of the same three.

The lever is the grant. At `-d:HBLANK_DMA_REQUEST_DELAY=9` (through 12) the
whole suite is green, 6998/6998, and that row is the only line in all 6998
that changes. The constant itself is refuted -- hdmamul measures 227 on an
idle bus where dingbat gives 226, so the request belongs at flag+1, not later
-- but the gap between "flag+1 on an idle bus" and "about flag+9 in this loop"
is exactly the deferral hdmasweep measures and dingbat does not model: the
grant waits for the CPU's bus access in flight, and for nothing else. A
prototype of that deferral makes hdmasweep sawtooth for the first time while
hdmamul stays flat; it is not calibrated and was not shipped. So closing this
row still needs sub-instruction dispatch resolution, as this file said -- but
the size of the correction is now known (about seven cycles) and two hardware
payloads bracket it.

What it did find is a real bug, now fixed. A DMA dispatched from a scheduler
handler bills its cycles to `bus.cycles`, which a running CPU closes out
with `scheduler.tick` after each instruction; a halted CPU never does, and
`fast_forward` sets the clock absolutely, so the debt rode until the wake.
Halting through a frame of HBlank DMA meant waking one transfer's worth of
cycles later for every transfer that had run: the suite's VBlank IRQ is
raised at cycle 0 of line 160, and dingbat entered its vector at cycle 647. It now enters at cycle 7,
and the HLE and real BIOS agree on this row where they used to differ by a
line.

Two costings were refuted along the way, both by the rest of the suite:
- a ROM burst surviving any cycle that does not touch the gamepak (which
  would make the fetch after the loop's open-bus read sequential, 4 cycles
  an iteration): 620 Timing rows fail, the `[sp]` rows pinning that a code
  fetch after an IWRAM data access is non-sequential;
- charging one pipeline refill instead of two in `clear_pipeline` (the
  in-flight fetch a taken branch has already made): Timing 2020 -> 1920,
  Timer count-up 936 -> 400, Timer IRQ 90 -> 69, SIO timing 4 -> 0.

So the 36-cycle iteration is pinned by four independent sections, and the
row stays red on a landing window no ROM measures.

## Video tests (interactive only)

The Video suite has no automated verdict and the auto-run ROM the runner
fetches skips it. `tests/mgba_video.nim` drives upstream's interactive build
through its menus and diffs each test's "actual" frame against its
"expected" one. All seven are pixel-exact; the four that did not match
before 2026-09-15 are PPU behaviour in `ppu.nim` (see `bg_enable_hist`,
`win0_inside`, `oam_view`, `bg_enable_cycle` in `gba.nim`):

* **Layer toggle / Layer toggle 2** — a BG draws while DISPCNT enables it
  now and at a sample 34 cycles into the line two lines back: enable shows
  on the third line, disable at once. The sample point is bracketed by
  "Layer toggle 2" under this core's CPU timing (a handler's enable 29
  cycles into a line counts, a poll loop's 39 cycles in does not).
* **Layer toggle 2, lines 65 and 146** — a text BG switched on after its
  line started draws nothing left of the pixel being output at the write,
  and its first tile comes out two pixels late. Pixel 0 is output 44
  cycles into the line (42–45 reproduce the screen).
* **OAM Update Delay** — sprites draw from OAM as it stood when the previous
  line was drawn.
* **Window offscreen reset** — WIN0V/WIN1V set a flag where VCOUNT equals Y1
  and clear it where it equals Y2; a Y2 VCOUNT never reaches leaves the
  window open into the next frame.

The late first tile is modelled for text BGs (modes 0 and 1) only; nothing
in the suite exercises a mid-line enable of an affine or bitmap layer.

## Under the real BIOS: the four SIO timing rows

Only with a BIOS image: `Normal8/256k` and `Normal8/2M` read one cycle high
(0x27A vs 0x279, 0xBA vs 0xB9), and the two Multi rows time out on hardware
too. The timed window is hand-written assembly plus BIOS code, so unlike the
rows above it does not move with the compiler.

The window runs from the transfer's start write to the stop write after a
`swi 2` Halt wakes on the serial IRQ. Tracing both BIOS modes: the wake, the
vector and the BIOS dispatcher take the same 82 cycles either way, and
everything before the halt is absorbed by it. The difference is the return:
the real BIOS runs `subs pc, lr, #4` (2 cycles here) and then its Halt tail
(`bx lr`, the shared SWI epilogue, `movs pc, lr`) at the textbook 21, where
the HLE charges 22 for the pair (`HALT_RETURN_COST`, tuned on these rows).

Three ways to remove that cycle, each refuted by another hardware-pinned
section:
- IRQ entry one cheaper when it wakes a halt (no in-flight fetch): Timer
  count-up 936 -> 920.
- the S-bit return discount in every mode, not just IRQ mode: fixes the SIO
  rows, but the BIOS Timing rows go 2020 -> 1992, each one cycle low.
- the discount only when the return resumes a halted stream: fixes the SIO
  rows, Timer count-up still 936 -> 920.

Timer count-up times the BIOS's IntrWait wake and these rows time its Halt
wake, and one constant cannot serve both. Separating them needs a hardware
probe that isolates the Halt wake path, not more fitting against the suite.

## Closed rows, for the record

* **Timing — 32 DMA-to/from-ROM prefetch rows.** All were `hardware − 1`.
  Anchoring the DMA's ROM stall on the DMA grant — `k = now − dma_grant_now`,
  stall iff `k mod s == 0`, first ROM access of a burst only — satisfies
  every row; it is the CPU hand-off's own predicate one cycle earlier
  (`bus.rom_access_cycles`, no occupancy state, no save-state change). An
  earlier proof that no such predicate could work used an `elapsed` read
  inside a scheduler dispatch, where `tick_slow` has rewound `sched.cycles`.
* **Timer count-up `0b, 0x000C 1xv 1d 4i`.** A PPU bug: `end_hblank`
  scheduled `schedule_interrupt_check(IRQ_SYNC_DELAY)` on every scanline
  whether or not a DISPSTAT condition had set a flag, and because
  `check_interrupts` re-evaluates all of `IE and IF`, that stale check let
  the timer's IF bit be recognised at rise+1 instead of its own +3. GBATEK
  ("Interrupt Control") drives IF 0–2 from the DISPSTAT conditions with no
  periodic re-evaluation; the check is now scheduled only when a flag was
  set. Residual: `check_interrupts` is still global, so a legitimate check
  can shortcut another peripheral's synchroniser window; the robust fix is a
  per-rise timestamp (save-state and rollback implications).

For the prefetch rows the suite's `expected` column is the only oracle
(other emulators score further from hardware on Timing); extra constraints
need a purpose-built ROM swept on hardware.
