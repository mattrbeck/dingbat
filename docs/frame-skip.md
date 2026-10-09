# Frame skip: frames nobody sees are not drawn

Status: prototype on branch `frame-skip`, for Matt to try. Not on main.

## Trying it

- **Web**: serve `web/` from this branch (build `em.wasm` first:
  `nim c -d:emscripten src/dingbat_wasm.nim`). Skipping is on; open the page
  with `?draw=all` to draw every frame and compare. Fast-forward's log line
  (every ~5 s of it, in the console) ends with how many frames went undrawn.
- **iOS**: `ios/build-core.sh && (cd ios && xcodegen generate)`, then build.
  Settings › Emulation › Advanced › **Draw every frame** turns it off.
- What to look for: fast-forward fps (the counter), battery and heat at 2x
  or with run-ahead, and any picture that looks a frame behind or wrong
  after fast-forward, rewind, a clip, a state load or pausing.
- `node web/e2e/frame-skip-probe.mjs <game.gba> [warmup]` (from `web/`)
  measures fast-forward, 2x and run-ahead both ways in headless Chromium.

## Why

A frontend shows at most one picture per display refresh. Whenever it runs
more than one emulated frame in a refresh, every frame but the last is drawn
and thrown away:

- fast-forward (uncapped): N frames per refresh, one shown;
- 2x on a 60 Hz display: two per refresh;
- normal speed on a display slower than the game (Safari in iPhone Low
  Power Mode refreshes at 30 Hz): two per refresh;
- run-ahead: the canonical frame and every lookahead frame but the last.

Drawing (the GBA PPU's `scanline`) is about 30% of a GBA frame on real
gameplay (stubbing it out is +44%, docs/research_ppu_hotspots.md), and the
existing whole-frame render skip never fires in gameplay.

## How

Core: `ppu.no_draw` (gba.nim): set by the frontend between frames for a frame it
will not show. `scanline` returns at once. A frame that changed marks the
next one dirty, so it is drawn whole; one that changed nothing leaves the
framebuffer holding the picture, as the existing render skip does (without
that, a mostly static scene drew more than before: -3% at 1 in 2). It is never serialized: drawing changes no
emulated state (the OAM and line latches live in `latch_oam` and
`latch_line_start`, outside `scanline`), so a skipped frame runs exactly as a
drawn one. Two things only drawing writes do go stale in a skipped frame:
the framebuffer itself (also saved in a state) and the mosaic's latched
affine point (latched again on line 0 of every drawn frame).

GBA only: the GB PPU draws as part of its timing. Off while the LCD response
is on (its panel model takes every frame).

Frontends: `wasm_unseen_next` / `dingbat_unseen_next` mark the next frame
(loop_tick / runahead_tick, dingbat_run_frame / _ahead) as one the tick will
not show. The core then leaves it undrawn unless its picture is kept: the
frame before a rewind snapshot (`Rewind.push_due`) or a clip anchor (whose
thumbnail is the previous frame's). An unseen frame with run-ahead runs no
lookahead at all (GB too); with run-ahead the canonical frame is never drawn,
only the last lookahead frame. The tick loops mark every frame but the last
at 1x/2x/slow (the count is known up front), and at fast-forward each frame
after which another is predicted to fit (running mean of a frame's time);
a wrong guess shows a frame or two back, never a broken one. Link, rollback,
2P, clip replay and frame advance draw every frame as before.

## Proof

`tests/render_skip_test.nim`: on every ROM a third machine skips drawing
runs of up to six frames; after every frame its state must equal a machine
that draws everything (but the two fields above), and every frame it draws
must match. Passes on all of tests/roms plus FireRed and LeafGreen for 1500
frames from boot (`DINGBAT_RENDER_SKIP_ROMS`, `DINGBAT_RENDER_SKIP_FRAMES`).

## Measured (core alone)

`tests/dingbat_bench.nim` with `DINGBAT_BENCH_DRAW_EVERY=n`, 600 frames,
best of 5, interleaved; Apple M-series, native release build. Moving scenes
from boot at the given warmup; FireRed at the Pokémon Center counter (65% of
its frames static) as the case the render skip already covers.

| scene | all drawn | 1 in 2 | 1 in 4 | 1 in 40 |
|---|---|---|---|---|
| Kirby NiDL (600) | 1932 fps | +21% | +36% | +50% |
| Metroid Fusion (600) | 2348 | +23% | +36% | +55% |
| Super Mario World (1500) | 1156 | +21% | +36% | +51% |
| Emerald (1500) | 1124 | +22% | +37% | +54% |
| Advance Wars (1200) | 757 | +9% | +14% | +20% |
| FireRed counter (state) | 1382 | +0% | +5% | +8% |

1 in 2 is 2x on a 60 Hz display or 1x on a 30 Hz one; 1 in 40 is about
fast-forward. Most of Advance Wars' frame time is outside drawing here.

## Measured (in the frontends)

- Headless Chromium, Super Mario World attract, `frame-skip-probe.mjs`,
  best of 2: fast-forward 231 fps vs 180 with `?draw=all` (+28%); 2x 107 ms
  of emulation per second vs 130 (-17%); run-ahead 2: 97 vs 155 ms (-38%).
- iOS simulator (Debug app, release core), same scene at fast-forward:
  392-426 fps vs 343-355 drawing every frame. LeafGreen `-present-check`: 0
  stale refreshes of 1230.

## Progress

- [x] core flag + test (all tests/roms + FR, LG, Kirby, Metroid, Emerald,
      Advance Wars, Golden Sun for 2000 frames)
- [x] bench `DINGBAT_BENCH_DRAW_EVERY`, numbers above
- [x] web: tick loops (normal/2x/slow, fast-forward), run-ahead in wasm
- [x] iOS: GameSession tick, dingbat_run_frame_ahead; ios_api_test case
- [x] A/B switch for testing (web `?draw=all`, iOS Advanced setting)
- [x] measurements (above); web tests speed-hold, rewind-toggle,
      rewind-doubletap, clip-range, run-pause, wasm-exports, lcd-response,
      gb-palette, game-delete, render pass; tsc + em.d.ts check clean; iOS
      device Release build compiles
- [ ] Matt's test at home (web on his devices, iOS on the phone)
- [ ] if kept: drop the switches or keep `?draw=all` as a diagnostic; the
      iOS setting is a prototype toggle
