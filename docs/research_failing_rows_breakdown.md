# mGBA-suite Timing: per-access breakdown of the three failing rows

Authoritative per-access reconstruction of three mGBA-suite Timing rows, to drive the
dingbat ROM-prefetch rewrite. **Everything numeric below is live-measured**, not
hand-waved: I built mGBA at the referenced commit `5157ce2` (master) *and* release
`0.10.5`, instrumented `GBAMemoryStall`, and drove the real `mgba-suite.gba` through
it, cross-checking every value three independent ways (see §0).

---

## 0. HEADLINE — the phase-0 premise is empirically false

> **mGBA does NOT produce the mgba-suite "expected" values on any of the three rows.
> mGBA *fails its own suite* on all of them.** The `expected` numbers baked into
> `timing.c` are **hardware-derived**, not mGBA output. The reconstruction doc
> (`research_gba_memory_stall.md` §5) asserts "dingbat = mGBA − 1"; the true ordering
> is **dingbat = mGBA + 1** on the prefetch rows — dingbat is *closer* to hardware than
> mGBA is, and mGBA's `GBAMemoryStall` under-counts. Porting mGBA's model verbatim
> would make dingbat *worse*.

Three-way, P.S column (WAITCNT `0x4010`), all values reported = raw − calibration:

| # | test (column) | **mGBA 5157ce2** | dingbat | **expected (HW)** |
|---|---------------|:----:|:----:|:----:|
| 1 | `ldr r2,[sp] / ldr r2,[#0x08000000]` — Thumb P.S | **15** | 16 | **17** |
| 2 | `Trivial DMA (16/ROM)` — ARM P.S | **12** | 12 | **13** |
| 3 | `ldmia [#0x07FFFFFC]!,{r3-r7}` — Thumb P.S | **11** | 26 | **27** |

Evidence that mGBA gives these (not 17/13/27): mGBA's own suite writes its verdict
into SRAM via `savprintf`. Dumping SRAM after a real run of `mgba-suite.gba` on my
instrumented mGBA build yields, verbatim:

```
Timing test: ldr r2, [sp] / ldr r2, [#0x08000000]
Thumb/ROM P.S: Got    15 vs    17: FAIL
Thumb/ROM PNS: Got    13 vs    15: FAIL
Timing test: Trivial DMA (16/ROM)
ARM/ROM P.S: Got    12 vs    13: FAIL
ARM/ROM PNS: Got    11 vs    12: FAIL
Timing test: ldmia [#0x07FFFFFC]!, {r3-r7}
Thumb/ROM ..S: Got    11 vs    26: FAIL
Thumb/ROM P.S: Got    11 vs    27: FAIL          <- mGBA billing bug, not prefetch
```

### How the ground truth was obtained
1. **Instrumented `GBAMemoryStall`** (added an `fprintf` of `wait_in, s, N, dist,
   previousLoads, loads, stall, ret, lastPrefetchedPc, mTimingCurrentTime, TM0CNT_LO`),
   rebuilt `libmgba.a`, drove `mgba-suite.gba` through a tiny `mCore` runner, gated the
   trace to each test's PC window (function addresses from `suite.elf` via
   `arm-none-eabi-objdump`).
2. **CPU-cycle timeline**: `mTimingCurrentTime = masterCycles + cpu->cycles` sampled at
   the timer-enable store and the timer-read `ldrh`, reproducing the exact
   `raw = (now_read − 2) − now_enable` the hardware timer computes.
3. **mGBA's own verdict**: dumped SRAM (`savprintf` log) after the run — the `Got X vs Y`
   lines above. All three agree to the cycle.

The `GBAMemoryStall` body at 5157ce2 and 0.10.5 is algebraically identical
(`git log 0.10.5..HEAD -- src/gba/memory.c` shows no functional change; the two textual
forms both subtract `(N−s)+stall`), and both builds measured identically. So "mGBA" below
means both.

---

## 1. Column / WAITCNT decode (verified against the live trace's `s=`,`N=` fields)

The 4-hex suffix *is* the WAITCNT written. Decode via `GBAAdjustWaitstates`:
`ws0=(x&0xC)>>2`, `ws0seq=(x&0x10)>>4`, `prefetch=x&0x4000`;
`N16 = {4,3,2,8}[ws0]`, `S16(WS0) = {2,1}[ws0seq]`.

| col | WAITCNT | prefetch | N16 (ws) | S16 (ws) | fetch S = 1+S16 | trace |
|-----|---------|----------|----------|----------|-----------------|-------|
| `..S` | `0x0010` | **off** | 4 | 1 | 2 | (no stall — prefetch off) |
| `P.S` | `0x4010` | **ON** | 4 | 1 | 2 | `s=1 N=4` ✓ |
| `.NS` | `0x0014` | off | 3 | 1 | 2 | — |
| `PNS` | `0x4014` | ON | 3 | 1 | 2 | `s=1 N=3` ✓ |
| `P..` | `0x4000` | ON | 4 | 2 | 3 | `s=2 N=4` ✓ |
| `PN.` | `0x4004` | ON | 3 | 2 | 3 | `s=2 N=3` ✓ |

Derived 32-bit ROM costs (P.S): `nonseq32 = N16+1+S16 = 6`, `seq32 = 2·S16+1 = 3`.

**The failures cluster exactly on `S16 = 1` (`ws0seq` set): only P.S (`0x4010`) and
PNS (`0x4014`) fail; P.. (`0x4000`) and PN. (`0x4004`), which have `S16 = 2`, PASS on
mGBA.** The prefetch divergence is an `S16=1`-only effect (§7).

---

## 2. Test 1 — `ldr r2,[sp] / ldr r2,[#0x08000000]` (Thumb)

`testLdrLdrRom_thumb_text` @ `0x08016c60`. Disassembly (all Thumb, 2 bytes):

```
08016c60  ldr  r3,[pc,#16]   ; r3 = 0x08000000        (SETUP)
08016c62  ldr  r0,[pc,#20]   ; r0 = 0x04000100 TM0CNT  (START)
08016c64  ldr  r1,[pc,#20]   ; r1 = 0x00800000
08016c66  str  r1,[r0]       ; TIMER ENABLE  (store32→IO)      PC=6a
08016c68  ldr  r2,[sp]       ; CODE1: load32 from IWRAM (stack) PC=6c   <-- calls stall
08016c6a  ldr  r2,[r3]       ; CODE2: load32 from ROM 0x08000000 PC=6e  <-- NO stall (addr≥ROM0)
08016c6c  ldrh r2,[r0]       ; TIMER READ    (load16←IO)        PC=70
08016c6e  strh r1,[r0,#2]    ; timer stop
```

Measured window = from the enable store to the read `ldrh`. Access classification:
CODE1 = data-load-to-**non-ROM** (IWRAM); CODE2 = data-load-**from-ROM**.

### 2a. `P.S` (0x4010) — FAILS — mGBA 15, dingbat 16, expected 17

Live stall trace (P.S rows only), with the cpu-cycle timestamp `now`:

```
PC=08016c6a str  waitIn=1 s=1 N=4 dist=big prevLoads=0 loads=1 stall=2 ret=-3 lastPF=6a now=…501 tm0=0
PC=08016c6c ldr  waitIn=2 s=1 N=4 dist=big prevLoads=0 loads=1 stall=2 ret=-3 lastPF=6c now=…503 tm0=0
  (ldr r2,[r3] from ROM — GBAMemoryStall NOT called; the address<ROM0 guard fails)
PC=08016c70 ldrh waitIn=2 s=1 N=4 dist=big prevLoads=0 loads=1 stall=2 ret=-3 lastPF=70 now=…518 tm0=15
```

Per-instruction `currentCycles` (mGBA model, Thumb, S16=1 N16=4):

| access | region | fetch (1+S16) | data wait | `GBAMemoryStall` | POST (N16−S16) | cycles |
|--------|--------|:---:|:---:|:---:|:---:|:---:|
| enable `str`→IO | IO | 2 | `++wait`=1 | wait 1→ **−3** (clamp stall=2) | +3 | **2** |
| CODE1 `ldr`←IWRAM | IWRAM | 2 | +2 | wait 2→ **−3** | +3 | **2** |
| CODE2 `ldr`←ROM | ROM0 | 2 | nonseq32 6, +2 = **8** | *not called* | +3 | **13** |
| read `ldrh`←IO | IO | 2 | +2 | (after sample) | +3 | (excluded) |

`GBAMemoryStall(wait=2, s=1, N=4, fresh)`: `stall=s+1=2`, `loads=1` (loop `2<2`
false), `lastPrefetchedPc=PC`, no clamp, `ret = 2 − (4−1) − 2 = −3`. **Verified live: `ret=-3`.**

Timeline: `now`: enable-store body = X, CODE1 body = X+2 (⇒ enable `str`=2 cyc),
read body = X+15 (⇒ CODE1+CODE2 = 2+13 = 15). Timer:
`raw = (now_read−2) − now_enable = 15`. Calibration (`P.S` of the empty harness) = **0**
(matches the suite's own "Calibration" table, thumb `_4010 = 0`; verified live).
**reported = 15 − 0 = 15.**

### 2b. `..S` (0x0010) — PASSES — 20 everywhere (prefetch OFF)

Prefetch off ⇒ `GBAMemoryStall` early-returns `wait` unchanged; no giveback.

| access | fetch | data wait | POST | cycles |
|--------|:---:|:---:|:---:|:---:|
| CODE1 `ldr`←IWRAM | 2 | +2 | +3 | **7** |
| CODE2 `ldr`←ROM | 2 | +8 | +3 | **13** |

reported = 7 + 13 = **20** = expected. mGBA passes (absent from its FAIL log).

### 2c. The single diverging access

`..S`→`P.S` is *only* the prefetch flag. The whole difference lands on **CODE1
(`ldr r2,[sp]`)**: prefetch off it costs **7**; prefetch on mGBA charges **2** — a
**5-cycle** giveback. Hardware gives back only **3** (20→17); dingbat gives back **4**
(20→16). CODE2 (`ldr`←ROM) is identical (13) in all models because a ROM data-load never
consults the prefetch state.

- **mGBA's error (−2 vs HW):** its `GBAMemoryStall(2)=−3` collapses the load to N→S
  *and* frees a full look-ahead halfword (`stall=2`), even though the very next access
  (CODE2) immediately seizes the ROM bus and, on hardware, aborts/invalidates that
  in-flight prefetch. mGBA never re-charges it. Hardware only lets the load convert its
  own N to an S (save ≈3), not free a downstream fetch.
- **dingbat's error (−1 vs HW):** dingbat's continuous `credit = now − rom_free_since`
  carries **one fractional-S-cycle** (at S16=1 a half-halfword ≈ 1 cyc) into the giveback
  that a whole-halfword floor would discard. It over-frees by exactly 1.

---

## 3. Test 2 — `Trivial DMA (16/ROM)` (ARM)

`testTrivialDmaRom_arm_text` @ `0x0800da28`. SETUP programs DMA3: `SAD=dmaRom` (source in
ROM), `DAD=dmaIwram` (dest IWRAM), `CNT=0x80000001` (enable, 1 unit, 16-bit). Measured
window (ARM, 4-byte instrs, PC = instr+8):

```
0800da48  str  r1,[r0]      ; TIMER ENABLE (store32→IO)           PC=da50
0800da4c  str  r3,[r2,#8]   ; CODE: write DMA3CNT → triggers DMA  PC=da54
0800da50  ldrh r2,[r0]      ; TIMER READ                          PC=da58
```

The CODE store starts a 1-halfword DMA **reading from ROM**, writing IWRAM. The DMA
engine **does not call `GBAMemoryStall`** (dma.c touches no prefetch state), so
`lastPrefetchedPc` is frozen across the burst.

### 3a. `P.S` (0x4010) — FAILS — mGBA 12, dingbat 12, expected 13

Live stall trace (P.S):
```
PC=0800da50 str(enable) waitIn=1 s=1 N=4 ret=-3 now=…326 tm0=0    ; timer enabled
PC=0800da54 str(CODE)   waitIn=1 s=1 N=4 ret=-3 now=…330 tm0=0    ; enable str = 4 cyc (ARM S32=3)
  (DMA runs here — no stall call)
PC=0800da58 ldrh(read)  waitIn=2 s=1 N=4 ret=-3 now=…342 tm0=14   ; raw read = 14
```

ARM per-instruction (fetch base = `1+S32 = 1+3 = 4`; store32→IO POST = `N32−S32 = 6−3 = 3`):
- enable `str`→IO: `4 + GBAMemoryStall(1)=−3 + 3 = 4`.
- CODE `str`→IO(DMA3CNT) **+ DMA**: measured `now_read − now_code = 342−330 = 12` — this is
  the CODE store's own cycles plus the whole DMA burst (2N ROM read + IWRAM write + DMA
  start-up), billed by the DMA engine.

`raw = (now_read−2) − now_enable = (342−2) − 326 = 14`. Calibration ARM `P.S` = **2**
(the suite's "Calibration" table, arm `_4010 = 2`). **reported = 14 − 2 = 12.**

### 3b. Passing sibling `..S` (0x0010) — 16 (prefetch off) — PASSES

With prefetch off the same DMA burst is billed with no giveback; mGBA matches expected 16
(absent from FAIL log). The DMA byte-costs are identical to P.S; the only moving part is
the prefetch resume on the fetch after the DMA.

### 3c. The single diverging access

Here **mGBA and dingbat agree (both 12)** and both miss hardware by 1. The diverging
access is **the first ROM opcode fetch that resumes after the DMA burst ends**
(the fetch feeding the `ldrh` read). Hardware charges that resume fetch one extra cycle
(a non-sequential restart of the prefetcher, `S16=1` case); both models treat the buffer
as still-primed. Because the DMA froze `lastPrefetchedPc` without advancing it, mGBA's
`previousLoads` for the resume is stale-but-consistent — it just never adds the +1
restart that hardware does. This is the *cleanest* of the three: a pure "+1 on the ROM
fetch that resumes after a non-prefetch ROM-bus event," with no other model noise.

---

## 4. Test 3 — `ldmia [#0x07FFFFFC]!, {r3-r7}` (Thumb)

`testLdmiaOverflow1OamToRom_thumb_text` @ `0x080119c4`. `r2 = 0x07FFFFFC` (**OAM**,
region 7). The LDM loads 5 words ascending with writeback:
`0x07FFFFFC` (OAM), then `0x08000000/4/8/C` (**ROM overflow**).

```
080119cc  str  r1,[r0]           ; TIMER ENABLE                     PC=d0
080119ce  ldmia r2!,{r3-r7}      ; CODE: 5-word LDM, OAM→spills ROM PC=d2
080119d0  ldrh r2,[r0]           ; TIMER READ                       PC=d4
```

### 4a. `P.S` — mGBA 11, dingbat 26, expected 27 — and the mGBA billing bug

Live trace (P.S) — **note there is NO stall entry for the LDM itself (PC=d2):**
```
PC=080119d0 str(enable) waitIn=1 s=1 N=4 ret=-3 now=…903 tm0=0
  (ldmia CODE at PC=d2 — GBAMemoryStall NOT called)
PC=080119d4 ldrh(read)  waitIn=2 s=1 N=4 ret=-3 now=…916 tm0=11   ; raw = 11
```

Two mGBA bugs stack here, both visible in `GBALoadMultiple`:
1. **Region is fixed from the *start* address** (`region = address>>24 = 7 = OAM`), and
   `LDM_LOOP` uses the OAM load macro for **all five** words. The four ROM-overflow words
   are billed at OAM speed (1 cyc each), not ROM speed. So the LDM costs ≈ OAM.
2. **The stall guard uses the *final* address.** After the ascending loop, `address =
   0x07FFFFFC + 20 = 0x08000010 ≥ GBA_BASE_ROM0`, so `if (address < GBA_BASE_ROM0)` is
   **false** and `GBAMemoryStall` is skipped entirely — no N→S conversion, no giveback,
   and `lastPrefetchedPc` untouched.

`raw = (now_read−2) − now_enable = (916−2) − 903 = 11`; calib `P.S` = 0 ⇒ **reported 11**.

Because prefetch-**off** `..S` also gets 11 (mGBA "Got 11 vs 26: FAIL"), **this row's
big miss is NOT the prefetch model at all** — it's the OAM-vs-ROM region billing (bug 1).

### 4b. Where the task's "26 vs 27" lives

dingbat already models the overflow correctly (bills the four ROM words at ROM speed →
26), so dingbat is *15 cycles better than mGBA here*. dingbat's residual **−1 vs
hardware (26 vs 27)** is the *same* prefetch-resume +1 as Tests 1–2: the first ROM
opcode fetch after the ROM-touching LDM. So for guiding the dingbat rewrite, Test 3's
relevant lesson is identical to Tests 1/2 (a +1 on the resume fetch); mGBA is simply not
a usable reference for this row.

---

## 5. Synthesis — the common structural condition and what a faithful port needs

### 5a. The common condition (all three)
Every failing row is a **ROM-executing instruction stream** where a measured
instruction performs a memory event that ties up a bus *without advancing the ROM
prefetch buffer past the current PC*, immediately followed by a **ROM opcode fetch that
resumes sequential execution**:

- Test 1: a **data-load to non-ROM** (`ldr [sp]`) runs the prefetcher, then a
  **data-load from ROM** seizes the ROM bus before the buffer is consumed.
- Test 2: a **DMA burst** occupies the bus (prefetch frozen), then code resumes.
- Test 3: an **LDM whose final address lands in ROM** (prefetch skipped/frozen), then
  code resumes.

In every case the *state that matters* is: **prefetch progress must be tracked as a
floored, integer count of whole halfwords fetched past PC, and the fetch that resumes
ROM execution after such an event must be charged one full `S16` restart** — hardware
does not treat the buffer as already holding that next halfword. `S16=1` is where this
becomes observable as exactly ±1 (at `S16=2` the rounding lands the same as hardware,
which is why P.. / PN. pass).

### 5b. What each model gets wrong
- **mGBA:** `GBAMemoryStall` frees a look-ahead halfword (`−stall`) on the *data* access
  and never re-charges the resume fetch → 1 low (Test 1 compounds to 2 low because the
  ROM-load downstream should have aborted the prefetch). For DMA/overflow-LDM it also
  skips the stall entirely. Net: mGBA is **1–2 low** on `S16=1` prefetch rows and is
  **not** the right target.
- **dingbat:** its continuous `credit = min(now − rom_free_since, 8·S)` in *raw cycles*
  keeps a fractional-halfword (≈1 cyc at S16=1) that a whole-halfword floor discards.
  It over-credits the resume by exactly **1**. dingbat is **1 low** — one integer floor
  away from hardware.

### 5c. The exact floor a port must maintain
Track prefetch fill as an **integer buffered-halfword count anchored to PC on a 2-byte
grid** (mGBA's `lastPrefetchedPc` representation is the right *shape*, wrong *arithmetic*).
Concretely, for the fetch that resumes ROM execution after a non-fetch ROM-bus event:

1. Convert cycles-available-to-prefetch to whole halfwords **before** offsetting cost:
   `buffered = floor(free_cycles / S16)` — never spend the `free_cycles mod S16`
   remainder. (This is dingbat's `credit`, floored — it removes dingbat's −1.)
2. Charge the resuming fetch a **full non-sequential/restart `S16`** unless the buffer
   provably already holds that halfword as a *completed* whole (not a mid-fetch
   fraction). A DMA or ROM-touching LDM advances the buffer by **zero** completed
   halfwords, so the resume fetch pays in full. (This is the +1 that both models miss.)
3. Do **not** copy mGBA's `−stall` "free the next fetch" giveback on a non-ROM data load
   when the following access is a ROM access — that downstream ROM access aborts the
   in-flight prefetch; the freed halfword must be re-charged (this removes mGBA's extra
   −1 in Test 1).

Target the **`expected` (hardware) table**, and validate against it — not against mGBA.
Where the doc's §5 remedy ("replace `credit` with `floor(credit/S)·S`") is directionally
correct for dingbat's −1, but its stated goal (match mGBA) is wrong: matching mGBA would
regress dingbat to 15/12/11.

### 5d. Cross-check the doc's claims
- ✅ `GBAMemoryStall` body, WAITCNT tables, the `address<ROM0` guards, `lastPrefetchedPc`
  reset-on-refill: all confirmed verbatim and behave as documented.
- ✅ Integer `loads`/2-byte `lastPrefetchedPc` quantization vs continuous credit: real,
  and it is the dingbat −1 mechanism.
- ❌ "mGBA reproduces the expected values" / "dingbat = mGBA − 1": **false.** mGBA fails
  all three; dingbat = mGBA **+1** on the prefetch rows and is nearer hardware.
- ❌ Treating mGBA as the port target: would move dingbat away from hardware.
