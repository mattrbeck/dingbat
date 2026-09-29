# Performance: how to measure, what is known

## Harnesses

* **Native:** `tests/dingbat_bench.nim`. `DINGBAT_BENCH_STATE=<file.state>`
  resumes an in-game scene; `DINGBAT_BENCH_COUNTERS=1` reports retired
  instructions; `DINGBAT_BENCH_HASH=1` prints a rolling framebuffer hash.
  `DINGBAT_BENCH_HASH=1` also prints a hash of the final state payload;
  `DINGBAT_BENCH_RTC_EPOCH=<unix seconds>` freezes a cartridge RTC so RTC
  games compare state for state.
* **Web:** `web/bench/bench.html` drives `_benchFrames` through the wasm
  exports; `web/bench/cdp.mjs` runs expressions over CDP. See
  `web/bench/README.md`.
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
* Unmeasured: the 16 MB iOS rewind ring (see `docs/speed-mode.md`), startup
  compile of 1.2 MB of wasm under the baseline compiler, audio buffer margin
  on a device at 1.2x realtime.
