# ARM9 caches: what they hold

Status: **working** (2026-10-02, branch `nds-icache`). Both ARM946E-S
caches hold contents: the data cache since round 5 (`nds-testroms`), the
instruction cache since this round. Code: `timing.nim` (TagCache, DcLine,
IcLine, the cachability tables), `bus9.nim` (`dc_*`, `ic_*`, fetch32/16,
cp15_write's C7 commands), `bus7.nim` (ARM7 stores), `hle_bios.nim`
(SoftReset).

## The hardware

GBATEK "DS Memory Control - Cache and TCM", "ARM CP15 Cache Control",
"ARM CP15 Control Register", "ARM CP15 Protection Unit":

| | Instruction cache | Data cache |
|---|---|---|
| size | 8 KB: 64 sets x 4 ways x 32-byte lines | 4 KB: 32 sets x 4 ways x 32 bytes |
| enable | control bit 12 | control bit 2 |
| cachable | PU region bit in C2,C0,1 | C2,C0,0; write-buffered (write-back) C3,C0,0 |
| allocation | on a fetch miss | on a read miss ("read-allocate": a write miss goes to memory) |
| replacement | round robin with control bit 14 set, pseudo-random with it clear | same |
| whole cache | C7,C5,0 invalidate | C7,C6,0 invalidate |
| one line by address | C7,C5,1 invalidate; C7,C13,1 prefetch (fill) | C7,C6,1 invalidate, C7,C10,1 clean, C7,C14,1 clean + invalidate |
| one line by set/index | C7,C5,2 is listed as **not** an ARM9 command | C7,C10,2 clean, C7,C14,2 clean + invalidate (C7,C6,2 also listed "-") |
| lock-down | C9,C0,1 (format B, Cache Type register 0F0D2112h) | C9,C0,0 |

Cachability needs the protection unit on (control bit 0): "cache can be
used only in combination with the Protection Unit". The firmware's regions
cache main RAM and the BIOS. The caches do not snoop: a store by DMA, the
ARM7, or the ARM9 itself past the cache (an uncached mirror, a region
without the cache bit) changes memory and leaves what a cache holds
alone. So code written to memory runs only after the instruction cache's
copy of those lines is invalidated (and, if the code was stored through
the write-back data cache, after the data cache is cleaned): the SDK's
`DC_FlushRange` + `IC_InvalidateRange`, what an overlay loader must do.

The ARM9 BIOS does it too: its routine at 0xFFFF0778 (called from reset
and from SoftReset, with r0 = 12078h) writes the control register, then
C7,C5,0 and C7,C6,0 (the data cache invalidated, **not** cleaned) and
drains the write buffer (C7,C10,4). GBATEK's SoftReset entry says
"flushes caches and write buffer".

## The model

**Tags and timing** (`timing.nim` TagCache, unchanged): per slot the line
number + 1, a round-robin victim per set, the last line hit as an inline
fast path. A fill costs FILL_MAIN / FILL_BIOS master cycles; a hit costs
nothing beyond the instruction (GBATEK "DS Memory Timings").

**Data cache contents** (round 5, docs/nds/test-roms.md): `main_ram` is
what the ARM9 sees through the cache; a cached line whose memory side
differs (dirty in write-back, or written behind the cache) keeps the
memory side in `DcLine.ram`. DMA, the ARM7, uncached accesses and code
fetches read that; clean / evict write the CPU's copy back, invalidate
drops it. Main RAM only (the other cachable memory, the BIOS, is
read-only).

**Instruction cache contents** (this round, `IcLine`):

- A hit runs what the line held when it was filled. A miss fills from
  memory's side -- not from a dirty data-cache line, which only reaches
  memory when cleaned or evicted.
- **Main RAM: copy on write.** A fill records only which RAM line the slot
  holds (`line1`, and a holder count in `slot_of` bits 8-15, beside the
  data cache's slot in bits 0-7). Every change to memory's side of a RAM
  line -- an ARM9 store past or through the data cache (`write9`), DMA
  (also `write9`), an ARM7 store (`write7`), a data-cache clean or
  write-back eviction (`dc_clean`, `dc_drop`) -- first calls `ic_keep`,
  which copies the line into every instruction slot holding it that has
  not kept a copy yet (`kept`), and counts it in `page_apart` for its
  4 KB page. A fetch from main RAM reads memory unless its page is
  `apart` (data-cache or instruction-cache copies), so the common path is
  the same single check as before.
- **Why that is exact.** Until a slot is kept, nothing has changed
  memory's side of its line since the fill (every such change goes
  through `ic_keep` first), so memory still holds what the fill read, and
  copying it at the first change copies the fill. A store into the CPU's
  copy of a dirty write-back line does not change memory and keeps
  nothing. A conservative keep (copying when memory would not have
  changed) is still exact. Checked by a scratch build that also copied
  every line at fill time and compared every cached fetch with that copy:
  SoulSilver 0-8100 frames (real BIOS) with no mismatch (below).
- **Other regions.** Shared WRAM, palette, VRAM and OAM lines are copied
  at the fill (no store path watches them). The BIOS is read-only. I/O and
  the GBA slot are read live (Assumed: caching them is a fault GBATEK warns
  against, and no program runs cached code there).
- **Disabled while lines are valid**: with control bit 12 clear (or the
  region uncachable) fetches read memory and the lines stay, so enabling
  the cache again without invalidating runs the old lines. Assumed: GBATEK
  says nothing; the tags already behaved this way.
- **Commands**: C7,C5,0 and C7,C5,1 drop lines; C7,C5,2 is ignored (not an
  ARM9 command, GBATEK); C7,C13,1 fills the line as a fetch would, when
  the protection unit is on and the address is code-cachable (Assumed: the
  enable bit does not matter; no cycles charged).
- **Mirrors**: each mirror of a RAM line is its own cache line (a
  different tag; all four 4 MB mirrors fall in one set). Unlike the data
  cache's one-mirror rule, nothing is merged: a store keeps every slot
  holding the RAM line.
- **HLE BIOS**: SoftReset now invalidates both caches after writing the
  control register, as the real BIOS's routine does (`hle_bios.nim`). No
  other SWI touches the caches or reads code.
- **Thumb**: a line holds 16 Thumb opcodes; a Thumb pair still shares one
  fetch for timing and its second half is read from the same kept copy.

**Save states** carry `iline` (line, kept flag, the kept bytes) and the
widened `slot_of` / `page_apart` in section 5; a state loaded mid-stale
runs the same stale code (`nds_testroms_test`).

**Idle-loop skipping** (docs/nds/perf.md): a fill already bumped
`idle_epoch9`; a keep bumps the shared epoch (a store that keeps a line
has bumped it anyway when it changed memory); C7 commands bump it in
cp15_write. `nds_perf_test` (skipping on/off byte-identical) passes.

**Cost**: SoulSilver p12, real BIOS, frames 0-8100: 377.41 G host
instructions retired before, 379.88 G after (+0.65 %; round 5's data
cache cost +1.0 %). Fills now call `ic_fill`; stores test one 16-bit map
entry as before.

## Evidence

`tests/nds/src/icache_stale` (ours, `build_3d.sh`, bottom-screen hex
digits read with `png_text.py`): code written into an instruction-cached
line behind the cache, run before and after invalidating. GBATEK's
semantics give the first column; the reference runs (docs/oracles.md)
model no cache contents at all:

| Row | What | GBATEK / ours | before this round | reference cores |
|---|---|---|---|---|
| STR | v1 filled; v2 stored to the same address (region not data-cached); C7,C5,1 | 1 1 2 | 1 2 2 | 1 2 2 |
| MIR | v2 stored through the uncached mirror; C7,C5,0 | 1 1 2 | 1 2 2 | 1 2 2 |
| DMA | v2 DMA'd in; C7,C5,1 | 1 1 2 | 1 2 2 | 1 2 2 |
| THM | Thumb, halfword store; C7,C5,1 | 1 1 2 | 1 2 2 | 1 2 2 |
| OFF | cache off: memory; on again: the old line (Assumed); C7,C5,1 | 1 2 1 2 | 1 2 2 2 | 1 2 2 2 |
| PRE | C7,C13,1 prefetch, then v2 stored | 1 2 | 2 2 | 2 2 |
| WB | v2 stored through the write-back data cache; C7,C5,1 alone; C7,C10,1 + C7,C5,1 | 1 1 2 | 1 1 2 | 1 2 2 |
| EVI | v2 stored, 8 other lines of the set run | 1 2 | 1 2 | 1 2 |

`tests/nds_testroms_test.nim` "ARM9 instruction cache contents" pins the
same through the bus (ARM7 and uncached-mirror stores, dirty data-cache
lines, clean, whole invalidate, off/on, round-robin eviction after four
lines of a set, Thumb halves, a save state, prefetch) and runs the ROM.

SoulSilver and the sweeps: see "Regression" below.

## Regression

- **SoulSilver** p12 (real BIOS, `--rtc 2004-01-01`): frames
  3000/5000/8000 unchanged (e4b66d68 / 6cf51b7e / ae4536a1). Under the
  verifying build (fill-time copy of every line, every cached fetch
  compared): 4.43 M line fills and 434 M checked fetches over frames
  0-8100, 810 lines kept before a store, 10 fetches answered from a kept
  copy, none of them different from memory and no mismatch -- the game
  invalidates whatever it rewrites (its overlays included) before running
  it.
- **Sweeps** (`tools/ndssweep --no-ref`, 600 frames, before and after):
  396 ROMs -- homebrew 60, homebrew-ex 72, homebrew-games 20, nds-examples
  14, BlocksDS tests/examples/pick 230. Seven differed between the two
  sweeps (BlocksDS `time__rtc_interrupt`, `time__rtc_set_get`,
  `time__timers` twice, `ipc__transfer_region`, `RealTimeClock`, `2048`
  twice, `nitrografx`); all seven read the host clock, and rerun with
  `--rtc 2004-01-01` every shot is identical. No ROM in the set runs code
  it changed without invalidating.
- All 14 `tests/nds_*_test.nim` suites pass, `nds_perf_test` (skipping
  on/off byte-identical) and `nds_hle_bios_test` (HLE vs real BIOS, 8358
  cases) included.

## Not modelled

- **Pseudo-random replacement** (control bit 14 clear): both caches always
  replace round robin. Nintendo's SDK (SoulSilver runs with control
  5707Dh) and libnds (5507Dh) set bit 14; BlocksDS leaves it clear
  (5307Dh), so on a console its programs evict pseudo-randomly. Which line
  goes differs, not what a line holds.
- **Lock-down** (C9,C0,0/1): stored and read back, not applied.
- **Cache timing beyond the fill**: prefetch and maintenance commands cost
  nothing; write-backs are free (docs/nds/test-roms.md, "Cache maintenance
  and write-back timing").
- **Uncached code changed under the pipeline**: without the cache, a store
  into the next opcodes is seen at once (fetches happen as each opcode
  runs; the ARM9's prefetch is not modelled).
- **A console run of icache_stale** (a flashcart) would settle the
  OFF row's third digit and confirm the rest.
