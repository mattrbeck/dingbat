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

## `Hblank` and `Flip 1-6` — the ROM is built by a different compiler

These seven rows time code the compiler emits, and the constants belong to
a build that is not the one CI runs.

`mgba-emu/suite@a58437f3` re-measured them in June 2026 ("modern gcc
values"). The auto-run fork is a separate build of that source: both trees
run `devkitpro/devkitarm` from Docker Hub, but months apart, and the newer
gcc lays `hblankBit` out differently — after the second `Halt()` it inserts
three one-cycle `movs` before the `ldrh` that reads TM0, where the older
build reads TM0 immediately. That alone accounts for the `Hblank` row's
three cycles.

Run against upstream's own January build (`~/code/suite`, whose embedded
newlib string dates its toolchain a year earlier), dingbat reproduces every
one of the June constants exactly:

| Row | dingbat on the January build | `@a58437f3` |
|---|---|---|
| Hblank | 0x4D0 | 0x4D0 |
| Flip 1 | 0x87 | 0x87 |
| Flip 2 | 0x3EC | 0x3EC |
| Flip 3 | 0xE5 | 0xE5 |
| Flip 4 | 0x3EB | 0x3EB |
| Flip 5 | 0xE3 | 0xE3 |
| Flip 6 | 0x3F3 | 0x3F3 |

So the PPU and CPU timing these rows measure is right, and the rows fail in
CI only because the fork's binary is compiled differently. Two further
checks agree: the June constants are not self-consistent for *any* build
(flips 3 and 5 run identical code starting at the same phase of the line —
flip 3 + flip 4 = 1232, one scanline — yet differ by 2), while the 2023
constants they replaced were (both flips 228). And a replay of the traced
loops under any shift of the flag edges, the calibration read, the loop
period, the entry cost or the read-to-TM0 latency reproduces none of the six
at once; a phase-dependent (mod 4) cost on DISPSTAT reads gets no closer
than 9 cycles, and one on timer reads breaks Timing and Timer IRQ.

Closing the rows in CI means rebuilding the fork's ROM with the toolchain
the constants were measured on (`devkitpro/devkitarm` pinned to a mid-2026
tag) and re-pinning `MgbaSuiteSha1`, or re-measuring on hardware with the
fork's own binary.

## `DMA Prefetch Break` — a phase-alignment row

`out[0] = 0x10000000 + 4 × reads`: a 7-instruction Thumb ROM loop reads open
bus until one read returns an HBlank DMA's last value instead of the
prefetched opcode. A DMA's value is readable only by the instruction right
after it, so the loop exits at the first line whose DMA lands just before
the `ldmia`. The loop takes 36 cycles here; 1232 mod 36 = 8, so the landing
point walks 8 cycles per line and the exit line depends on the loop's phase
at line 0.

Dingbat exits at line 9 (2641 reads, `0x10002944`) under the HLE BIOS and at
line 1 (`0x10002530`) under the real BIOS; hardware's 2725 reads is about
line 11½ at 36 cycles, which no single landing window reproduces, so the
iteration cost or the VBlankIntrWait return phase differs as well. One
constant cannot separate the two. Not a usable accuracy signal as built.

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
