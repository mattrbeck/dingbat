# Performance Optimization Log

This document tracks performance profiling and optimization work on the
crab_nim emulator. It serves as a reference for future optimization efforts.

## Profiling Setup

- **ROM:** Pokemon Ruby (GBA) — representative of real-world game workload
- **Tool:** macOS `sample` (1ms sampling interval, 10-second runs)
- **Build:** `nim c -d:danger -d:lto --opt:speed src/crab.nim`
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
