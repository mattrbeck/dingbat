# The mGBA suite's failing rows: per-row verdicts

Current state is the Summary in `tests/results_mgba_suite.md` (6990/6998;
the 8 failures are all in "Misc. edge case"). This file says why each
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

## `Hblank` (out[1]) — a real 3-cycle defect

```c
Halt();  int calibration = REG_TM0CNT_L;
Halt();  int value       = REG_TM0CNT_L;
out[1] = value - calibration;
```

The TM0 delta between two consecutive HBlank-IRQ halt-wakes at identical
code points, so wake-to-read latency cancels and codegen cannot influence
it. The constant is `0x4D0 = 1232 = 308 dots × 4`, the GBATEK scanline.
Dingbat reports `0x4D3`, three cycles long, invariant across builds. The
PPU schedules the line as `960 + 272 = 1232` exactly, so the IRQ *period* is
right and the three cycles are an asymmetry between the first and second
halt-wake. `IRQ_GATE_DELAY` (0/9/12/15 swept) does not move it. Instrument
the HLE `Halt` SWI's `HALT_RETURN_COST` deferral and
`hle_charge_units_interruptible` against the wake path, not the PPU.

## `Flip 1–6` — the waitloop skip resolution

```c
while (((bit ^ REG_DISPSTAT) & 2));
value = REG_TM0CNT_L;
```

The idle-loop detector fast-forwards that shape, so the edge is seen at
whatever bound `fast_forward_bounded` was given, not where the loop would
have sampled it. Evidence that the rows are quantized rather than mistimed:
hardware measures the 226-cycle HBlank-high window (1232 − 1006, both
GBATEK constants; `HBLANK_FLAG_DELAY = 46` reproduces both) as 229 and 227
on successive passes; dingbat measures 228 and 244 — a 16-cycle spread no
PPU phase error can produce. Every difference is a multiple of the skip
granularity. `-d:gbaskipcap=N` bounds the skip by a constant instead of the
PSG's soonest deadline (a real Thumb spin loop resolves ~15 cycles, which is
the physically defensible bound); sweeping N against these rows is an
accuracy/perf trade that wants a retired-instructions number alongside it.

## `DMA Prefetch Break`

`out[0] = 0x10000000 + 4 × iterations`: how many iterations of a tight
ROM-resident read loop over open-bus space fit before a running HBlank DMA
puts a value on the bus. Hardware `0x10002A94`, dingbat `0x10002478`. The
quantity depends on the loop's codegen and on the same skip resolution as
the Flip rows (a scheduler-event-count change moved it without touching
prefetch or open-bus code). Not a usable accuracy signal as built.

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
