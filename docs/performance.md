# Performance Optimization Log

This document tracks performance profiling and optimization work on the
dingbat emulator. It serves as a reference for future optimization efforts.

## Profiling Setup

- **ROM:** Pokemon Ruby (GBA) — representative of real-world game workload
- **Tool:** macOS `sample` (1ms sampling interval, 10-second runs)
- **Build:** `nim c -d:danger -d:lto --opt:speed src/dingbat.nim`
- **Hardware:** Apple Silicon (ARM64)

## Optimization History (2026-03-09)

Starting point: the Nim port ran roughly 2x slower than the original Crystal
implementation. Profiling identified overhead from Nim runtime features rather
than algorithmic differences.

### 1. Disable threads and switch to ARC (`8761dc6`)

Nim 2.2+ defaults to `--threads:on`, which makes all module-level variables
thread-local. Every access goes through `_tlv_get_addr` — a measurable cost
when it appears in CPU instruction handlers, PPU rendering, and the scheduler
(all called millions of times per frame). Since the emulator is
single-threaded, this is pure overhead.

Switching from ORC to ARC removes the cycle collector (`rememberCycle`),
which was firing frequently due to closure ref-counting in the scheduler.

| Setting | Value |
|---------|-------|
| `threads` | `off` |
| `mm` | `arc` |
| Added to | `nim.cfg` |

**Result:** ~25% reduction in emulation CPU time.

### 2. Eliminate closure allocations in scheduler (`600be9d`)

The scheduler stored `proc() {.closure.}` callbacks in each event. Every
`schedule()` call heap-allocated a new closure, and every `call_current()`
deallocated one. APU channels were the worst offenders — channel 4 (noise)
reschedules itself every ~32-512 CPU cycles, creating thousands of closures
per frame.

The Crystal reference uses `Proc(Nil)` (a value-type method pointer with no
heap allocation). Our fix goes further: remove closures entirely and dispatch
on `EventType` via a `case` statement.

Changes:
- Removed `cb: proc() {.closure.}` from `Event`
- Added `dispatch: proc(kind: EventType) {.closure.}` to `Scheduler` (set
  once at emulator init — one closure total instead of thousands per frame)
- Split event types for 1:1 callback mapping:
  - `etAPU` -> `etAPUFrameSeq` + `etAPUSample`
  - `etPPU` -> `etPPUStartLine` + `etPPUStartHBlank` + `etPPUEndHBlank`
- Removed `events: array[4, proc()]` and `interrupt_flags: array[4, proc()]`
  from `Timer` and `DMA` types; replaced with inline `case` dispatch
- Removed `make_timer_irq_flag`, `make_overflow_event`, `make_dma_irq_flag`
  closure-factory procs

**Result:** ~37% reduction in remaining emulation CPU time. Eliminated all
`rawAlloc`, `rawDealloc`, `eqsink`, and `rttiDestroy` from the scheduler
hot path.

### 3. Add `{.inline.}` to hot-path functions (`017daf2`)

The Crystal reference marks hot functions with `@[AlwaysInline]`. Nim's
compiler may inline based on heuristics, but `{.inline.}` guarantees it.
This matters most for small functions called from tight inner loops.

Functions marked:
- **CPU:** `check_cond`, `lsl`, `lsr`, `asr`, `ror`, `sub`, `sbc`, `add`,
  `adc`, `fill_pipeline`, `read_instr`
- **Bus:** `read_byte_internal`, `read_half_internal`, `read_word_internal`
- **PPU:** `se_address`

Note: forward declarations in `gba.nim` must have matching `{.inline.}`
pragmas or the compiler will error.

**Result:** Modest improvement (hard to isolate with `-d:lto` already
enabling cross-module inlining, but guarantees correct behavior at all
optimization levels).

### Cumulative Results

| Stage | Emulation CPU samples (10s) | Reduction |
|-------|-----------------------------|-----------|
| Original (threads:on, ORC, closures) | ~1385 | — |
| After threads:off + mm:arc | ~1045 | 25% |
| After closure elimination | ~660 | 37% of remaining |
| After inline annotations | ~655 | ~1% (LTO already helped) |
| **Total** | **~655** | **~53%** |

## Current Profile (post-optimization)

With overhead eliminated, the remaining CPU time is genuine emulation work:

| Component | Samples | % of emulation CPU |
|-----------|---------|-------------------|
| PPU `calculate_color` (blending/windowing) | ~233 | 36% |
| PPU `render_reg_bg` (background tiles) | ~246 | 38% |
| PPU `render_sprites` | ~36 | 5% |
| Scheduler `insert` (sorted insertion) | ~48 | 7% |
| Timer/DMA/APU | ~50 | 8% |
| CPU instruction handlers | ~40 | 6% |

## Future Optimization Opportunities

### Scheduler: `seq` to `Deque` (skipped — low impact now)

Crystal uses `Deque` with O(1) `shift` (front removal) vs our `seq` with
O(n) `delete(0)`. However, Nim's `std/deques.Deque` lacks `insert` at
arbitrary positions and `delete` by index, making the migration complex.
With ~10 events in the queue and closures eliminated, the scheduler is only
~7% of CPU time. Not worth the complexity.

### Scheduler: binary search for insertion (skipped — low impact)

Crystal uses `bsearch_index` for O(log n) sorted insertion. With ~10 events,
linear search is faster due to cache effects. Only revisit if event count
grows significantly.

### PPU rendering optimizations

The PPU now dominates at ~79% of emulation CPU. Possible approaches:
- **Dirty-line tracking:** skip re-rendering unchanged scanlines
- **SIMD color blending:** `calculate_color` does per-pixel blend math that
  could benefit from NEON/SSE intrinsics
- **Tile caching:** avoid re-decoding unchanged tiles each scanline
- **Layer compositing:** batch layer operations instead of per-pixel priority

### Storage virtual dispatch

`Storage` uses `method` (vtable dispatch) for cartridge save read/write.
Could replace with enum-based dispatch to avoid indirection. Low impact since
save access is infrequent during normal gameplay.

### DMA channel caching

`trigger_hdma` and `trigger_vdma` loop all 4 DMA channels every HBlank/VBlank
even when none are active. Caching which channels are HBlank/VBlank-triggered
would skip the loop entirely when no DMA is configured for that timing.

## Comparison with Crystal Reference

Key architectural differences that affect performance:

| Aspect | Crystal | Nim |
|--------|---------|-----|
| Instruction LUT | Runtime `Proc` array (4096/256 entries) | Compile-time `const` array (4096/1024 entries) |
| Scheduler events | `Deque` + `Proc(Nil)` value type | `seq` + enum dispatch (no closures) |
| Scheduler removal | `Deque.shift` O(1) | `seq.delete(0)` O(n) for ~10 items |
| Register arrays | `Slice` (heap pointer) | `array` (stack-allocated, zero indirection) |
| Inlining | Explicit `@[AlwaysInline]` | Explicit `{.inline.}` |
| GC | Boehm GC | ARC (no cycle collector) |
| Thread model | Single-threaded by default | `--threads:off` (Nim 2.2+ defaults to on) |

The Nim port has advantages in LUT generation (compile-time vs runtime) and
register storage (stack arrays vs heap slices), while Crystal's `Deque` and
`Proc` value types were more efficient for the scheduler until we eliminated
closures entirely.

---

# Optimization round: 2026-07-24 (FireRed, in-game save state)

Driven by a report that the browser build no longer reached the ~400-450 fps
it used to on an M2 MacBook, and that enabling the MP2K audio HLE cost a
visible chunk of it.

## Method

Two harnesses, both measuring *emulation only* (no present, no audio
scheduling, no rAF pacing), on Pokemon FireRed resumed from an in-game save
state so the workload is real gameplay rather than the title screen:

- **Web:** `web/bench/bench.html` drives `_benchFrames` through the wasm
  exports; `web/bench/cdp.mjs` runs expressions in the page over CDP.
- **Native:** `tests/dingbat_bench.nim`, which now takes
  `DINGBAT_BENCH_STATE=<file.state>` to resume the same scene.

Every change below was gated on `DINGBAT_BENCH_HASH=1` producing a
byte-identical rolling framebuffer hash across 60 ROMs, plus an unchanged
mGBA suite score (6910/7008).

> **Measure in a visible browser window.** Headless Chrome on Apple Silicon
> gets background QoS and is scheduled onto efficiency cores: the identical
> build measured 185 fps headless and 441 fps in a real window. An automation
> harness that launches Chrome headless will look like a catastrophic
> regression that does not exist. See `web/bench/README.md`.

> **Isolate saves when A/B-ing ROMs.** The emulator writes `.sav` next to the
> ROM, so running build A then build B over the same ROM has B booting from
> A's freshly written SRAM. That produced six phantom "mismatches" in the
> first sweep. Give each build its own copy of the ROM.

## Results

| Build | Web (HLE off) | Web (HLE on) | Native (HLE off) | Native (HLE on) |
|---|---|---|---|---|
| Before | 441 fps | 399 fps | 484 fps | 446 fps |
| After  | 464 fps | 445 fps | 731 fps | 691 fps |
| Delta  | +5.2% | **+11.5%** | +51% | **+55%** |

Audio-HLE overhead fell from 9.5% to 3.1% on the web build.

## 1. Collapse the per-instruction audio-HLE hook checks

`cpu.tick` ran three separate HLE tests on *every instruction*: the MP2K mixer
hook, its learning probe, and the Camelot "Bon" hook. Each re-loaded
`gba.mp2k_hle`, its driver pointer and a hook address, and two of them
independently recomputed the pre-pipeline PC. All three fire at most once per
frame — profiling showed the checking cost more host time than the mixing
(`tick` self-time rose 941 -> 1187 samples with HLE on, while the actual
`render_sample` work was only 90).

They now share one sentinel compare against `cpu.hle_hook_pc`, recomputed by
`refresh_hle_hook` at each arm/disarm site (once per frame after the driver
polls, plus immediately when MP2K learns its entry mid-frame). The work moved
out of line into `fire_hle_hook`. With HLE off the path is one load and one
perfectly-predicted branch.

A single slot serves both drivers because they are mutually exclusive by
construction: `gs_frame_poll` refuses to engage once MP2K has learned a hook,
and MP2K only probes on its own SoundInfo ident.

**Native: 446 -> 465 fps (+3.5%)**, with `hook_fires`, `engaged` and
`avg_out_energy` bit-identical.

## 2. Render backgrounds a tile span at a time

`render_reg_bg` walked 240 pixels, recomputing the effective column,
re-deriving `tile_x` and testing it against the previous column's to catch the
~30 tile boundaries that actually matter, and re-testing `is_8bpp` per pixel.

It now walks tile spans. A span never crosses a tile boundary and never wraps
(`bg_width + 1` is 256 or 512, both multiples of 8), so the screen entry, tile
row base, flip mask and palette bank are computed once per tile. The 4bpp case
— by far the common one — pulls the whole 4-byte tile row as a single aligned
word instead of one byte load per pixel.

**Native: 491 -> 513 fps (+4.5%)**

## 3. Inline `next_layer`

The per-pixel layer walk returned a three-field tuple from an out-of-line
proc, so every call went through memory (sret) instead of registers, 1-3 times
per pixel on the windowed/blending path. Marking it `{.inline.}` also lets the
compiler hoist `walk_n` / `walk_bgs` / `bitmap_direct` out of the column loop.

**Native: 513 -> 533 fps (+3.9%)**

## 4. Disable the AArch64 machine outliner (native only)

The single largest win, and it is one flag. Apple's clang enables the machine
outliner by default at -O2 and above; it factors recurring instruction
sequences into shared subroutines for code size. In an emulator that means the
hottest straight-line code pays a call/return per occurrence — it showed up in
`sample` as a wall of `OUTLINED_FUNCTION_*` leaf entries totalling ~15-20% of
all samples.

`nim.cfg` now passes `-mno-outline` for `arm64 and not emscripten`, covering
the macOS and iOS builds.

**Native: 511 -> 693 fps (+35%)**, pixel-identical across 60 ROMs.

`em.wasm` is *byte-identical* with and without the flag — the outliner is an
AArch64 backend pass with no wasm equivalent — so the browser build is
unaffected. Worth re-testing on the Windows/x86-64 cross-build, where the
outliner is a different (and off-by-default) pass.

## Current profile after this round

Native, HLE on, leaf-weighted:

| Component | Share |
|---|---|
| `cpu.tick` self (dispatch prologue + cycle accounting) | ~17% |
| `composite` (incl. inlined `next_layer`) | ~8% |
| `bus.fetch_half` (instruction fetch) | ~6.7% |
| `render_reg_bg` | ~6.5% |
| `render_sprites` | ~2.8% |
| instruction handlers (`arm_execute`, thumb ops) | ~5% |
| scheduler (`schedule`, `tick_slow`, `fast_forward`) | ~4% |
| `render_sample` (HLE mixing) | ~1.2% |
| `analyze_loop` (waitloop detection) | ~1.1% |

## Next candidates, roughly by value

1. **CPU dispatch prologue.** `tick` re-tests `cpu.halted` up to four times
   and separately checks `irq_line`, `intr_wait_active` and
   `halt_resume_charge` every instruction, all rare. Collapsing them into one
   "something pending" bitmask tested once should recover a few percent — the
   same shape of win as the HLE hook collapse above.
2. **Instruction-fetch page cache.** `fetch_half` is ~6.7%. A cached
   (base pointer, limit, waitstate) tuple for the current fetch page,
   invalidated on branch and region change, removes most of the region
   dispatch on sequential fetches.
3. **Layer-at-a-time compositing.** The current compositor walks layers
   per pixel with a data-dependent early-out, which cannot vectorize. Building
   each BG row and combining rows with vectorized priority-select is the
   restructure that would make wasm SIMD128 / NEON usable here — the largest
   remaining structural opportunity for the PPU.
4. **`render_sprites` span batching**, mirroring what §2 did for backgrounds.
5. **wasm SIMD128** (`-msimd128`) for the 4bpp nibble expansion and the
   BGR555 blend math. Baseline in every current browser, but it needs either a
   second build or runtime feature detection for older targets.

See `docs/research_cached_interpreter.md` before reaching for a block cache or
JIT: the decoded-block ceiling was measured at only +8-12% because the
cycle-accurate timing model cannot be precomputed, and any such change has to
preserve the bit-exact determinism the rollback netplay depends on.
