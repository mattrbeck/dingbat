# DS performance: the cheap, exact wins, then caching and the interpreter

Three rounds: low-hanging fruit (branch `nds-perf`: idle loops, 3D frame
reuse), a measured one on caching and the interpreter (branch
`nds-cache-perf`: where the host instructions go, 2D line reuse, and the
CPU's per-opcode overhead) and one on the 3D engine (branch `nds-3d-perf`,
"3D renderer speed" below). One rule over everything: **a speed-up may not
change any output** -- frames, sound, the whole machine state (save-state
payload), opcode counts, the sweep's statuses. The skips (idle loops, 3D
frames, 2D lines) can be turned off with `DINGBAT_NDS_NO_SKIP=1`, and
`ndsrun --state-hash N` prints a CRC-32 of the whole state every N frames,
so an on/off pair of runs can be compared byte for byte; the interpreter
changes are always on, and were checked by whole-state hashes against the
build before them (same layout) and by the tests named in their sections.

## Idle-loop skipping (arm/cpu.nim `loop_edge`, nds.nim `quiet`)

Nothing to model on the hardware side: a CPU that spins executes. Programs
that never halt -- `B .` at the end of a demo, VCOUNT and IPC polls, keys
polled in a loop -- cost the emulator 150-250 host instructions per spun
opcode (docs/nds/compat.md, "Performance outliers").

**The proof.** The machine keeps an *epoch*, bumped by anything a loop
could see change:

| bumps the shared epoch | bumps one CPU's own epoch |
|---|---|
| a store that changes main RAM or shared WRAM (a same-value store does not) | a store that changes its TCMs (ARM9) or ARM7 WRAM |
| any store to I/O, VRAM, palette, OAM, the GBA slot | a read of an I/O register that is not *steady* (below) |
| an IPC receive-FIFO pop | a GBA-slot read by the slot's owner (GPIO, RTC) |
| every event dispatch | an ARM9 cache line fill, any CP15 write |
| every `run_until` call (the frontend may have changed keys, touch, the lid) | an unmapped access (both CPUs: the count is state) |
| an instruction-cache line kept before memory under it changes (docs/nds/cache.md) | |

and each CPU counts its exceptions, mode switches and SWIs (HLE SWIs write
memory directly). *Steady* registers are the ones only writes and events
change, read without a side effect: DISPSTAT/VCOUNT, the 2D engine
registers, DMA, KEYINPUT, IPCSYNC, IPCFIFOCNT, ROMCTRL, EXMEMCNT, IME/IE/IF,
VRAMCNT/WRAMCNT/VRAMSTAT, POSTFLG, POWCNT, and on the ARM7 the SPU
registers (`bus9.nim io9_steady`, `bus7.nim io7_steady`). Timers, the
divider/square-root unit, GXSTAT and the other 3D reads, SPI/AUXSPI busy
flags, RTC, wifi and the card data port are not.

The bus calls `loop_edge` when it fetches the target of a backward branch
(the fetch path's non-sequential case, so straight-line code pays
nothing). One loop head is watched at a time. When the CPU is back at it
with its epoch (shared + own + CPU count) untouched since an earlier visit
and r0-r14, CPSR, SPSR and the bus's timing state (`idle_sig`: last
fetch/data addresses, protection-unit pages, cache fast-path lines) equal
to a snapshot taken then, the stretch between the two visits read the same
values, cost the same cycles and ended where it began: it repeats exactly
until something outside changes. Inside one `run` call nothing outside
runs, so the whole repeats that still start before the slice end are
counted instead of executed: the clock, the opcode count and the skipped
total advance by whole repeats, and the opcode at the head then runs as it
would have. The repeat may contain inner loops and calls (a `keysDown()`
wait with `scanKeys()` inside): other backward branches do not move the
watched head unless it goes unvisited for 32 of them, and each visit is
compared with a snapshot kept for up to 32 visits. A head that keeps
finding work (16 visits in a row) is left unwatched for 256 backward
branches, so compute loops rarely pay for a call (longer or growing pauses
were tried: they cost SoulSilver 1.2 % by missing its waits).

**Slices.** `run_until` interleaves the CPUs in 64-cycle slices. When
neither can change anything before the next event -- each is either in a
proven loop with its epoch untouched, or halted with no interrupt to wake
it -- interleaving changes nothing, and the slice runs straight to the
event (as it already did with both halted). An event, a store or a
volatile read ends the proof; it is re-made in two or three passes.

**What it does not catch.** Loops that change memory every pass (libnds
`scanKeys`' key-repeat countdown: MAXMXDS's menu), loops that poll a timer
or a busy flag (the value moves with time), loops whose state cycle is
longer than 32 visits of the head, and loops that keep taking interrupts.
Those run as before.

## 3D frame reuse (gpu3d.nim `render_frame`)

The renderer reads only the swapped Polygon/Vertex buffers, DISP3DCNT, the
swap parameter, the render registers (0x4000320-0x40003BF) and the texture
and palette slots, and what it writes that outlives the frame (the colour
buffer, line costs, RDLINES, the underflow flag) follows from those alone;
its other buffers are scratch, rewritten before they are read
(render.nim, savestate.nim RENDER_SKIP). A frame whose inputs all equal
the last drawn frame's comes out the same, so it is not drawn again.
`render_frame` keeps copies of the registers and parameters it last drew
and compares them field by field; the Polygon/Vertex lists it drew stay
where they are (`last_is_cur`) until the next SWAP_BUFFERS moves those
buffers to `last_polys`/`last_verts` (no copy), so a frame with no swap
since the last render needs no list comparison at all. For textures no copy is
needed: a bank in a texture or texture-palette slot (VRAMCNT MST 3) has no
CPU address ("can be accessed only by the display controller", GBATEK "DS
Memory Control - VRAM"), and display capture writes only LCDC-allocated
banks (GBATEK "DS Display Capture"; gpu.nim checks it), so slot contents change only after
a remap or through a write to the slot regions themselves (test harnesses
do that); both bump `vram.tex_gen`. The cache is outside the save state;
`after_load`'s remap bumps `tex_gen`, so a loaded machine draws afresh.

Games re-submit their whole scene every frame even when nothing moves:
in SoulSilver's overworld (600 frames from frame 7100 of the p12 script)
471 of 546 rendered frames had the same polygons and vertices as the frame
before and 468 the same everything; those are now reused.

## 2D line reuse (engine2d.nim `render_line`)

A graphics line (display mode 1) reads the engine's registers and line
latches (window Y, affine reference points, the mosaic latch), its half of
palette and OAM, the VRAM banks mapped into its BG, OBJ and extended-palette
regions, and for engine A the 3D line. What it leaves behind is `line` (and
with affine mosaic, the reference-point latch); `bgpix`, `objpix`, the
window mask and the other per-line buffers are rewritten before they are
read, so they are scratch and no longer in the save state (`ENGINE_SKIP`).
A line whose inputs all equal those it had when it was last drawn comes out
the same, so it is copied from a per-line store (192 lines of output, key
and, for engine A, the 3D line) instead of drawn.

- **Registers and latches**: compared as a key (`LineKey`) built at the
  line's start.
- **Palette**: the bus counts every change to each engine's half
  (`mem_gen`; a store of the value already there is not a change).
- **OAM**: a change to an entry counts for the lines its OBJ is on before
  and after the store (`oam_store`, `lgen`): `render_objs` skips an OBJ on
  every other line before reading more than its first two halfwords. A
  rotation/scaling parameter counts for the lines of every affine OBJ
  using its group. A game's per-frame OAM copy with one sprite moving
  redraws only the lines that sprite leaves and enters.
- **VRAM**: per 1 KB block of the banks, `vram.vgen` counts the stores that
  changed a byte there. While a line is drawn, every VRAM read marks its
  block (the views know each page's place in the banks); the line keeps
  that set and the sum of the blocks' counts, and is reused only while the
  sum is the same, so a store elsewhere in the engine's VRAM (a text box
  being typed, a tile animating) leaves it alone. A read through
  overlapping banks makes the line not reusable. A remap is in the key
  (`remap_gen`). Display capture writes only LCDC banks, which no engine
  reads.
- **3D line**: compared by value (1 KB).
- Not reused: display capture lines (they need `gfx`), VRAM and
  main-memory display, an engine switched off, the 2D unit tests (`lc_on`
  is set by the machine; they poke memory directly).

A state load remaps VRAM, which bumps `remap_gen`: a loaded machine draws
every line afresh. In SoulSilver 0-6000 (p12) 82 % of engine A's lines and
90 % of engine B's are reused (with one change counter per engine instead
of per block: 70 % and 90 %; per block it costs 2 % fewer host
instructions overall). What is left is mostly register changes (scroll,
fades) and the 3D line.

`tests/nds_perf_test.nim` runs 15 2D ROMs (scrolling, affine and
rotscale BGs, affine and extended-palette sprites, H-blank and mid-frame
windows, bitmaps, 3D under 2D) with reuse on and off, changes palette, OAM,
BG VRAM and the mapping behind reused lines through the bus, then moves,
grows, rotates, wraps and hides an OBJ through OAM alone, and loads a
state over a running machine. Dropping the palette count, a block's
count, the OBJ's old lines or the parameter group fails it.

## Error-flag checks (`quirky`)

Nim's exceptions under ARC are "goto" exceptions: after every call to a
proc that might raise, the caller loads a global error flag and branches
(`ldrb; tbnz` on arm64; `if (*nimErr_) goto BeforeRet_` in the C). Defects
count as raising, so the checks stay in -d:danger builds, and the
interpreter makes several calls per emulated opcode (the bus, the
execute dispatch): about 5000 such pairs in the binary, and 12 % of
SoulSilver's host instructions. No proc in the DS core raises on purpose
(the save-state loader and file reading excepted), so every emulation
module pushes `quirky`, which drops the test after calls. A raise site
still jumps out of its own proc; what changes is only that a caller in a
quirky proc goes on after a callee that raised, and the exception reaches
the first non-quirky frame (the frontend's call) later. With checks off
(-d:danger, the web build) nothing in the core raises at all; in -d:release
a bounds defect surfaces late, and not harmlessly: measured with a
small program (-d:release, Nim's goto exceptions), the out-of-range access
still happens (a read returns whatever lies there, so a write would land
in memory) and the quirky caller goes on with that value before the
exception reaches a non-quirky frame. A division by zero still stops the
program at once. Modules that already push `checks: off` (render.nim)
check nothing either way. `savestate.nim` (state_error) and
`read_file_bytes`/`load_nds` (IOError) stay outside.

## Sequential fetch fast paths (bus9.nim `fetch_line9`, bus7.nim `fetch_page7`)

Most opcode fetches follow the one before. For those, the timing model's
answer is known in advance:

- **ARM9**, inside the 32-byte line of the last fetch, when that fetch was
  an ITCM fetch or an instruction-cache hit or fill (the line is now
  `icache.last`) and the bytes are memory's (ITCM, the BIOS, a main RAM
  line in a page with nothing apart, or with no kept copy and no dirty or
  written-behind data-cache line of its own: `line_clean9`): no cost, no
  tag change, no protection check (not a branch target, not a page's
  first word), no loop edge; only `last_data9`, `last_pc9` and
  `last_fetch9` move. (Homebrew that mixes code and written data in a
  page -- NitroGrafx -- spent a third of its time in the slow path before
  `line_clean9`.)
- **ARM7**, inside the 4 KB page of the last fetch, in the BIOS (fetches
  pass BIOSPROT: pc = address), main RAM with nothing apart, or WRAM: the
  fixed sequential cost of that region; `last_data7` and `last_fetch7`
  move.

`fetch32`/`fetch16` test one line or page number and the sequential
address, then read the opcode through a host pointer. An ARM9 fetch that
runs on into the next line of the same page (same region, nothing apart)
needs only that line's tag check: ITCM again, or an instruction-cache hit
(which makes it `last`, as the full lookup would); a miss leaves the tags
alone for the full path to fill. Everything else goes
the old way (`fetch_slow9`/`fetch_slow7`), which sets the shortcut up for
the next fetch. It is turned off by everything that changes what it
assumes: any CP15 write (TCMs, enables, C7 commands), WRAMCNT, a main RAM
page getting a memory side apart from the CPU's view (a dirty data-cache
line, a kept instruction-cache line: `page_apart_now`, before the change)
and a state load (it is not saved). Line fills and tag changes happen only
on fetches outside the line, or C7 commands.
`nds_testroms_test` ("sequential fetch fast paths") changes memory under a
line mid-run, invalidates, dirties a data-cache line in the ARM7's code page
and moves WRAMCNT under the ARM7; dropping any of the turn-offs fails it.

## Dispatch tables (arm/cpu.nim `arm_lut`, `thumb_lut`)

ARM opcodes are dispatched through a 4096-entry table indexed by bits
27-20 and 7-4 (after the condition check), Thumb opcodes through a
1024-entry one indexed by bits 15-6. An entry is the old decode tree and
its main handlers (ALU, single transfer, branch) forced inline, given the
opcode with the entry's index bits replaced by constants: `(instr and not
M) or K`, which equals `instr` because the table was indexed by those very
bits. The C compiler folds every test on them, so an entry is the one
path through the decoder and an ALU op specialised by opcode, immediate or
shift type and S bit. Exact by construction: the decoder's code is
unchanged, only what the compiler knows about its input. Entries that
differ only in bits nothing decodes there (a branch offset, an immediate,
a Thumb register number: `arm_fixed`, `thumb_fixed`) share one proc,
which reads those bits from the opcode: 1778 ARM and 100 Thumb procs per
CPU. The binary grows by 0.8 MB (ndsrun 1.13 -> 1.94 MB). A bus module
expands `dispatch_tables(B)` at its end, where every mixin is declared.

## ARM7 WRAM data accesses (bus7.nim `wram7_fast`)

Most ARM7 data accesses go to its own WRAM (0x03800000-0x03FFFFFF: 71 M
of 85 M in SoulSilver's first 6000 frames). There `data_cost7` and
`read7`/`write7` come to two master cycles whatever the width or sequence,
`last_data7 = a`, and (for a store) the change-detecting store that bumps
`idle_epoch7`; the bus's `read*`/`write*` do just that before the general
path.

## Interrupt checks only when something changed (arm/cpu.nim `run`, `attn`)

Before each opcode the run loop tested HALT and the IRQ line (IME, IE and
IF through two pointers, then CPSR.I): about a dozen host instructions per
opcode. Inside one `run` call nothing but that CPU executes -- no event is
dispatched, the other CPU waits -- so these can only change through what
the CPU itself does: an I/O or GBA-slot access (register writes, reads
with side effects, DMA started, the geometry FIFO, HALTCNT), a CPSR write
(`set_cpsr`: MSR, a return from a mode), a SWI (HLE SWIs halt and write
I/O) or a CP15 write (wait for interrupt). Each of those sets the CPU's
`attn` flag; the loop tests halt and the IRQ line only when it is set, and
`run` starts with it set (events, the other CPU and the frontend change IF
between calls). Taking an exception only sets CPSR.I. The traced loop
(`--trace9/7`) keeps the old per-opcode checks. `nds_testroms_test`
("interrupts taken at the opcode after the write that allows them") runs
an `STR` to IME and an `MSR` clearing CPSR.I on both CPUs and checks the
IRQ comes before the next opcode; leaving out the I/O write's flag fails
it (the IRQ comes one opcode late).

## Where the host instructions go (round 2, `nds-cache-perf`)

Measured on `ndsrun` -d:danger (the web build's mode) with
`/usr/bin/time -l` (instructions retired: load-independent, exact per
binary) and an in-process sampler (SIGPROF every 100 us of CPU time,
pcs symbolised with inline frames by `atos -i`, then sorted into
components by the innermost recognisable frame; scripts in the round's
scratch directory). SoulSilver p12 frames 0-6000, real BIOS: 187.5 G host
instructions, 2.3 G of them loading the ROM; the CPUs *executed* 205 M
ARM9 opcodes (238 M counted: idle-loop skipping did the rest) and 225 M
ARM7 ones, so 431 host instructions per executed opcode all told.

Sampled time at the start of the round (base 20a766f2), and the same
converted to host instructions per executed opcode of that CPU (time share
x 185 G / opcodes: approximate, as instructions per cycle differ a little
by component):

| component | ARM9 | ARM7 |
|---|---|---|
| run loop + `step` (IRQ line, halt, trace, cycle accounting, the error-flag tests after calls) | 8.0 % (72) | 8.8 % (72) |
| opcode fetch (fetch timing, PU page check, I-cache tags, the read) | 4.8 % (43) | 2.0 % (16) |
| decode (condition, the dispatch tree) | 4.3 % (39) | 4.7 % (39) |
| handler bodies (ALU, transfers) | 4.0 % (36) | 6.5 % (53) |
| data accesses (TCM/region tests, timing, D-cache tags and contents, I/O) | 7.0 % (63) | 7.0 % (58) |
| **CPU** | **28.1 % (254)** | **29.0 % (239)** |

The rest: 2D engines 22.1 %, 3D 8.4 %, startup and seq copies 5.1 %, SPU
3.8 %, the slice loop and events 2.4 %. So per executed opcode the CPU
side was ~245 host instructions, and the fetch side only ~1/6 of it: most
went to loop overhead, decode and the data path.

What each change removed (exact: successive builds, same frames,
whole-state hashes equal):

| change | SoulSilver 0-6000 | per executed opcode |
|---|---|---|
| base | 187.5 G | 431 |
| 2D line reuse, one change count per engine | -35.4 G | (2D) |
| error-flag tests after calls (`quirky`) | -18.8 G | -44 (32 of it CPU + bus) |
| sequential fetch fast paths | -6.4 G | -15 |
| dispatch tables (specialised decoders) | -9.9 G | -23 |
| halt/IRQ checks only on `attn` | -5.4 G | -12 |
| 2D: per-block VRAM, per-line OAM counts | -2.8 G | (2D) |
| ARM9 fetch into the next cached line | -2.2 G | -5 |
| ARM7 own-WRAM data | -2.1 G | -5 |
| ARM9 fast path for clean lines in pages apart | +0.4 G | (-37 % on NitroGrafx) |
| **now** | **104.9 G** | **239** |

And where the time goes now (same sampler): ARM9 33 % (handler bodies
with decode 13 %, data 6.5 %, fetch 7.6 %, loop 3.6 %, tags 1.9 %), ARM7
30 % (handler bodies with decode 16.6 %, loop 5 %, data 4.1 %, fetch
4.6 %), 3D 12 %, 2D 8 %, SPU 5 %, slice loop 3.6 %, startup 6 %. Per
executed opcode that is roughly 160 host instructions for the ARM9 and
140 for the ARM7, about 55 of them the run loop and fetch: the stores of
pc, r15, cur_pc and the trackers, the table jump, and the cycle and opcode
counts.

## A decoded or block cache?

The question was whether the code being "materially the same between
caches" could be cached decoded. Decoding is now memoised at compile time
instead: the dispatch tables are the decoder specialised for every index,
and a lookup costs the same as a decoded-cache hit (a load and an indirect
call) with nothing to invalidate. What a block cache could still remove is
the per-opcode fetch work left in the fast paths -- the line/page and
sequence compares, the opcode load, the index computation -- about 15 of
the ~55 remaining loop and fetch instructions per opcode, an upper bound of
6-7 % of SoulSilver now. Exactness would cost a write barrier on every
code-holding page (both CPUs' stores, DMA, cache write-backs, the loaders)
or a per-block check of the opcodes, which is the fetch it saves. The GBA
core's cached-interpreter study (2026-07, since dropped from docs/)
reached the same ceiling, +8-12 %, for the same reason: the timing
model's per-access work, not decode, is what is left. Not built.

## Numbers: round 2 (`nds-cache-perf`)

Host instructions retired, -d:danger, real BIOS unless noted,
`--rtc 2004-01-01`; homebrew: 600 frames, the sweep's default input
script. Base = `worktree-nds-skeleton` 20a766f2. Every row's screens (and
for SoulSilver the shots at 3000/5000/8000: e4b66d68 / 6cf51b7e /
ae4536a1) and opcode counts are identical to the base; the state rows run
from the same machine states (saved by each build: the layout dropped the
2D scratch).

| workload | base | now | change |
|---|---|---|---|
| SoulSilver p12, frames 0-8100 | 318.8 G | 182.9 G | -42.6 % |
| SoulSilver p12, frames 0-8100, HLE BIOS | 307.8 G | 174.9 G | -43.2 % |
| SoulSilver p12, frames 0-6000 | 187.5 G | 104.9 G | -44.0 % |
| SoulSilver title, 600 frames from frame 1000 | 25.70 G | 17.28 G | -32.8 % |
| SoulSilver intro dialogue, 600 frames from frame 3000 | 19.23 G | 9.40 G | -51.1 % |
| SoulSilver overworld, 600 frames from frame 7100, walking | 42.91 G | 27.15 G | -36.7 % |
| Cave Story | 33.86 G | 23.07 G | -31.9 % |
| MAXMXDS | 74.28 G | 44.45 G | -40.2 % |
| nesDS | 7.74 G | 4.60 G | -40.6 % |
| NitroGrafx | 101.45 G | 56.49 G | -44.3 % |
| trans flag (beam race) | 90.12 G | 37.62 G | -58.3 % |
| Space Impakto | 23.65 G | 13.92 G | -41.1 % |
| Tales of Dagur | 16.11 G | 14.35 G | -10.9 % |
| Triple Triad | 15.72 G | 9.04 G | -42.5 % |

Tales of Dagur scrolls its affine BGs every frame (engine A's lines all
change) and maps two banks over one page of engine B's BG (the slow,
OR'd path, never reused); its 2D compositing is what is left. NitroGrafx
changes its palette or VRAM mapping every frame (no line reused); its gain
is the interpreter's, a third of it from fetching code in pages that also
hold written data (`line_clean9`).

**Checks.** All 14 DS suites pass (`nds_perf_test` gained the 2D line
reuse runs and pokes, `nds_testroms_test` the fetch fast path and
interrupt latency checks). Every ROM in `~/.cache/dingbat-nds/roms` (504:
our tests, the 3D suite, BlocksDS tests and examples, gbeplus, homebrew,
libnds examples; 600 frames, the default input script, real BIOS) ran
with skipping on and off and on the base build: whole-state hashes every
30 frames equal on/off, and final screen, three shots, sound and opcode
counts equal on/off and to the base, in all 504. Over the 504 runs the
host instructions fell from 5809 G to 3961 G (-31.8 %; the largest:
disp_mmem 132 -> 113 G, math__atan2 126 -> 66 G, NitroGrafx 102 -> 57 G,
the gbeplus ARM9 tests ~99 -> ~70 G). SoulSilver with the HLE BIOS gives
the same shots and opcode counts as before; a -d:release build (checks
on) drops from 231.2 G to 135.0 G on frames 0-6000.

The DS web module (`web/nds/nds.wasm`, emcc -O3) grows from 617 KB to
780 KB (gzip 185 KB to 206 KB) with the dispatch tables; ndsrun from
1.13 MB to 1.94 MB.

## Numbers: the first round (`nds-perf`)

Host instructions retired (`/usr/bin/time -l`), real BIOS unless noted,
`--rtc 2004-01-01`, the sweep's default input script for homebrew; base =
`worktree-nds-skeleton` 0f2beeea. Shots, WAV and (SoulSilver) the frames
3000/5000/8000 are byte-identical in every row.

| workload | base | nds-perf | change |
|---|---|---|---|
| SoulSilver p12, frames 0-8100 | 415.8 G | 368.9 G | -11.3 % |
| SoulSilver p12, frames 0-8100, HLE BIOS | 407.7 G | 360.6 G | -11.6 % |
| SoulSilver overworld, 600 frames from a frame-7100 state, walking (skips off / on in one build) | 63.2 G | 53.9 G | -15 % |
| fb_both, 600 frames (both CPUs `B .`) | 45.0 G | 3.30 G | 13.6x fewer |
| snd_tone, 600 frames | 45.4 G | 3.48 G | 13.0x fewer |
| trans flag (beam race), 600 frames | 153.3 G | 105.0 G | -31.5 % |
| Our First Time (3D + polling), 600 frames | 93.5 G | 89.8 G | -4.0 % |
| Textured_Cube (libnds 3D example), 600 frames | 7.59 G | 5.70 G | -25 % |
| NitroGrafx (compute loops, never idle) | 92.1 G | 93.8 G | +1.9 % |
| MAXMXDS (scanKeys loop, not provable) | 84.4 G | 85.3 G | +1.2 % |
| dicewars (ARM7 exception loop after quitting) | 44.3 G | 45.1 G | +1.7 % |

The last three are the cost where nothing can be skipped: the store
comparison, the volatile-read bumps and the occasional `loop_edge` call,
plus code-layout noise (two builds of one source in different nimcache
directories differ by up to 0.25 %).

**Checks.** `tests/nds_perf_test.nim` (`nimble test_ndsperf`) runs ROMs
with both speed-ups on and off and compares the state payload every 10
frames, both screens and the sound every frame; it also checks that
skipping happened, steps `run_until` by odd amounts, loads states taken
mid-skip, and rewrites a texture behind a reused frame. Breaking either
rule (calling the timers steady, dropping the `tex_gen` check) fails it.
Beyond that, every ROM in `~/.cache/dingbat-nds/roms` (247: our tests,
the 3D suite, the homebrew and libnds examples, 600 frames, the default
input script) ran on and off: identical state every 30 frames, final
screens, sound and opcode counts in all 247. All twelve DS suites pass;
the save-state layout is unchanged (old states load).

## 3D renderer speed (round 3, `nds-3d-perf`)

The benchmark is SoulSilver's title, frames 1000-3000: Lugia animated in
3D on the bottom screen. HLE BIOS, -d:danger, `ndsrun --frames 3001 --rtc
2004-01-01 --press START@700`. The game draws a new scene every second
frame and the frame between two swaps is reused, so 1000 frames are drawn.
Each one has 674 polygons, mostly 64x64 4-, 16- and 256-colour textures,
repeated and modulated, W-buffered and anti-aliased (DISP3DCNT 0x19). It
draws 233 K dots a frame, 168 K of which pass the depth test. 212 K of the
dots lie in the runs between edges and 21 K are edge dots, and 97 % lie
on spans whose ends' w differ (perspective). The scene was counted with
the `-d:r3dprof` build plus histograms.

### Where the title's host instructions went

The totals are exact. Each was measured by retiring instructions on builds
with one part switched off (rasterising, geometry command execution);
`render.nim` stays as it is otherwise. The split inside the rasteriser
comes from the in-process sampler (SIGPROF, pcs symbolised with inline
frames).

| whole run, frames 0-3001 | base (c0975913) | now |
|---|---|---|
| everything | 148.59 G | 108.31 G (-27.1 %) |
| frames 1000-3000 only | 113.55 G | 78.32 G (-31.0 %) |
| 3D rasteriser (`render_frame_body`) | 75.6 G (51 %) | 39.3 G (36 %) |
| geometry commands (`execute`: matrices, lighting, vertices, clipping, assembly) | 6.9 G | 3.7 G |
| everything else (CPUs, DMA, GX FIFO, 2D, SPU) | 66.1 G | 65.3 G |

| sampled time, share of the whole run | base | now |
|---|---|---|
| per dot: depth test, interpolation, blending, writes | 38.1 % | 25.8 % |
| texture fetch and decode (by format: `texel`) | 7.5 % | 2.2 % |
| span and row setup (edge ends, span steps, AA coverage) | 1.9 % | 3.0 % |
| polygon setup and sort | 3.3 % | 3.1 % |
| clear, page tables, AA pass, frame reuse check, line hand-off | 0.8 % | 1.4 % |
| geometry: clipping / assembly / commands | 1.3 / 0.8 / 1.4 % | 0.7 / 1.2 / 2.0 % |
| GX FIFO, command timing, the FIFO IRQ | 4.7 % | 5.5 % |
| 2D engines (engine A composites the 3D layer on every line) | 7.4 % | 10.0 % |

The title uses no edge marking or fog. The AA pass, line budget and clear
together came to 0.5 G before. The line hand-off is one 1 KB copy per
line plus one 192 KB copy per drawn frame (`draw_lines`). The 2D side
did not change; its share grew because the rest shrank.

### What changed, in order, with each change's delta

These are host instructions on the title (frames 0-3001). After every
change the shots at 1500/2000/3000 are unchanged, HLE (be57c2d1 / 584005dd /
1fff9866) and real BIOS (263b5ac4 / 839dafa9 / 115a4dc6).

| commit | change | title |
|---|---|---|
| f0f2971d | span invariants (length, equal w, the depth step's 2^18 / len, a division per dot) set up once per span | -1.03 G |
| cf53ae81 | decoded texel cache (below) | -8.05 G |
| 8d25c0f5 | span runs by dot loops specialised per polygon and span (below), helpers pinned inline | -13.95 G |
| 5134ed85 | the span loop keeps the context, ends and stepper in locals; `wrap_coord`'s clamp spelt out (system.clamp was a call per coordinate) | -4.23 G |
| ad269de5 | polygons inside all six planes skip the six clipping passes | -2.68 G |
| ca6fc28e | perspective span runs do not step the linear factor | -4.37 G |
| 2834965f | edge dots by the specialised instances too | -0.41 G |
| 9310ff29 | a FIFO write raises the level IRQ without a second catch-up | -0.69 G |
| b2cc74d4 | frame reuse moves the drawn lists' buffers instead of copying them | -0.41 G |
| 33c01d92 | span runs in range skip the colour and depth clamps | -2.76 G |
| 4e0cdcc8 | texture flip by a per-polygon mask | -0.75 G |
| f110533c | a dot's depth, IDs, flags, coverage and layer behind in one 16-byte record | -0.93 G |

(8d25c0f5's commit message says -9.9 G. The three measured steps it
combines, run one at a time, give -4.12, -7.36 and -2.47 G.)

**Decoded texels (`tex_cached`, `tex_at`).** A texel depends only on these:

- TEXIMAGE_PARAM's address, size, format and colour-0 bit;
- PLTT_BASE, for the paletted formats;
- (u, v);
- the texture and palette slots' contents, which change only with
  `vram.tex_gen` (the invariant 3D frame reuse already rests on).

Each texture therefore keeps a buffer of its texels in pixel format. The
old decoder (`texel_uv`) fills each texel the first time a dot reads it,
and the buffer is kept while `tex_gen` stands. A fresh texel holds
NOT_DECODED (0xFFFFFFFF); a decoded one never has bit 31 set. The buffers
live in a pool of 1 M texels (4 MB), which starts over when it is full or
`tex_gen` moves; a texture of 512 K texels or more is decoded per dot. The
cache is outside the save state, and a load remaps VRAM (which bumps
`tex_gen`). In SoulSilver `tex_gen` moved twice in the title's 1000
drawn frames, and 15 times in the 400 frames drawn in p12's frames
0-8100.

**Specialised span loops (`fill`, `fill_k`, `plot_k`, `by_kind`).** The
per-dot code is one generic body, `plot_k[K]`, where K is a set of facts
known at compile time:

- textured or not;
- equal or unequal w at the span's ends;
- anti-aliasing on or off;
- W- or Z-buffer;
- K_SIMPLE: not a wire-frame, not under the edge-marking rule,
  modulation, and the "less" depth test;
- K_INR, for `fill` only: the span is in range.

A fact the instance knows becomes a constant the C compiler folds;
otherwise the body reads the polygon context as before. `by_kind` tests
the real flags once per span and picks the instance whose facts hold.
Anything else uses K = 0, the old code unchanged, so the result is the
same by construction. The runs between edges go through `fill`, one call
per run with the context in locals. Edge dots go through `plot`, one
dispatch per dot. The swapped-row loop visits the same dots: its filled
ends as edge dots, the rest as one run.

- **Perspective runs.** The 38-bit linear factor (SpanStep) serves only
  equal-w spans. It stays exact whenever it is read, because it is either
  stepped from a consistent (n, f, remainder) or recomputed by division,
  so the perspective instances leave it alone.
- **In range (K_INR).** A run's dots lie on the span (0 <= n < len), so
  the interpolation factors are in [0, 1) and every colour, Z and w lies
  between the two ends' values. `span_step` checks that both ends are in
  range: colours in 0..511, Z in 0..0xFFFFFF, w in 1..0xFFFFFF (which also
  keeps the perspective denominator positive). When they are, the per-dot
  clamps cannot change anything and are left out. Edge dots, which can lie
  off the span in crossed rows, keep the clamps.

Divided by the title's dots, the rasteriser costs about 160 host
instructions a dot, down from about 310. In the disassembly, a dot of a run
that passes the depth test takes about 100 instructions on its main path:
one division (the perspective factor; there were two), the attribute and
texel arithmetic, blending, and 8 stores into one record.

**Clipping.** A polygon inside all six planes leaves every
Sutherland-Hodgman pass unchanged: each vertex is kept and none is added.
`clip_polygon` therefore returns such a polygon at once. Before, it copied
two 16-vertex arrays per plane.

### Other workloads (host instructions, -d:danger)

| workload | base | now | change |
|---|---|---|---|
| SoulSilver title, 3001 frames, HLE | 148.59 G | 108.31 G | -27.1 % |
| SoulSilver title, 3001 frames, real BIOS | 149.82 G | 109.38 G | -27.0 % |
| SoulSilver p12, frames 0-8100, real BIOS | 179.25 G | 169.66 G | -5.4 % |
| SoulSilver p12, frames 0-8100, HLE BIOS | 175.42 G | 165.93 G | -5.4 % |
| scene_sd4k (fogged tunnel) | 75.63 G | 57.03 G | -24.6 % |
| Env_Mapping (nds-examples) | 10.98 G | 7.39 G | -32.7 % |
| Toon_Shading | 3.97 G | 3.29 G | -17.2 % |
| volumetricshadow (shadow volumes) | 31.54 G | 26.27 G | -16.7 % |
| scene_our_first_time | 52.14 G | 46.50 G | -10.8 % |
| Picking | 6.68 G | 6.11 G | -8.5 % |
| portalds | 45.04 G | 41.32 G | -8.3 % |
| blimpchicken | 28.07 G | 26.01 G | -7.3 % |
| 3D_Both_Screens | 10.52 G | 9.78 G | -7.0 % |
| tetris3d | 4.79 G | 4.48 G | -6.4 % |
| wolveslayer | 18.62 G | 17.46 G | -6.3 % |
| counterstrike | 10.19 G | 9.80 G | -3.8 % |
| dscraft | 5.50 G | 5.35 G | -2.7 % |
| NitroGrafx, Textured_Cube, Paletted_Cube, lesson08 | | | 0 to -0.4 % (CPU-bound) |

Homebrew numbers are 600 frames with the sweep's default input; the
libnds examples get `A@200` because they power off on START. Their screens
match the base in every row. In p12 most overworld frames are reused (400
drawn in 8100), so its 3D share was small to begin with.

**The web build.** The DS wasm core runs in Node (`ENVIRONMENT=node`,
emcc -O3), and node's retired instructions for the title's frames
1000-3000 went from 171.17 G to 131.30 G (-23.3 %). These figures are
frames 0-3000 minus frames 0-1000, and repeat to 0.1 %. The wasm module
grew from 780 KB to 825 KB. Wall-clock fps could not be measured this
round: the machine ran at load average 55-100 under other agents' jobs,
and the same binary measured 18-38 fps from run to run. The instruction
ratios predict about 420 fps native (from ~290) and about 270 fps wasm
(from ~210) for frames 1000-3000. Those figures assume host time scales
with instructions, which the rasteriser's divisions and mispredicted
depth tests make optimistic.

**Checks.** These outputs are unchanged at every commit, or at the
batches of commits marked in the round's log:

- `nds_3d_test`: 68 ROM hashes, unit scenes and render timing;
- polyrastertest 77/77 (`nds_testroms_test`);
- the hardware line captures, 198,404 of 198,404;
- `nds_perf_test`: reuse on/off byte-identical;
- the title's shots, HLE and real BIOS;
- p12 e4b66d68 / 6cf51b7e / ae4536a1, real BIOS and HLE;
- the continue-from-save check, hle 6b9b805f / bios 228bc64d.

All 14 suites pass on the final commit. Every ROM in
`~/.cache/dingbat-nds/roms` ran on the base and the final build: 505 ROMs,
600 frames, the default input, real BIOS. In all 505 the whole-state hashes
every 30 frames, the final screen, two shots, the sound and the opcode
counts are identical. Host instructions over the 505 fell from 3968.9 G to
3872.4 G (-2.4 %); most of those ROMs draw no 3D.

### Tried and dropped

- **Coverage step per edge.** `aa_cov`'s division moved into `make_edge`
  cost +0.1 G: the larger Edge is copied per row.
- **`below` written only for partly covered or edge dots.** This is
  provably exact, because `below` is read only there and only an opaque
  write makes a dot one. It saved 0.2 G, but it adds an invariant that
  every future reader of `below` would have to know.

### What is left

- **The dot path** is about 25 % of the title's time. The rest of its
  wall-clock cost is the perspective division per dot (an exact 8-bit
  factor) and the depth-test branch, which fails 28 % of the time,
  unpredictably. Going further needs several dots at once (SIMD), not
  fewer instructions per dot.
- **Edge dots** are 9 % of the dots and about a quarter of the
  rasteriser's time. Each is a call and a dispatch, plus `aa_cov` with
  its divisions. A row-at-a-time loop with the coverage stepped (h grows
  by exactly `inc` per dot on x-major runs) would remove the calls.
- **Row setup.** Each row runs two `edge_end` (one or two divisions each)
  and `span_step` (three divisions): about 450 host instructions per row,
  7.3 K rows a frame.
- **Geometry** is 3.7 G: matrix products on every matrix command,
  lighting per NORMAL, and three divisions per vertex in `to_screen`. The
  GX FIFO bookkeeping (`push`, `catch_up`, deque operations) runs per
  parameter word.
- **The 2D side of the scene** (engine2d.nim, outside this round). Engine
  A composites the 3D line under its BGs on every line. The 2D line reuse
  compares the 1 KB 3D line by value, and a line whose 3D part changed is
  composited again.
- **A finding for the 3D owner.** This is not a speed issue and was not
  changed here. render.nim's perspective factor `pfac` divides by
  n·w0 + (d − n)·w1, which is 0 at an end whose vertex has w = 0 (the
  only point inside the view volume with w = 0 is the eye itself, clip
  (0, 0, 0, 0)). The division is then 0/0. arm64 gives 0, wasm traps
  (`i64.div_s`), and an x86 build takes SIGFPE. `edge_end` has the same
  form at n = d. K_INR's range check keeps the specialised loops away
  from w < 1, but the generic path still divides.

## Left for later

- **Passable events.** Every event ends every proof; an SPU tick without
  capture, a timer overflow without an IRQ or an H-blank without DMA
  changes nothing a VCOUNT poll reads. Classing events (as the GBA core's
  waitloop pass-through does) would save the two or three passes of
  re-proof per event, which is most of what a `B .` spinner still costs.
- **Timer polls.** A loop waiting for a timer counter could be skipped to
  the pass where the value crosses; not seen in a hot loop yet.
- **One CPU halted, the other working.** Slices stay 64 cycles so a write
  that wakes the halted CPU lands on the same slice boundary; ending the
  slice at the next 64-cycle grid point after such a write would allow
  longer slices; the slice loop is now 3.6 % of SoulSilver.
- **The ARM9 data path** (6.5 % of SoulSilver, 13 % of its overworld):
  the TCM tests go through two pointers (cp15, dma9) on every access and
  main RAM through the D-cache tag check and `dc_apart`; a per-page "data
  TLB" (host pointer, region, cost class), turned off where the fetch
  fast path is, would roughly halve it. DTCM alone is too little (21 M of
  71 M ARM9 accesses, ~5 instructions each).
- **2D compositing** is most of the 2D cost left (Tales of Dagur, lines
  whose scroll changes every frame): per-layer line reuse would save the
  BG/OBJ passes but not the per-pixel layer search, which is the bigger
  part; vectorising it is the lever there.
- **Conditions by table** (a 16 x 16-bit table instead of the switch in
  `cond_passed`): same instruction count, fewer mispredicted branches;
  not measurable in instructions, so not kept.
- **3D per line.** When rendering follows mid-frame register writes
  (TODO in render.nim), the reuse key must include them. What is left of
  the 3D engine's cost is listed at the end of "3D renderer speed".
