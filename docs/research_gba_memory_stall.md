# mGBA ROM-Prefetch Timing Model — Reconstruction (Phase 0)

Authoritative reconstruction of mGBA's `GBAMemoryStall` prefetch model, for the
rewrite of dingbat's `src/dingbat/gba/bus.nim` prefetch timing. Everything below
is quoted from real mGBA source; no values are from memory.

> **Independently re-verified** (2026-07-14) against a fresh `github.com/mgba-emu/mgba`
> checkout at the stated commit `5157ce2`, by a second reader diffing the actual bytes:
> the verbatim `GBAMemoryStall` body (§3a) is character-exact; the
> `if (address < GBA_BASE_ROM0)` call-site guard is present at all 8 load/store sites
> (memory.c:525, 640, …, 1551, 1669); the fn-ptr `cpu->memory.stall` is invoked from
> **only** those data-access sites and the two multiply macros (isa-inlines.h:52,67) —
> **never** an opcode-fetch path; `lastPrefetchedPc = 0` resets in both `GBAMemoryReset`
> (memory.c:135) and `GBASetActiveRegion` (memory.c:286); and the `GBAAdjustWaitstates`
> const tables + fills (§4) match line-for-line. Safe to transcribe.

---

## 1. Source provenance

Repo: `github.com/mgba-emu/mgba` (public).

| ref | commit | date |
|-----|--------|------|
| `master` (primary) | `5157ce208a5965e8a47bf5b48b5aae5198c22a5e` | 2026-07-05 |
| tag `0.10.5` (reconcile) | `26b7884bc25a5933960f3cdcd98bac1ae14d42e2` | — |
| tag `0.9.3` (reconcile) | `1163869139a4cf38027e567ad77854691958ae84` | — |

Files read (line numbers are for `master`):

- `src/gba/memory.c`
  - `GBA_ROM_WAITSTATES` / `GBA_ROM_WAITSTATES_SEQ` const tables — L39–40
  - `GBAMemoryInit` (stall wiring, field init) — L52 (`cpu->memory.stall = GBAMemoryStall;`)
  - `GBAMemoryReset` (`prefetch=false`, `lastPrefetchedPc=0`)
  - `GBALoad32` / `GBALoad16` / `GBALoad8` and `GBAStore*` — data-access cost + stall call (call sites L526, L641, L752, L871, L1016, L1102)
  - `GBALoadMultiple` / `GBAStoreMultiple` — L1552, L1670
  - `GBASetActiveRegion` — L~330–377 (resets `lastPrefetchedPc`, loads `activeSeqCycles*`)
  - `GBAAdjustWaitstates` — L1693–1726 (WAITCNT → wait tables)
  - `GBAMemoryStall` — **L1779–1821 (THE function)**
  - `GBAMemoryStallVRAM` — L1823+ (VRAM stall, separate; not the ROM prefetch model)
- `include/mgba/internal/gba/memory.h`
  - `struct GBAMemory` wait/prefetch fields — L119–126
  - `GBAMemoryRegion` enum + base/size constants — L31–82
- `include/mgba/internal/arm/arm.h`
  - `struct ARMMemory` active-cycle fields + `stall` fn ptr — L129–132 and the `stall` member
- `include/mgba/internal/arm/isa-inlines.h`
  - `ARMWritePC` / `ThumbWritePC` (pipeline refill cost) — L74–91
  - `ARM_WAIT_SMUL` / `ARM_WAIT_UMUL` (multiply → stall via fn ptr) — L40–68
- `src/arm/isa-thumb.c`
  - `THUMB_PREFETCH_CYCLES`, `THUMB_LOAD/STORE_POST_BODY` — L50–56
- `src/arm/isa-arm.c`
  - `ARM_PREFETCH_CYCLES` (isa-arm.h L13), `ARM_LOAD/STORE_POST_BODY` — L270–276
- `include/mgba/internal/arm/arm.h` — `WORD_SIZE_ARM=4`, `WORD_SIZE_THUMB=2`, `ARM_PC=15`

**Reconciliation note (master vs 0.10.5 vs 0.9.3):** the `GBAMemoryStall` body is
**algebraically identical** across all three. The only textual change is a
cosmetic regrouping of the final two subtractions:

```c
// 0.10.5 / 0.9.3:
int32_t n2s = cpu->memory.activeNonseqCycles16 - cpu->memory.activeSeqCycles16 + 1;
...
wait -= n2s;          // = (N - s + 1)
wait -= stall - 1;    // = (stall - 1)
// master:
wait -= cpu->memory.activeNonseqCycles16 - s;  // = (N - s)
wait -= stall;                                  // = stall
```

Total subtracted is `(N - s) + stall` in both. The `+1`/`-1` were merged into
the two terms in master. `REGION_CART0` (old) was renamed `GBA_REGION_ROM0` (new).
The wait-table construction (`GBAAdjustWaitstates`) and the const tables are
unchanged. **Use `master`; older releases give bit-identical timing.**

---

## 2. State

### 2a. `struct GBAMemory` (memory.h L119–126)

```c
char waitstatesSeq32[256];      // per-region 32-bit sequential WAITSTATE count
char waitstatesSeq16[256];      // per-region 16-bit sequential WAITSTATE count
char waitstatesNonseq32[256];   // per-region 32-bit non-seq WAITSTATE count
char waitstatesNonseq16[256];   // per-region 16-bit non-seq WAITSTATE count
int  activeRegion;              // region index (address>>24) the CPU is EXECUTING from
bool prefetch;                  // WAITCNT bit 14: gamepak prefetch buffer enabled
uint32_t lastPrefetchedPc;      // byte address the prefetch buffer has fetched UP TO
uint32_t biosPrefetch;          // (BIOS open-bus latch; unrelated to ROM prefetch)
```

Indexing: all `waitstates*[256]` arrays are indexed by **region = address >> 24**
(`BASE_OFFSET = 24`, memory.h L82). ROM regions are `0x8..0xD`; SRAM `0xE..0xF`.
These store the **waitstate count** (the stall on top of the base access cycle),
NOT the full access cost. (Contrast dingbat, §6.)

### 2b. `struct ARMMemory` (arm.h L129–132 + fn ptr)

```c
uint32_t activeSeqCycles32;     // = waitstatesSeq32[activeRegion]     — cached for exec region
uint32_t activeSeqCycles16;     // = waitstatesSeq16[activeRegion]
uint32_t activeNonseqCycles32;  // = waitstatesNonseq32[activeRegion]
uint32_t activeNonseqCycles16;  // = waitstatesNonseq16[activeRegion]
int32_t (*stall)(struct ARMCore*, int32_t wait);   // = GBAMemoryStall
```

### 2c. Region enum + constants (memory.h)

```c
GBA_REGION_ROM0 = 0x8, GBA_REGION_ROM0_EX = 0x9,
GBA_REGION_ROM1 = 0xA, GBA_REGION_ROM1_EX = 0xB,
GBA_REGION_ROM2 = 0xC, GBA_REGION_ROM2_EX = 0xD,
GBA_REGION_SRAM = 0xE, GBA_REGION_SRAM_MIRROR = 0xF
GBA_BASE_EWRAM = 0x02000000, GBA_BASE_ROM0 = 0x08000000
GBA_SIZE_ROM0  = 0x02000000, BASE_OFFSET = 24
WORD_SIZE_ARM = 4, WORD_SIZE_THUMB = 2, ARM_PC = 15   // (arm.h)
```

### 2d. Buffer-size cap

There is **no `#define`** for the buffer depth. The cap of **8 halfwords** is a
literal inside `GBAMemoryStall`: `int32_t maxLoads = 8;`. There is **no
`prefetchCursor` field** — `lastPrefetchedPc` is the entire prefetch state.

### 2e. Where the state is set / reset / advanced

| field | init | reset / advance | file:line |
|-------|------|-----------------|-----------|
| `lastPrefetchedPc` | `0` in `GBAMemoryInit`/`GBAMemoryReset` | **reset to `0`** on every `GBASetActiveRegion` (i.e. every pipeline refill / branch / region change); **advanced** only inside `GBAMemoryStall` | memory.c set-active-region + L1807 |
| `prefetch` | `false` at reset | set from WAITCNT bit 14 in `GBAAdjustWaitstates` (`memory->prefetch = prefetch;`) | memory.c L1719 |
| `activeSeqCycles16` etc. | `0` at reset | recomputed in `GBASetActiveRegion` (region change) AND in `GBAAdjustWaitstates` (WAITCNT write), from the `waitstates*[activeRegion]` tables | memory.c L373–376, L1721–1725 |
| `activeRegion` | — | set in `GBASetActiveRegion` to `address>>24` | memory.c |

**Key fact 1 — `lastPrefetchedPc` is reset on every pipeline refill.**
`GBASetActiveRegion` (called by `ARMWritePC`/`ThumbWritePC` on every branch,
exception, and mode switch) unconditionally executes `memory->lastPrefetchedPc = 0;`.
So the prefetch-overlap "memory" only survives across straight-line execution.

**Key fact 2 — `GBAMemoryStall` runs on ROM-executing *data accesses* and
*multiplies*, NOT on ordinary opcode fetches.** Ordinary sequential opcode fetch
cost is the flat `THUMB_PREFETCH_CYCLES = 1 + activeSeqCycles16` (isa-thumb.c L50)
/ `ARM_PREFETCH_CYCLES = 1 + activeSeqCycles32`. The stall function is what models
the prefetcher *working ahead while the CPU is busy with something that isn't an
opcode fetch*. Call sites:

- Every `GBALoad*` / `GBAStore*` — but **only when the data address is OUTSIDE
  ROM**: the call is guarded `if (address < GBA_BASE_ROM0) { wait = GBAMemoryStall(cpu, wait); }`
  (e.g. GBALoad32 L523–527). A data access *into* ROM shares the prefetch bus, so
  it gets no overlap and does not call the stall.
- `GBALoadMultiple` / `GBAStoreMultiple` — same guard (L1550–1553).
- `ARM_WAIT_SMUL` / `ARM_WAIT_UMUL` — multiply internal cycles, via the
  `cpu->memory.stall(cpu, wait)` function pointer (isa-inlines.h L52, L67).
- Inside `GBAMemoryStall` itself there is a second guard: it early-returns unless
  the CPU is **executing from ROM** (`activeRegion >= GBA_REGION_ROM0`) with
  prefetch enabled.

So the model fires exactly when: **CPU is running code in ROM, and does a
data/multiply that ties up the CPU (or the non-ROM bus) for `wait` cycles, during
which the prefetcher can fill the buffer with upcoming ROM opcodes.**

---

## 3. `GBAMemoryStall` — verbatim then pseudocode

### 3a. Verbatim (master, memory.c L1779–1821)

```c
int32_t GBAMemoryStall(struct ARMCore* cpu, int32_t wait) {
	struct GBA* gba = (struct GBA*) cpu->master;
	struct GBAMemory* memory = &gba->memory;

	if (memory->activeRegion < GBA_REGION_ROM0 || !memory->prefetch) {
		// The wait is the stall
		return wait;
	}

	int32_t previousLoads = 0;

	// Don't prefetch too much if we're overlapping with a previous prefetch
	uint32_t dist = (memory->lastPrefetchedPc - cpu->gprs[ARM_PC]);
	int32_t maxLoads = 8;
	if (dist < 16) {
		previousLoads = dist >> 1;
		maxLoads -= previousLoads;
	}

	// Figure out how many sequential loads we can jam in
	int32_t s = cpu->memory.activeSeqCycles16;
	int32_t stall = s + 1;
	int32_t loads = 1;

	while (stall < wait && loads < maxLoads) {
		stall += s;
		++loads;
	}
	memory->lastPrefetchedPc = cpu->gprs[ARM_PC] + WORD_SIZE_THUMB * (loads + previousLoads - 1);

	if (stall > wait) {
		// The wait cannot take less time than the prefetch stalls
		wait = stall;
	}

	// This instruction used to have an N, convert it to an S.
	wait -= cpu->memory.activeNonseqCycles16 - s;

	// The next |loads|S waitstates disappear entirely, so long as they're all in a row
	wait -= stall;

	return wait;
}
```

### 3b. Line-by-line pseudocode with EXACT integer arithmetic

All variables are 32-bit integers. `dist` is **unsigned**; everything else is
signed. `>>` on `dist` is a logical/unsigned shift. There is **no division** other
than the `>> 1` (unsigned floor-divide by 2).

```
GBAMemoryStall(cpu, wait):                 # wait = the cycles this access would cost with no prefetch overlap
  if activeRegion < 0x8  OR  prefetch == false:
      return wait                          # not executing from ROM, or buffer off → no overlap

  previousLoads = 0

  # --- how many whole halfwords the buffer already holds ahead of PC ---
  dist = (uint32)(lastPrefetchedPc - PC)   # PC = cpu.gprs[15]; wraps as unsigned
  maxLoads = 8                             # buffer depth cap = 8 halfwords (literal)
  if dist < 16:                            # buffer overlaps the next <8 halfwords of code
      previousLoads = dist >> 1            # FLOOR(dist / 2) = whole halfwords already buffered
      maxLoads = maxLoads - previousLoads  # only room for the remaining halfwords

  # --- jam as many sequential opcode fetches into the wait window as fit ---
  s = activeSeqCycles16                    # ROM seq WAITSTATE (NOT full cost); e.g. 1 or 2
  stall = s + 1                            # cost of the FIRST prefetched halfword = base(1) + s
  loads = 1
  while stall < wait  AND  loads < maxLoads:
      stall = stall + s                    # each further halfword adds exactly s cycles
      loads = loads + 1
  # after loop: stall = 1 + loads*s  ,  loads in [1 .. maxLoads]  (integer count of whole halfwords)

  # --- advance the buffer position, in WHOLE 2-byte halfwords ---
  lastPrefetchedPc = PC + 2 * (loads + previousLoads - 1)     # WORD_SIZE_THUMB = 2

  if stall > wait:                         # the buffer fill cannot take less time than the access
      wait = stall

  wait = wait - (activeNonseqCycles16 - s) # rebill this access N→S: it no longer starts a fresh N burst
  wait = wait - stall                      # the |loads| prefetched S-fetches become free (overlapped)
  return wait                              # may be negative → net cycles GIVEN BACK to the caller
```

Integer-arithmetic notes a transcriber MUST preserve:

1. `dist >> 1` is an **unsigned floor** divide-by-2 → whole halfwords. Because
   `PC` is halfword-aligned and `lastPrefetchedPc` is always set to
   `PC' + 2*(…)` (even offset from an aligned PC'), `dist` is always even in
   practice, so this shift is exact here — the *quantization to whole halfwords*
   happens earlier, at the integer `loads` count and the `2 * (…)` advance, not
   at this shift. See §5.
2. The `while` loop computes `loads` = the least integer ≥1 with `1 + loads*s ≥ wait`,
   capped at `maxLoads`. Equivalent closed form: `loads = clamp(ceil((wait-1)/s), 1, maxLoads)`.
   `stall = 1 + loads*s`.
3. `lastPrefetchedPc` advance uses `loads + previousLoads - 1` (the `-1` because
   the first of `loads` is the access that is happening now, not a look-ahead).
4. The two trailing subtractions net to `-( (N16 - s) + stall )` where `N16 =
   activeNonseqCycles16`. The return can be negative; the caller adds it to a
   running `*cycleCounter`/`currentCycles`, so a negative "wait" credits cycles back.

### 3c. What the caller passes as `wait`

For a data access from ROM-executing code to a non-ROM region (`GBALoad16`, memory.c):
```c
int wait = memory->waitstatesNonseq16[dataRegion];   // N waitstate of the DATA region
...
wait += 2;                                            // 16-bit data access base (2 cycles)
if (address < GBA_BASE_ROM0) wait = GBAMemoryStall(cpu, wait);
*cycleCounter += wait;
```
`GBALoad32`: `wait` accumulates `waitstatesNonseq32[dataRegion]` then `wait += 2`.
`GBALoadMultiple`/`StoreMultiple`: `wait = waitstatesSeq32[region] - waitstatesNonseq32[region]`
then `++wait` before the stall (the per-element S costs were added in the loop; the
stall reconciles the single leading N of the whole burst).

---

## 4. WAITCNT → wait tables (`GBAAdjustWaitstates`, memory.c L1693–1726)

### 4a. Const lookup tables (memory.c L39–40)

```c
static const char GBA_ROM_WAITSTATES[]     = { 4, 3, 2, 8 };       // N waitstate by 2-bit setting
static const char GBA_ROM_WAITSTATES_SEQ[] = { 2, 1, 4, 1, 8, 1 }; // S waitstate, region-offset indexed
```

### 4b. WAITCNT bit decode

```c
int sram   = parameters & 0x0003;
int ws0    = (parameters & 0x000C) >> 2;   int ws0seq = (parameters & 0x0010) >> 4;
int ws1    = (parameters & 0x0060) >> 5;   int ws1seq = (parameters & 0x0080) >> 7;
int ws2    = (parameters & 0x0300) >> 8;   int ws2seq = (parameters & 0x0400) >> 10;
int prefetch = parameters & 0x4000;
```

### 4c. Table fills (verbatim relationships)

SRAM (regions 0xE, 0xF):
```c
waitstatesNonseq16[SRAM] = waitstatesSeq16[SRAM] = GBA_ROM_WAITSTATES[sram];
waitstatesNonseq32[SRAM] = waitstatesSeq32[SRAM] = 2 * GBA_ROM_WAITSTATES[sram] + 1;
```

ROM non-seq 16 (regions ROM0/1/2 and their _EX mirrors):
```c
waitstatesNonseq16[ROM0] = GBA_ROM_WAITSTATES[ws0];
waitstatesNonseq16[ROM1] = GBA_ROM_WAITSTATES[ws1];
waitstatesNonseq16[ROM2] = GBA_ROM_WAITSTATES[ws2];
```

ROM seq 16 — note the **region-offset indexing** into the SEQ table:
```c
waitstatesSeq16[ROM0] = GBA_ROM_WAITSTATES_SEQ[ws0seq];       // index 0..1 → {2,1}
waitstatesSeq16[ROM1] = GBA_ROM_WAITSTATES_SEQ[ws1seq + 2];   // index 2..3 → {4,1}
waitstatesSeq16[ROM2] = GBA_ROM_WAITSTATES_SEQ[ws2seq + 4];   // index 4..5 → {8,1}
```

ROM 32-bit (built from the 16-bit values):
```c
waitstatesNonseq32[ROMx] = waitstatesNonseq16[ROMx] + 1 + waitstatesSeq16[ROMx];  // N + 1 + S
waitstatesSeq32[ROMx]    = 2 * waitstatesSeq16[ROMx] + 1;                          // 2S + 1
```

Then `memory->prefetch = prefetch;` and the `activeSeqCycles*` cache is refreshed
from `waitstates*[activeRegion]`.

### 4d. Resolved value tables (waitstate counts, per GBATEK)

| setting | N16 (`GBA_ROM_WAITSTATES`) | S16 WS0 | S16 WS1 | S16 WS2 |
|---------|---------|---------|---------|---------|
| bits=0  | 4 | 2 | 4 | 8 |
| bits=1  | 3 | 1 | 1 | 1 |
| bits=2  | 2 | — | — | — |
| bits=3  | 8 | — | — | — |

(N16 uses the 2-bit `ws*` field → {4,3,2,8}. S16 uses the 1-bit `ws*seq` field;
per region the two choices are WS0∈{2,1}, WS1∈{4,1}, WS2∈{8,1}.) SRAM row: a
single value `{4,3,2,8}` used for both N and S, 16 and (as `2N+1`) 32-bit.

These are **waitstate counts**; the real access cost is `waitstate + 1` for the
first (base) cycle. `GBAMemoryStall` re-adds that `+1` explicitly (`stall = s + 1`).

---

## 5. The −1, explained mechanically

### 5a. Where quantization lives

mGBA's *only* record of prefetch progress between accesses is `lastPrefetchedPc`,
a **byte address on a 2-byte grid**. It moves only in `GBAMemoryStall`, only by
`2 * (loads + previousLoads - 1)` — an **integer number of whole halfwords**,
where `loads` came from the integer `while` loop (`loads = clamp(ceil((wait-1)/s),
1, maxLoads)`). There is **no representation of a fractional halfword of fill**.
The buffer "either has halfword k or it doesn't."

dingbat's model records prefetch progress as **`rom_free_since`, a continuous
cycle timestamp**, and computes
`credit = min(now - rom_free_since, 8*s)` in **raw cycles**
(`bus.nim` L111–115), then `cost = max(1, need - credit)`. Because `credit` is in
cycles, not halfwords, it can hold **up to `s-1` cycles of a *partial* next
halfword** — fill that has "started" but not completed. dingbat spends that
partial toward reducing `cost`; mGBA has structurally discarded it.

### 5b. Why the first fetch after a non-fetch ROM access is +1 in mGBA

A "non-fetch ROM access" is a DMA burst or an `LDR`/`LDM` **data-load into ROM**:

- **It never runs `GBAMemoryStall`.** DMA does not call it at all (dma.c touches
  no prefetch state — verified). A data access *into* ROM is excluded by the
  `if (address < GBA_BASE_ROM0)` guard at the call sites. Therefore
  `lastPrefetchedPc` is **not advanced** and holds an integer halfword boundary
  frozen from before the event.
- When the CPU next does a stall-triggering access, mGBA reads that frozen integer
  position back via `previousLoads = (lastPrefetchedPc - PC) >> 1` — a **whole
  count**. Any cycles that elapsed during the DMA/to-ROM burst contribute **zero**
  extra buffered halfwords (the prefetcher can't run while the bus is busy), and
  crucially there is **no partial-halfword carry**: the buffer position is exactly
  where it was, on the 2-byte grid.

dingbat, over the same interval, keeps `rom_free_since` as a continuous cycle
count. When it computes `credit = now - rom_free_since`, it can pick up a partial
halfword's worth of accumulated cycles that mGBA quantized away. In the boundary
case that partial is worth exactly **one cycle**: dingbat's
`cost = max(1, need - credit)` lands 1 lower than the whole-halfword result mGBA
produces (`stall = 1 + loads*s`, integer `loads`). Hence **dingbat = mGBA − 1** on
that first fetch.

### 5c. Worked numeric examples

The quantization is `loads = clamp(ceil((wait-1)/s), 1, maxLoads)` and the buffer
advance `2*(loads + previousLoads - 1)`. Compare against a hypothetical continuous
model that would allow `wait/ s` fractional halfworths.

**From-ROM case, s = 2** (WS0 seq waitstate = 2; matches the suite's `P.S`/`PNS`,
s=2). CPU executes in ROM, does a 16-bit data load to fast RAM. Entering `wait`
after `+= 2` base ≈ 3 (region N=1, +2). Fresh stream, `dist ≥ 16` →
`previousLoads = 0, maxLoads = 8`.

```
s=2, wait=3:
  stall = s+1 = 3, loads=1
  while (3 < 3)? no                 → loads=1, stall=3        (ONE whole halfword)
  lastPrefetchedPc = PC + 2*(1+0-1) = PC + 0
```
mGBA has "used up" exactly 1 whole halfword of buffer (`stall=3 = 1 + 1*s`). A
continuous model with `wait=3, s=2` would say `3/2 = 1.5` halfworths of overlap —
the extra `0.5` halfword (1 cycle at s=2) is what dingbat's `credit` can carry and
mGBA cannot. On the immediately following fetch that half-halfword either is, or
is not, present; mGBA rounds it to *absent* → charges the full next `s`, i.e. **1
more** than dingbat's `max(1, need - credit)` which still had ~1 cycle of credit.

**To-ROM case, s = 3** (WS0 seq waitstate = 3 → e.g. `ws=... ` giving S16=... ;
matches the suite's `P..`/`PN.`, s=3). A DMA writes *into* ROM, or an `LDM` loads
*from* ROM:

```
DMA into ROM:
  - GBAMemoryStall is NEVER called (dma.c has no stall; guard address<ROM0 fails).
  - lastPrefetchedPc unchanged; the DMA's ROM cycles add ZERO buffered halfwords.
  - Next CPU fetch: previousLoads = (lastPrefetchedPc - PC) >> 1 = the OLD integer
    count, no fractional carry from the DMA duration.
```
With s=3 a full buffered halfword is 3 cycles; a continuous credit model can hold
1 or 2 leftover cycles ( < one halfword ) that mGBA floors to a whole-halfword
boundary. dingbat's `credit` spends those 1–2 cycles; mGBA does not. The observable
divergence is again exactly 1 cycle on that first post-burst fetch (`P..` → `PN.`
transition in the test: what dingbat scores as a still-sequential-ish cheap access,
mGBA scores as one cycle dearer because its buffer count is a floored integer).

The common root in both cases: **mGBA counts prefetch progress in whole halfwords
(integer `loads`, 2-byte `lastPrefetchedPc` advance); dingbat counts it in
continuous cycles (`now - rom_free_since`). The fractional halfword dingbat keeps
is the missing +1.**

---

## 6. Mapping to dingbat (`src/dingbat/gba/bus.nim`)

| mGBA concept | dingbat equivalent | notes / gaps |
|---|---|---|
| `prefetch` (WAITCNT bit 14) | `bus.prefetch_on` (`w.gamepack_prefetch_buffer`) | equivalent |
| `activeRegion >= ROM0` guard (must be *executing* in ROM) | dingbat keys off `page 8..0xD` of the *access* + `fetch` flag; there is no separate "execution region" gate | mGBA only overlaps when the *code* is in ROM; dingbat's `rom_access_cycles` is reached for any ROM-page access |
| `lastPrefetchedPc` (buffer position, **whole halfwords**, reset to 0 on every pipeline refill) | `rom_free_since` (**continuous cycle timestamp**) + `rom_next_addr`/`rom_next_addr2`/`rom_hot` | **fundamental representation difference** — see §5. dingbat has no floored-halfword buffer position; its `rom_cool()` sets `rom_free_since = now` on stream break instead of zeroing a position |
| `previousLoads = (lastPrefetchedPc - PC) >> 1` (floored whole halfwords already buffered) | `credit = min(now - rom_free_since, 8*s)` (raw cycles) | dingbat does **not** floor to halfwords → carries a partial halfword → the −1 |
| `maxLoads = 8` (buffer depth cap) | `8 * s` cap on `credit`, and `8*s` floor on `new_free_since` (L112, L117) | same 8-halfword depth, expressed in cycles |
| `s = activeSeqCycles16` (waitstate, +1 added as `stall=s+1`) | `s = wait16_s[page]` which is **`ROM_S_WAITS + 1` (full cost)** (L29) | **off-by-one in convention**: mGBA `s` excludes the base cycle, dingbat `s` includes it. A transcriber must not double-count the `+1`. |
| `waitstatesSeq16/Nonseq16` = waitstate counts | `wait16_s`/`wait16_n` = **full access costs** (`= waitstate + 1`) | dingbat stores cost, mGBA stores stall; `wait32_n = n + s`, `wait32_s = s + s` (already-cost form). mGBA's `nonseq32 = N16 + 1 + S16`, `seq32 = 2*S16 + 1` (waitstate form). Equivalent once the `+1`s are reconciled. |
| `stall = 1 + loads*s`, `loads = clamp(ceil((wait-1)/s),1,8)` (integer) | `cost = max(1, need - credit)`; `need = s` or `2s` (L114–115) | dingbat's continuous `need - credit` is the analytic version of mGBA's integer jam-loop |
| `wait -= (N16 - s)` (N→S rebill) + `wait -= stall` (overlapped S's are free) | dingbat folds this into `cost`/`new_free_since` bookkeeping (L116–118) rather than returning a signed credit | dingbat never returns negative cycles; the give-back is realized by advancing `rom_free_since` (L118 `floor`/`max`) |
| DMA does **not** touch prefetch state | dingbat *does* actively track DMA ROM bursts (`dma_active`, `rom_next_addr2`, cold sentinel `rom_next_addr==1`, L70–95) | **dingbat models more than mGBA here.** mGBA's DMA leaves `lastPrefetchedPc` frozen; dingbat maintains explicit dual-stream burst trackers. The rewrite must decide whether to keep dingbat's richer DMA burst model or fall back to mGBA's "frozen buffer position" semantics. |
| pipeline refill resets buffer (`lastPrefetchedPc=0` in `GBASetActiveRegion`) | dingbat has no explicit "reset buffer position on branch"; it relies on `rom_next_addr` mismatch + `contiguous` to detect stream breaks | **potential gap**: mGBA hard-zeroes the buffer on *every* branch/refill; dingbat infers breaks from address continuity. Behaviour matches for straight-line code but the reset trigger differs. |

### Flagged for the rewrite
- The **halfword-quantized buffer position** (`lastPrefetchedPc`, integer `loads`,
  `2*(…)` advance) is the single behaviour dingbat's continuous-credit model lacks
  and is the sole cause of the documented −1. To match mGBA exactly, the buffer
  fill available to a fetch must be **floored to whole `s`-cycle halfwords** before
  it offsets the cost — i.e. replace `credit` (cycles) with
  `floor(credit / s) * s`, or track an integer buffered-halfword count directly.
- Reconcile the **`s` convention** (`+1` base cycle): mGBA `activeSeqCycles16` is
  the raw waitstate; dingbat `wait16_s` already includes the base. Do not add the
  `+1` twice.
- Decide DMA policy: mGBA freezes the buffer across DMA (never advances/consumes
  `lastPrefetchedPc`); dingbat's dual-stream tracker is a superset. Keeping
  dingbat's is fine for accuracy but is *not* mGBA-faithful — document whichever is
  chosen.
