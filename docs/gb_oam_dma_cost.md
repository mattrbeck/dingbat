# Benchmarking the GB CPU bus hot path

`mem_read`/`mem_write` sit on clang's inline-cost threshold with ~160
generated opcode bodies calling them. This is how to measure a change there,
and why wall-clock fps cannot.

## Use retired instructions, not fps

Two builds that differ only in code the benchmark never executes measure
~1.3 % apart in fps from link layout alone; layout error is systematic, so no
sample count averages it out. `dingbat_bench` reports hardware counters under
`DINGBAT_NO_WAITLOOP=1 DINGBAT_BENCH_COUNTERS=1 ./dingbat_bench rom.gb 2400 300`
(`proc_pid_rusage(RUSAGE_INFO_V4)` around the measured window; no root, no
Xcode), printing `cycles=`, `instructions=` and `hwcycles=`:

- `instructions` reproduces to 0.002 % run to run on an idle machine.
  `ri_instructions` includes kernel work charged to the process, so a
  contended run reads high (0.5 % at load average ~100, correlated with the
  run's own fps). Check `uptime`; take the minimum of four or more runs per
  arm and require the minima to agree to ~0.01 %.
- `cycles=` (emulated) is the control: both arms must report the same count
  or they did different work.

## The inline cliff

Adding or removing one compare on `mem_read`/`mem_write` flips whether clang
inlines them into a large, arbitrary subset of the opcode bodies
(`colonanonymous` 108 → 324 bytes, `cb_set` 156 → 320; 123–162 functions
changed size between builds meant to differ by three instructions). That
flip is worth ~0.9 % of all retired instructions, more than the OAM-DMA
bus-conflict model and the PPU VRAM/OAM lock combined, and every edit here
re-tosses it. `hot_bus_inline` (`gb.nim`) pins it: `always_inline` on clang
(−0.84 % DMG / −0.93 % CGB for +568 bytes of `__text`), plain `inline` on gcc,
where a failed `always_inline` is a hard error the CI builds cannot be proven
to avoid. Pinned, feature costs are additive: the PPU lock (+0.353 %) and the
DMA flag (+0.370 %) sum to the measured +0.722 % on Link's Awakening.

## What the OAM-DMA model costs, and why not less

- +0.37 % of retired instructions: three instructions (`ldrb`/`cmp`/`b.ne`)
  on the cached `dma_busy` flag per bus access. The cold handlers
  (`mem_read_busy`/`mem_write_busy`) take ~5 of 10 300 profiler samples:
  1.07 % of accesses land during a transfer, and games busy-wait in HRAM,
  which is on no bus.
- A DMA owns whole buses (cart+SRAM+WRAM, or VRAM, or CGB WRAM), so unlike the
  PPU lock it cannot be gated on the address first. Merging `dma_busy` into
  one "slow path" flag with the PPU lock was rejected: VRAM is locked ~40 %
  of every scanline, so ~40 % of all reads would go out of line to re-test an
  address that is almost never VRAM (Link's Awakening: zero CPU VRAM reads in
  28.9 M). Address test first, state test second.
- A bus access retires ~771 instructions, mostly the per-dot FIFO PPU, so the
  residue is small; removing it outright needs a page-pointer read path
  instead of the `case idx` dispatch, a core rewrite for a third of a percent.

## Rules

1. Compare **instructions** under `DINGBAT_BENCH_COUNTERS=1`, not fps.
2. Check `cycles=` matches between arms first.
3. Diff per-function sizes between the two binaries. If more than the
   functions you edited changed size, you measured an inlining decision.
4. `uptime` first; minimum of four or more runs per arm.
5. Build both arms the same way (`tools/gbgate/build.sh` slots, or two trees
   built by one script): identical source in different directories differs
   by up to 0.25 % (the nimcache path reaches the generated C and renumbers
   `_uNNNN` symbols). A failed `nim c` leaves the previous binary in place,
   so a stale slot reports the previous revision (`tools/gbppu/counters.sh`
   guards this).
