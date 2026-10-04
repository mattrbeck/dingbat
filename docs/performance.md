# Performance: how to measure, what is known

## Harnesses

* **Native:** `tests/dingbat_bench.nim`. `DINGBAT_BENCH_STATE=<file.state>`
  resumes an in-game scene; `DINGBAT_BENCH_COUNTERS=1` reports retired
  instructions; `DINGBAT_BENCH_HASH=1` prints a rolling framebuffer hash.
  `DINGBAT_BENCH_HASH=1` also prints a hash of the final state payload;
  `DINGBAT_BENCH_RTC_EPOCH=<unix seconds>` freezes a cartridge RTC so RTC
  games compare state for state (both cores). `DINGBAT_BENCH_GB_DMG=1` runs
  a CGB-flagged cart on DMG hardware.
* **Web:** `web/bench/bench.html` drives `_benchFrames` through the wasm
  exports; `web/bench/cdp.mjs` runs expressions over CDP. See
  `web/bench/README.md`.
* **Per-setting cost (web):** `web/bench/settings.html` times every user
  setting through `loop_tick` / `runahead_tick`, the presenter, the glow and
  the analog filter; results and method in `docs/settings-cost.md`. Native
  knobs for the same: `DINGBAT_BENCH_FIFO_INTERP=0`, `DINGBAT_BENCH_SGB=1`.
* **Web core, headless:** `web/bench/node_wasm.sh build <out.js>` compiles
  the native harness with the web build's flags for Node (same V8 wasm
  engine as Chrome, a foreground process, every `DINGBAT_BENCH_*` variable
  passed through); `--passL:--profiling-funcs` keeps names for
  `node --cpu-prof`. Wasm inlining differs from native: profile both.
* Profile with macOS `sample` (1 ms, 10 s), leaf-weighted, Nim mangling
  stripped and generic instantiations summed.

## Rules that keep measurements honest

* **Wall clock lies below ~1.3 %** on this machine (single runs spread
  5–10 %). Use retired instructions (stable to ~0.1 %), or best-of-9
  interleaved runs where every repetition runs every (build, game) pair.
* **Measure the browser in a visible window.** Headless Chrome on Apple
  Silicon gets background QoS and efficiency cores: the same build measured
  185 fps headless and 441 fps in a window.
* **Isolate saves.** The emulator writes `.sav` next to the ROM; build B then
  boots from build A's SRAM. Give each build its own ROM copy.
* **Gate every change on `DINGBAT_BENCH_HASH=1`** being byte-identical across
  the ROM set, and on the mGBA suite score.
* **A waitloop or scheduler change is gated on the library, against
  `DINGBAT_NO_WAITLOOP=1`.** Every 8th title of the archive (988), 300
  frames, framebuffer hashes plus the final state payload with the RTC
  frozen, each build on its own symlinked ROM: skip on must equal skip off.
  Framebuffers alone missed 85 titles where the skip had moved emulation.
* **Probe the ceiling before writing the optimisation.** Stub the stage out
  and measure; a stub that deletes render work is valid (the emulated CPU
  never reads the framebuffer), a stub that skips CPU work is not (it stops
  IRQs and "measures" 2.3x).
* **Calibrate on several gameplay states, never one.** A FireRed title-screen
  state that is 100 % windowed compositing inverted the PPU ranking; see
  `docs/research_ppu_hotspots.md`.
* **One wasm binary for A/B.** Two builds differ in code layout by more than a
  3 %-of-tick feature costs; compile both arms into one binary and interleave.
* `mem_read` / `mem_write` sit on clang's inline threshold; a small edit there
  can re-roll inlining and move everything (`docs/gb_oam_dma_cost.md`).

## Build flags that matter

| flag | effect |
|---|---|
| `--threads:off` (`nim.cfg`) | module globals stop being TLS (`_tlv_get_addr` in every hot handler) |
| `--mm:arc` | no cycle collector; the scheduler's closures were triggering it |
| `-mno-outline` (arm64, not emscripten) | Apple clang's machine outliner turned hot straight-line code into `OUTLINED_FUNCTION_*` calls, ~15–20 % of samples; +35 % native. `em.wasm` is byte-identical with or without it |
| `-d:danger` | +17 % native, rejected: bounds checks have caught real OOB on hostile ROMs |
| `-msimd128` | +1.6 %, not shipped: needs Safari 16.4+, breaking the iOS 15 targets; a second bundle doubles the offline precache (`web/sw.js` precaches `em.wasm` by name) |

Scheduler events dispatch on `EventType` through one closure set at init;
per-event closures were thousands of heap allocations per frame. Hot leaf
procs carry `{.inline.}`; forward declarations must repeat the pragma.

## Where the time goes (GBA, native, gameplay states)

`cpu.tick` self ≈ 20–32 %, ARM/Thumb handlers ≈ 15–17 %, `fetch_half` 5–12 %,
named PPU 21–38 % (`render_reg_bg` 11–17 %, `composite_span` 6–11 %,
`render_sprites` 4–10 %), scheduler ≈ 4 %. After `-mno-outline`, clang is
already doing LICM, register promotion and redundant-load elimination:
hand-hoisting invariants measures as noise. Gains come from doing less work.

Measured ceilings and verdicts are in `docs/research_ppu_hotspots.md`. A
block cache / JIT was assessed at only +8–12 % because the cycle-accurate
timing model cannot be precomputed, and must preserve the bit-exact
determinism rollback netplay depends on. Layer-at-a-time SIMD compositing:
ceiling 3–5 % on web for three inner loops (opaque / shade / blend, all
carrying real games), permanent dual scalar/SIMD maintenance of the
renderer's most correctness-sensitive code, no benefit on the oldest devices
— no-go unless the compositor's share grows or SIMD becomes assumable.

The MP2K HLE has no per-instruction cost (2026-09-14). It learns no code
address. Each work-RAM store pays one subtract and compare against a window
the HLE keeps on the driver's SoundInfo, and a mixer pass is the driver's
lock write followed by its first store into the ring the sound DMA plays
(`src/dingbat/gba/mp2k.nim` "Runtime detection", census in
`tools/mp2kprobe/README.md`). It replaced a PC hook tested per instruction
and then per branch. Retired instructions, minimum of five runs:

| Scene | HLE off | HLE on |
|---|---|---|
| Emerald, Littleroot (600 frames), PC hook | 12.37 B | 12.69 B |
| Emerald, write trigger | 12.20 B | 12.50 B |
| Beast Shooter, attract (900 frames), PC hook | 17.46 B | 19.10 B |
| Beast Shooter, write trigger | 17.25 B | 18.88 B |

The HLE-off drop of about 1.3 % sits at the code-layout noise floor, and the
frame hashes are unchanged. Tagging each FIFO byte with its source address
for the HLE's slot timing (2026-09-15) adds 0.15 % with the HLE on or off. The mixer renders a voice at a time across the
frame, and the quality tier's unstretched sinc is a dot product with a
precomputed per-phase row. Against the pre-2026-09-14 per-instruction PC
compare, the HLE's overhead fell from 1.22 B to 0.30 B on Emerald and from
4.00 B to 1.63 B on Beast Shooter.

What remains on Beast Shooter is mostly the stretched kernel for its
decimated voices (about 0.6 B). A per-step table would save only the kernel
lookups, not the 64-tap products, so it was left alone.

## Idle loops (2026-09-28)

An idle loop's skip used to stop at every scheduler event and run the
iteration that crossed it for real. FireRed dispatches ~1930 events a frame
(548 output samples, four PPU events a line, 224 sound-timer overflows), so
its WaitForVBlank loop still ran ~1370 real iterations a frame, 17 % of the
CPU's executed cycles. The skip now runs through an event whose handler
cannot tell whether the iteration ran (`gba.wl_passable`: samples, and line,
H-blank and timer events on their plain paths), for a loop that cannot see
it (no IO read, no renderer-contended access, no window open, no interrupt
pending, period at most `WL_CROSS_PERIOD_MAX`). Measuring it exposed two
places the old skip was not exact (a verdict taken before the branch's
refill dispatched events after the loop's read; skipped iterations leaving
an open access window's stamps stale); both are fixed, and skip on now
equals skip off on 987 of the 988 sampled titles.

Retired instructions from gameplay states, before this round -> after it
(including the fetch inlining and serializer fixes below): FireRed 10.08 B
-> 8.74 B, Emerald 10.15 B -> 8.80 B, Kirby NiDL 7.01 B -> 5.81 B, Golden
Sun 8.53 B -> 8.34 B, Minish Cap 8.98 B -> 8.65 B (the last two idle in
Halt). Web build (wasm under Node, best of 5): FireRed +17 %, Emerald +16 to
+18 %, Kirby +22 to +24 %, Golden Sun +3 to +5 %, Minish Cap +4 to +6 %.

### Second round (2026-09-29)

* **A skip needs a repeated iteration, not two equal verdict gaps.** The
  verdict is taken inside the branch, whose position in its iteration moves
  with the prefetcher (Iridion II read 17 and 17 on a 16-cycle loop).
  `waitloop_skip` records the prefetcher's time-relative state and the
  boundary at every judged iteration's end, and skips only after an
  iteration that began in the previous one's state, took the verdict's
  period, and had no DMA and no renderer-contended access in it.
* **IO pollers pass events that leave their register alone**
  (`Bus.io_read` classes): DISPSTAT/VCOUNT readers stop only at
  SetHBlankFlag and EndHBlank, keypad readers at nothing. The skip moves
  the IO load's access stamps with the time it skips.
* **More loop shapes judged:** Thumb bodies up to `WL_BODY_MAX` (32),
  high-register ADD/CMP/MOV and the `mov r8, r8` NOP, register-offset
  loads, a second, forward exit; ARM loops (`scan_arm_loop`, hooked in
  `arm_branch`). Verdicts are keyed by start, state and length
  (`wl_key`). A volatile read inside the loop rests its judgement for
  `WL_VOLATILE_REST` iterations (Nintendo's EEPROM wait).
* **Never judged:** code outside real memory (a crashed bad dump).

Skip on equals skip off over the whole archive, audio included (frames,
final state, every emitted sample; 7897 titles, the two bad dumps that
crash on every build aside). Probe for what is left:
`-d:idle2`-style counting of executed cycles in iterations that start in
the previous one's registers and write nothing; in a 1/8 sample's clean
dumps that was 15.5 % of executed cycles before this round and 6.4 %
after. What it still finds: loops that call a function (`bl`) or close
with an unconditional branch, and loops under a per-line H-blank
interrupt (Tekken Advance, Guilty Gear X).

Cost on games this round does not help (FireRed, Emerald, Kirby, Golden
Sun, Minish Cap from gameplay states): +0.2 to +0.4 % retired
instructions, in steps of 0.03-0.11 % each (the ARM branch hook the
largest). Gains, from boot: Adventures of Mr. Bean -97 %, Koala Brothers
-70 %, Rockman Zero 4 -67 %, Digimon Battle Spirit -66 %, Super Bubble Pop
-65 %, Tringo -55 %, Polly Pocket -53 %, Rampage Puzzle Attack -43 %,
Horse & Pony -36 %, Iridion 3D -34 %.

### Third round (2026-09-29): loops the scan cannot prove

* **A dynamic verifier (`waitloop.dyn_loop`).** The static scan now says
  accept, never (a loop-carried register, a PC write) or *dynamic*: a body
  with calls, stores or shapes it cannot parse, up to `DYN_BODY_MAX` bytes,
  hooked on unconditional backward branches too. A dynamic loop is armed at
  its head: registers and CPSR snapshotted, stores tracked (`note_store`; a
  work-RAM store of the value already there does not count, any store near
  the PC or into the MP2K sound area does), and SWIs, interrupts taken, DMA
  bursts and event kinds counted. The next arrival at the head with all of
  it unchanged, no IO read an event could have moved and no interrupt line
  up is an iteration that repeated the last, and the skip machinery takes
  it from there. A failed check rests the loop for `DYN_REST` arrivals, so
  loops that do work cost little. Verdicts live in `WLTables` (a ref: big
  arrays in the CPU object cost ~0.3 % in layout alone), a direct-mapped
  table ahead of the hash sets; a verdict on RAM code keeps the body's bytes
  and holds only while they still match.
* **Interrupt-heavy loops keep their verdict.** A loop that read no IO
  cannot have been changed by an event that writes no memory
  (`WL_MEMORY_QUIET_KINDS`), so the per-line H-blank interrupt no longer
  costs it its verdict every line; StartHBlank with the H-blank interrupt
  on passes only for periods shorter than the 31 cycles to the interrupt's
  window. Passing that window itself (the rest of Tekken Advance's and
  Guilty Gear X's time) would mean skipping IRQ_LAST_WAITS' notes, which
  are serialized; not done.
* The verifier's one exactness hole on the archive: it skipped with an
  interrupt line already up, so Franklin the Turtle took an H-blank
  interrupt three iterations (180 cycles) late; frames and audio still
  matched, the stack's stale bytes did not. `-d:wlcheck` now asserts no
  skip passes a deliverable interrupt.

Skip on equals skip off over the whole archive again, audio included.
Instructions from boot, main -> this round: Magical Quest 3 -45 %, Final
Fight One -37 %, Powerpuff Girls -19 %, Land Before Time -17 %, Super
Monkey Ball Jr -17 %, Quiere ser Millonario -17 %, Oshare Princess 3 -15 %,
WarioWare trial (RAM code) -11 %, Guilty Gear X -9 %, Tekken Advance -8 %,
Scooby-Doo -7 %; titles it does not help at most +0.6 %. Gameplay states:
FireRed +0.30 %, Emerald +0.27 %, Kirby +0.03 %, Golden Sun +0.27 %,
Minish Cap +0.21 %.

`fetch_half` / `fetch_word` and their cached halves were `{.inline.}` and
out of line anyway, natively and in wasm: now `always_inline` under clang
(-3.4 % FireRed native, +4 % web). The rewind ring's serializer wrote the
framebuffer a halfword at a time into a buffer grown from empty; one copy
into a pre-sized buffer halves rewind's cost.

## Carried over from the DS core (2026-10-03)

The DS core's caching round (branch `worktree-nds-skeleton`) proposed six
items for the GBA. What each came to, measured on six gameplay states and
six intros, retired instructions (min of 4), per-frame hashes identical:

* **Same-value stores don't dirty the frame** (the cheap half of "per-line
  reuse"). The whole-frame render skip never fired in gameplay: every game
  rewrites its PPU registers from a shadow copy each V-blank and DMAs the
  same OAM, and any store set `render_dirty`. Now a PRAM/VRAM/OAM store
  dirties only if it changes the memory, a register write only if it
  changes a field it writes (`dirty_if_changed` in ppu.nim: DISPCNT with
  the BG-enable latches, the affine reference points with the internal
  point a write reloads), and `latch_oam` only if the view it copies
  differs. Kirby -30 %, F-Zero GPL intro -27 %, Emerald walking -25 %,
  Minish Cap -22 %, FireRed -11 %, Emerald -10 %, GS TLA -8 %; Golden Sun
  and Mario Kart redraw every frame (0 %). Web: Kirby +29 %, Emerald +10 %.
  Guarded by `tests/render_skip_test.nim` (a never-skipping twin; breaking
  the reference-point, VRAM or OAM check makes it fail).
* **One test before each opcode** (the DS's interrupt-check item, made exact
  by construction instead): the five CPU fields `tick` tests go through
  setters that keep `cpu_slow`. -1.5..-2.5 %; the DS's attention flag, set
  from every event that could change them, was not built.
* **No error-flag test after calls (`quirky`)**: only in `-d:danger` builds
  (`QUIRKY_CORE`, gba.nim), +3-4 % on the web. Natively it is worth ~10 %,
  but quirky, an out-of-range access goes ahead before anything tests the
  flag: `tools/statefuzz.nim kirby.gba 3000 777` finds two hostile states
  that fault while running, and the quirky desktop build died of SIGSEGV
  where main reports an IndexDefect. `--panics:on` instead recovered only
  ~2-3 % (3674 of 6658 flag tests remain), and would make the state
  loaders' Defect backstops fatal. The same push over `common/scheduler.nim`
  measured -0.1 %.

What is left of per-line reuse: after the change above, Emerald still draws
59 % of its lines, FireRed 52 %, GS TLA 64 %, though 99 % of them come out
identical to the previous frame's. Those frames change only VRAM (BG tiles
at 0x3400-0x3FFF, OBJ tiles at 0x10000) and OAM, so reusing their lines
needs the DS's full machinery: per-1 KB VRAM blocks marked as each line
reads them, and per-sprite line coverage. Ceiling about 11-15 % on those
titles (~20k host instructions a line), ~0 on Kirby and Minish Cap.

Not pursued, from the profile: the sequential fetch already tests the
fetch key, page, hot flag and next address (a few instructions of ~250 per
opcode); folding them is worth 1-2 % at most, inside the inlining-cliff
noise. Thumb already has its 1024-entry specialised table; a decoded-block
cache stays rejected (see above).

## Game Boy / Game Boy Color (2026-09-29)

Where the time went (native, `sample`, 11 GBC titles and one DMG): the FIFO
PPU's mode-3 pipeline 56-69 %, the per-M-cycle machine tick and the SM83
interpreter 27-41 %, the APU 2 %. Emulated time is mostly idle: halted plus
exact-repeat polling loops were 70-85 % of cycles on nine of the eleven (LY
polls, HALT waiting for V-blank); Shantae is the busy exception. Plain lines
(no object, no window, no mode-3 register write) were 59-89 % of lines.
The scanline renderer (removed 2026-09-30, below) was no ceiling for the
PPU: its own `do_scanline` and per-M-cycle tick were half its time.

Three changes, each exact by construction and each with a check build:

* **A stripped steady state (`fifo_plain_span`).** Past the head's
  throw-away fetch and fine-scroll latch, a span with no object, window
  start or special dot in reach (`fifo_plain_ok`) runs only the BG fetcher
  and shifter, with fifo_mix reduced to the BG palette lookup. The steady
  eight-dot cycle (drain seven, fetch, push on the dot the FIFO empties,
  pop one) runs as one block. `-d:gb_plaincheck` runs the general dots over
  every span and compares every PPU field and the line's pixels;
  `-d:gb_spancheck` compares blocks against single dots.
* **Deferred mode 3 (`PLAIN_LAZY`).** A plain span longer than the tick is
  not run: the tick moves the dot, one compare, as modes 0-2 already did,
  up to the horizon `fifo_plain_horizon` computes (retire pixel, window
  start, next object, WX check dot). Everything that reads the pipeline or
  changes what it reads calls `fifo_sync` first: `write_byte` for VRAM, OAM
  and I/O, `ppu_write`, the CGB late pipeline stores, `ppu_write_machinery`,
  `ppu_blank_frame`, `stop_instr`, `hdma_edge_lookahead`, the state writer;
  a state load drops the deferral. `-d:gb_lazypoison` fills the deferred
  fields with garbage so a missed reader shows up in a sweep.
* **Idle loops and HALT (`GB_IDLE_SKIP`).** A taken backward JR/JP marks a
  head. An iteration that repeated the last one (registers, no
  `write_byte`, the straight-line period `wl_scan` computes over a body of
  side-effect-free instructions whose reads are all of ROM, work RAM, HRAM,
  IE/IF, LY, STAT, P1 or constant PPU registers) is skipped with the
  iterations after it, in whole periods, up to `wl_horizon`: the next
  non-APU scheduler event, the PPU's next stop (idle target or `lazy_end`),
  the next TIMA overflow. The machine is advanced with
  `mem_tick_components`, as the iterations would have. The iteration copied
  must have started after the last point anything it reads could change
  (`gb.wl_mark`: PPU slow path, non-APU event, timer slow path, input,
  STOP), or a loop that straddled a line change carries the old LY into the
  skip. LY loops stop two dots short of the line end (the read ripples) and
  never skip on line 153 (the snap); STAT loops need the copied iteration
  clear of STAT's read-back window. A halted CPU is advanced to the same
  horizon once the CGB halt lead is paid. No skip with OAM DMA, a due
  H-blank block, a parked CGB store, an internal-clock transfer, or a
  requested transfer with a peer on the cable (the coordinator catches the
  slave up to the master's time; `link.nim`). `-d:gb_idlecheck` runs the
  iterations instead and checks they are back at the head, unchanged, on
  the cycle the skip would have landed.

Gates: every GBC title of the local 1G1R set (538), 1500 frames, framebuffer
hashes, final state payload and every mixed sample, against the same tree
with `-d:PLAIN_SPAN=0 -d:GB_IDLE_SKIP=0`; the 143 dual-mode carts again on
DMG hardware (`DINGBAT_BENCH_GB_DMG=1`); each check build over the library;
the test-ROM runner; `gblinktest`, the Crystal lockstep-link stability run
and `gb_rollback_test`. All identical, all clean.

Main -> this (native, 1800 frames from boot):

| title | fps | instructions |
|---|---|---|
| Super Mario Bros. DX | +96 % | -50 % |
| Wario Land 3 | +87 % | -50 % |
| Metal Gear Solid | +86 % | -50 % |
| Link's Awakening DX | +79 % | -46 % |
| Donkey Kong Country | +78 % | -47 % |
| Alone in the Dark | +77 % | -46 % |
| Tetris DX | +66 % | -44 % |
| Oracle of Ages | +53 % | -40 % |
| Link's Awakening (DMG) | +51 % | -36 % |
| Pokémon Crystal | +49 % | -35 % |
| Shantae | +26 % | -19 % |

Wasm in JavaScriptCore (the shell, same build flags as the web): Crystal
1643 -> 2436 fps, Alone in the Dark 1111 -> 2277, Link's Awakening 1400 ->
1959, Shantae 1000 -> 1284.

Where the gain came from, each change stacked on the last (fps, share of
main's frame rate; best of three, 1800 frames). The hooks alone (every
switch off, the `fifo_sync` tests and `write_count` still in) cost 1-3 %.
Idle skip is most of the gain, but only on top of deferred mode 3: without
it mode 3 has no horizon, a third of every line, and the skip alone was
-11 % to +16 %.

| title | stripped span | deferred mode 3 | idle skip |
|---|---|---|---|
| Super Mario Bros. DX | +8 % | +23 % | +68 % |
| Wario Land 3 | +11 % | +16 % | +60 % |
| Metal Gear Solid | +11 % | +19 % | +59 % |
| Alone in the Dark | +13 % | +15 % | +54 % |
| Donkey Kong Country | +12 % | +17 % | +52 % |
| Link's Awakening DX | +11 % | +19 % | +51 % |
| Oracle of Ages | +7 % | +13 % | +37 % |
| Tetris DX | +22 % | +15 % | +26 % |
| Link's Awakening (DMG) | +19 % | +16 % | +16 % |
| Pokémon Crystal | +21 % | +20 % | +8 % |
| Shantae | +9 % | +19 % | -3 % |

The scanline renderer had no deferred mode 3 and first paid for the skip
without getting it: a repeating loop decoded its body every iteration to
meet a zero horizon, up to 20 % of its instructions. The horizon is now
asked before the decode; the scanline renderer also marked no loop heads
and advanced a halted CPU to its next mode boundary. Measured as speed mode (the scanline renderer drawing every
other frame; the mode was removed on 2026-09-29), main -> this: Oracle of
Ages +106 %, Metal Gear Solid +95 %, Super Mario Bros. DX +58 %, Tetris DX
+52 %, Crystal +24 %, Donkey Kong Country +23 %, Link's Awakening +13 %,
Link's Awakening DX +12 %, Wario Land 3 +10 %, Alone in the Dark and Shantae
flat.

Second round, from a count of why each general mode-3 dot was not plain
(line head ~12 a line everywhere; objects up to 2.9 M per 600 frames on
Link's Awakening; the window 1.25-1.5 M on Oracle of Ages and Metal Gear
Solid) and of where a halted CPU's retries went:

* `wl_horizon`'s component locals were owning refs: seven ARC copies and
  destroys a call. `{.cursor.}`: -0.5 to -2.6 %.
* A halted CPU that met a mode 3 run dot by dot (no horizon, and the mark
  moves every M-cycle) asked again every M-cycle; it now waits for the mode
  to end or defer (`wl_halt_m3`): Oracle of Ages -5.2 %.
* Window lines past the restart's first push take the plain span, compiled
  once per source: Oracle of Ages -9.5 %, Metal Gear Solid -3.3 %.
* A switched-off LCD settles once (`off_wc`): until the next write a tick
  only moves the panel clock, and idle loops and HALT skip to the dot before
  the blank frame. Metal Gear Solid -4.5 %.
* The plain span drains an object's pixels from the OBJ FIFO: Link's
  Awakening -2.1 %.

Together -0.2 % (Alone in the Dark) to -16 % (Oracle of Ages) instructions;
main before either round -> now, -20 % (Shantae) to -55 % (Metal Gear
Solid).

Tried and dropped: caching fifo_tick's idle target (`fast_end`), with and
without splitting the compare out to inline: at most -3 % instructions,
within noise in wall time; plain dots up to the horizon inside a tick that
reaches an object (+1.5 to +3 %: the second eligibility test near every
object costs more than the dots). Left: the line head (~0.4 % by count, and
the most timing-bound dots of the line); the object fetch itself; the
steady block's per-pixel FIFO shifts.

After both rounds the scanline renderer was no longer the fast one (fps,
best of three, 1800 frames): the FIFO renderer led on eight of eleven
titles, by up to half again (Alone in the Dark +50 %, Wario Land 3 +49 %,
Link's Awakening DX +34 %, Donkey Kong Country +27 %, Super Mario Bros. DX
+17 %, Metal Gear Solid +7 %, Crystal +4 %, Shantae +1 %), and trailed by
5-8 % on Link's Awakening, Tetris DX and Oracle of Ages. The FIFO renderer
also retired fewer instructions on every title but Oracle of Ages (+0.8 %).
The scanline
renderer was removed on 2026-09-30, with the setting that chose it.

## Old and constrained devices

CPU-throttled M2 as a stand-in (scales compute, not cache or memory latency):
FireRed gameplay, HLE on, runs 0.88x realtime at 8x throttle — full speed
needs hardware no worse than ~7x slower than an M2 performance core, before
presentation, audio and touch. The dominant risk on an A9-class phone is not
instruction count but **Safari demoting the tab's wasm to its baseline
compiler under memory pressure** ("slow until force-quit"). Memory stability
buys more frames than micro-optimisation there.

* The ROM CRC for netplay is computed once at load from the cartridge buffer
  over `rom_size` (the file length, minus the power-of-two pad and the
  Classic NES mirrors); it is wire-visible, so it must equal
  `crc32(readFile(rom))`.
* **Known, not fixed: the ROM is resident twice** — in the cartridge buffer
  and in the Emscripten MEMFS (on the JS heap, invisible to
  `Module.memory.buffer.byteLength`). Deleting the FS copy after load is a
  trap: Reset, the post-save-delete reboot and the save-import reboot all
  call `loadRom` again without re-staging, and the FS file is the only copy JS
  can reach. The fix is a wasm-side reset that rebuilds the core from the
  cartridge it holds. Re-staging from IndexedDB was rejected (async, and
  fails in private mode or when quota-bound).
* Unmeasured: the 16 MB iOS rewind ring, startup
  compile of 1.2 MB of wasm under the baseline compiler, audio buffer margin
  on a device at 1.2x realtime.
