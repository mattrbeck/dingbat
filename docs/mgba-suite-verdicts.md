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

## `Hblank` (out[1]) — 3 cycles of code shape, not PPU timing

The test halts twice and reads TM0CNT_L after each wake; the row is the
difference. The constant is `0x4D0 = 1232`, one scanline. Dingbat reads
`0x4D3` under the HLE BIOS and under the real one.

Both halts wake at the same line phase (1012) here, so the IRQ period is
right. The three cycles are in the code the compiler emitted after each
`Halt()`: after the second one it placed three one-cycle Thumb
`movs` register setups (IWRAM) ahead of the `ldrh` that reads TM0, and after
the first none. The second read lands 103 cycles after its wake, the first
100. Hardware reports exactly 1232 anyway.

Upstream's earlier binary of the same source (built before
`mgba-emu/suite@a58437f3`, whose constants were measured for it) has no
extra instructions after either halt; dingbat reads 1232 there and hardware
1233. So in both binaries hardware minus dingbat is 1 mod 4 (−3 and +1),
while dingbat's own halt entries sit at the same phase mod 4 for both halts
(both binaries), which rules out a wake that keeps the CPU's phase across
the halt. What does absorb it is not identified; it lives in the halt
entry/wake path that Timing and Timer count-up are calibrated against, and
needs a hardware probe that varies the instruction count after a halt.

## `Flip 1–6` — poll-loop sampling, after an idle-loop exit fix

Each flip spins on DISPSTAT bit 1 and reads TM0 when it changes. Until
2026-09-15 these rows mostly measured the idle-loop skip: the Thumb
conditional-branch handler judged the loop before evaluating the branch, so
the not-taken branch that leaves the loop could still be called a waitloop
and fast-forward past the exit to the next deadline (a PSG step, up to ~500
cycles). Only a taken branch is judged now (`thumb.nim`), which also leaves
Emerald's overworld 1% cheaper in retired instructions.

| Row | Before | Now | Expected |
|---|---|---|---|
| Flip 1 | 0x9D | 0x80 | 0x87 |
| Flip 2 | 0x3D2 | 0x3EF | 0x3EC |
| Flip 3 | 0xEF | 0xE2 | 0xE5 |
| Flip 4 | 0x3E1 | 0x3EE | 0x3EB |
| Flip 5 | 0xFF | 0xE2 | 0xE3 |
| Flip 6 | 0x3E0 | 0x3F0 | 0x3F3 |

The remaining offsets are within the poll loop's own period (8 cycles in
IWRAM). With the skip the edge is seen at once; hardware sees it at the
loop's next read, so its rows jitter by up to a period (2+3 sums to 1233,
4+5 to 1230). Skipping off entirely (`DINGBAT_NO_WAITLOOP=1`) gives
0x80/0x3ED/0xE3/0x3F3/0xE3/0x3E9: the cumulative edge times match hardware
on flips 4–5 and read 6–10 cycles early on 1–3 and 6, which is the
calibration read above plus the loop phase. Passing these rows needs the
`Hblank` row's missing piece first.

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
"expected" one. Six of seven are pixel-exact; the three that did not match
before 2026-09-15 are now latches in `ppu.nim` (see `bg_enable_hist`,
`win0_inside`, `oam_view` in `gba.nim`):

* **Layer toggle / Layer toggle 2** — a BG draws while DISPCNT enables it
  now and at a sample 34 cycles into the line two lines back: enable shows
  on the third line, disable at once. The sample point is bracketed by
  "Layer toggle 2" under this core's CPU timing (a handler's enable 29
  cycles into a line counts, a poll loop's 39 cycles in does not).
* **OAM Update Delay** — sprites draw from OAM as it stood when the previous
  line was drawn.
* **Window offscreen reset** — WIN0V/WIN1V set a flag where VCOUNT equals Y1
  and clear it where it equals Y2; a Y2 VCOUNT never reaches leaves the
  window open into the next frame.

Layer toggle 2 still differs in 16 pixels: the first tile of lines 65 and
146, where the enable lands mid-line. The expected screen draws those eight
pixels shifted two to the right (with pixels 0–1 transparent on line 65),
which neither whole-line rendering nor a per-pixel enable reproduces.

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
