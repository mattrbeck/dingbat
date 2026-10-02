# DS performance: the cheap, exact wins

Scope of this round (branch `nds-perf`): only low-hanging fruit, while
accuracy work goes on. One rule over everything: **a speed-up may not
change any output** -- frames, sound, the whole machine state (save-state
payload), opcode counts, the sweep's statuses. Each speed-up below can be
turned off with `DINGBAT_NDS_NO_SKIP=1`, and `ndsrun --state-hash N` prints
a CRC-32 of the whole state every N frames, so an on/off pair of runs can
be compared byte for byte.

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
`render_frame` keeps copies of the buffers, registers and parameters it
last drew and compares them field by field. For textures no copy is
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
- **Palette and OAM**: the bus counts every change to each engine's half
  (`mem_gen`; a store of the value already there is not a change, so a
  game's per-frame OAM copy costs nothing).
- **VRAM**: `vram.eng_gen[e]` counts every change to a byte of a bank
  engine e reads (the per-page engine mask `weng` is rebuilt with the page
  tables) and every remap. Display capture writes only LCDC banks, which no
  engine reads; the ARM7's banks and the 3D slots are not engine regions.
- **3D line**: compared by value (1 KB).
- Not reused: display capture lines (they need `gfx`), VRAM and
  main-memory display, an engine switched off, the 2D unit tests (`lc_on`
  is set by the machine; they poke memory directly).

A state load remaps VRAM, which bumps `eng_gen`: a loaded machine draws
every line afresh. In SoulSilver 0-6000 (p12) 70 % of engine A's lines and
90 % of engine B's are reused. Engine A's misses are mostly memory changes
elsewhere in the engine's VRAM (65 %: a counter per engine, not per line),
then register changes (15 %) and the 3D line (9 %); see "Left for later".

`tests/nds_perf_test.nim` runs 15 2D ROMs (scrolling, affine and
rotscale BGs, affine and extended-palette sprites, H-blank and mid-frame
windows, bitmaps, 3D under 2D) with reuse on and off, changes palette, OAM,
BG VRAM and the mapping behind reused lines through the bus, and loads a
state over a running machine. Dropping the palette/OAM or the VRAM count
fails it.

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
a bounds defect would surface a few instructions late. `savestate.nim`
(state_error) and `read_file_bytes`/`load_nds` (IOError) stay outside.

## Sequential fetch fast paths (bus9.nim `fetch_line9`, bus7.nim `fetch_page7`)

Most opcode fetches follow the one before. For those, the timing model's
answer is known in advance:

- **ARM9**, inside the 32-byte line of the last fetch, when that fetch was
  an ITCM fetch or an instruction-cache hit or fill (the line is now
  `icache.last`) and the bytes are memory's (ITCM, the BIOS, main RAM with
  nothing apart in its page): no cost, no tag change, no protection check
  (not a branch target, not a page's first word), no loop edge; only
  `last_data9`, `last_pc9` and `last_fetch9` move.
- **ARM7**, inside the 4 KB page of the last fetch, in the BIOS (fetches
  pass BIOSPROT: pc = address), main RAM with nothing apart, or WRAM: the
  fixed sequential cost of that region; `last_data7` and `last_fetch7`
  move.

`fetch32`/`fetch16` test one line or page number and the sequential
address, then read the opcode through a host pointer; everything else goes
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

## Numbers

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
  longer slices, but the slice loop is ~1 % of SoulSilver.
- **The interpreter itself** is the real lever (150-250 host instructions
  per opcode; SoulSilver's profile: the run loop ~25 %, I-cache tag
  lookups ~4 %, 2D compositing ~7 %, rasteriser ~5-20 %): decoded-opcode
  caching, cheaper fetch timing. Not low-hanging.
- **3D per line.** When rendering follows mid-frame register writes
  (TODO in render.nim), the reuse key must include them.
