# Performance: how to measure, what is known

## Harnesses

* **Native:** `tests/dingbat_bench.nim`. `DINGBAT_BENCH_STATE=<file.state>`
  resumes an in-game scene; `DINGBAT_BENCH_COUNTERS=1` reports retired
  instructions; `DINGBAT_BENCH_HASH=1` prints a rolling framebuffer hash.
* **Web:** `web/bench/bench.html` drives `_benchFrames` through the wasm
  exports; `web/bench/cdp.mjs` runs expressions over CDP. See
  `web/bench/README.md`.
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

The audio-HLE hook check is one sentinel compare against `cpu.hle_hook_pc`
(refreshed at each arm/disarm site); three separate per-instruction tests
cost more than the mixing they guarded.

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
