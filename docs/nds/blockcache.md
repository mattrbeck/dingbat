# DS CPUs: decoded blocks, a block-threaded interpreter, measured

Branch `nds-blockcache` (from main 7dc82b46). The question: DS emulation is
still too expensive, on the web (wasm) and natively; is a cached,
block-threaded interpreter worth reconsidering? docs/nds/jit.md (branch
`nds-jit`) measured an ahead-of-time translator and found decode and
dispatch already cheap, the rest of the per-opcode cost being the exact
timing bookkeeping; its next step was "the timing model decided per block".
This branch builds that step without generating code, so it would run the
same in wasm and in the iOS app, and measures it. The rule stays the one in
docs/nds/perf.md: **a speed-up may not change any output**.

Short answer, measured below:

- Built, exact (whole-state and screen hashes equal with blocks on and off
  on Golden Sun, two SoulSilver stretches and 15 homebrew/test ROMs; a new
  test of self-modifying code on both CPUs), and **not faster anywhere**.
  Against main, blocks on take 8-12 % more host instructions natively and
  4-7 % more cycles (Golden Sun's intro +3.8 % cycles, SoulSilver +5-7 %);
  in V8 and in JavaScriptCore they take 8-12 % more instructions and
  7-12 % more cycles (fps -6 to -11 %).
- Why: a block entry costs about 93 host instructions more than the plain
  run loop spends on its first opcode, and each further opcode in the block
  saves about 17. Break-even is about 6.4 opcodes per block; Golden Sun's
  ARM9 blocks average 4.3 opcodes per entry, SoulSilver's 3.5. And 17 is the
  ceiling per opcode even for endless blocks: of the ~55 host instructions
  of run loop and fetch per opcode (perf.md, round 2) a data access still
  needs most (the clock exact before and after it, the trackers, cur_pc,
  r15, next_pc, the `attn`, abort and jump checks), and every opcode still
  costs a dispatch and an indirect call into its handler. At best, with
  endless blocks, that is about 10 % of Golden Sun's host instructions.
- Recommendation: **drop** it. A block-threaded interpreter cannot beat
  this interpreter by a margin worth its complexity while the timing model
  is exact per access. jit.md's ahead-of-time translation got its 1.28x on
  Golden Sun natively by folding each handler and its bookkeeping into
  straight-line code with registers kept in host registers, which is code
  generation. Without code generation the gain does not appear.

## What was built (`arm/blockcache.nim`, included by `arm/cpu.nim`)

A block is decoded at run time where an opcode jumped, where a block ended,
or where a `run` call starts (a slice may end anywhere): up to 32 opcodes,
through conditional branches and loads and stores, to the first
unconditional jump, or to before the first opcode the run loop must see
(MSR, SWI, coprocessor, undefined, BKPT, LDM^/STM^, anything writing r15
other than a jump). It is an array of {dispatch-table entry, opcode, kind,
two bounds} in a pool, found through a direct-mapped table keyed by pc and
Thumb state. The decoder (`blk_class_arm`, `blk_class_thumb`) mirrors
`arm_dispatch`/`thumb_dispatch` and sorts each opcode as

- **pure** (ALU, multiply, MRS, CLZ, Q ops, SMLAxy, Thumb BL prefix): only
  registers and flags; no bus access, no jump, no exception, never `attn`;
  a cost the decoder can bound (base cycles, the fetch, internal cycles up
  to 6);
- **check**: as pure, but it may jump (branches, ALU or MOV to r15, BX/BLX);
- **memory**: a load or store, which may also jump (LDR pc, LDM/POP {pc}).

Each opcode then runs exactly as the run loop would run it -- the same
handler on the same opcode, the same bus calls in the same order with the
same clock -- and the bookkeeping nothing can see in between is done once:

- **Fetch.** The first opcode goes through `fetch32`/`fetch16` as in
  `exec_one`. When the bus says the rest of the line (ARM9: `fline9`,
  32 bytes) or page (ARM7: `fpage7`, 4 KB) is fetched at no extra cost and
  without effects but the trackers, the next opcodes are read from the
  bus's own pointer and only compared with the decoded ones; the trackers
  (`last_pc9`/`last_fetch9`/`last_data9`, `last_fetch7`/`last_data7`) are
  written once, before anything that reads them. Into the next ARM9 line,
  `blk_next_line` does `fetch_next9`'s effects (an instruction-cache hit or
  ITCM, memory's bytes); otherwise the block ends there. An ARM7 data access
  breaks the sequence (`break_fetch7`), so the opcode after it is fetched
  through the bus again; an ARM9 one only ends the block when it turned the
  line's fast path off.
- **Invalidation.** None. Every opcode is compared with the word the fetch
  reads when it runs, so self-modifying code, overlays, DMA, the other
  CPU's stores and state loads are all seen as a changed word. The block
  ends before a changed opcode (the run loop fetches it as usual), or
  finishes it as `exec_one` when the bus already fetched it, and is dropped
  (decoded again after 64 lookups).
- **Clock.** A pure opcode's cost is the CPU's base cycles, the fixed fetch
  cost and the internal cycles its handler counts in `icycles` as before.
  They are summed in a local and added to `cycles`, with the bus's `wait`,
  only where the clock is read: before a data access (which reads it:
  `overlap9`, `sync9`, I/O), after it and at the block's end. That is
  the run loop's sum in a different order. A bus fetch's cost is taken out
  of `wait` at once, so the wait is empty between opcodes and a data access
  sees the clock of its opcode's start.
- **Slice end.** The run loop runs an opcode only while `cycles < until`.
  After every opcode whose cost the decoder cannot know (the first, every
  data access) the clock is exact. If the pure opcodes up to the next data
  access cannot reach `until` at their bound (`ahead_n`, `ahead_ic`), they
  all run. Otherwise only those that surely start before it run, and the run
  loop takes over from there.
- **The rest.** The opcode count is added when the block ends. cur_pc,
  r15 and next_pc are written before an opcode that reads them and at the
  end. `attn` (I/O, CPSR writes) and aborts end the block after the
  opcode, where the run loop looks at them next. A block that jumps or ends
  with nothing for the run loop to look at goes straight on to the next
  block (chaining: 5.4 blocks per call on Golden Sun).
- **Off switch.** `DINGBAT_NDS_NO_BLOCKS=1` runs the plain interpreter in
  the same binary (`=9` / `=7`: the other CPU's blocks only). The block
  state is not machine state (CPU_SKIP), so the save-state layout is
  unchanged. On the branch the blocks are on by default, so the DS suites
  run with them (all pass).

Bus side (`bus9.nim`, `bus7.nim`): `blk_peek` (the opcode for decoding,
nothing changed), `blk_fast_ok`, `blk_ptr`, `blk_mask`, `blk_seq_cost`,
`blk_bound`, `blk_commit`, `blk_next_line`, `blk_after_data`, `blk_breaks`,
`blk_lines`: 90 lines restating, for the block runner, what the fetch fast
paths already know.

## Exactness

- **Games.** Golden Sun: Dark Dawn intro pages 3001-3600, SoulSilver
  7101-7700 (the walk downstairs) and 10001-10600 (New Bark Town), from
  states (below): whole-state CRC and both screens' CRC every 25 frames, 48
  hashes plus the final opcode counts: identical with blocks on and off,
  natively and in wasm under V8 and JavaScriptCore (the frame-3600, -7200
  and -10200 state hashes are the same in all three).
- **Homebrew and test ROMs.** The 15 of jit.md (NitroGrafx, MAXMXDS, Cave
  Story, Tales of Dagur, Space Impakto, nesDS, Triple Triad, trans flag,
  The Strongest Demo, GameYob, ds81, dsniccc, armwrestler, arm7wrestler,
  rockwrestler; 600 frames, the sweep's input script, state and screens
  every 30 frames): identical with blocks on, ARM9-only and ARM7-only.
- **`tests/nds_blockcache_test.nim`** (`nimble test_ndsblockcache`). Two
  machines run the same programs (`tests/nds/src/blockcache/*.s`), one with
  blocks and one without, and must have equal states after every frame. The
  programs rewrite their own next opcode into another kind of opcode (an ADD
  into a load). The ARM7 also rewrites one of the ARM9's opcodes. Both run
  Thumb and ARM, conditional loads, operand-dependent multiplies and
  register shifts, and read a timer after "memory, pure, memory" sequences.
  Scenarios: the ARM9 in ITCM with the ARM7 in its WRAM; the ARM9 in main
  RAM through the instruction cache with the ARM7 in main RAM; and a state
  of the plain machine loaded over the one running blocks. Removing any of
  these pieces makes it fail: the word check, the slice-end check, its
  internal-cycle bound (two places), the stop inside a block, the clock
  before a data access, the trackers before it, the ARM7's fetch after a
  data access, and the bus-fetch cost taken out of `wait`. Not covered by a
  failing test: the ARM9's line re-check after a data access and the
  page-boundary condition of `blk_next_line`. Both are defence in depth (the
  word check catches the cases tried), and both need code that turns a line
  off under itself or crosses a page in a protection region.
- **What it caught.** Two real bugs, both in the ARM7's fetch after a data
  access, and both invisible on the games until the second was. The block
  first did that fetch eagerly, so a changed next opcode was fetched twice.
  Then its cost sat in `wait` and the next data access saw it in the clock;
  I/O reads saw the wrong time, and every game diverged. The first version
  of the test missed the second bug, because its programs read nothing
  time-dependent. That is the risk of this design in one example: each
  shortcut restates a timing rule of the bus in a second place.
- The DS suites (cpu, savestate, testroms, perf, compat, boot, hle_bios,
  cheats) pass with blocks on.

## Numbers

Apple-silicon Mac, shared with other agents' work, so each figure is the
minimum of several runs, interleaved, with the 1-minute load average while
they ran. Host instructions are exact per binary natively (0.02 %); cycles
and fps move with load. The same 600-frame stretches as jit.md, from states
saved by the base build (jit.md's states were not kept; "Method").

**Native** (`ndsrun`, -d:danger, real BIOS; 4 runs each, load 3.4-4.2;
"off" is this branch with `DINGBAT_NDS_NO_BLOCKS=1`):

| | host instructions main / off / on | host cycles main / off / on | fps main / off / on |
|---|---|---|---|
| Golden Sun intro 3001-3600 | 65.22 / 66.62 / 70.31 G (on +7.8 %) | 12.81 / 13.95 / 13.30 G (on +3.8 %) | 152.3 / 137.8 / 144.9 |
| SoulSilver 7101-7700 | 20.10 / 20.52 / 22.49 G (+11.9 %) | 4.40 / 4.63 / 4.70 G (+6.8 %) | 441.9 / 423.8 / 407.0 |
| SoulSilver New Bark 10001-10600 | 35.26 / 35.78 / 38.18 G (+8.3 %) | 7.83 / 8.07 / 8.24 G (+5.2 %) | 244.4 / 239.6 / 234.4 |

An earlier round at load 11-13 gave the same instruction counts and the
same order of cycles (Golden Sun 13.86 / 14.70 / 13.94 G). On Golden Sun
the blocks beat the plain interpreter of the same binary by 4.7 % in cycles.
But that binary's plain interpreter is itself 9 % slower than main's: the
run loop now inlines `exec_one` twice, behind the `blk_on` test. A
production version would need two run loops chosen per call to keep the
off path free.

**Web** (the same core as wasm: emcc -O3, -d:danger, emmalloc, as the web
build; `tools/ndswasm`): host instructions and cycles of the engine process
over the timed frames, from `proc_pid_rusage` read at the frames' edges.
V8 is node 24. JavaScriptCore is Playwright's WebKit 26.5 build, headless
and muted, with the WebContent process that runs the page measured. 3 runs
each, interleaved (main is main's core built the same way), load 2.9-4.7:

| | host instructions main / off / on | host cycles main / off / on | fps main / off / on |
|---|---|---|---|
| **V8** Golden Sun 3001-3600 | 114.66 / 125.61 / 128.43 G (on +12.0 %) | 18.83 / 20.14 / 20.36 G (+8.1 %) | 108.8 / 100.8 / 100.6 |
| **V8** SoulSilver 7101-7700 | 38.06 / 39.32 / 41.60 G (+9.3 %) | 7.30 / 7.45 / 7.78 G (+6.5 %) | 292.4 / 288.4 / 276.0 |
| **V8** SoulSilver 10001-10600 | 61.25 / 64.53 / 67.26 G (+9.8 %) | 12.00 / 12.35 / 12.93 G (+7.7 %) | 164.2 / 160.3 / 153.3 |
| **JSC** Golden Sun 3001-3600 | 100.45 / 102.39 / 109.32 G (+8.8 %) | 16.81 / 17.12 / 18.13 G (+7.9 %) | 129.1 / 127.9 / 120.9 |
| **JSC** SoulSilver 7101-7700 | 34.44 / 35.32 / 38.21 G (+10.9 %) | 7.34 / 7.59 / 8.18 G (+11.5 %) | 346.2 / 342.7 / 307.7 |
| **JSC** SoulSilver 10001-10600 | 56.11 / 57.10 / 60.45 G (+7.7 %) | 11.68 / 11.97 / 12.61 G (+8.0 %) | 186.5 / 184.2 / 174.3 |

Blocks are slower in both engines, by about as much as natively, or a
little more. jit.md's AOT translator lost in V8 because V8 compiled its
large functions badly; the block runner's code is small, so that is not
the cause here. The cause is the same per-entry cost as natively. In V8
the compiled-in switch alone costs main 3-10 % (the larger run loop), and
blocks on add 2-4 % to that; in JavaScriptCore the switch costs 1-3 % and
blocks add 6-8 %. JavaScriptCore runs main's core in 0.88-0.92x V8's host
instructions and at 1.14-1.18x its fps, which jit.md could not say. That
matters for iOS Safari.

## Where the cost is

Golden Sun, ARM9 (-d:nds_blkstats; executed ARM9 opcodes ~418 M):

| | value |
|---|---|
| opcodes run in blocks | 379 M (91 %) |
| block entries | 88.7 M (4.27 opcodes each) |
| calls from the run loop (chained entries) | 16.5 M (5.4 blocks a call) |
| returns to the run loop at a slice end | 6.2 M |
| blocks decoded | 204 K |
| changed opcodes | 0 |

SoulSilver New Bark: 106 M opcodes in blocks (90 %), 30.0 M entries (3.53
each); 7101-7700: 3.78 per entry. ARM7: 4.1-4.4 per entry.

Cost per entry and per opcode, from a build with 1-opcode blocks (every
opcode an entry) against the full one, ARM9 blocks only: a 1-opcode block
costs **93** host instructions more than the plain loop spends on that
opcode; with full blocks the cost is 37 per entry, so each opcode after the
first saves **~17**. In order of the versions built (Golden Sun, host
instructions, plain loop 66.6 G):

| version | Golden Sun | what changed |
|---|---|---|
| v1: a generic per-opcode loop | 81.9 G | flags tested per opcode (bus fetch? kind? pc? condition?), a flush before and after every data access and bus fetch, a call into the block runner per block |
| v2: one switch per opcode on a combined code | 71.4 G | a sentinel END opcode, no flush before the entry fetch, chaining, the runner inlined, the ARM9 line step inline |
| v3 (the branch) | 70.3 G | exactness fixes (ARM7 after-data fetch), the slice end inside a run of pure opcodes, a lookup at every `run` call |

What stays per opcode in a block: the dispatch switch (an indirect
branch), the handler's indirect call, the word compare. A data access also
keeps the flush before and after, the trackers, cur_pc/r15/next_pc, and the
abort, `attn` and jump checks. Per entry come the table lookup, the bus fetch
with its compare, the flush and slice-end check after the first opcode, and
the exit (trackers, flush, count, pc).

What could still be removed, and what it would buy (estimates from the
figures above, not built):

- Following static branches and returns inside a block (traces) removes
  the lookup and exit at most block boundaries, but every jump still needs
  its bus fetch (the timing model: the refill, the instruction-cache tag,
  the protection page, the loop head) and the flush after it. That is
  roughly half of the 93: Golden Sun from +5.5 % to about even.
- A per-page write generation instead of the word compare: about 3
  instructions an opcode, and a write barrier in every store path (both
  CPUs, DMA, cache write-backs, loaders).
- Neither reaches the per-access bookkeeping of data accesses, a third of
  the opcodes, nor the handler call. Getting rid of those means fusing
  handler and bookkeeping into straight-line code per block: a JIT
  (jit.md's options (a) and (b)).

## Cost of the code

- 552 lines `arm/blockcache.nim`, +64 net in `arm/cpu.nim` (types, the run
  loop, `exec_fetched` split out of `exec_one`), 90 in the buses, 7 in
  `nds.nim`/`savestate.nim`; the test 139 lines plus 135 of assembly and a
  53-line generated table. ndsrun 2.31 -> 2.36 MB; the wasm ndsrun 1,244,547
  -> 1,285,173 bytes (+3.3 %; gzip 299,281 -> 307,973).
- The maintenance cost is the real one. The decoder's classes must mirror
  the dispatch decoder exactly: a pure opcode that touches the bus would
  silently break timing. The block runner restates the bus's fetch fast
  paths, tracker rules, the ARM7's after-data rule and the ARM9 overlap's
  use of the clock. Every future change to the timing model (perf.md's
  rounds changed these paths four times) would have to change both places,
  with a test that fails for each. Both bugs above were of exactly that
  kind.

## Recommendation

Drop. Effort to make it production-ready, were it worth it: 3-5 agent-days.
That covers separate run loops so the off path costs nothing, tests for the
two uncovered pieces, the slice-end rule documented in perf.md's style,
the pool sized per target, and the iOS app's build. It would ship a
slowdown. Keep the branch for the record and salvage the tooling:

- `ndsrun --perf-from` prints host cycles beside instructions (as on
  `nds-jit`); `-d:pcsample` samples pcs over the timed frames.
- `tools/ndswasm`: ndsrun as wasm for node and the browser, with the engine
  process's host counters. It is the first JavaScriptCore measurement of
  the DS core.

The way to make the DS cheaper on these terms is still jit.md's: per-block
timing pays only together with generated code. For the web that is a
wasm-module JIT (jit.md option (a)), and JavaScriptCore now has numbers to
compare against.

## Method

- **States.** Made by the base build (main 7dc82b46 + host cycles) with the
  scripts of docs/nds/commercial.md, `--rtc 2004-01-01`, real BIOS:
  `ndsrun GoldenSunDarkDawn.nds --press "$(tr -d '\n' < gs_dd_field.txt)"
  --frames 3000 --state-save gs3000.st@3000` and `ndsrun
  PokemonSoulSilver.nds --press "$(tr -d '\n' < ss_p12.txt)" --frames 10000
  --state-save ss7100.st@7100,ss10000.st@10000`. Each run is `--state-load
  STATE --frames END` with the same press list (3600, 7700, 10600). The
  press files have line breaks, which `--press` does not take, so strip them.
- **Exactness.** `--state-hash 25 --screen-hash 25` with
  `DINGBAT_NDS_NO_BLOCKS=1` and without, outputs compared.
- **Native counts.** `--perf-from` (host instructions and cycles of the
  timed frames).
- **Web.** `tools/ndswasm/build.sh OUT NAME`; V8: `node drive.mjs
  OUT/ndsrun_NAME.js gs` with `NDSWASM_DATA` (states, press lists) and
  `DINGBAT_NDS_BIOS`; JavaScriptCore: `server.py PORT DIR` (DIR holding the
  builds, page.html and links under `f/`) and `node webkit.mjs PORT
  ndsrun_NAME.js gs 1` (0 = blocks off) with `NDSWASM_WEB` pointing at
  web/. Emscripten reads the environment as the runtime starts, so the off
  switch is set in `preRun` (setting it later silently leaves blocks on).
  The rusage helper (`cc -O2 -o rusage rusage.c`) reads the engine
  process's counters. Under WebKit the server keeps the single process
  that grew most between the two reads. Summing every WebKit process
  counted other agents' browsers.
- **Where the time goes.** `-d:pcsample` with `DINGBAT_PCSAMPLE=FILE`,
  symbolised with `atos -i` against a `--debugger:native` build.
