# Prefetch-model rewrite: occupancy model to close the 46 Timing fails

Status: **Phase 0 done; premise revised; Phase 1 blocked on a scope decision** (2026-07-14).
Prereq baseline: `main` @ a6ec55e — mGBA suite 6898/7218 HLE, 6897 LLE.

> ## UPDATE 2026-08-01 — 14 of the 46 closed, without the occupancy rewrite
> The CPU-side half of the −1 **is** localizable after all, and needs no new state:
> it is the **prefetch hand-off** at a CPU data access to the gamepak. The prefetcher
> has been streaming since `rom_free_since`, so it is `elapsed mod s` cycles into a
> halfword; a halfword in its **final** cycle is committed and the CPU waits that
> cycle out, one in an earlier cycle is abandoned for free. `elapsed mod s == s-1`,
> one line in `rom_access_cycles`. Derived from the suite's own hardware table — the
> seven `(elapsed, s)` observations behind it are in the commit message for this
> change. Timing 1974 → **1988**; the 2 `ldr [#0x08000000]` rows and all 12
> `ldmia [#0x07FFFFF*]` rows pass, no Timing row regresses.
>
> Still open: the **32 DMA rows**. The same effect exists there but is not a function
> of `(elapsed mod s)` at the DMA's first ROM access — `Trivial DMA (16/ROM)` ARM P.S
> (elapsed 2, s 2) needs the stall while Thumb P.S (elapsed 4, s 2) must not have it,
> so the CPU rule cannot simply be extended. Applying it to DMA measured 1980 Timing
> with 8 new DMA-row failures. What blocks it is that dingbat's DMA runs on the
> *scheduled* event clock while `rom_free_since` is on the CPU's bus clock, and the
> two are skewed by up to a fetch; the DMA hand-off needs that reconciled first.
>
> Also note: the six `HBl W ±SRAM/=*` **DMA-suite** rows that flip with this change are
> the documented **log-length artifact**, not a timing regression. Those tests DMA out
> of SRAM, and SRAM *is* the suite's own `savprintf` log (main.c:167); once the log
> passes 0x8000 its NUL terminator wraps onto SRAM[0], so what the DMA reads depends
> on how many lines the suite printed — i.e. on how many tests failed. Verified: the
> bursts are parameter-identical before/after (src 0x0E00000C, len 4), only
> `SRAM[0]` differs (0x47 'G' vs 0x00) and only after the wrap point moved.

> ## ⚠️ PREMISE CORRECTION (2026-07-14) — read before touching this
> Phase 0 empirically **inverted this doc's original premise.** An agent built and
> instrumented real mGBA (5157ce2) and ran the suite: **mGBA FAILS these rows too**, giving
> values *below* dingbat (`ldr…P.S`: mGBA 15 / dingbat 16 / hardware 17). The `expected`
> column is **hardware-derived**, not mGBA output — and corroborating this, memory records
> "mGBA itself: 1552/2020 Timing" vs dingbat's 1974. So **dingbat = hardware − 1**, and the
> target is the **hardware `expected` table, NOT mGBA**. Porting `GBAMemoryStall` verbatim
> would *regress* dingbat to 15/12/11. Details: `docs/research_failing_rows_breakdown.md`.
>
> **The needed change is +1** on the first ROM fetch resuming after a non-fetch ROM-bus
> event, by discarding the fractional-halfword credit. **Empirically probed via the Phase-0
> harness (all under HLE):**
> - blanket whole-halfword floor `credit=(raw div s)*s` → Timing **1758 (−216)**: fixes
>   exactly **16 rows** (all *DMA-to-ROM* `P..`/`PN.`, s=3) but regresses **232** ordinary
>   prefetch hits (`mla`, `smull`, `Calibration`, `nop/ldrh`). Confirms the memory's −216.
> - floor **only when `dma_active`** set the buffer dirty → **inert** (post-DMA resume fetch
>   already has credit 0; the −1 for DMA-to-ROM lives in a *later* prefetch hit whose
>   fractional credit traces to the DMA-to-ROM *write* timing, not flagged at that access).
> - floor on **any** non-fetch ROM access → **1518 (−456)**: PC-relative literal-pool loads
>   (`ldr [pc,#imm]`, ubiquitous, read ROM) set the flag everywhere and the `rom_hot` fast
>   path never clears it, so it leaks across thousands of fetches.
>
> **Conclusion:** the −1 is **not localizable** to a simple per-access condition; the 16
> DMA-to-ROM rows are the *only* cleanly-identifiable subset, and even they resist a
> targeted floor (the disturbing access and the mis-credited fetch are separated). Matching
> the hardware table needs a genuine integer occupancy carried across accesses in whole
> halfwords — a real model, derived from **hardware**, not transcribed from mGBA. See the
> revised Decision gate at the bottom.

## Objective

Replace the continuous **time-credit** prefetch model in `bus.nim rom_access_cycles`
with an integer **halfword-occupancy** model matching the **hardware** `expected` table
(NOT mGBA's `GBAMemoryStall`, which under-counts these rows — see the premise correction),
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
1. **Per-row diff harness.** ✅ DONE (`tests/mgba_rowdiff.py` + `tests/golden/`). Emits a
   machine-readable TSV `(suite, ord, name, status, ours, expected, delta)` for **every**
   row (all suites, passing and failing), keyed by stable `(suite, ord)`. Golden captured
   at a6ec55e for both configs: **HLE 6898 / LLE 6897** of 7008 emitted rows
   (`mgba_rows_hle.tsv` / `mgba_rows_lle.tsv`). `mgba_rowdiff.py diff` classifies every
   changed row as REGRESSED / FIXED / VALUE / STRUCTURAL and exits nonzero on any change —
   this is how every subsequent change is judged, never by the aggregate. See
   `tests/golden/README.md` for the workflow and the 4 known HLE↔LLE artifact rows.
2. **Reconstruct authoritative `GBAMemoryStall`.** ✅ DONE — `docs/research_gba_memory_stall.md`
   (mgba `master` @ `5157ce2`, verbatim body + line-by-line pseudocode + WAITCNT tables +
   the −1 mechanically, all independently re-verified against a fresh checkout). **Three
   findings that revise the framing above and matter for Phase 1:** (a) there is no
   `prefetchCursor` — `lastPrefetchedPc` (a byte addr on a 2-byte grid, reset to 0 on
   *every* pipeline refill in `GBASetActiveRegion`) is the entire prefetch state, cap
   `maxLoads=8` halfwords; (b) `GBAMemoryStall` runs **only** on a ROM-executing *data
   access to non-ROM* (`if address < GBA_BASE_ROM0`) and on *multiplies* — **never on
   opcode fetches** (those are flat `1+s`), and **DMA never touches prefetch state at
   all**; the stall computes how many opcode halfwords the prefetcher jams into that
   access's `wait` window and returns a (possibly negative) cycle credit. So mgba applies
   the prefetch discount at the *preceding data access*, whereas dingbat applies it at the
   *fetch* — Phase 1 must reconcile this, not just floor the credit. (c) mgba's `s =
   activeSeqCycles16` is the raw waitstate (base `+1` re-added as `stall=s+1`); dingbat's
   `wait16_s` already includes the `+1` — do not double-count. The lever for the −1 is
   unchanged: floor available fill to whole `s`-cycle halfwords before it offsets cost.

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
