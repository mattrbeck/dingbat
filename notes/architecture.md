# Architecture

A map, not an essay. Every path below exists in the tree; sizes are rough
(`wc -l`, 2026-07) and will drift — trust the tree over this file.

## Build targets

Four entry points share the two cores under `src/dingbat/`:

| Target | Entry | Build | Links |
|---|---|---|---|
| Native GUI | `src/dingbat.nim` (~2200 ln) | `nim c -d:release src/dingbat.nim` | SDL2 + OpenGL + Dear ImGui (imguin); per-OS link flags in `nim.cfg` (macOS Homebrew / `-d:macdist` static, Linux `-lGL`, Windows static mingw) |
| Browser (wasm) | `src/dingbat_wasm.nim` (~1300 ln) | `nimble wasm` (`-d:emscripten`; flags in `src/dingbat_wasm.nims`) | Emscripten + `USE_SDL=2`; emits `web/em.js` + `web/em.wasm`; the exported `_wasm_*`/`_link_*`/`_rollback_*`/`_netlink_*` C ABI is what `web/index.js` calls (typed by generated `web/types/em.d.ts`) |
| iOS | `src/dingbat_ios.nim` + `src/dingbat_ios_audio.c` | `ios/build-core.sh` → static libs in `ios/lib/` | No SDL: pull-based audio ring in the .c file; Swift shell in `ios/Dingbat/`, C header `ios/include/dingbat.h` |
| Test harness | `tests/dingbat_test.nim` (+ `dingbat_test_runner.nim`, `dingbat_bench.nim`) | `nimble test_build` / `bench_build`, always `-d:test_harness` | Nothing graphical: `-d:test_harness` makes `nim.cfg` skip the SDL2/GL link flags entirely (see the comment in `dingbat.nimble`) — that flag is why headless binaries link on machines without SDL dev libs |

`nim.cfg` also sets the perf-critical globals: `threads:off`, `mm:arc`
(component→parent back-refs must be `{.cursor.}` or they leak), `opt:speed`,
and `-mno-outline` on arm64 (Apple clang's machine outliner costs ~15-20% in
the hot loops; +35% fps measured — rationale in `nim.cfg` itself).

## Composition model: `include`, not `import`

`gba/gba.nim` (~1250 ln) and `gb/gb.nim` (~1370 ln) are hubs: each declares
**all** of its core's types in one block, forward-declares the cross-file
procs, then `include`s every implementation file. The annotated include lists
in those two files are the de-facto architecture diagram.

Why it stays this way (not just history): each hub compiles as **one Nim
module → one C translation unit**, so the C compiler inlines across "files"
with plain `-O3` — no LTO flag anywhere in the build. That whole-core
visibility is load-bearing for the measured wins:

- `{.inline.}` hot procs (bus reads, barrel shifter, `mbc_read_rom_lo/hi`)
  inline into callers that live in *other* included files.
- The GB MBC devirtualization (`gb/mbc/mbc.nim`: flat-ROM window cache that
  bypasses `method` dispatch on every instruction fetch) only pays off
  because the fast path inlines into `memory.nim`'s `read_byte`.
- `-mno-outline` recovers straight-line code in the merged hot loops.

Rules that follow: new fields/types go in the hub's type block; new procs go
in the included file; a proc called before its file is included needs a
forward declaration in the hub (with a matching `{.inline.}` pragma if the
definition has one). Never `import` between core-internal files. The verified
hard ordering constraints are commented at the include lists themselves
(`hle_bios` before `arm/arm`+`thumb/thumb`; `arm/arm` before `arm/lut`;
`cb_opcodes` before `opcodes`).

## Directory tour

### `src/dingbat/` (shared)

- `bitfield.nim` — macro mimicking the Crystal bitfield DSL (used by GB regs).

### `src/dingbat/common/` (imported by both cores; real modules, not includes)

- `cheats.nim` — cheat engine (GB GameGenie/GameShark; GBA PARv3/CodeBreaker), core-agnostic.
- `config.nim` — YAML config load/save (keybindings, paths).
- `emu.nim` — tiny `Emu` base class; the frontends drive both cores through its methods.
- `input.nim` — the `Input` button enum.
- `linkproto.nim` — wire format for the network link (transport-agnostic).
- `lut_macros.nim` — `checkBits`/`call`: compile-time bit-pattern decode-table builders behind the ARM LUT (`gba/arm/lut.nim`), the THUMB LUT (`gba/thumb/thumb.nim`) and the GB CB-prefix table (`gb/cb_opcodes.nim`).
- `resampler.nim` — cubic audio resampler.
- `rewind.nim` — bounded ring of zlib-compressed XOR state deltas.
- `scheduler.nim` — the event scheduler both cores run on (shared module, one instance per core).
- `serialize.nim` — hand-rolled little-endian Writer/Reader + `.state` header; `STATE_VERSION` covers the header only, payload changes bump the **per-core** `GBA_PAYLOAD_VERSION`/`GB_PAYLOAD_VERSION` with a migration (rules in its header comment; guarded by `tests/savestate_compat_test.nim`).
- `test_output.nim` — serial/debug capture for `-d:test_harness` builds.
- `timestretch.nim` — WSOLA pitch-preserving fast-forward.
- `util.nim` — hex helpers, `bit`/`bits_range`.

### `src/dingbat/gba/`

Hub `gba.nim`; everything below is included into it (except `link.nim`,
`rollback.nim`, `netcore.nim`, `netlink.nim`, which import `gba`).

- `reg.nim` — I/O register bitfield objects (included first; types use them).
- `pipeline.nim` — 2-deep fetch pipeline.
- `cartridge.nim` — ROM load (pow2-sized buffer), title extraction.
- `storage.nim` + `storage/{sram,flash,eeprom}.nim` — save-type detect + backends.
- `gpio.nim`, `rtc.nim` — cart GPIO and the RTC behind it.
- `interrupts.nim`, `keypad.nim` — IE/IF/IME + input regs.
- `waitloop.nim` — idle-loop detection/fast-forward.
- `hle_bios.nim` — all HLE BIOS SWIs (`hle_swi`), split out of `arm/arm.nim` (c5c450a).
- `arm/arm.nim` — ARM handlers, statically parameterized; `arm/lut.nim` — 4096-entry compile-time dispatch table.
- `thumb/thumb.nim` — THUMB handlers + their 1024-entry LUT.
- `cpu.nim` — registers, modes, stepping, halt.
- `apu/` (channels 1-4 + `dma_channels.nim` FIFO A/B) + `apu.nim` mixer.
- `timer.nim`, `serial.nim`, `dma.nim` — scheduler-driven peripherals.
- `bus.nim` — memory map, waitstates/prefetch, open bus.
- `mp2k.nim`, `gs_bon.nim` — sound-driver HLE shadow mixers (runtime-detected, off by default).
- `ppu.nim` — scanline renderer + compositor.
- `mmio.nim` — 0x04000000 register dispatch.
- `savestate.nim` — per-subsystem serialization visitor.
- `link.nim` — in-process lockstep link (N cores); `rollback.nim` — GGPO-style input-rollback session; `netcore.nim` — transport-independent network-link state machine; `netlink.nim` — its TCP pump.

### `src/dingbat/gb/`

Hub `gb.nim`; `link.nim` and `rollback.nim` import it, the rest are included.

- `mbc/` — mapper base + factory (`mbc.nim`, incl. the flat-ROM fast path) and one file per mapper: `rom`, `mbc1`, `mbc2`, `mbc3` (RTC), `mbc5` (rumble), `mbc6`, `mbc7` (accelerometer/EEPROM), `huc1`, `huc3`, `mmm01`, `camera`, `tama5`.
- `apu/` (channels 1-4) + `apu.nim` mixer.
- `interrupts.nim`, `serial.nim`, `timer.nim`, `joypad.nim` — peripherals.
- `ppu.nim` — shared PPU base; `scanline_ppu.nim` and `fifo_ppu.nim` — the two renderers (frontends pick via `new_gb`'s `fifo` flag).
- `memory.nim` — bus dispatch, OAM DMA/HDMA, I/O regs.
- `cb_opcodes.nim`, `opcodes.nim` — compile-time CB table + the 256 unprefixed handlers; `cpu.nim` — SM83 stepping.
- `savestate.nim`, `link.nim`, `rollback.nim` — as on the GBA side.

### `src/dingbat/frontend/` (native GUI only)

ImGui widgets imported by `src/dingbat.nim`: `file_explorer`, `config_editor`,
`bios_selection`, `keybindings_widget`, `controller_widget`, `cheats_widget`,
`save_states_widget` (9-slot grid with thumbnails), `video_widget`,
`gba_debug`/`gb_debug` (debug windows), `util`.

## Web front-end (`web/`)

Script-tag, no-build architecture: `index.html` loads `glpresent.js`,
`index.js` (~6700 ln, the whole app), `sdputil.js`, `netplay.js`, `em.js` as
plain scripts sharing one global scope — no bundler, no transpile; what's in
the repo is what ships. `embed.html`+`embed.js` is the minimal 2P pane.

- Typecheck gate: `web/types/` runs `tsc --checkJs` over the shipped files
  as-is; `em.d.ts` is **generated** from the `{.exportc.}` procs in
  `src/dingbat_wasm.nim` (`node web/types/gen-emdts.mjs`, CI `--check`s
  staleness); `globals.d.ts` declares cross-file globals by hand.
- `sw.js` — service worker; its `ASSETS` precache list must contain every
  script `index.html` loads (`web/tests/sw-assets.test.mjs` is the tripwire).
- `web/tests/` — node:vm unit suite over the real `index.js` (see
  `web/tests/README.md` and `tests/README.md`).
- `web/signaling/` — room-code rendezvous server (`server.js` + `server.nim`, a protocol-identical low-RSS rewrite for VPS deployment).
- `serve.py` — dev server; must send `same-origin-allow-popups` COOP or
  Google Drive sign-in breaks.
- `web/bench/`, `tools/webbench/` — browser throughput/latency harnesses.

## Tests, tools, docs

- `tests/` — harnesses, committed baselines, homebrew ROMs: **`tests/README.md`**.
- `tools/` — `gbfuzz/` (cross-emulator GB library sweep vs SameBoy/mGBA),
  `romfuzz/` (same for GBA), `webbench/`, `mp2k_*.py`/`pcmdiff.py` (audio HLE
  comparison).
- `docs/` — per-topic deep dives (`performance.md`, `multiplayer.md`,
  `building.md`, `research_*.md`, ...).
- `notes/` — working notes (`todo.md`, `progress.md`, this file).
- `docker/`, `ci/`, `.github/workflows/` — Windows cross-build, CI: the test
  matrix lives in `.github/workflows/test.yml`.
