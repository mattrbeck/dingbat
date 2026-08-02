# What the GB OAM-DMA bus-conflict model actually costs

`28ae07e` ("gb: model OAM DMA bus conflicts") took gambatte's `oamdma`
directory from 223/811 to 681/811. It was reported as costing **-2.0%** on
Link's Awakening (DMG) and **-1.5%** on Pokemon Crystal (CGB), measured by
wall-clock fps.

Re-measured with retired-instruction counts instead of wall clock, its true
marginal cost on the CPU bus hot path is **+0.37% of retired instructions**,
and the companion refactor `4fbbbe8` makes the DMA half of that path *cheaper*
than what `main` did. The -2.0% was not the model.

## Why wall clock could not answer this

Two builds that differ only in code the benchmark ROM never executes measure
~1.3% apart on this machine, purely from where the linker put things. The
effect being measured is smaller than that, so fps cannot resolve it at any
sample count -- layout error is systematic, not random, and does not average
out across runs of the same binary.

`dingbat_bench` therefore reports hardware counters under
`DINGBAT_BENCH_COUNTERS=1`, read from `proc_pid_rusage(RUSAGE_INFO_V4)` around
the measured window only. No root, and no Xcode (`xctrace` needs a full Xcode
install, which a plain command-line-tools box does not have).

```
DINGBAT_NO_WAITLOOP=1 DINGBAT_BENCH_COUNTERS=1 ./dingbat_bench rom.gb 2400 300
  zelda: 2400 frames in 1.164s = 2062.1 fps
    cycles=168395236 mcps=144.69
    instructions=23146620157 hwcycles=3920335108 ins_per_emucycle=137.45413
```

Retired instructions reproduce to **0.002%** run to run, against 1.3% for fps.
`cycles=` (emulated cycles) is the control: an A/B is only meaningful when both
arms report the same emulated cycle count, i.e. both did the same work.

## The measurement trap: an inline-cost cliff

The first factorial run produced impossible numbers -- a build with *both*
hot-path checks removed retired 186M **more** instructions than one that kept
the OAM-DMA check. Diffing per-function code sizes between the two binaries
explains it: removing one compare shrinks `mem_read`/`mem_write` past clang's
inline-cost threshold, and they are then inlined into a large, arbitrary subset
of the ~160 generated opcode bodies (`colonanonymous` 108 -> 324 bytes,
`cb_set` 156 -> 320, ...). 123-162 functions changed size in builds that were
supposed to differ by three instructions.

So a one-compare edit to this path moves ~0.9% of all retired instructions by
flipping an inlining coin, on top of the ~1.3% layout noise in fps. That, not
the bus-conflict model, is what -2.0% measured.

**Pin the inlining decision before A/B-ing anything on this path.** With
`mem_read`/`mem_write` forced `noinline`, the only functions that change size
between variants are the four intended ones, and the costs become additive:

| variant (Link's Awakening, 2400 frames) | instructions | vs none |
|---|---|---|
| neither check | 23,187,255,713 | - |
| PPU CPU VRAM/OAM lock only (`944cd30`) | 23,269,082,883 | +81.8M (+0.353%) |
| OAM-DMA cached flag only (`4fbbbe8`+`28ae07e`) | 23,273,005,538 | +85.7M (+0.370%) |
| both (current HEAD) | 23,354,704,547 | +167.4M (+0.722%) |
| `main`'s old inline OAM predicate only | 23,290,841,856 | +103.6M (+0.447%) |

81.8 + 85.7 = 167.5 against 167.4 measured. **The two features are additive;
there is no interaction.** The leading hypothesis -- that the -2.0% came from
`944cd30` and `28ae07e` colliding on one hot path -- is dead.

Predicted from first principles and confirmed: the DMA check is 3 instructions
(`ldrb`/`cmp`/`b.ne`) over 30,028,939 bus accesses = 90.1M, measured 85.7M.

## The answers

* **OAM-DMA model, marginal cost: +0.37%** of retired instructions (both ROMs).
  The cold handler is genuinely cold -- `mem_read_busy` takes 5 samples out of
  ~10,300 in a Time Profiler run, because only 1.07% of bus accesses land
  during a transfer.
* **`4fbbbe8` is a real but small win**: the cached `dma_busy` flag costs 85.7M
  where `main`'s three-term predicate cost 103.6M, so it is **+0.077% faster**,
  not the +1.55% originally reported (also an artifact of the cliff).
* **Net vs `main`'s shape**, PPU lock included, HEAD retires *fewer*
  instructions: -28.0M on DMG, -12.8M on CGB.
* **The single biggest lever on this path is not either feature.** Pinning the
  inlining decision to always-inline is worth **-0.84% (DMG) / -0.93% (CGB)**
  of retired instructions for +568 bytes of `__text` -- more than twice the
  entire cost of the bus-conflict model.

## Why the model cannot be made much cheaper

The hot path is already 3 instructions, and it has to answer a question only
runtime state can answer: a DMA owns whole *buses* (cart+SRAM+WRAM, or VRAM, or
CGB WRAM), so unlike the PPU's VRAM/OAM lock it cannot be gated on the address
first. Folding `dma_busy` into a combined "slow path needed" flag alongside the
PPU lock was evaluated and rejected: VRAM is locked for roughly 40% of every
scanline, so a merged state flag would divert ~40% of *all* reads into an
out-of-line handler to re-test an address that is almost never VRAM (Link's
Awakening: **zero** CPU VRAM reads in 28.9M reads, and 89,096 VRAM writes out
of 30.0M accesses). Address test first, state test second is already the right
order.

The remaining 3 instructions are ~0.37% because dingbat spends most of a bus
access elsewhere: 771 retired instructions per access, dominated by the per-dot
FIFO PPU (`tick_shifter` alone is 28% of a Time Profiler run, `mem_tick_components`
15%). Eliminating the DMA check outright -- gambatte's approach, where the
conflict is folded into a swapped memory-map pointer so the fast path is
untouched -- would win at most that 0.37% here, because dingbat's read path is
a `case idx` range dispatch rather than a page-pointer table. Converting it is a
core rewrite, for a third of a percent.

## Rules for the next person benchmarking this path

1. Use `DINGBAT_BENCH_COUNTERS=1` and compare **instructions**, not fps.
2. Check `cycles=` matches between arms first, or the arms did different work.
3. Diff per-function sizes between the two binaries before believing any
   result. If more than the functions you edited changed size, you measured an
   inlining decision, not your change.
4. `uptime` before trusting even the counter numbers for wall-clock claims.
