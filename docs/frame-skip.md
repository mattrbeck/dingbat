# Frame skip: frames nobody sees are not drawn

Status: prototype on branch `frame-skip`, for Matt to try. Not on main.

## Trying it

- **Web**: serve `web/` from this branch (build `em.wasm` first:
  `nim c -d:emscripten src/dingbat_wasm.nim`). Skipping is on; open the page
  with `?draw=all` to draw every frame and compare. Fast-forward's log line
  (every ~5 s of it, in the console) ends with how many frames went undrawn.
- **iOS**: `ios/build-core.sh && (cd ios && xcodegen generate)`, then build.
  Settings › Emulation › Advanced › **Draw every frame** turns it off;
  **Start frames late** (off by default) tries the lower-latency pacing.
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
| desktop fast-forward (uncapped) | it presents once per display interval: the frames before are run undrawn in a batch, then one drawn, then the present; the batch stops at once for a pending key, button, click or quit, so input is read after every frame as before |
| desktop turbo (2x, paced by the audio queue) | no batching: a frame run undrawn would pull the drawn one after it ahead of the queue (a two-frame jump, input read up to a frame early) |
| 120 Hz screens | at 1x a tick runs at most one frame: nothing to skip, nothing changes |
| 2P (local link), lockstep netlink, clip replay, frame advance | draw every frame as before |
| link desync dumps compared across peers (`rollback_dump_size`, iOS LINKDUMP, the link e2e tests) | each peer draws only its own core, so the dump blanks the picture and the mosaic latch (`peer_state_bytes`); web/e2e/link-rom-skip passes |
| the A/B switch (`?draw=all`, Draw every frame) | one core switch (`wasm_set_draw_all` / `dingbat_set_draw_all`): also rollback, Add pictures and the clip pre-roll |
| Add pictures (web, iOS): ~600 frames a game for one picture | each 30-frame chunk draws only its last (a deadline can end the run between chunks) |
| a clip's silent pre-roll | only its last frame, the one presented, is drawn |
| desktop input log (playtest recordings) | no batching under it: its every-60-frames hash reads the previous frame's picture |
| desktop turbo/fast-forward: a changed frame left unpresented, then a static one presented | the texture is uploaded if any frame changed since the last upload (on main too; iOS had it fixed in dc1b85d0) |
| playtest driver `run N` | draws only the last frame, the one read (hashes and shots unchanged) |
| the SGB or the LCD response refusing a skip | `*_unseen_next` returns whether the frame will really go undrawn, so fast-forward's timing and the log count only real skips |
| input latency at 30 Hz | the skip adds none; iOS can now run a refresh's frames late (Start frames late, below); the web cannot (the picture must be handed over inside the refresh callback) |

Not done (each draws every frame, as before): rollback's ticks per refresh
(1-2 at 1x, up to 4 at 2x, each also converted to RGBA), local 2P (both
cores shown, up to 4 frames per refresh at 2x on iOS) and the lockstep
netlink's catch-up. A stall can end any of them early, so the last frame is
not known up front; rollback's stall test could be asked before each tick.

## Start frames late (iOS, prototype, off by default)

Settings › Emulation › Advanced. The display link wakes the app right after
a refresh; normally the app runs the frames it owes at once and hands the
picture over, and the system shows it at the next refresh. Everything
pressed after that moment waits for the following run, so a press is read on
average half a refresh after it happens and shown a whole refresh after it is
read: about 1.5 refreshes, ~25 ms at 60 Hz and ~50 ms at 30 Hz (Low Power
Mode), before the game's own frames of delay.

With it on, the app waits until just before the next refresh, the run's
expected time (`lateFrame`, a running mean per frame, times the frames
owed) plus `lateMargin` (time for the GPU and the compositor) ahead of it,
and runs then, on a strict timer with no leeway (a coalesced timer would
eat the margin). Input is read later in the
same refresh, so it reaches the screen up to most of a refresh sooner: ~10 ms
at 60 Hz, ~25 ms at 30 Hz. The frames, their count and the audio are the
same; only when they run moves.

The risk is missing the refresh: if the run, the GPU or the compositor runs
long, the picture lands a refresh late (a hitch, and that frame later than
without the setting). So the margin learns, aiming for misses well under 1
in 500: a picture the system reports shown after its refresh or never (on a
device; in the simulator, the GPU finishing within 1 ms of it), or a late run
not started by the next refresh, widens it by 3 ms; a run that merely ends
within 2 ms of its refresh, by 1 (up to 12); only 120 on time in a row
narrow it, by 0.5 ms (down to 3). It runs at once, as without the setting:
when nothing is owed (a 120 Hz screen at 1x, every other refresh), after a
hitch (a catch-up owes more than a refresh's frames and has no time to
lose), when the wait would be under 1 ms, at fast-forward (it fills the
whole interval anyway), and in link play or 2P (their pacing is the link's).
If a late run has not started when the next refresh's callback arrives (the
main thread was busy), that callback cancels it, counts a miss and runs its
frames itself, so a refresh is never skipped waiting for it.

Not yet known: whether the on-screen buttons gain at all. UIKit may deliver
touches once per refresh, just before the display link's callback; if so a
run at the start of a refresh already sees every touch a late one would.
Controllers and keyboards deliver as they happen and do gain. The phone
test (or a high-speed camera) decides.

Simulator, tonc m7_demo, 40 presses, press to the refresh its picture is
aimed at, average: at 30 Hz 30.4 / 28.0 ms off against 14.7 / 15.6 ms on,
with 2 and 4 misses in 542 and 495 late runs (the margin settled at 9-11.5
ms on the simulator's jittery timing; the first controller, which settled
near 5% misses, measured 9.2 / 9.4). At 60 Hz the simulator's display link
calls back about 0.5 ms after its own target refresh, so late start rightly
never arms there (and earlier 60 Hz numbers were noise). The simulator has
no presented-time API and approximate refresh timing: the phone decides
whether it ships.

## Where else it could apply (survey, not done)

An agent surveyed every place frames run unseen; ranked by value against
risk:

- Developer tools that read a few frames of thousands (romfuzz and gbfuzz
  nav, filtershot, gbprobe shots, mp2k sweep and probe, audio dumps,
  trade_repro, the bench warmups): ~20% GBA, 5-14% GB, no product risk.
  Final pictures identical on 3524 gambatte, 986 other GB, 244 GBA test
  ROMs and 20 library titles. Keep drawing: the bench's per-frame hash
  (the library A/B sweep), playtest runhash/stable, bootsweep, inputsweep,
  state_soak and statefuzz (they exist to exercise drawing code).
- tests/dingbat_test.nim modes that never read the picture (GB serial,
  sram, mooneye, microtest; gambatte's 15 frames; GBA mgba/jsmolka): ~10-12%
  of GB rows. Catches: `--screen-check` must draw the verdict frame; GB
  screenshot mode ends early on `LD B,B`, so it keeps drawing.
- Local 2P: the last frame of a tick is known up front (a link step always
  completes a frame); ~20% of both cores, only at iOS 2x or 30 Hz.
- Rollback ticks per refresh: nothing feeds the session between two ticks
  of one refresh, so whether the next tick will stall is exactly
  predictable from the buffered remote inputs; worth 5-9% of rollback CPU
  at 2x or 30 Hz only.
- DS: `render_line` could skip the 2D engines when no capture uses them
  (5-10%); skipping the 3D rasteriser changes game-readable state
  (RDLINES_COUNT, underflow), so only for fast-forward and run-ahead.
- Not worth it: lockstep netlink catch-up (a frame can park mid-frame on
  the peer), run-ahead's canonical frame (rewind, states and thumbnails
  read it).

## Proof

`tests/render_skip_test.nim` (CI): on every ROM a machine that skips drawing
runs of up to six frames must, after every frame, hold the same state as one
that draws everything (but the framebuffer and the GBA mosaic latch), and
every frame it draws must match; its rewind snapshots, taken only on drawn
frames, must each hold their own frame's picture at the age `frames_back`
gives. GBA test ROMs and the GB ones in CI; locally also FireRed, LeafGreen,
Kirby, Metroid, Emerald, Advance Wars, Golden Sun (2000 frames) and Crystal,
Blue, Link's Awakening DX (1500). Synthetic: a raster effect (a palette
change mid-frame every frame) across undrawn frames; the redraw after an
undrawn changed frame. `ios_api_test`: unseen frames show the same pictures
and end on the same machine, with run-ahead too; the online-link 6-frame
rollback replay (now drawing only the shown frames) stays bit-identical.

## Performance review (instructions, vs main)

The machine was under heavy load from other jobs (load average 270-650), so
wall-clock numbers this round are noise; these are CPU instruction counts
(`DINGBAT_BENCH_COUNTERS=1`, repeatable to ~0.2%), branch against main built
the same way, 600 frames, best of 3.

| scene | every frame drawn | 1 in 2 | 1 in 4 | 1 in 40 |
|---|---|---|---|---|
| Kirby NiDL | -0.1% | -18.7% | -28.0% | -36.2% |
| Metroid Fusion | -0.1% | -20.3% | -30.9% | -40.2% |
| Super Mario World | -0.3% | -20.1% | -29.9% | -38.9% |
| Emerald | -0.1% | -20.1% | -30.2% | -39.2% |
| Advance Wars | +0.2% | -8.8% | -14.0% | -18.5% |
| Pokémon Crystal (GBC) | -0.1% | -5.0% | | -9.6% |
| Pokémon Blue (GB) | +0.1% | -7.3% | | -14.3% |
| Link's Awakening DX (GBC) | -0.1% | -4.8% | | -9.2% |

Every frame drawn costs nothing. The first GB version checked `no_draw` per
pixel (+0.3-0.5% on drawn frames); undrawn frames now take their own copy of
the span path. GB drawing is a smaller share of a frame than GBA's, so its
gain is smaller. Rewind snapshots on drawn frames only: forced draws had cost
~5% of fast-forward, and the snapshots themselves another 2-9%.

iOS late start, simulator (loaded machine), tonc m7_demo, 30 presses, press
to the refresh its picture lands on, two rounds each: at 30 Hz 23.7 / 29.6 ms
average off, 9.2 / 9.4 ms on; at 60 Hz inconclusive (15.1 / 9.2 off, 8.9 /
10.5 on), with the first margin controller (round 5 numbers under Start frames late). The simulator's refresh timing is approximate (some readings come
out negative); a device decides it.

## Measured (core alone, first prototype, quiet machine)

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

## Measured (in the frontends, first prototype, quiet machine)

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
- [x] edge-case mitigations (table above), GB, rollback, desktop, iOS late
      start; perf review (instructions); all tests above, web tests, tsc,
      desktop and iOS builds
- [ ] Matt's test at home (web on his devices, iOS on the phone): fast-
      forward, 2x, run-ahead, link play, Low Power Mode with late start
- [x] round 4 (independent review): link dumps, the one A/B switch, Add
      pictures, clip pre-roll, desktop input log and stale texture, late
      start on real present times, playtest driver; tools/ci_local.py 32/32,
      web link-rom-skip e2e 4/4, the browser tests, tsc
- [x] the playtest train (79ea2262 on origin/main dc1b85d0): CLEAN — none
      of the 140 games differs from the baseline in any hash (checkpoint
      frames, audio, battery files, load cells) in any of the four dingbat
      configurations; the corpus played in 25.7 min against the baseline's
      27.5 (the driver's `run N` now draws only its last frame)
- [x] round 5 (adversarial latency review): late start's margin settled
      near 5% misses (now aims under 0.2%), a catch-up tick started late,
      a slipped late run swallowed the next refresh and counted as on time,
      timer leeway, the work estimate (now per frame, from every tick);
      desktop turbo no longer batches, desktop fast-forward reads input
      after every frame again; `*_unseen_next` marks only frames that
      really go undrawn. iOS link e2e 6/6 and the FireRed/LeafGreen trade
      e2e (2% loss) pass with native and wasm states identical
- [ ] desktop: compiled, not run here (driving the GUI needs asking)
- [ ] if kept: drop the switches or keep `?draw=all` as a diagnostic; the
      iOS setting is a prototype toggle
