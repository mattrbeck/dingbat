# The mGBA suite's 41 failing rows: regression archaeology and per-row verdicts

*Audit date: 2026-08-11. Baseline commit: d83d098, **6957/6998** (41 failures).*
*After the one fix landed here: **6958/6998** (40 failures).*

This document answers one question that had never been written down: **which of the
mGBA suite's failing rows are regressions, and which are the suite disagreeing with
hardware or with itself?** It was opened after a request to "get the mGBA suite back
to 100%, it used to pass fully".

## 1. There is no regression. The suite has never been at 100%.

`git log --follow -p -- tests/results_mgba_suite.md` records every runner pass that
was ever committed. The Pass/Fail line moved exactly seven times:

| commit | date | Total | Pass | Fail |
|---|---|---|---|---|
| 91bfdd0 | 2026-03-19 | 3702 | 1683 | 2019 |
| c636831 | 2026-03-22 | 7008 | 4029 | 2979 |
| ecf3c64 | 2026-03-28 | 7008 | 4093 | 2915 |
| 2a119c2 | 2026-03-29 | 7008 | 4227 | 2781 |
| 1054f33 | 2026-07-08 | 7008 | 4239 | 2769 |
| 4935065 | 2026-07-10 | 7008 | 6734 | 274 |
| a6ec55e | 2026-07-14 | 7008 | 6898 | 110 |
| 98b5b43 | 2026-07-18 | 7008 | 6910 | 98 |
| de6d28c | 2026-08-02 | 7008 | 6967 | 41 |
| 3181c89 | 2026-08-03 | **6998** | **6957** | **41** |

The count is monotonically improving at every step. **The failure count has never
been below 41, and 41 was first reached nine days ago.**

The one apparent drop — 6967 → 6957 at 3181c89 — is not an emulator change at all.
That commit switched the suite ROM from a pinned v1.0 tag to
`mgba-suite-auto/releases/latest`, and the newer ROM contains **ten fewer tests**
(Total 7008 → 6998: upstream de-flaked two DMA0 rows, −12 DMA; Misc grew 10 → 12).
Failures stayed at exactly 41 across the swap. Pass dropped by precisely the number
of tests that disappeared.

**Verdict: the "it used to pass fully" premise is false.** There is no flip commit to
bisect, no root cause to revert, and this week's GBA-side hwprobe work (Booth carry,
HLE Sqrt cost, IRQ gamepak-context, `stm` r15) did not cost a single row — verified by
re-running the suite at d83d098 and getting the committed per-section numbers back
byte-for-byte:

```
1552/1552  130/130  1988/2020  935/936  90/90  140/140  93/93
72/72  615/615  1244/1244  90/90  4/4  4/12          = 6957/6998
```

## 2. What the 41 rows are

| # rows | section | verdict | see |
|---|---|---|---|
| 32 | Timing — DMA to/from ROM, prefetch-on columns | **blocked on a proven-necessary prefetch-unit rewrite** | §3 |
| 1 | Timer count-up — `0b, 0x000C 1xv 1d 4i` | **root-caused and FIXED here** | §4 |
| 7 | Misc — `H-blank bit start` Hblank + Flip 1-6 | **mostly measures dingbat's waitloop skip resolution, not its PPU timing**; one row is a real 3-cycle bug | §5 |
| 1 | Misc — `DMA Prefetch Break` | not comparable across ROM builds by construction | §6 |

## 3. The 32 DMA timing rows — **CLOSED 2026-08-19** (§3 below is the pre-fix state)

All 32 now pass; Timing is **2020/2020** and the suite is **6990/6998**. The
proof restated below is sound but its `elapsed` column was not physical:
`now - rom_free_since` at a DMA's ROM access is read inside a scheduler dispatch,
where `tick_slow` has rewound `sched.cycles` to the due event and holds the rest
of the CPU's tick quota back — a skew measured at -2..+1 across four columns of
the *same* test. Two more of the eight points were vacuous (the Thumb `P.S`/`PNS`
from-ROM rows genuinely expect 2, and dingbat already returned 2). Anchoring the
phase on the DMA grant instead — `k = now - dma_grant_now`, stall iff
`k mod s == 0`, first ROM access of a burst only — satisfies every row. It is the
CPU hand-off's own predicate one cycle earlier, not a second rule. ~15 lines in
`bus.rom_access_cycles`, no occupancy state, no save-state change, +0.016% perf.
Full write-up: `docs/prefetch-model-rewrite.md` (top).

## 3. The 32 DMA timing rows (blocked, and provably so)

Fully analysed in `docs/prefetch-model-rewrite.md`. Summary of the standing proof, not
re-derived here: all 32 are `dingbat = hardware − 1`, and they reduce to eight distinct
`(s, elapsed)` points at the DMA's first ROM access. For `s = 2`, `elapsed = 2` must
stall and `elapsed = 4` must not — but `2 + k ≡ 4 + k (mod 2)` for every `k`, so **no
predicate of the form "stall iff `(elapsed + k) mod s == r`" can satisfy them.** The
shipping CPU hand-off rule (`elapsed mod s == s-1`, which closed 14 sibling rows) is an
instance of that form and is therefore excluded, as are the two re-anchored variants.
Three candidate models were built and scored; the best was inert and the worst cost 152
Timing rows.

Closing these needs the prefetcher to become a real unit carrying its own position and
occupancy across a bus hand-off, which is a five-phase change touching
`bus.rom_access_cycles` (the hottest bus function), the DMA burst trackers,
`clear_pipeline`, the save-state format (STATE_VERSION bump), and the waitloop
fast-forward's `rom_free_since` assumption. That document explicitly scopes it as "one
focused session, **not** a background agent — too much shared-state risk to run blind",
and it is not attempted here.

Note for whoever picks it up: mGBA is **not** an oracle for these rows. It scores
1552/2020 on Timing and misses them *further* from hardware than dingbat does. The
suite's own `expected` column is the only oracle and it supplies eight data points; any
additional constraint has to come from a purpose-built ROM swept on hardware.

## 4. Timer count-up `0b, 0x000C 1xv 1d 4i` — a PPU bug, fixed

Despite living in the "Timer count-up" section this cell uses no cascade at all. It
arms TM0 at 0xFFF4 with prescaler 1 and IRQ on, spins on the enable bit, and reports
TM0 frozen at the cycle the ISR disables the timer on the 4th interrupt. Hardware
reads FFFF; dingbat read FFFE. (Column order here is the normal one — `timers.c`
prints `Got <ours> vs <hardware>`.)

The one cycle was not in `timer.nim`. Cycle-exact tracing of the failing cell against
a passing neighbour showed the timer's IF bit being recognized at rise+1 instead of
its own `IRQ_SYNC_DELAY` of 3:

```
blk4 (1d 4i, FAILS)              blk10 (2d 4i, passes)
EN    10420                      EN    22713
SCHED 10432 delay=3   <-- stale  (no stale check in window)
OV    10434  IF.timer0 rises
SCHED 10434 delay=3              SCHED 22727 delay=3
CHK   10435  -> irq_line=true    CHK   22730  (= OV+3)
IRQ   10436  (= OV+2)            IRQ   22730  (= OV+3)
DIS   10888  tm=FFFE             DIS   23182  tm=FFFF
```

Every anomalous `delay=3` check in the trace was an exact multiple of **1232 cycles**
— the scanline period — from the next. The source was `end_hblank`, which called
`schedule_interrupt_check(IRQ_SYNC_DELAY)` **unconditionally on every scanline**,
whether or not the video controller had raised anything. Because `check_interrupts`
re-evaluates the whole of `IE and IF` at the cycle it lands, that stale check acts as a
free early-recognition opportunity for any *other* peripheral whose flag rose inside the
preceding 3-cycle window. Here it pulled the handler entry one cycle early, and the four
rigid 121-cycle ISR rounds carried that cycle all the way to the disable write.

**Fix** (`src/dingbat/gba/ppu.nim`, `end_hblank`): schedule the check only when the
V-counter or V-blank condition actually set a flag. This is the hardware reading —
GBATEK has IF bits 0-2 driven by the DISPSTAT conditions and their enables, and there is
no periodic re-evaluation of the interrupt controller. Every other writer of `reg_if`
already schedules its own check (`timer.nim:42`, `dma.nim:282`, `serial.nim:121`,
`keypad.nim:21`, `rtc.nim:36,152`, `ppu.nim:101` for the H-blank flag, `mmio.nim:53`,
and the `interrupts.nim` register-write paths), so dropping this one can only ever
restore a flag to its own peripheral's delay, never lengthen one.

Measured at d83d098: Timer count-up **935/936 → 936/936**, total **6957 → 6958**, and a
line-by-line diff of every `FAIL:` line across the two full runs shows exactly one row
removed and none added. Timer IRQ holds 90/90. It also deletes 228 scheduler events per
frame: retired instructions on the FuzzARM bench go 6,639,962,594 → 6,617,524,890
(−0.34%).

Known residual, not fixed here: `check_interrupts` is still a *global* re-evaluation, so
a legitimate check (a real V-counter IRQ, say) can still shortcut another peripheral's
synchronizer window. The robust fix is a per-rise timestamp, which adds interrupt state
with save-state and rollback implications and was out of scope for this row.

## 5. The `H-blank bit start` rows are a waitloop-resolution measurement

The prior verdict on record (commit message of 3181c89) was that these rows "compare a
measurement against constants upstream re-measured for one specific codegen, so they are
calibrated to the compiler that built the ROM" — i.e. not our problem. **That verdict is
too broad and partly wrong.** Two corrections.

### 5a. Our own results table has the columns backwards for this section

`misc-edge.c` is the one suite file whose result call inverts its arguments:

```c
doResult(activeTest->valueNames[j], activeTest->testName,
         activeTest->expected[j],    /* -> printed as "Got"  */
         currentTest[j]);            /* -> printed as "vs"   */
```

Every other suite file passes `(value, expected)`. `dingbat_test_runner.nim` parses
`"Got X vs Y"` into `actual=X, expected=Y` uniformly, so for the **Misc. edge case**
section only, `tests/results_mgba_suite.md` prints the ROM's hardcoded constant in the
"Actual" column and *dingbat's measurement* in the "Expected" column. Anyone reading
that table for this section has been reading it backwards. Fixed in this change.

### 5b. `Hblank` (out[1]) is compiler-independent, and it is a real 3-cycle bug

`out[1]` is not a poll measurement. It is

```c
Halt();  int calibration = REG_TM0CNT_L;
Halt();  int value       = REG_TM0CNT_L;
out[1] = value - calibration;
```

— the TM0 delta between two consecutive HBlank-IRQ halt-wakes, sampled at *identical*
code points. Whatever the wake-to-read latency is, it cancels in the subtraction, so
codegen cannot influence this row. The value is therefore one scanline, and indeed the
ROM's constant is `0x4D0 = 1232 = 308 dots x 4` exactly — the GBA scanline in CPU
cycles, straight out of GBATEK.

Dingbat reports `0x4D3 = 1235`, i.e. **three cycles too many**, and this value is
invariant across every build tested (bd57c5c, 09d601c, d83d098). Since dingbat's own
PPU schedules the line as `960 + 272 = 1232` exactly (`ppu.start_line` /
`ppu.start_hblank`), the HBlank IRQ *period* is right and the 3 cycles are an asymmetry
between the first and second halt-wake, not a drift. This row is a genuine, localized,
unfixed defect. It is not codegen-calibrated and should not have been dismissed as such.

#### 5b-i. `IRQ_GATE_DELAY` is not it (2026-08-18)

The only halt/IRQ phase constant in the GBA core is `IRQ_GATE_DELAY` (12), which
holds recognition off after a register write re-opens the gate on a parked IF --
plausible for this row, because the first of the two halts has such a write
behind it and the second does not, which is exactly the shape of a
first-versus-second asymmetry. Swept 0 / 9 / 12 / 15 against the suite: the row
reads `0x4D3` at **every** value. Not the gate.

Also checked while here, because it would have inverted the whole entry: the
raw suite line prints `Got 0x4D0 vs 0x4D3`, which reads as though dingbat were
producing the GBATEK-exact 1232. It is not. `misc-edge.c` passes
`(expected, value)` where every other suite file passes `(value, expected)`, and
`dingbat_test_runner.nim` already un-swaps this section before writing the
table. The direction in 5b stands: dingbat is three cycles LONG.

### 5c. Flip 1-6 measure the waitloop skip resolution

The six `Flip` rows time the gaps between DISPSTAT bit-1 edges with a spin loop:

```c
while (((bit ^ REG_DISPSTAT) & 2));
value = REG_TM0CNT_L;
```

Dingbat's idle-loop detector recognises that shape and **fast-forwards it**, so the
edge is not detected when the loop would have sampled it but at whatever bound
`fast_forward_bounded` was given. `cpu.nim` already says so in as many words: the skip
length "IS that loop's sampling resolution", and moving the PSG waveform deadlines out
of the event buffer took these very rows "from 3-48 cycles out to 124-394".

So these rows are a legitimate oracle — for the skip resolution, not for the PPU. The
evidence that they are quantized rather than mistimed:

* Hardware measures the same 226-cycle HBlank-high window (1232 − 1006, both GBATEK
  constants, and dingbat's `HBLANK_FLAG_DELAY = 46` reproduces both) as 229 and 227 on
  two successive passes — a spread of 2 cycles, consistent with a tight spin loop.
* Dingbat measures the same window as 228 and 244 — a spread of **16** cycles. A PPU
  phase error cannot make one window 228 and the next 244; a coarse, event-aligned skip
  bound can.
* Every dingbat-vs-hardware difference on these rows is a multiple of the skip
  granularity, not a constant offset.

`-d:gbaskipcap=N` exists to bound the skip by a stated constant instead of by whatever
the PSG's soonest deadline happens to be, and the comment there already names the
physically defensible reading: "a real Thumb spin loop resolves ~15 cycles, so a small
constant is the physically defensible resolution; the PSG deadline is an inherited
accident that merely happens to be fine-grained."

### 5d. Today's IRQ commit moved these rows, unnoticed

Commit **503f73f** (`gba/irq: the +6 handler-entry latency is a gamepak-context cost`)
reports "mGBA suite 6957/6998 — identical per-suite scores, no movement". The *pass
counts* are indeed identical, but the measured values are not. Bisected (build + full
suite run at bd57c5c, 09d601c, d83d098; 09d601c is inert, so 503f73f is the sole cause):

| row | hardware | before 503f73f | at d83d098 | change |
|---|---|---|---|---|
| Hblank | 0x4D0 | 0x4D3 | 0x4D3 | — |
| Flip 1 | 0x087 | 0x092 | 0x09D | +11 |
| Flip 2 | 0x3EC | 0x3DD | 0x3D2 | −11 |
| Flip 3 | 0x0E5 | **0x0E4** | 0x0EF | +11 |
| Flip 4 | 0x3EB | **0x3EC** | 0x3E1 | −11 |
| Flip 5 | 0x0E3 | 0x0F4 | 0x0FF | +11 |
| Flip 6 | 0x3F3 | 0x3E0 | 0x3E0 | — |

Flip 3 and Flip 4 were **one cycle** from passing and are now ten out. The shift is a
uniform ±11 — exactly one skip quantum — because 503f73f changed the absolute phase of
the poll loop relative to the PPU, and edges that were being caught on the marginal
iteration now slip to the next one.

This is **not** an argument to revert 503f73f. That change is anchored on AGB SP
hardware transcriptions (gbaedge IRQLAT2/IRQWIN2/IRQWIN3), and per project policy
real-hardware evidence outranks the mGBA suite where they conflict. It *is* an argument
that these rows are too phase-sensitive to be used as a regression gate while the skip
is coarse, and that a commit which claims "no movement" on this suite should compare
values, not just pass counts.

## 6. `DMA Prefetch Break`

`out[0]` is `0x10000000 + 4 * iterations` — the address at which a tight ROM-resident
read loop over open-bus space first sees a value the running HBlank DMA put on the bus.
Hardware breaks at `0x10002A94` (2725 iterations), dingbat at `0x10002478` (2334). The
quantity being compared is *how many loop iterations fit before a bus event*, which is a
function of the loop's codegen and of the same skip resolution as §5c. Left failing;
this row is not a useful accuracy signal in its current form. (Confirming that reading:
the §4 fix, which touches nothing but a scheduler event count, moved this row's value
from `0x10002478` to `0x1000257C` without going near any prefetch or open-bus code.)

## 7. What to do next, in payoff order

1. **The `Hblank` row (§5b).** One row, a hard 3-cycle target, compiler-independent, and
   the ROM's constant is a GBATEK identity rather than a measurement. The asymmetry is
   between the first and second halt-wake, so the place to instrument is the HLE `Halt`
   SWI's `HALT_RETURN_COST` deferral and `hle_charge_units_interruptible` against the
   wake path, not the PPU (whose 960+272 line is already exact).
2. **Decide what the waitloop skip resolution should be (§5c).** `-d:gbaskipcap=N`
   already exists and the code already argues that "a real Thumb spin loop resolves ~15
   cycles" is the physically defensible bound, versus today's inherited PSG deadline.
   Sweeping N against the six Flip rows would say how much of their residual is
   quantization; it is an accuracy/perf trade and wants the owner's call plus an
   instructions-retired number, so it was measured-but-not-shipped here.
3. **The 32 DMA rows (§3).** Highest row count, but gated on the occupancy rewrite in
   `docs/prefetch-model-rewrite.md` and explicitly not a background-agent task.
4. **Generalize the §4 fix**: give each IF rise its own timestamp so a global
   `check_interrupts` cannot shortcut another peripheral's synchronizer window.

## 8. A note on how these rows should be gated

Commit 503f73f reported "no movement" on this suite on the strength of identical
per-section pass counts, while six row *values* moved by a full quantum and two
near-misses regressed from one cycle out to ten. `tests/results_mgba_suite.md` records
the values, not just the counts, and it is the artifact to diff. The Misc section's
columns were also printed backwards until this change, so any earlier reading of that
section's Actual/Expected pair should be re-checked.
