# Prefetch-model rewrite: occupancy model to close the 46 Timing fails

Status: **scoped, not started** (2026-07-14). Owner: next dedicated GBA-timing session.
Prereq baseline: `main` @ a6ec55e — mGBA suite 6898/7218 HLE, 6897 LLE.

## Objective

Replace the continuous **time-credit** prefetch model in `bus.nim rom_access_cycles`
with an integer **halfword-occupancy** model equivalent to mGBA's `GBAMemoryStall`,
closing the 46 remaining Timing failures **without** regressing:

- the ~1974 currently-passing Timing rows,
- DMA (1244/1256),
- waitloop detection (fast-forward relies on `rom_free_since`),
- link / rollback / speclink determinism (prefetch state is in the savestate),
- perf (this is the hottest bus function; `rom_hot` streaming keys off it).

**In scope:** the 46 Timing rows (32 DMA-to/from-ROM prefetch-ON columns, 12
`ldmia [#0x07FFFFF*]` region-crossing, 2 `ldr [#0x08000000]`), and — as a likely
free side-effect once ROM-source DMA open-bus is understood — a re-look at the 8
DMA `R+0x10` rows.

**Out of scope:** Timer count-up (separate prescaler-phase problem; a prefetch fix
must NOT touch the IRQ-entry cost that count-up +106 depends on), Misc H-blank,
the 2 Misc DMA-prefetch-*content*-readback rows (an unimplemented data feature,
not timing).

## The two models

### Current (time credit) — `bus.nim:100-126`
```
credit = min(now - rom_free_since, 8*s)         # continuous cycles, capped at buffer
need   = s (16-bit) or 2*s (32-bit)
cost   = max(1, need - credit)
rom_free_since advances by `need` (floored so credit never exceeds 8*s)
```
`rom_free_since` is the absolute cycle the ROM bus last went idle; elapsed time since
then IS the buffer fill. Continuous.

### Target (mGBA `GBAMemoryStall`, integer occupancy)
mGBA tracks `lastPrefetchedPc` (advanced in whole 2-byte steps) and derives buffered
**halfwords** as an integer: `previousLoads = (lastPrefetchedPc - PC) >> 1`. The buffer
fill since the last ROM access is computed as `elapsed_cycles / s` **floored to whole
halfwords**, capped at 8. The stall charged is then a function of that integer count.

### Why the −1
The models agree on straight-line code. They diverge by exactly 1 cycle when a
**non-fetch** ROM access (a DMA burst, or an LDM/LDR data-load into ROM) leaves a
**partial** halfword of accumulated fill. Our continuous model counts that partial
cycle as credit; mGBA's integer floor discards it → mGBA charges 1 more. That is the
uniform −1 seen only in prefetch-ON columns on the first CPU fetch after the ROM bus
was used for something other than a fetch. Proof it is not a local (credit,s) function:
the same `credit=2` value occurs in both a failing `P.S` refill and a passing `P..`
refill — the correct value depends on mGBA's integer `lastPrefetchedPc` phase, which we
do not maintain. (3 scoped patches were empirically falsified: whole-halfword floor
→ Timing 1758; −1 after any non-fetch ROM access → 1516; DMA-scoped → inert.)

## Plan

### Phase 0 — Safety net FIRST (do not skip)
1. **Per-row diff harness.** Extend the runner (or a throwaway script) to emit a
   machine-readable table `(suite, test, ours, expected, delta)` for **every** Timing
   and DMA row, not just the aggregate. Capture the a6ec55e baseline for HLE and LLE
   as golden. Every subsequent change is judged by `diff` against this — the only way
   to see a silent regression among 3200 rows. This harness is the deliverable that
   makes the rest safe.
2. **Reconstruct authoritative `GBAMemoryStall`.** Pull the real mgba source
   (`src/gba/memory.c` `GBAMemoryStall` + `lastPrefetchedPc`/`prefetchCursor` wiring +
   how WAITCNT feeds `activeSeqCycles16`/`activeNonseqCycles16`). Write it out as
   pseudocode with the exact integer/floor/cap semantics. Do not code from memory.

### Phase 1 — Occupancy representation
- Decide the state that replaces/augments `rom_free_since`. Candidate: keep an absolute
  `last_rom_cycle` plus derive integer occupancy on demand, OR store `buffered_hw:int`
  + `buffer_anchor:CycleCount`. Constraints: (a) serializable (savestate.nim:88-103),
  (b) survives event-driven `catch_up` and the waitloop fast-forward (which can push
  `rom_free_since` *ahead* of `now` — see the FireRed RangeDefect note at bus.nim:106).
- Reimplement the sequential-fetch branch with **integer** halfword fill:
  `fill_hw = min(8, elapsed_cycles div s)` (floored), charge from that. The floor is the
  whole point — it is what recovers the −1.

### Phase 2 — DMA hand-off (32 of the 46 rows live here)
- Model the buffer across CPU→DMA→CPU. mGBA disables prefetch during DMA; the buffer
  must rebuild from empty (or from the correct residual) on the first post-DMA fetch.
- Reconcile with the existing `dma_active` dual-tracker (`rom_next_addr`/`rom_next_addr2`,
  bus.nim:70-95). Decide whether occupancy subsumes it or they coexist. The
  `rom_next_addr != 1` cold-sentinel fix (2f9f5be) must be preserved or subsumed.

### Phase 3 — Region-crossing LDM/LDR (12 + 2 rows)
- `ldmia [#0x07FFFFF*]` crosses OAM→ROM; `ldr [#0x08000000]`. Verify the occupancy model
  resets correctly when an access leaves and re-enters the gamepak. `clear_pipeline`
  (cpu.nim:124, sets `rom_hot=false`) already invalidates on branch/PC-write — confirm
  it maps to zeroing occupancy, and that data-load-into-ROM (not a fetch) rebuilds right.

### Phase 4 — Full re-verification (the bulk of the work)
Run the Phase-0 harness and require, under **both HLE and LLE**:
- all 46 target rows PASS, **zero** of the 1974 passing Timing rows regress;
- DMA holds ≥1244 (watch the log-length-luck `-SRAM` reshuffle — judge by the real
  `R+0x10` rows and the non-artifact rows, not the aggregate);
- Timer count-up stays 893 (the IRQ-entry cost must be untouched), Timer IRQ 90,
  Memory 1552, everything else unchanged.
- waitloop fast-forward: suite still runs in ~1.6s (not ~68s) — a regression means the
  fast-forward's `rom_free_since` assumption broke.
- link + rollback + speclink acceptance all PASS (savestate completeness). **Bump
  STATE_VERSION** for the changed serialized fields.
- perf: instructions-retired A/B (`/usr/bin/time -l`) on ~3 games vs a6ec55e; the
  occupancy math must stay inlinable and cheap (the `rom_hot` fast path depends on it).

## Files / touchpoints
- `src/dingbat/gba/bus.nim` — `rom_access_cycles` (the swap), `rom_cool`/`add_cycles`
  (idle bookkeeping), `update_waitcnt` (wait tables), lines 473/490 (`rom_hot` re-arm).
- `src/dingbat/gba/dma.nim` — DMA tracker seeding (rom_next_addr=1 sentinel).
- `src/dingbat/gba/cpu.nim:124` — `clear_pipeline` invalidation.
- `src/dingbat/gba/savestate.nim:88-103` — serialize new fields; STATE_VERSION bump.
- `docs/research_dma_bios_rom.md`, `research_waitloop_tracer.md` — prior context.

## Risks & mitigations
- **Silent regression of passing rows** (highest): the Phase-0 per-row harness is the
  mitigation; never judge by aggregate count.
- **Savestate / determinism**: new state must serialize and reload identically or
  rollback desyncs. Guarded by the link/rollback/speclink acceptance + STATE_VERSION.
- **Waitloop fast-forward**: `rom_free_since` doubles as the "bus idle since" marker for
  `rom_cool` and the fast-forward. If replaced, that path needs an equivalent.
- **Perf**: hottest bus fn. Keep it branch-lean; re-measure instructions retired.

## Decision gate / fallback
If Phase 4 shows 46-and-hold-1974 is unreachable (some passing rows depend on quirks of
the credit model), fall back to landing only the cleanly-separable subset (likely the 14
region-crossing LDM/LDR rows if they isolate from the DMA rows) and document the rest as
a known model limitation. A partial, correct, fully-verified gain beats a risky full swap.

## Effort
One focused session (not a background agent — too much shared-state risk to run blind).
Phase 0 ~30%, Phases 1-3 iterative, Phase 4 the majority. Reward: +46 Timing (+0.6% of
the suite) and a cleaner, reference-faithful prefetch model.
