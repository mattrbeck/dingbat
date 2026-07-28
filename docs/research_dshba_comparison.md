# Research: what dingbat can learn from DSHBA

**Date:** 2026-07-27
**Subject:** [DSHBA](https://github.com/DenSinH/DSHBA) — DenSinH's "pure performance"
GBA emulator (C++, OpenGL hardware renderer, cached interpreter). Reports ~900-1000 fps
on Pokémon Emerald and 5-17k fps on menu screens.
**Question:** Are any of its techniques applicable to dingbat, given our stricter
accuracy requirements?

**Short answer:** Almost everything on DSHBA's optimization list is *already* in
dingbat, and the three items that were not, I implemented or probed this session and
**all measured as noise**. The one genuinely unharvested idea is its **hardware
renderer**, and that turns out to have a far bigger prize than we previously
believed: removing PPU rendering entirely is worth **+20% to +85%** (mean ~+47%)
across eight games, not the +11% the 2026-07-24 round inferred from a
compositor-only probe. It remains a no-go to build for the reasons in
`performance.md`, but the *size* of the number should change how we rank future
renderer work.

---

## Method

Cloned DSHBA and read the core in full: `Mem.h` / `MemReadWrite.inl` /
`MemPageTables.inl` / `MemDMA.inl` / `MemDMAUtil.inl`, `scheduler.h`,
`ARM7TDMI.h` / `.cpp` / `Pipeline.h`, the THUMB instruction `.inl` files, and
`include/helpers.h`.

Measurements are native, Apple Silicon,
`nim c -d:test_harness -d:danger -d:lto --opt:speed`, via `tests/dingbat_bench.nim`,
600 frames after 120 warmup, best-of-N (N=5 or 7). Eight ROMs; Pokémon Emerald runs
from an in-game save state, the rest from boot. Each build got its own copy of every
ROM so neither could boot from the other's freshly written `.sav` (the trap recorded
in `performance.md`).

Every candidate that produced a shippable diff was gated on
`DINGBAT_BENCH_HASH=1` rolling framebuffer hashes being byte-identical to baseline
across all eight ROMs before its fps number was believed.

### Baseline profile (Pokémon Emerald, in-game, leaf-weighted, 6777 samples)

| Component | Share |
|---|---|
| `step_frame` self (= `cpu.tick` fully inlined) | 25.6% |
| `render_reg_bg` | 14.4% |
| `fetch_half` | 9.1% |
| `composite_span` | 7.1% |
| scheduler dispatch closure (incl. inlined `scanline` body) | 7.0% |
| `render_sprites` | 5.6% |
| `fetch_word` | 3.0% |
| ARM/THUMB instruction handlers | ~10% |
| data read/write paths (`[]`, `read_word`, `*_internal`) | ~4% |
| **DMA (`run_pending`)** | **0.4%** |

Note this differs sharply from the FireRed-derived profile in `performance.md`: that
save state is 100% windowed compositing, which flatters the compositor's share and
understates `render_reg_bg`. Emerald is the more representative gameplay workload.

---

## Technique-by-technique verdict

| DSHBA technique | Status in dingbat |
|---|---|
| Templated instruction handlers | **Already have.** `arm/lut.nim` + `thumb/thumb.nim` build 4096/1024-entry `const` tables of generic instantiations with static fields baked in — compile-time, where DSHBA's is runtime-built. |
| Faking the pipeline | **Already have.** `pipeline.nim` is a 2-slot latch, filled only when needed; SMC near-PC writes snapshot the pre-write opcodes. Same idea as DSHBA's `FakePipelineFlush` / `PipelineReflush`. |
| Circular i32 scheduler clock | **Already have, better.** `common/scheduler.nim` uses `uint32` + `rebase()` on wasm and `uint64` natively. DSHBA's trick exists because it compiles 32-bit, where a u64 tick costs two instructions; on 64-bit native that motivation is gone. Our queue is a fixed sorted array with O(1) pop and an inlined `tick` — DSHBA uses `std::priority_queue` with a linear-scan `remove`. |
| Batching APU ticking | **Already have, further.** GBA PSG does lazy closed-form catch-up (2b323ff); the GB APU likewise. |
| Fast open-bus reconstruction | **Already have.** `read_open_bus_value`. |
| Compiler intrinsics / `likely`/`unlikely` | **Not used anywhere.** Left alone deliberately — see "measured as noise" below; `performance.md` already established clang is doing these micro-optimizations for us after `-mno-outline`. |
| Memory read page tables | **Partially have, for the hot half.** `install_fetch_cache` caches (pointer, mask, 16/32-bit cost) per page for *instruction fetch*, plus a `rom_hot` straight-line path. Data reads still re-decode the region. See "not attempted" below. |
| Fast DMA (memcpy) | **Ruled out by profile.** DMA is 0.4% of runtime. Even a perfect memcpy DMA cannot pay for the classifier. |
| Cached interpreter | **Already researched** — `research_cached_interpreter.md` measured the ceiling at +8-12% because our cycle-accurate timing model cannot be precomputed. DSHBA reports 10-20%, consistent, and it can afford it because it does *not* model waitstates/prefetch. |
| Hardware (OpenGL) renderer | **The one real gap.** Ceiling measured below. |
| Affine 4x supersampling | Quality feature, not perf. Genuinely nice; orthogonal. |
| OAM update delay | **We don't model it.** Accuracy observation, not perf — see below. |

---

## Experiments run this session

All three were implemented, hash-gated, and measured. All three are **not worth
shipping**, recorded here so the effort is not spent twice.

### 1. Eliminate the redundant per-scanline BG clears — NOISE

`scanline` pre-clears 240 bytes per enabled BG, then `render_reg_bg` writes **all
240 pixels unconditionally** (every path, including the transparent-tile cases,
stores to `dst[col + k]`). For text BGs the clear is pure dead work. It is
genuinely load-bearing for `render_aff_bg`, which `continue`s past out-of-range
pixels, and for BGs enabled in DISPCNT but not rendered in the current mode.

So a safe version was available: skip the clear only for BGs the current mode will
fully overwrite (all four in mode 0, the most common mode in real games).

Ceiling probe first, per the `performance.md` rule — clears removed entirely:

| Game | ceiling |
|---|---|
| GoldenSunTLA | +1.91% |
| MetroidFusion | +0.69% |
| SuperstarSaga | +0.57% |
| PokemonRuby | +0.30% |
| PokemonFireRed | +0.17% |
| PokemonEmerald | +0.15% |
| AdvanceWars | +0.04% |
| Kirby | −0.08% |

**Verdict: not built.** clang vectorizes the clear into a memset over a 240-byte
L1-resident buffer. The whole idea is worth at most 0.5%, and the safe version
captures only part of that.

### 2. Branchless condition-code evaluation — NOISE / SLIGHTLY NEGATIVE

DSHBA evaluates conditions as `(Conditions[cond] >> (CPSR >> 28)) & 1` — a 16-entry
truth table indexed by the NZCV nibble, one load + shift + mask, no branch. Ours is
a 16-way `case` on `cond` that clang lowers to an indirect jump, and **every ARM
instruction pays it** (`arm_execute` checks before dispatch) plus every THUMB
conditional branch.

Implemented, with the table generated at compile time from exactly the predicates
the old `case` used (identical by construction, not by inspection). Our PSR already
places N/Z/C/V at bits 31-28, so the trick ports directly.

Hash-gated byte-identical across all 8 ROMs. Result:

| Game | delta |
|---|---|
| PokemonRuby | +0.65% |
| GoldenSunTLA | +0.53% |
| SuperstarSaga | +0.30% |
| PokemonEmerald | −0.13% |
| MetroidFusion | −0.31% |
| PokemonFireRed | −0.65% |
| Kirby | −1.58% |
| AdvanceWars | −1.94% |

**Verdict: reverted.** The premise doesn't hold on ARM64: the overwhelming majority
of ARM instructions use `AL` (0xE), so the indirect branch has one dominant target
and predicts near-perfectly. The LUT replaces a correctly-predicted branch with a
guaranteed memory load. DSHBA's win here is an x86/32-bit artefact.

### 3. Full PPU render removal — the ceiling probe that matters

A valid probe: the emulated CPU never reads the framebuffer, so deleting render work
cannot change what the game executes.

| Game | baseline | no PPU render | ceiling |
|---|---|---|---|
| MetroidFusion | 2191.5 | 4061.7 | **+85.3%** |
| SuperstarSaga | 2608.6 | 4426.8 | **+69.7%** |
| PokemonRuby | 1499.8 | 2377.2 | **+58.5%** |
| Kirby | 1160.0 | 1703.4 | **+46.8%** |
| PokemonEmerald | 1185.1 | 1716.4 | **+44.8%** |
| AdvanceWars | 940.7 | 1193.8 | **+26.9%** |
| GoldenSunTLA | 973.0 | 1176.2 | **+20.9%** |
| PokemonFireRed | 1065.9 | 1277.2 | **+19.8%** |

Mean ~+47%.

---

## The one real finding: the PPU prize is much larger than we thought

`performance.md`'s 2026-07-24 SIMD-compositor investigation concluded NO-GO on a
measured ceiling of **+9.2%** — but that was *compositor only*, measured on a
FireRed save state that is 100% windowed. The full renderer — `render_reg_bg`,
`render_sprites`, `composite`, the per-scanline clears and the layer-walk setup —
is worth **20-85%**. That is the number DSHBA's architecture is aimed at, and it is
why its headline figures look the way they do.

This does **not** overturn the SIMD no-go, whose reasoning (three compositor paths,
dual maintenance of the renderer's hardest code, iOS 15 devices can't run wasm SIMD,
doubled offline payload) stands unchanged. But it does mean:

- Renderer work should be ranked against a **~47% mean** prize, not ~9%.
- The biggest single named component is now **`render_reg_bg` at 14.4%**, not the
  compositor. It was declared "done, near optimal" in the last round on the basis of
  a +4.8% stub-out ceiling measured on FireRed — a windowed, sprite-heavy scene that
  is unrepresentative. That conclusion is worth re-measuring on Emerald/Ruby before
  it is trusted.
- A GPU renderer specifically remains a no-go for dingbat, for a reason DSHBA never
  faces: our framebuffer is *read back* every frame by `frame_static`, the rewind
  ring, save-state thumbnails and the screenshot path. DSHBA renders and presents;
  we render, hash, thumbnail and rewind. GPU readback per frame would eat the win
  and add latency, on top of the dual-implementation and web/iOS-15 objections.

---

## Not attempted, with reasoning

**Data-read page tables.** DSHBA indexes a flat `u8*[4M]` table by `address >> 10`,
with `nullptr` meaning "take the slow path". Ours re-decodes the region on every data
access — `[]`/`read_word` compute the page for timing, again for the MMIO/catch-up
test, and a third time inside `read_*_internal`. Collapsing that into one indexed
load of `{ptr, mask, cost16, cost32, flags}` is the natural port, and we have already
proved the technique works for instruction fetch.

Not attempted because the visible share is ~4% (much is inlined into handlers, so
that understates it) and because three independent micro-optimizations this session
all landed in the noise — consistent with `performance.md`'s conclusion that after
`-mno-outline`, clang is already performing this class of transformation. If anyone
does try it, ceiling-probe it first.

**Lazy N/Z flags.** The one DSHBA idea *not* on its README, and structurally
different from the rest: in THUMB mode it stores the raw ALU result to `LastNZ`
(one store) and materializes N/Z into CPSR only when the flags are actually read —
conditional branch, SWI, IRQ entry, BX, MSR. It encodes "flags currently unknown"
in bit 32 of a u64 so the ARM→THUMB transition can seed it.

This *removes* work rather than reorganizing it, so it is the most plausible
remaining candidate. It was not attempted here because it is invasive in exactly the
places dingbat is most conservative: every THUMB ALU site, every flag reader, plus
mandatory materialization before save-state serialization and before every rollback
netplay snapshot — a new correctness hazard class in determinism-critical code. Note
also that THUMB conditional branches flush on every taken check, so the saving is
only over ALU ops whose flags are dead before the next flag-setting op.

Worth a ceiling probe before anyone commits to it. A valid one is not obvious —
stubbing flag computation changes execution — which is itself a reason to be wary.

---

## Accuracy observation (not performance)

DSHBA models an **OAM update delay**: OAM writes take effect the scanline *after*
they happen. It got this nearly for free from its object-batching dirty flags
(one bool became two).

dingbat does not model this. `bus.write_*` stores straight into `ppu.oam`, and
`ppu.scanline()` runs at the *start* of H-blank, after all 960 visible cycles of that
line have elapsed. On hardware, sprite data for line N is fetched during line N−1's
H-blank, so an OAM write during line N−1's visible period should not affect line N.

This is the standard scanline-renderer simplification and I have **not** verified it
against hardware or found a failing test — flagging it as worth a targeted test ROM,
not as a confirmed bug. Given `render_sprites` is 5.6% of runtime and the fix is a
double-buffer of OAM, it is cheap if a test does show a divergence.

---

## Recommendations

1. **Don't port anything from DSHBA's optimization list.** We have it, or it
   measures as noise here, or the profile rules it out. This document is the record;
   re-deriving it is wasted effort.
2. **Re-measure `render_reg_bg`'s ceiling on Emerald/Ruby.** It is the largest named
   component at 14.4%, and the "already near optimal" verdict rests on a FireRed
   probe that is unrepresentative of the workload.
3. **Rank future renderer work against ~47%, not ~9%.** The SIMD no-go stands, but
   it was decided against a number that was 5x too small.
4. **Treat lazy N/Z flags as the only live CPU-side candidate**, behind a ceiling
   probe, and with the save-state/rollback materialization requirement understood up
   front.
5. **Consider a test ROM for OAM write timing.**
