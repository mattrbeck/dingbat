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

## Follow-up round: each candidate measured (2026-07-24, same session)

Every item on the original list was implemented or probed and **all but one
came back neutral**. Recorded here so the effort is not spent twice.

Re-profiled first, because the pre-`-mno-outline` ranking was distorted by the
`OUTLINED_FUNCTION_*` noise. Clean attribution, native, HLE on, 6880 samples:

| Component | Share |
|---|---|
| `cpu.tick` self | 24.4% |
| `composite` | 11.8% |
| `bus.fetch_half` | 11.5% |
| `render_reg_bg` | 8.5% |
| `render_sprites` | 3.6% |
| `scheduler.schedule` | 3.4% |
| `render_sample` (HLE mixing) | 1.7% |
| `analyze_loop` (waitloop detection) | 1.2% |

### Results

1. **CPU dispatch prologue — NEUTRAL, reverted.** Restructured so `halted` is
   tested once up front and returns early, making the `not cpu.halted` guards
   on the IRQ and IntrWait checks redundant (safe: `irq()` only ever wakes the
   CPU; only `check_intr_wait` can re-halt). Pixel-identical, and 724 vs 729
   fps — no better than baseline. Clang already keeps these flags in registers.
2. **Instruction-fetch page cache — ALREADY EXISTS.** `install_fetch_cache`
   caches (pointer, mask, 16/32-bit cost) per page and the ROM path has a
   `rom_hot` straight-line fast path. The original entry was written without
   checking; `research_cached_interpreter.md` already said so. The remaining
   11.5% is genuine fetch + waitstate work, not dispatch overhead.
3. **`render_sprites` invariant hoisting — NEUTRAL, reverted.** Hoisted eight
   sprite-constant values (obj_mode, priority, 8bpp, mapping, palette bank,
   tile id) out of the per-pixel loop and clipped the loop bounds instead of
   sweeping the full width with a `continue`. Pixel-identical across 60 ROMs
   and flat on FireRed, Metal Slug, Kirby and Sonic Pinball alike — clang's
   LICM was already hoisting all of it.
4. **wasm SIMD128 — +1.6%, NOT shipped.** `-msimd128` builds cleanly and does
   change codegen: 472.9 -> 480.5 fps (HLE off), 450.2 -> 458.7 (HLE on),
   best-of-9. Too small to justify the compatibility cost: wasm SIMD needs
   Safari 16.4+, so it would break the iOS 15 targets the frontend explicitly
   supports. Revisit only as a second build behind feature detection — or once
   §5 gives it something worth vectorizing.

### Ceilings, so the next attempt is not a guess

Measured by stubbing each stage out entirely. These are *valid* probes: the
emulated CPU never reads the framebuffer, so deleting render work cannot change
what the game executes. (Contrast the CPU-prologue probe, which was invalid —
skipping it stopped IRQs, froze the game and "measured" 2.3x.)

| Probe | fps | Ceiling vs 695.7 baseline |
|---|---|---|
| compositor removed entirely | 775.0 | **+11.4%** |
| `render_reg_bg` removed entirely | 729.3 | +4.8% |

So **layer-at-a-time compositing is the only structural PPU item left worth
attempting**, and even a perfect rewrite caps at +11.4% — realistically half
that. It is also the highest-risk code in the renderer (blending, windows,
sprite priority, semi-transparent objects), so it wants a dedicated session
with the 60-ROM hash A/B in the loop from the first commit. `render_reg_bg` is
done: 8.5% of profile with a 4.8% ceiling means it is already near optimal.

### The general lesson from this round

After `-mno-outline`, clang -O3 is already performing the micro-optimizations —
LICM, register promotion of hot flags, redundant-load elimination. Hand-hoisting
invariants out of inner loops now measures as noise. What remains in `tick`,
`fetch_half` and the instruction handlers is genuine work, not overhead. Future
gains have to come from doing *less work* (structural change) rather than doing
the same work more tidily, and every candidate should get a stub-out ceiling
probe before anyone writes the optimization.

See `docs/research_cached_interpreter.md` before reaching for a block cache or
JIT: the decoded-block ceiling was measured at only +8-12% because the
cycle-accurate timing model cannot be precomputed, and any such change has to
preserve the bit-exact determinism the rollback netplay depends on.

---

## Investigation: layer-at-a-time SIMD compositing (2026-07-24) — NO-GO

Assessed the one structural item the previous round left open. Recommendation
is **don't build it**, on cost/benefit rather than impossibility.

### The prize, measured on web (the target)

Stubbing the compositor out entirely, best-of-9 in a real Chrome window:

| | baseline | compositor removed | ceiling |
|---|---|---|---|
| HLE off | 468.6 | 511.5 | **+9.2%** |
| HLE on | 445.5 | 484.6 | +8.8% |

That is the hard ceiling for *deleting* the compositor. Any rewrite still has
to do the work, so it captures a fraction — realistically 3-5%.

### Feasibility: better than expected

The obvious objection — wasm SIMD128 has no gather instruction, and the
compositor's core operation is a PRAM palette lookup — turns out not to bite.
Replacing every palette lookup with a constant (keeping the walk and all
opacity tests intact) measured **469.3 vs 468.6 fps: no change at all**. PRAM
is 1 KB and permanently L1-resident, so the gather is free.

So the compositor's ~9% is the *walk logic* — per-pixel loop, opacity tests,
priority comparisons, branches — which is exactly what a branchless 16-lane
byte pass would vectorize well. `layer_palettes` is already laid out as one
contiguous 240-byte row per BG, which is the right shape for it.

### Why it is still a no-go

**It is three implementations, not one.** `composite` has three paths and all
three carry real games (400-frame samples from boot):

| Game | fast | blend-only | windowed |
|---|---|---|---|
| Mega Man Zero | 92% | — | 7% |
| Metal Slug Advance | 91% | 8% | — |
| Kirby: Nightmare in Dream Land | 89% | — | 10% |
| Pokemon Emerald | 78% | 21% | — |
| Pokemon FireRed (title) | 24% | — | 75% |
| Final Fantasy Tactics Advance | 32% | — | 67% |
| Advance Wars | — | 32% | 67% |
| Superstar Saga | 18% | 81% | — |
| Golden Sun | 2% | 97% | — |
| Metroid Fusion | — | 100% | — |

The fast path is the only easy one to vectorize. The blend path conditionally
runs a *second* layer walk per pixel to find the blend target — data-dependent
work that does not vectorize cleanly. The windowed path has a per-pixel enable
mask and per-pixel effect flag.

And note the FireRed save state this whole round was tuned against is **100%
windowed** — the hardest path. A fast-path-only SIMD compositor would do
nothing for the exact workload that prompted the work.

**The devices that need it most are the ones that cannot run it.** wasm SIMD
needs Safari 16.4+ (March 2023). The iOS 15 devices the frontend explicitly
supports (see the iOS 15 compat work) are iPhone 6s-X era — precisely the slow,
battery-constrained hardware a speedup would help, and precisely the hardware
that would fall back to the scalar path.

**The bundle cost is real.** Feature detection itself is the easy part —
`WebAssembly.validate()` on a tiny SIMD module is reliable and needs no UA
sniffing. The problem is `web/sw.js`, which precaches `./em.js` and `./em.wasm`
by fixed name for the offline PWA. Two bundles means either precaching both
(offline install goes 1.2 MB -> 2.4 MB of wasm) or making service-worker
install feature-dependent, which is a meaningfully more fragile install path
for an app with a deliberate offline story.

**And the scalar path never goes away.** Every compositor change would have to
be made and verified twice, in the most correctness-sensitive code in the
renderer — the code the 6910/7008 mGBA suite score and the 60-ROM pixel A/B are
mostly measuring.

### Verdict

3-5% on web, for three SIMD implementations, permanent dual maintenance of the
renderer's hardest code, a doubled offline payload, and no benefit on the
oldest devices. Revisit only if the compositor's share grows substantially, or
if a future baseline makes SIMD assumable without a fallback.

---

## Old / constrained devices (2026-07-24)

Different problem from raw throughput. What follows is measured on an M2 with
CPU throttling as a stand-in for slow hardware; treat it as a headroom budget,
not a device compatibility list (throttling scales compute but not cache or
memory latency).

### Headroom

FireRed from the in-game save state, audio HLE on, emulation only:

| throttle | fps | realtime |
|---|---|---|
| 1x | 447.9 | 7.50x |
| 2x | 213.9 | 3.58x |
| 4x | 105.5 | 1.77x |
| 6x | 70.3 | 1.18x |
| 8x | 52.5 | **0.88x** |

Full speed needs hardware no worse than ~7x slower than an M2 performance core,
and that is emulation alone — presentation, audio scheduling and touch handling
come out of the same budget.

### The dominant risk is JIT demotion, not instruction count

An A9-class phone lands somewhere around 1.2-1.9x realtime by this budget:
playable with little margin. But if Safari demotes the tab's wasm to its
baseline compiler under memory pressure, the multiplier is far larger than
anything on the optimization list — it turns a 1.5x-realtime device into a
sub-realtime one in one step. That is the "slow until force-quit" symptom.

**So on these devices, memory stability buys more frames than any amount of
micro-optimization.** A 5% throughput win is irrelevant next to staying under
the tab's memory budget. Rank work accordingly.

### Shipped: cache the ROM CRC instead of re-reading the ROM

`netlink_init` and `netlink_attach` each re-read the entire ROM back out of the
Emscripten FS purely to `crc32` it — a full 16 MB read plus a 16 MB transient
allocation for a 4-byte result, at exactly the moment (starting online play) a
pressured phone can least afford a spike. The CRC is now computed once at load
from the cartridge buffer.

`Cartridge` gained `rom_size` (the true file length, i.e. the buffer minus its
power-of-two zero pad and minus the Classic NES 4x mirrors) so the hash covers
exactly the bytes a peer gets from hashing the file. Verified byte-identical to
`crc32(readFile(rom))` across all 60 local ROMs — the value is wire-visible, so
a mismatch would reject real peers.

### Known, not fixed: the ROM is resident twice

A 16 MB game occupies 16 MB in the cartridge buffer *and* 16 MB in the
Emscripten FS for the whole session. MEMFS keeps file contents on the JS heap,
so this does **not** show up in `Module.memory.buffer.byteLength` — it is
invisible to the obvious instrument but entirely real to the tab's memory
budget, which is what iOS Safari kills on.

Deleting the FS copy after load looks trivial and **is a trap**: three paths
reboot the core by calling `loadRom` again *without* re-staging the ROM —
the Reset button (`index.js:4618`), the post-save-delete reboot
(`resetLoadedGameSave`), and the save-import reboot (`applyImportedSave`). The
FS file is the only copy of those bytes the JS side can reach. Deleting it
breaks Reset.

The right fix is a wasm-side reset that rebuilds the core from the cartridge it
already holds, after which the FS copy can be dropped at load. That also makes
Reset cheaper (no 16 MB FS write and re-read). Re-staging from IndexedDB
instead was considered and rejected: it makes Reset async and dependent on a
store that can fail in private mode or when quota-bound.

### Other candidates, unmeasured

- **Rewind ring.** Capped at 16 MB on iOS. On the oldest devices that is a
  large slice of the budget for a feature that is arguably a desktop luxury —
  worth making adaptive, or opt-in below some device threshold.
- **Startup.** 1.2 MB of wasm has to be compiled by Safari's baseline compiler
  before anything runs. Worth timing on real hardware before assuming it is
  fine.
- **Audio buffer sizing.** Underruns are heard as stutter and cost more
  perceived quality than a few fps; the pacing margin that is right on a
  desktop may be too tight when the device is at 1.2x realtime.
