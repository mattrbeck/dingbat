# Architecture

A map, not an essay. Trust the tree over this file.

## Build targets

| Target | Entry | Build | Links |
|---|---|---|---|
| Native GUI | `src/dingbat.nim` | `nim c -d:release src/dingbat.nim` | SDL2 + OpenGL + Dear ImGui (imguin); per-OS link flags in `nim.cfg` (`-d:macdist` static on macOS, `-lGL` on Linux, static mingw on Windows) |
| Browser (wasm) | `src/dingbat_wasm.nim` | `nimble wasm` (`-d:emscripten`; flags in `src/dingbat_wasm.nims`) | Emscripten + `USE_SDL=2`; emits `web/em.js` + `web/em.wasm`; the exported `_wasm_*`/`_link_*`/`_rollback_*`/`_netlink_*` C ABI is what `web/index.js` calls (typed by the generated `web/types/em.d.ts`) |
| iOS | `src/dingbat_ios.nim` + `src/dingbat_ios_audio.c` | `ios/build-core.sh` → static libs in `ios/lib/` | No SDL; Swift shell in `ios/Dingbat/`, header `ios/include/dingbat.h` |
| Test harness | `tests/dingbat_test.nim` (+ `dingbat_test_runner.nim`, `dingbat_bench.nim`) | `nimble test_build` / `bench_build`, always `-d:test_harness` | `-d:test_harness` makes `nim.cfg` skip the SDL2/GL link flags, which is why headless binaries link on machines without SDL |

`nim.cfg` sets the perf-critical globals: `threads:off`, `mm:arc` (component→parent
back-refs must be `{.cursor.}` or they leak), `opt:speed`, `-mno-outline` on arm64
(rationale in `nim.cfg`).

## Composition model: `include`, not `import`

`gba/gba.nim` and `gb/gb.nim` are hubs: each declares all of its core's types in one
block, forward-declares cross-file procs, then `include`s every implementation file. Each
hub is one Nim module and one C translation unit, so the C compiler inlines across files
at plain `-O3` with no LTO. The `{.inline.}` hot procs (bus reads, barrel shifter,
`mbc_read_rom_lo/hi`) and the GB MBC flat-ROM fast path depend on that.

Rules: new fields go in the hub's type block; new procs in the included file; a proc
called before its file is included needs a forward declaration in the hub with the same
pragmas as the definition. Never `import` between core-internal files. Ordering
constraints are commented at the include lists (`hle_bios` before `arm/arm` + `thumb/thumb`;
`arm/arm` before `arm/lut`; `cb_opcodes` before `opcodes`).

## Directory map

`src/dingbat/common/` (real modules, imported by both cores): `cheats.nim`, `config.nim`
(YAML), `emu.nim` (the `Emu` base the front-ends drive), `input.nim`, `linkproto.nim`
(network wire format), `lut_macros.nim` (compile-time decode tables for the ARM/THUMB LUTs
and the GB CB table), `resampler.nim`, `rewind.nim` (ring of zlib-compressed XOR deltas),
`scheduler.nim` (one instance per core), `serialize.nim` (`.state` header; payload changes
bump the per-core `GBA_PAYLOAD_VERSION`/`GB_PAYLOAD_VERSION` with a migration, guarded by
`tests/savestate_compat_test.nim`), `test_output.nim`, `timestretch.nim` (WSOLA),
`util.nim`.

`src/dingbat/gba/` (hub `gba.nim`; `link`, `rollback`, `netcore`, `netlink` import it):
`reg.nim` (included first), `pipeline`, `cartridge`, `storage` + `storage/{sram,flash,eeprom}`,
`gpio`, `rtc`, `interrupts`, `keypad`, `waitloop`, `hle_bios`, `arm/arm` + `arm/lut`,
`thumb/thumb`, `cpu`, `apu/` + `apu`, `timer`, `serial`, `dma`, `bus`, `mp2k` / `gs_bon`
(sound-driver HLE shadow mixers), `ppu`, `mmio`, `savestate`. The annotated include list
in the hub is the diagram.

`src/dingbat/gb/` (hub `gb.nim`; `link` and `rollback` import it): `mbc/` (one file per
mapper), `apu/` + `apu`, `interrupts`, `serial`, `timer`, `joypad`, `sgb`, `ppu` (shared
base), `scanline_ppu`, `fifo_ppu`, `memory`, `cb_opcodes`, `opcodes`, `cpu`, `savestate`.

`src/dingbat/frontend/`: the native GUI's ImGui widgets.

## Web front-end (`web/`)

Script-tag, no-build: `index.html` loads `glpresent.js`, `index.js` (the whole app),
`sdputil.js`, `netplay.js`, `em.js` as plain scripts in one global scope. `embed.html` +
`embed.js` is the 2P pane.

- `web/types/`: `tsc --checkJs` over the shipped files; `em.d.ts` is generated from the
  `{.exportc.}` procs in `src/dingbat_wasm.nim` (`node web/types/gen-emdts.mjs`, CI checks
  staleness); `globals.d.ts` is hand-written.
- `sw.js`: its `ASSETS` precache list must name every script `index.html` loads
  (`web/tests/sw-assets.test.mjs` is the tripwire).
- `web/tests/`: node:vm unit suite over the real `index.js` (`web/tests/README.md`).
- `web/signaling/`: room-code rendezvous (`server.js`, and `server.nim` for VPS deployment).
- `serve.py`: dev server; must send `same-origin-allow-popups` COOP or Drive sign-in breaks.
- `web/bench/`: browser throughput bench.

## Tests, tools, docs

- `tests/` — harnesses, committed baselines, homebrew ROMs: `tests/README.md`.
- `tools/` — `gbfuzz/`, `romfuzz/` (cross-emulator library sweeps), `gbgate/`, `gbdiff/`,
  `gbppu/`, `gbapu/`, `gbprobe/`, `gbphoto/`, `nbadiff/`, `mp2k_*.py` / `pcmdiff.py`.
- `docs/` — usage, building, multiplayer, performance, hardware-probe catalog, Pan Docs
  disagreement list, per-suite triage. `docker/`, `.github/workflows/` — cross-build, CI.
