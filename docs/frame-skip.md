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

Core: `ppu.no_draw` (gba.nim, and on the GB's PPU in gb.nim), set by the
frontend between frames for a frame it will not show. The GBA's `scanline`
returns at once; the GB's FIFO runs every fetch, shift and timing step but
mixes and stores no pixel. A GBA frame that changed marks the next one dirty,
so it is drawn whole; one that changed nothing leaves the framebuffer holding
the picture, as the existing render skip does (without that, a mostly static
scene drew more than before: -3% at 1 in 2). The flag is never serialized:
drawing changes no emulated state (the GBA's OAM and line latches live in
`latch_oam` and `latch_line_start`, outside `scanline`; its contention model
reads only registers, OAM and line timing), so a skipped frame runs exactly
as a drawn one. Two things only drawing writes go stale in a skipped frame:
the framebuffer itself (also saved in a state) and the GBA mosaic's latched
affine point (latched again on line 0 of every drawn frame).

Frontends: `wasm_unseen_next(ff)` / `dingbat_unseen_next(ff)` mark the next
frame (loop_tick / runahead_tick, dingbat_run_frame / _ahead) as one the tick
will not show. The tick loops never mark a tick's last frame, so **after
every tick the core holds that tick's own picture**, whatever reads it next
(screenshots, recordings, save states and their thumbnails, the library
picture, a pause). An unseen frame runs no run-ahead lookahead and does not
step the LCD panel. Desktop batches the same way in its unpaced modes.

## Edge cases, and what handles each

| case | handling |
|---|---|
| fast-forward guesses which frame is a tick's last | a frame goes undrawn only with room after it for a drawn one (running means of each kind); a tick never ends on an undrawn frame |
| pausing, a state saved or a screenshot right after fast-forward | the invariant above: the core always holds the last frame's picture |
| run-ahead's canonical frame | drawn (only the hidden lookahead frames are not): the picture states, recordings and thumbnails read |
| rewind snapshots and clip anchors keep a picture | one due on an undrawn frame waits for the next drawn one; `Rewind.frames_back` stamps each snapshot's frame so the scrubber's ages stay exact; no forced draws (they cost ~5% of fast-forward) |
| raster effects (mid-frame register changes) | each drawn frame is built line by line from its own registers; test below |
| LCD response | its panel steps per shown picture; skips at fast-forward, but at 1x/2x every frame is drawn (it is what blends a sprite drawn on alternate frames, which 2x on a 60 Hz screen would otherwise drop) |
| Game Boy / Game Boy Color | skipped too (`no_draw` on the FIFO PPU), except under the Super Game Boy, whose freeze copies the picture |
| online link (rollback) | only this peer's core is shown: the friend's core never draws, nor do replayed frames but the newest (`drawOnlyShown`; peers never exchange state checksums, which tests alone compare) |
| desktop fast-forward / turbo | it presents once per display interval: the frames before are run undrawn in a batch, then one drawn, then the present |
| 120 Hz screens | at 1x a tick runs at most one frame: nothing to skip, nothing changes |
| 2P (local link), lockstep netlink, clip replay, frame advance | draw every frame as before |
| input latency at 30 Hz | the skip adds none; iOS can now run a refresh's frames late (Settings › Advanced › Start frames late, a prototype), reading input most of a refresh later; the web cannot (the picture must be handed over inside the refresh callback) |

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
