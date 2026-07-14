# Research: cached / bytecode interpreter for the GBA core

**Date:** 2026-07-11
**Question:** Some emulators translate hot ROM code paths into cached bytecode
executed by a VM, keyed by the address of the executing code. Would that help
dingbat's performance?

**Short answer:** The classic wins of this technique are mostly already
harvested in dingbat's current design, and the dominant per-instruction cost
that remains is the cycle-accurate timing model, which a block cache cannot
skip without regressing the mGBA suite score. A well-executed decoded-block
cache is worth roughly **+8-12% fps on CPU-bound games** (less on PPU-bound
ones) for ~1-2k lines of subtle, invalidation-prone machinery. There are
cheaper wins to take first. Details below.

## Background: what the technique actually is

The family of designs, from least to most aggressive:

1. **Decoded-dispatch interpreter** — decode each instruction word into a
   handler pointer via a lookup table; re-decode on every execution.
2. **Cached (block) interpreter** — at a branch target, decode the
   straight-line run of instructions *once* into an array of
   `(handler ptr, pre-extracted operands)` entries ("bytecode"), cache it
   keyed by address, and on re-entry execute the array directly — no
   instruction fetch, no decode, no dispatch-table hash. Dolphin and PPSSPP
   ship this as their middle tier.
3. **Dynarec / JIT** — same block discovery, but emit host machine code (or
   wasm) instead of a handler array. DraStic, No$GBA fast mode, PPSSPP/Dolphin
   top tier. Order-of-magnitude wins, but per-target backends, and on the web
   it requires runtime `WebAssembly.Module` generation with JS glue.

All of them pay for it in the same places: **self-modifying code
invalidation** (GBA games routinely copy hot code to IWRAM and overwrite
overlays), **interrupt granularity** (events must not slip to block
boundaries), and **timing fidelity** (per-access waitstates and prefetch
state don't batch).

## Where dingbat already is

Reading the core with this lens, dingbat is already design (1) with several
elements of design (2) baked in at compile time:

- **Decode is already cached — in the binary.** `arm/lut.nim` and
  `thumb/thumb.nim` build 4096/1024-entry `const` dispatch tables where every
  entry is a *generic instantiation* with the static instruction fields baked
  in (`thumb_conditional_branch[cond]`, `arm_data_processing[imm, op, set,
  shift]`…). The only runtime decode left in a handler is extracting register
  numbers / immediates — a few shifts and masks.
- **Instruction fetch is already a fast path.** `bus.fetch_half/fetch_word`
  keep a per-page pointer cache, and the `rom_hot` straight-line path reduces
  a sequential ROM fetch to one compare + one add + one masked load
  (2026-07 perf round 2).
- **Idle loops are already short-circuited** by `waitloop.nim` detection with
  a cached-verdict set, feeding `scheduler.fast_forward`.

So the headline savings a cached interpreter delivers elsewhere — "stop
re-decoding, stop re-fetching" — are mostly not available here anymore.

## Profile: what a block cache could and couldn't remove

Sampled this session (`sample`, 8s, release `dingbat_bench`, M-series Mac).
Pokémon Emerald intro (CPU-heavier of the two), ~6200 samples, top-of-stack:

| Bucket | Samples | % | Removable by block cache? |
|---|---|---|---|
| PPU (next_layer, sprites, reg/aff bg, scanline, composite) | ~1810 | ~29% | No |
| `cpu.tick` self (read_instr, pipeline, dispatch, per-instr checks, cycle bookkeeping) | 867 | ~14% | **Partially** |
| ROM timing model (`rom_access_cycles`) | 262 | ~4% | No — must run per access |
| `fetch_half`/`fetch_word` | 319 | ~5% | Data-read half yes; timing half no |
| `arm_execute` (cond check + LUT hash + indirect call) | 113 | ~2% | **Mostly** |
| `clear_pipeline` (branch refill) | 54 | ~1% | Bookkeeping yes; refill cycles no |
| Scheduler (`schedule`, `tick_slow`, `fast_forward` self) | ~280 | ~5% | No |
| Instruction handlers (scattered thumb_*/arm_* + rotate_register) | ~400 | ~6% | Operand re-extraction only |
| Waitloop analysis (`analyze_loop` + HashSet `contains`) | ~50 | ~1% | Yes — subsumed at decode time |
| Compiler-outlined chunks (mixed attribution) | ~900 | ~15% | Mixed |

Kirby (intro) is similar but with a large `fast_forward` halted-drain share —
already optimal, a block cache does nothing for halted time.

The genuinely addressable pool — pipeline buffer bookkeeping, `read_instr`
branchiness, LUT hash + cond dispatch, `tick()`'s per-instruction state
checks (`intr_wait_active`, `halt_resume_charge`, `entered_waitloop`,
halt/irq flags), opcode memory loads, operand re-extraction, waitloop HashSet
probes — is roughly **15-20% of total runtime**. A realistic implementation
captures maybe half of it (the execute loop still needs one indirect call and
one scheduler-budget compare per op). That lands at **+8-12% fps** on
CPU-bound games, less on PPU-bound ones, before counting icache-pressure
losses. For comparison: the PPU compositing rewrite was +31%, the fetch
pointer cache alone was +~50% on Emerald overworld.

**The structural reason the ceiling is low:** dingbat's per-instruction cost
is dominated by the *timing simulation* (prefetch credit, `rom_hot` stream
tracking, waitstate accumulation, scheduler catch-up) that the 2026-07
accuracy work (mGBA suite 4239→6734) depends on. That state is
history-dependent — it cannot be precomputed into a block at decode time. Any
design that batches or approximates it regresses the suite; any design that
keeps it per-op keeps most of today's cost.

## Design sketch, if we ever want it

For the record, the shape that fits dingbat:

- **Block** = decoded straight-line run starting at a branch target, ending
  at any instruction that can write PC (branches, `bx`, ALU/ldm with Rd=15,
  pop pc, SWI, msr/mode changes), capped at ~32 ops. Conditional non-branch
  ARM instructions stay in-block (handlers already receive the cond via the
  existing specialization; a pre-decoded `cond` byte per entry replaces
  `check_cond` + hash).
- **Entry** = `(handler: existing specialized proc ptr, instr: uint32,
  pc: uint32)`. Reuse the existing handlers unchanged — they take
  `(cpu, instr)` and charge timing through the existing `fetch/add_cycles`
  paths. Phase 2 could pack pre-extracted operands, but the win is small.
- **Fetch timing without fetching:** per op, call a `charge_fetch(page, addr,
  is32)` that is exactly today's `fetch_half/word` minus the masked load.
  This is what keeps the prefetch/`rom_hot` model — and the suite score —
  intact.
- **Cache key** = `address | thumb_bit`, open-addressed table. ROM/BIOS-page
  blocks are immutable. RAM blocks (IWRAM/EWRAM — where games put their
  hottest code, e.g. the m4a mixer) carry a generation stamp validated on
  entry against per-1KB page counters; CPU stores *and DMA writes* to pages
  2/3 bump the counter (one array store on the write path — measure it, this
  is the classic cost of the technique).
- **Events/IRQs:** per op, compare accumulated cycles against
  `scheduler.next_event` (same cost as today's inlined `tick`); when the slow
  path fires events, set a flag that breaks out of the block to re-run the
  halt/IRQ/IntrWait checks. Never defer events to block boundaries — that is
  precisely what the timer-IRQ suite tests would catch.
- **Subsumes waitloop detection** at decode time (block-level analysis could
  also finally catch the known miss shapes: BL-in-loop, oversized bodies —
  see waitloop findings).
- **Invalidation triggers:** savestate load (flush all), WAITCNT writes
  (nothing — timing is charged live, not baked), cheat/debugger pokes if ever
  added.
- **Known accuracy edge:** a store into the *very next* instruction slot is
  currently modeled by the 2-entry pipeline buffer (old value executes); a
  block executes decode-time values. Real self-modifying-adjacent code is
  rare on GBA (no icache to defeat) but AGS-style test ROMs may probe it.
- **Excluded regions:** BIOS (bios_latch open-bus semantics per fetch),
  page 0xD (EEPROM aliasing).

Cost estimate: ~1-2k lines touching the most calibrated code in the repo,
plus a write-barrier tax on every RAM store, plus savestate/netplay
(lockstep determinism) interaction testing.

## Recommendation

Don't build it now. The idea's premise — "decode and dispatch dominate" —
doesn't hold for dingbat: decode is compile-time specialized, fetch is a
pointer-cache fast path, and the remaining cost is the timing model we
deliberately paid for. Cheaper sequenced alternatives:

1. **Fold `tick()`'s rare-state checks behind one flag.** `intr_wait_active`,
   `halt_resume_charge`, `halted`, `irq_line` are almost always false/idle;
   a single `slow_path_flags` bitmask check per instruction with the rare
   handling out-of-line trims the 14% `tick` self bucket at near-zero risk.
2. **Extend waitloop detection** to the BL-in-loop / oversized-body miss
   shapes (4/9 mGBA-override loops still undetected) — idle-loop
   fast-forward is worth far more per detected loop than shaving dispatch.
3. **More PPU** — still the single largest bucket (~30-40%).
4. If web performance becomes the driver, revisit the block cache *as the
   groundwork for a wasm dynarec* (runtime `WebAssembly.Module` emission) —
   that's the only variant with order-of-magnitude headroom, and the block
   discovery/invalidation layer above is the reusable half of it.
