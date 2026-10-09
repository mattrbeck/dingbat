# DS CPUs: what a JIT would buy, and a translator prototype

Branch `nds-jit` (from `phone-ui`). The question: what would dynamic
recompilation take for the DS core's two CPUs (arm/cpu.nim), and how much
faster would it be? The rule over everything stays the one in
docs/nds/perf.md: **a speed-up may not change any output** -- frames, sound,
the whole machine state, opcode counts.

Short answer, measured below:

- An exact block translator that keeps today's timing model -- opcodes as
  constants, decode and dispatch folded away, guest registers in host
  registers across runs of ALU opcodes -- makes Golden Sun's ARM9-bound
  intro **1.28x faster** natively, SoulSilver **1.03-1.08x**, and the web
  build **no faster** (0.97x in V8).
- What is left per opcode is the exact timing model: the fetch and data
  access bookkeeping, the clock and opcode count after every opcode, the
  slice-end and `attn` checks. A full JIT that kept those exact but did
  them at block granularity is bounded by the time split at about **2.2x**
  (Golden Sun) and **1.5x** (SoulSilver overworld), for 25-35 agent-days
  per host architecture, and needs the timing model reworked to be
  decided per block, not per opcode.
- iOS native cannot JIT at all (below); iOS Safari can, through wasm.

## Where the time goes

`ndsrun -d:pcsample` (new) samples the interrupted pc every 100 us of CPU
time over the `--perf-from` frames and writes them to `$DINGBAT_PCSAMPLE`;
symbolised with inline frames (`atos -i` against a `--debugger:native`
build's dSYM) each sample is sorted by its innermost frames: a data access
(read*/write* and everything under them), the opcode fetch, the opcode's
handler, or the run loop and its bookkeeping (condition, table call, clock
and opcode counts). The scripts are in the round's scratch directory
(`samp.sh`, `classify.py`). -d:danger, real BIOS, 600 frames from a state:

| share of host time | Golden Sun: DD intro pages (3001-3600) | SoulSilver New Bark overworld (10001-10600) |
|---|---|---|
| ARM9 run loop + bookkeeping | 38.1 % | 19.6 % |
| ARM9 fetch | 17.0 % | 9.4 % |
| ARM9 handlers | 12.3 % | 8.9 % |
| ARM9 data path (incl. cache/PU tags out of line) | 19.0 % | 14.9 % |
| ARM9 idle-loop detection | 0.6 % | 0.4 % |
| **ARM9** | **87.1 %** | **53.6 %** |
| ARM7 | 4.7 % | 8.3 % |
| 3D | 0.5 % | 26.8 % |
| 2D | 4.1 % | 3.6 % |
| SPU | 1.0 % | 1.5 % |
| slice loop, events, other | 2.7 % | 6.3 % |

Host instructions: Golden Sun 65.1 G for 418 M ARM9 and 14 M ARM7 opcodes
(about 135 host instructions per ARM9 opcode); New Bark 35.3 G for 117 M
ARM9 and 19 M ARM7 opcodes (about 160). Dynamic opcode mix (from the
profiles below): Golden Sun's ARM9 is all ARM state -- ALU 44 %, branches
22 %, loads 17 %, stores 7 %, LDM/STM 6 %, MSR/MRS 5 %; SoulSilver's ARM9
runs 19 % Thumb.

**Amdahl.** With the CPUs infinitely fast Golden Sun's intro would run 12x
faster and the New Bark overworld 2.6x (its 3D renderer is 27 %). A JIT
removes most of the run loop, fetch and handler shares, not the data path,
which is the timing model itself. Taking the run loop and bookkeeping down
to 15 % of what it is, the fetch to 20 %, the handlers to 50 % and leaving
the data path: **about 2.2x** for Golden Sun, **about 1.5x** for New Bark.
That is a ceiling for an excellent JIT, not a forecast.

## The prototype: translated blocks, exact by construction

`arm/blocks.nim` (included by cpu.nim, compiled only with `-d:nds_jit`),
`tools/jitgen.py`. The translation is done ahead of time from a profile,
by the C compiler -- the measurement vehicle for "how fast is translated
code", not a shippable JIT:

1. `ndsrun -d:nds_jitprof` with `DINGBAT_JITPROF=FILE` counts every
   executed (cpu, pc, Thumb, opcode) and how often it was reached by a jump.
2. `tools/jitgen.py PROFILE... -o FILE --v3` forms blocks: starting at jump
   targets (and after MSR, MCR, SWI and unconditional branches), running
   through the profile's next opcodes until an opcode that may change the
   pc, mode or Thumb state unconditionally; conditional branches stay inside
   (a taken one leaves). Hot blocks are kept until they cover `--cover` of
   the profiled opcodes.
3. A `-d:nds_jit -d:nds_jit_gen=FILE` build compiles them in. The run loop
   looks `next_pc` (+ Thumb bit) up in a direct-mapped table before each
   interpreted opcode; a hit calls the block. `DINGBAT_NDS_NO_JIT=1` turns
   them off at run time.

Each translated opcode is exactly `exec_one` for that opcode:

- **Fetch**: the bus's own fetch (its sequential case inline, jumps and
  line changes out of line), so every timing, tag, protection and
  loop-head effect stays. The word fetched is compared with the translated
  one; a changed word (self-modifying code, overlays, another program at
  the address) runs through the table as before and the block leaves.
- **Execute**: `arm_dispatch(K)` / `thumb_dispatch(K)` with K a literal: the
  C compiler folds the condition, the decode and the register numbers --
  the dispatch table entry's code, minus the index, the indirect call and
  the operand extraction.
- **Leave** wherever the run loop would do anything but run the next opcode:
  the opcode jumped (next_pc), `attn` is set (I/O access, CPSR or CP15 write,
  SWI: halt, the IRQ line and the slice end are checked there), the clock
  reached `until`, an interworking opcode changed the Thumb state.

Three forms, each adding to the one before (`jitgen.py --v2`, `--v3`):

- **v1**: the above.
- **v2**: a *pure* opcode (ALU, multiply, MRS, CLZ, Q-arithmetic; no data
  access, no write to r15 or the CPSR control bits) in the same line (ARM9,
  32 bytes) or page (ARM7, 4 KB) as the opcode before needs no fetch checks
  (the bus's sequential conditions are proved once, `fetch_seq_ok`, and
  only a non-pure opcode can break them), no abort, attn or next_pc check;
  the clock and opcode count live in locals between non-pure opcodes.
- **v3**: two or more pure opcodes in a row run as a transaction on a stack
  shadow of the CPU (registers, CPSR, internal cycles), which the C compiler
  keeps in host registers: the same handlers, inlined. The run commits --
  the registers it writes, the CPSR, its last fetch's trackers, clock and
  count -- only when every opcode in memory is the translated one and the
  clock after the last is still below `until` (it rises with every opcode,
  so it was below after each: the run loop would have run them all).
  Otherwise nothing has changed and the run goes opcode by opcode.
- Also tried: **chaining** (`--chain`: a block calls the block its static
  branch reaches instead of returning to the run loop): no gain, the hot
  exits are returns (BX lr, POP pc).

### Exactness

Every build was checked against the interpreter, whole-state CRC and both
screens' CRC (`--state-hash`, `--screen-hash`):

- Golden Sun 3001-3600 (every 50 frames: v1, v2, v3; every 25 frames with
  screens: v3, v3 with out-of-line fetches, chaining), SoulSilver 7101-7700
  and 10001-10600 with the New Bark blocks (every 25 frames, 48 hashes
  each): identical.
- 15 homebrew and test ROMs (NitroGrafx, MAXMXDS, Cave Story, Tales of
  Dagur, Space Impakto, nesDS, Triple Triad, trans flag, The Strongest Demo,
  GameYob, ds81, dsniccc, armwrestler, arm7wrestler, rockwrestler; 600
  frames, state and screen every 30) with one block set built from all
  their profiles at once, so most ROMs also run other ROMs' blocks at their
  addresses (up to 1.4 M opcodes a run took the changed-word path):
  identical in all 15.
- The default build (no `-d:nds_jit`) is unchanged: same hashes; the new
  `jit_on` field is left out of the save state (CPU_SKIP), so the layout is
  the same; nds_savestate_test and nds_cpu_test pass.

### Numbers

Apple-silicon Mac, quiet machine (load < 5; host cycles of the timed frames
from `proc_pid_rusage`, which `--perf-from` now prints with the
instructions, repeat to 0.5 %), 600 frames from a state, blocks built from
the same stretch's profile (a warmed-up JIT; translation cost not counted):

| Golden Sun intro, 3001-3600 | host instructions | host cycles | fps |
|---|---|---|---|
| interpreter | 65.06 G | 13.36 G | 151.8 |
| v1 | 61.97 G | 11.39 G | |
| v2 | 59.94 G | 10.81 G | |
| v3 | 59.13 G | 10.75 G | |
| v3, fetch slow paths out of line | 60.77 G | 10.38 G | **195.0 (1.28x)** |
| + chaining | 60.92 G | 10.44 G | |

96 % of the ARM9's opcodes ran inside blocks (305 ARM9 and 543 ARM7
blocks, 9,100 opcodes), 4.2 opcodes per block entry.

| SoulSilver (blocks from New Bark's profile: 3,222 ARM9 + 461 ARM7 blocks, 48 K opcodes, 95 % cover) | interpreter | v3 inline | v3, slow paths out of line |
|---|---|---|---|
| New Bark overworld 10001-10600: cycles, fps | 7.96 G, 254 | 8.11 G (slower) | 7.66 G, **263 (1.035x)** |
| walk downstairs 7101-7700: cycles, fps | 4.48 G, 450 | | 4.16 G, **488 (1.08x)** |

The New Bark binary is 27 MB (48 MB with everything inline, which was
slower than the interpreter): about 500 bytes of host code per translated
opcode, most of it the bus's inlined fast paths. Code size is the first
cost of translation here.

**Web.** The same core and blocks built as wasm (emcc -O3, run by node 24 /
V8; `ndsrun` compiled with `-s ENVIRONMENT=node -s NODERAWFS=1`), Golden Sun
3001-3600: 115.6 G instructions and 111.5 fps for the interpreter, 99.5 G
(-14 %) for v3 -- but **108 fps** (default tiering) and 86 fps with
`--no-liftoff`: fewer instructions, more cycles (18.6 G -> 21.3 G). V8 runs
the large translated functions worse than clang's native code of the same
source; v1 was no better (107 / 88 fps). Compiling the 6.9 MB module with
the optimising tier cost 28 G host instructions at startup. Safari (JSC)
was not measured.

### Why the prototype stops at 1.28x

Per translated opcode the core still does what makes it exact: the bus's
fetch (tracker stores, the line check, the opcode compare that catches
changed code), `cur_pc`/`next_pc`/r15, the clock (`base + wait + internal`)
and opcode count, and the slice-end check; non-pure opcodes also the abort
and `attn` checks, and all guest registers and the CPSR go back to memory
around every data access, whose fast paths read and write the CPU's clock.
Golden Sun's hot code is small functions (4.2 opcodes per entry): every
entry is a jump, so a full jump fetch (protection page, I-cache tag) and a
run loop pass.

## What a real JIT would take

Common to every option: a translator for ARMv5TE and ARMv4T (ARM and Thumb,
about 150 opcode forms), with the bus fast paths emitted inline and the
rest (I/O, misses, aborts) as calls; block cache and invalidation (code
pages written by either CPU, DMA, cache write-backs, loaders; or the
per-opcode compare above); and, to get past the prototype, the timing model
decided per block: a block's fetch costs and cache tags checked once at
entry (with a per-opcode fallback when they do not hold), the clock checked
against the slice end once per block with an exact replay for the block
that crosses it, registers and flags in host registers until a slow path.
That is a redesign of the timing model's interface, and every piece needs
a test that fails when it is removed (the perf.md standard). The validator
is the prototype's: whole-state hashes against the interpreter, plus a
lockstep mode that compares state after every block.

| option | effort (agent-days) | expected | blocked by |
|---|---|---|---|
| (a) **Web: wasm-module JIT** -- hot blocks emitted as small wasm modules at run time (`new WebAssembly.Module(bytes)`), importing the core's `WebAssembly.Memory` and function table; blocks installed in the table, called by `call_indirect` from the run loop | 25-35 | uncertain: our AOT blocks were 0.97x in V8; needs much leaner code than the prototype's, and JSC measured | nothing (iOS Safari JITs wasm in its WebContent process; no CSP in web/) |
| (b) **Native AArch64 JIT** (macOS, Linux arm64) | 25-35, plus 15 for an x86-64 backend (Windows, Linux) | up to ~2.2x CPU-bound, ~1.5x SoulSilver | macOS: Hardened Runtime needs `com.apple.security.cs.allow-jit`; `mmap(MAP_JIT)`, `pthread_jit_write_protect_np` per thread, `sys_icache_invalidate` |
| (c) **iOS native without JIT**: a block-threaded interpreter (pre-decoded blocks of handler pointers built at run time) | 5-8 | about the prototype's v1: 5 % fewer instructions, up to ~15 % fewer cycles on Golden Sun-like code | -- |
| (d) Ship the prototype as it is | -- | -- | it compiles a game's code into the binary: per game, from a profile; not shippable for user-supplied games |

**iOS, exactly.** iOS enforces code signing on every executable page: an
app can only map memory writable-then-executable with the
`dynamic-codesigning` entitlement, which Apple does not grant to App Store
apps (WebKit's WebContent process has it; since iOS 17.4, in the EU only,
BrowserEngineKit gives alternative browser engines' content processes a JIT
-- browser apps only). App Review Guideline 2.5.2 also forbids executing
downloaded code that changes the app's features; Guideline 4.7 lets
emulators download games but grants nothing for code generation. JIT on
iOS outside the store only works with a debugger attached (developer
sideloading). So the native iOS app gets (c) at most. An iOS app could host
the wasm core in a WKWebView, whose WebContent process does JIT -- but the
native interpreter already runs the same frames in 65 G host instructions
against wasm's 116 G, so a wasm JIT would have to be 1.8x faster than the
wasm interpreter just to break even with native.

**The GBA core.** Its ARM7TDMI runs at 16.78 MHz, far fewer opcodes per
frame than the DS, and it already runs well above full speed on every
target. Its timing model (prefetch buffer, history-dependent waitstates) is
per access like the DS's; the 2026-07 cached-interpreter study capped a
block cache at +8-12 % for the same reason as here. A DS JIT's ARMv4T
translator could be reused, with the GBA bus's own timing rules; not worth
building for the GBA alone.

## Open decisions

1. Whether a native JIT (option b) is wanted at all, given ~1.5x on
   SoulSilver at best and the risk to exactness; its prerequisite is
   reworking the timing model's interface to per-block decisions.
2. For the web, whether to first measure Safari (JSC) with the prototype's
   wasm build -- if JSC also runs translated code slower, (a) is not worth
   starting.
3. Option (c) for iOS native is the only one available there; worth it only
   if Golden Sun-like games (ARM9-bound) matter more than SoulSilver-like
   ones (3D and data-path bound).
