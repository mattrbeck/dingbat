# DS performance: the cheap, exact wins, then caching and the interpreter

Three rounds: low-hanging fruit (branch `nds-perf`: idle loops, 3D frame
reuse), a measured one on caching and the interpreter (branch
`nds-cache-perf`: where the host instructions go, 2D line reuse, and the
CPU's per-opcode overhead), and one on what that left outside the 3D
renderer (branch `nds-perf3`: the ARM9 data path, branch fetches, 2D
compositing, slices and events; "Round 3" below). One rule over everything: **a speed-up may not
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
| a DMA's hold on the bus (`dma_stall`: the CPU's clock moves), a state load | an ARM9 cache line fill, any CP15 write |
| an instruction-cache line kept before memory under it changes (docs/nds/cache.md) | an unmapped access (both CPUs: the count is state) |

Events and frontend calls (`run_until`: keys, touch, the lid) bump an
*event epoch* of their own, which only a loop that read a device since its
epoch was taken must see ("Passable events" below).

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
proven loop with its epoch untouched and no interrupt it will take, or
halted with no interrupt to wake it -- interleaving changes nothing, and
the slice runs straight to the event (as it already did with both halted;
with one halted and the other running, see "Long slices"). A store or a
volatile read ends the proof, and an event does for a loop that read a
device; it is re-made in two or three passes.

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
a bounds defect would surface a few instructions late. `savestate.nim`
(state_error) and `read_file_bytes`/`load_nds` (IOError) stay outside.

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
address, then read the opcode through a host pointer (a jump inside the
page takes a short path too since round 3: "Jumps inside the fetch
page"). An ARM9 fetch that
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

## Round 3 (`nds-perf3`): the data path, branch fetches, compositing, slices and events

Same rule, same method, one change of yardstick: `ndsrun --perf-from F`
now also prints the host instructions the timed frames took (macOS
`proc_pid_rusage`), so the numbers below leave out loading the ROM and the
state, which `/usr/bin/time` counts too (2.3 G for SoulSilver) and which
does not repeat to better than 0.5 %; the emulated part repeats to 0.02 %.
Below about 0.5 % two builds of nearly the same source still differ by
code layout (inlining, register allocation in the run loops): a change
was kept for what it does on the workloads together, not for a 0.3 % on
one. `ndsrun --screen-hash N` (a CRC of both screens every N frames) joins
`--state-hash` for changes to what is drawn, which the state leaves out.

### ARM9 data TLB (bus9.nim `dtlb_*`, `read32` .. `write32`)

What the general path (`read9`/`write9`: the ITCM and DTCM windows through
`cp15` and `dma9`, the protection unit, `charge9`, the region decode)
decides for an access depends, for most of them, on the page alone -- the
TCM windows, the load modes, the data cache's enable and the page's
cachability, all CP15 state -- and for main RAM on the line. In
SoulSilver's overworld (600 frames) the ARM9 made 30 M loads and 20 M
stores: DTCM 8.2 M / 7.6 M, main RAM through the cache 16.6 M / 9.1 M,
I/O 3.8 M / 2.9 M, ITCM 1.1 M loads. So each direction has a 256-entry
direct-mapped TLB (page -> kind, host pointer), filled by the general path
and read by the inlined `read8`..`write32` first:

| kind | load | store |
|---|---|---|
| DTCM | free, read the page | free, store (a change bumps the ARM9's epoch) |
| main RAM through the cache | a tag hit (`last`, else the 4-way compare, which makes it `last` as the lookup would) is free and reads the CPU's copy: `dc_hit` is then true, so `dc_apart` does not matter | a tag hit on a *dirty* line: write9's plain store, free |
| main RAM past the cache | in a page with nothing apart: the uncached charge, memory as it is | on a line no cache holds (`slot_of` = 0): the uncached or write-buffered charge, a plain store |

Everything else -- misses, fills, a clean line's first store, I/O, VRAM --
goes the general way, which does its own lookup, fill and charge. The
DMA gets its own bus type (`Dma9Bus`), so its accesses never see the TLB
(the TCMs are invisible to it). Entries follow CP15 state only: a CP15
write that moves a TCM window or changes the TCM enables or load modes
drops them all, one that changes cachability or the data cache's enable
drops those it decides (cached main RAM, uncached pages a region makes
cachable); C7 line operations need nothing, since line state is checked
at every access; a main RAM page going apart drops its uncached load
entry (`page_apart_now`; every mirror of a page has the same index); a
state load and WRAMCNT drop everything. The TLB remembers what it filled
since the last drop, so a drop clears only those entries: the BIOS in
"The Strongest Demo" toggles the protection unit about 9400 times a frame,
and a full clear there cost 24 %.

After it, 23.6 M of the overworld's 29.7 M loads and 15.7 M of its 19.9 M
stores take the short path (MAXMXDS: 50.9 M of 55.3 M loads; its 16.8 M
VRAM stores, a frame buffer drawn by the CPU, do not). The binary grows by
the inlined checks in every load and store handler (below).
`nds_testroms_test` "ARM9 data TLB" switches the data cache off and on,
makes a page uncachable, dirties clean lines through the TLB, invalidates a
line under it, reads the uncached mirror of a line kept apart and stores
through it to a cached line, turns the cache on over an uncached entry,
moves DTCM over main RAM and away, uses load mode, lets DMA read behind
DTCM and loads states with DTCM elsewhere; removing any drop rule, the
hit, dirty or `slot_of` checks, the page-apart drop, the drop log's kinds
or the DMA bus type fails it.

### Jumps inside the fetch page (bus9.nim `fetch_jump9`, bus7.nim `fetch_jump7`)

The sequential fetch fast paths (above) held a line (ARM9) or page (ARM7);
any branch target still took the whole fetch path. A jump inside the page
now takes a short one:

- **ARM9**: inside the 4 KB page of `fline9`, in the page the protection
  unit allowed last for this privilege (`pu_ok[0]`, keyed by page and
  User mode), to the same line (ITCM, or the instruction cache's `last`),
  to ITCM, or to a line the instruction cache hits (made `last`; a miss
  changes nothing and goes the long way) whose bytes are memory's (no kept
  copy, nothing apart: as `fetch_next9`). fetch_cost9 there only calls the
  loop head, charges the refill and does that lookup; the page is one host
  block (ITCM, main RAM, the BIOS), so `fptr9` moves by lines.
- **ARM7**: inside `fpage7`, the page's fixed nonsequential fetch plus the
  refill's second fetch (`fjump7`, set with `fseq7`), then memory.

A line `fetch_line9` set up is ITCM or `last` at that moment except in
one shape: after the fast path is turned off, the second halfword of a
Thumb word shares the word's fetch (no lookup) and sets the line up again.
The resets are a CP15 write (an MCR: ARM code, whose next fetch is a new
word and looks the line up), WRAMCNT (the line stays cached and `last`),
a page going apart (the line is still cached; `line_clean9` decides) and a
state load (the tags are in the state), so the line is cached and `last`
whenever a jump can look at it. `nds_testroms_test` "fetch jumps match the
long way" runs 20000 random jumps and sequential runs over ITCM, the BIOS,
main RAM (lines cached, kept and apart, written behind by the ARM7, lines
dropped by C7 from ARM code) and ARM7 WRAM, ARM and Thumb, on two
machines, one taking the long way every time, and compares every opcode,
charge and tracker; and a User-mode jump into privileged code must abort.
Dropping the privilege check, the hit, the memory's-bytes condition or the
ARM7's jump cost fails it.

### Painted compositing (engine2d.nim `composite`)

The per-pixel search for the top two layers became one pass per layer,
lowest priority first: per priority level its BGs (higher numbers first),
then that priority's OBJ pixels (`obj_prios` skips empty levels). Each
pixel ends holding what the search in priority order finds first and,
where an effect can need it, what it finds next -- the layer that was on
top when the last one was laid. The passes are branch-free selects (masks,
not `if`) over 256 pixels into local arrays, which the C compiler
vectorises (the first try, with `if` and the engine's own `gfx` as the
target, was not: clang could not if-convert it nor prove the arrays
apart). The colour effect then runs the old per-pixel rules on the two
layers; lines without effects need only the colour, brighten/darken only
the top layer's number. The old search stays as `composite_search`, and
`nds_2d_test` draws 400 random scenes (VRAM, palettes, OAM, 3D lines,
modes, priorities, windows, effects, mosaic) both ways and compares all
153 600 lines; painting OBJs at the wrong level, BGs in the wrong order or
dropping the second layer fails it. Every frame's screens of 69 2D-heavy
ROMs (`--screen-hash 1`) and, with reuse off, of all 504 ROMs in the cache
were compared with the build before: identical.

`gpu.nim render_line` routed each engine's finished line to the screens a
pixel at a time through refs the compiler could not prove apart (2 % of
SoulSilver's time); it is two 512-byte copies now.

### Long slices (nds.nim `run_long`, `slice_cut`)

SoulSilver runs one CPU alone a lot: in frames 0-6000, 11.6 M 64-cycle
steps had the ARM9 halted (the ARM7 sequencing sound), 8.7 M the ARM7
(the ARM9 working), against 5.2 M quiet slices and 2.2 M with both
running -- 3400 steps a frame, each a slice-loop pass and two `run` calls.
With one CPU halted and no interrupt to wake it, the other now runs
straight to the next event. The step loop would have acted, at the end of
the step in which it happened, on three things the running CPU can do:
make the halted one's interrupt arrive, book or move an event, put the
ARM7 to sleep (or the machine off). After any of them its run ends at the
end of that step -- the next point on the 64-cycle grid from where the
long slice began, after the access (`sched.now`) -- and the halted CPU is
left where the steps would have left it: the step loop ran the ARM9 first,
so an ARM7 woken by the ARM9 wakes at the start of that step, an ARM9
woken by the ARM7 at its end. `slice_cut` is looked at with the CPU's
`attn` (every such action is an I/O access, a SWI or a CP15 write) and
once more after the run, for an access whose own cost carried the clock
past the end (a full geometry FIFO, a DMA: SoulSilver's frame 1126 found
that one). Nothing else happens between steps and a CPU's own execution
does not depend on where its run calls end, so the result is the steps'.
Off with `DINGBAT_NDS_NO_SKIP=1`. `nds_perf_test` "long slices" runs
programs that wake the other CPU (both ways), book a timer (both CPUs),
go to sleep, and stall in a DMA that books a timer (both CPUs), after 1-40
loop passes so the access falls at every point of a step, with long slices
on and off; removing any cut rule, either check after the run or the woken
ARM7's step fails it.

### Passable events (arm/cpu.nim `loop_edge`, `ev_epoch`)

Every event and `run_until` call ended every idle-loop proof, so a
spinning CPU re-proved its loop after each of the ~1100 events a frame
(two or three passes, in 64-cycle steps meanwhile). Events and frontend
calls change devices -- registers, VRAM through display capture, the 3D
engine -- and memory only through stores, which bump the epoch
themselves; so they now bump their own epoch (`ev_epoch`), which only a
loop that read a device since its epoch was taken must see (`dev9`/`dev7`:
I/O, VRAM, palette, OAM and GBA-slot reads, and code fetched from outside
RAM; set by the bus). As in the GBA core's waitloop pass-through, a loop
polling RAM -- a flag the other CPU or an interrupt handler sets, `B .` --
stays proven across events. Three things an event does besides: a DMA's
hold on the bus moves the CPU's clock (`dma_stall` bumps the epoch); a
state load replaces memory (it bumps it too); and an interrupt it makes
takeable is taken at the next `run`, which ends the proof (an exception),
but until then the CPU is not quiet: its handler is work, which the long
run of a quiet slice would let book events late (SoulSilver's frame 1002:
its GX FIFO handler). SoulSilver's waits end by interrupt, so it gains
nothing; spinners do. `nds_perf_test` "passable events" runs loops
polling VCOUNT on either CPU (each noting a timer when it sees the line),
a RAM loop held by H-blank DMA, a RAM loop whose timer handler wakes the
halted ARM7 (which notes the time), and a state loaded over a proven loop;
dropping either CPU's device flag, the DMA or load bump, or the interrupt
check of `quiet` fails them.

### Numbers: round 3

Host instructions of the emulated frames (`--perf-from`), -d:danger,
`--rtc 2004-01-01`, real BIOS unless noted; homebrew 600 frames with the
sweep's default input script; each column adds one commit. Every row's
screens, sound, opcode counts and whole-state hashes are the base's.

| workload | base | TLB | +uncached | painted 2D | long slices | line copy | events | jumps | change |
|---|---|---|---|---|---|---|---|---|---|
| SoulSilver title, 600 frames from 1000 | 14.97 | 14.70 | 14.74 | 14.29 | 14.06 | 13.79 | 13.87 | 13.28 | -11.3 % |
| SoulSilver intro, 600 frames from 3000 | 7.04 | 6.88 | 6.90 | 6.79 | 6.58 | 6.30 | 6.34 | 5.95 | -15.5 % |
| SoulSilver overworld, 600 frames from 7100, walking | 24.82 | 22.83 | 23.00 | 22.87 | 22.51 | 22.24 | 22.47 | 21.09 | -15.0 % |
| NitroGrafx | 57.33 | 57.43 | 57.49 | 56.11 | 54.49 | 54.22 | 54.90 | 48.17 | -16.0 % |
| trans flag (beam race) | 38.46 | 38.52 | 38.52 | 38.56 | 37.85 | 37.59 | 38.23 | 37.20 | -3.3 % |
| MAXMXDS | 45.28 | 42.48 | 42.13 | 41.78 | 40.49 | 40.23 | 40.44 | 37.03 | -18.2 % |
| Cave Story | 23.90 | 22.66 | 22.71 | 22.62 | 22.22 | 21.95 | 22.03 | 20.92 | -12.5 % |
| Tales of Dagur | 14.90 | 14.70 | 14.71 | 12.39 | 12.35 | 12.08 | 12.12 | 11.95 | -19.8 % |
| Space Impakto | 14.48 | 14.15 | 14.15 | 13.71 | 13.46 | 13.20 | 13.28 | 12.83 | -11.4 % |
| nesDS | 5.38 | 5.37 | 5.39 | 5.39 | 5.36 | 5.09 | 5.13 | 4.89 | -9.1 % |
| Triple Triad | 9.48 | 9.49 | 9.49 | 9.07 | 8.99 | 8.72 | 8.74 | 8.41 | -11.2 % |
| fb_both (both CPUs `B .`) | 3.26 | 3.26 | 3.26 | 3.27 | 3.28 | 3.01 | 1.99 | 1.93 | -40.8 % |
| snd_tone (both CPUs spinning, sound) | 3.33 | 3.33 | 3.34 | 3.34 | 3.35 | 3.08 | 2.05 | 2.00 | -39.8 % |

| SoulSilver p12, frames 0-8100 | base | now | change |
|---|---|---|---|
| real BIOS (shots e4b66d68 / 6cf51b7e / ae4536a1) | 180.96 G | 155.76 G | -13.9 % |
| HLE BIOS | 177.15 G | 152.29 G | -14.0 % |
| real BIOS, `/usr/bin/time` (with loading) | 183.0 G | 157.9 G | -13.7 % |
| real BIOS, skipping off (`DINGBAT_NDS_NO_SKIP=1`), with loading | 293.0 G | 250.9 G | -14.4 % |

The uncached kinds and the drop log were for "The Strongest Demo" (the
first TLB cost it 24 %: 21.55 -> 26.76 G; now 18.71 G, -13 %) and the
uncached mirror homebrew uses; "events" is for spinners and costs SoulSilver
0.1-0.2 % (head with and without it: title 13.26 / 13.28 G, overworld
21.04 / 21.09 G), within the layout noise above. Over the 152 ROMs under
`homebrew*/` (600 frames, `/usr/bin/time`, loading included) the host
instructions went from 1503.0 G to 1334.3 G (-11.2 %; ds81 -24.9 %,
MAXMXDS -18.2 %, nitrotracker -16.2 %, NitroGrafx -15.9 %, bitbox
-15.3 %).

The DS web module (`web/nds/nds.wasm`, emcc -O3) grows from 780 648 to
830 997 bytes (gzip 206 159 to 217 032), ndsrun from 1.93 to 2.00 MB:
mostly the TLB checks inlined into every load and store handler.

**Checks.** All 14 DS suites pass. SoulSilver p12 (real BIOS) gives the
base's shots and whole-state hashes every 100 frames with skipping on and
off, and the HLE run the base's shots; Continue from the New Bark save
(c3) gives hle 6b9b805f, bios 228bc64d. Every commit ran the homebrew set
(the 152 ROMs under `homebrew*/`) with skipping on and off: whole-state
hashes every 30 frames, final screen, three shots, sound and opcode
counts equal on/off and to the base. New invalidation rules each have a
test that fails when the rule is removed (above; the mutation runs are in
the round's scratch directory).

### Where the host instructions go (round 3)

Sampled time of SoulSilver p12 frames 0-6000 (real BIOS), leaving out the
ROM loading (12 % of the samples: page faults of copying a 256 MB ROM
count as time, not as instructions):

| component | round 2 | now |
|---|---|---|
| ARM9 (handlers with decode, fetch, data, loop) | 33 % | 33 % |
| ARM7 | 30 % | 33 % |
| 3D | 12 % | 16 % |
| SPU (the mixer tick, sample fetch and decode) | 5 % | 7 % |
| 2D | 8 % | 5 % |
| slice loop and events | 3.6 % | 3 % |

The ARM9's share stayed while the whole shrank: its data path and branch
fetches were most of the round. What is left in both CPUs is the run
loop's per-opcode bookkeeping (cur_pc, r15, next_pc, the opcode and cycle
counts, the bus's wait accumulator), LDM/STM (a generic proc with a load
or store per register) and the handlers themselves; the ARM7's share rose
because the rest fell.

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

## Left for later

- **The SPU mixer** (7 % of SoulSilver's time): `step` is one large proc
  called per sample, and `tick` walks all 16 channels three times with
  64-bit pan and volume products. Per-channel constants (format, loop
  points, shifts) could be derived when SOUNDxCNT is written, silent
  channels skipped in the mix, and PCM samples inside the current word
  stepped without the call.
- **The effect pass for alpha, 3D and semi-transparent OBJs** is still
  per pixel with branches (engine A in SoulSilver: BG0 is 3D, so every
  line); with the second layer's number per pixel it could be masks too.
- **CPU stores to VRAM** (MAXMXDS: 16.8 M in 600 frames, a frame buffer
  drawn by the CPU) take the whole write path; a TLB kind for VRAM pages
  (the bank's host pointer, the 1 KB change counts, PU-checked per
  privilege like the fetch jumps) would make them short. ITCM data (1 M
  loads in the overworld) likewise.
- **The run loop's bookkeeping** per opcode (above) and LDM/STM, which
  walk 16 register bits with a full load or store each.
- **Loading.** A 256 MB ROM is read into a string, copied into a seq and
  copied again into the cart: 2.3 G host instructions and, in time, more
  (page faults) before the first frame.
- **Timer polls.** A loop waiting for a timer counter could be skipped to
  the pass where the value crosses; not seen in a hot loop yet.
- **Conditions by table** (a 16 x 16-bit table instead of the switch in
  `cond_passed`): same instruction count, fewer mispredicted branches;
  not measurable in instructions, so not kept.
- **3D per line.** When rendering follows mid-frame register writes
  (TODO in render.nim), the reuse key must include them. The 3D renderer
  (16 % of SoulSilver's time now) is outside these rounds.
