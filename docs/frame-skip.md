# Frame skip: frames nobody sees are not drawn

Status: prototype, for Matt to try. Not on main. Branch `frame-skip-2` is
`frame-skip` rebased onto main b98294aa (2026-10-12) without iOS's Start
frames late; its fresh measurements are in **Rebased onto main b98294aa**
below, and the older sections describe the original branch.

## Trying it

- **Web**: serve `web/` from this branch (build `em.wasm` first:
  `nim c -d:emscripten src/dingbat_wasm.nim`). Skipping is on; open the page
  with `?draw=all` to draw every frame and compare. Fast-forward's log line
  (every ~5 s of it, in the console) ends with how many frames went undrawn.
- **iOS**: `ios/build-core.sh && (cd ios && xcodegen generate)`, then build.
  Settings › Emulation › Advanced › **Draw every frame** turns it off.
- **Desktop**: fast-forward (Tab) batches undrawn frames before each
  present; `DINGBAT_DRAW_ALL=1` turns that off, `DINGBAT_FPS_LOG=1` prints
  the frames run each second.
- What to look for: fast-forward fps (the counter), battery and heat at 2x
  or with run-ahead, and any picture that looks a frame behind or wrong
  after fast-forward, rewind, a clip, a state load or pausing.
- `node web/e2e/frame-skip-probe.mjs <game> [warmup]` (from `web/`)
  measures fast-forward, 1x, 2x and run-ahead 1 and 2 both ways (GPU=1,
  ENGINE=webkit, STATE=, WALK=, HOLD=: see its header).

## Rebased onto main b98294aa (2026-10-12)

Branch `frame-skip-2`: `frame-skip` (e62140e0) replayed onto main b98294aa.
Left out: iOS's Start frames late and its DEBUG pieces (the late-start
controller, GameRenderer's presented-time reporting, `-display-30`, the
cooldown and `-pacing-test`), and the branch's web jitter commits (main has
its own `web/framegrid.js`, 6f10bccc; only pacing-probe's comma-separated
ONLY= came across). Reconciled: the desktop stale texture (main's
`gba_changed_unuploaded` / `note_gba_frame`, a14908b1, kept; the branch's
copy dropped); the desktop batch on SDL 3 (main's loop and scheduler kept,
turbo does not batch, the batch's pending-input check names SDL 3's event
types and leaves out the controller update-complete and sensor events a
connected pad sends every poll); the DS (never marked unseen, run-ahead
and clips as main has them). New: the draw-all switch also draws
run-ahead's lookahead frames (it did not, so an A/B of run-ahead compared
skipping with skipping), desktop `DINGBAT_DRAW_ALL` / `DINGBAT_FPS_LOG`,
bench `DINGBAT_BENCH_RUNAHEAD`, and the web probe's scenes and A/B slices.

Every number below is one binary with the skip on against the same binary
drawing every frame, at the same commit; Apple M-series, load average 3-5.

### Core: host instructions per emulated frame

`dingbat_bench`, `DINGBAT_BENCH_COUNTERS=1`, 600 frames, minimum of 5 runs
interleaved, `DINGBAT_BENCH_DRAW_EVERY=n` (frames drawn 1 in n). Static:
the share of frames main's whole-frame render skip already leaves undrawn
(`frame_static`, every frame drawn). Scenes from save states, with input:

| scene | M instr/frame, all drawn | static | 1 in 2 | 1 in 4 | 1 in 8 | 1 in 40 |
|---|---|---|---|---|---|---|
| Emerald, walking in Littleroot | 13.15 | 2% | -13.1% | -19.7% | -23.0% | -25.7% |
| FireRed, walking in a Pokémon Center | 14.26 | 7% | -11.5% | -17.7% | -21.0% | -23.6% |
| FireRed, start menu open (static) | 11.23 | 64% | -5.2% | -5.6% | -7.2% | -10.3% |
| F-Zero Maximum Velocity, racing (mode 7) | 21.37 | 0% | -22.0% | -32.1% | -37.2% | -41.3% |
| Metroid Fusion, intro (scrolling) | 7.89 | 1% | -19.6% | -29.7% | -34.8% | -38.8% |
| Kirby NiDL, story text | 5.27 | 88% | -0.3% | -5.7% | -8.4% | -10.4% |
| Pokémon Blue (GB), walking | 4.88 | | -6.7% | -10.0% | -11.7% | -13.0% |
| Pokémon Silver (GBC), walking | 6.94 | | -3.8% | -5.8% | -6.7% | -7.5% |

1 in 2 is 2x on a 60 Hz display (or 1x at 30 Hz); fast-forward is near
1 in 8 to 1 in 40 but with rewind on draws at least 1 frame in 10 (the
rewind-due frame). Main's render skip covers what is static; the gain left
is in moving scenes. GB/GBC gain less (drawing is a smaller share of a
frame, and the FIFO's timing work runs undrawn too). The wasm core under
Node (V8, wall clock, best of 5, ±5%) gains less than native: Emerald
+8/+13/+18% frames a second at 1 in 2/4/40, F-Zero +15/+22/+32%, Blue and
Silver +2 to +6%.

### Fast-forward (uncapped), frames a second

| scene | desktop | Chromium (GPU) | WebKit | iOS simulator |
|---|---|---|---|---|
| Emerald walking | 1338 vs 1103 (+21%) | 896 vs 802 (+12%) | 1095 vs 928 (+18%) | 300 vs 276 (+9%) |
| FireRed walking | 1250 vs 1044 (+20%) | 832 vs 738 (+13%) | 1005 vs 852 (+18%) | |
| FireRed menu | 1404 vs 1316 (+7%) | 922 vs 890 (+4%) | 1152 vs 1109 (+4%) | 302 vs 260 (+16%) |
| F-Zero racing | 1385 vs 871 (+59%) | 690 vs 572 (+21%) | 818 vs 637 (+29%) | 199 vs 178 (+12%) |
| Metroid intro | 1040 vs 858 (+21%) | 1483 vs 1255 (+18%) | 1648 vs 1329 (+24%) | |
| Kirby text | 2753 vs 2554 (+8%) | 1948 vs 1813 (+7%) | 2327 vs 2064 (+13%) | |
| Blue walking | 3716 vs 3440 (+8%) | 3526 vs 3307 (+7%) | 3825 vs 3597 (+6%) | 743 vs 654 (+14%) |
| Silver walking | 2328 vs 2225 (+5%) | 2212 vs 2132 (+4%) | 2295 vs 2208 (+4%) | |

- Desktop: the app hidden (GUI driver), scratch HOME, muted, Tab
  fast-forward from the state, `DINGBAT_FPS_LOG`, median of 3 runs of 8 s
  per arm, `DINGBAT_DRAW_ALL=1` the other arm. (F-Zero's race ends within
  the 8 s at fast-forward; the rest of the run is the crash replay, still
  mode 7.)
- Web: `web/e2e/frame-skip-probe.mjs` with `AB=1`: both arms in one page in
  alternating 1 s slices from the state (separate headless pages differ by
  ±15% at 1x, where nothing is skipped), 2 pages x 4 slices per arm.
  Chromium headless with `--use-angle=metal --enable-gpu`; WebKit
  Playwright headless. 83-88% of fast-forward frames went undrawn (a tick's
  last frame and every rewind-due frame are drawn).
- iOS: simulator (iPhone 17, iOS 26.2), Debug app with the release core,
  a local bench hook (not committed) loading the state and setting the
  speed, `-drawAll YES` the other arm, mean of 2 runs of 10 s. The
  simulator's fast-forward is far below the desktop's (its budget per
  refresh and the simulator's own costs), so the share saved is smaller.

### 2x and 1x

Emulation share of one core at 2x (120 frames a second), skip vs draw-all:

| scene | native core (instructions x native time) | wasm, Node | Chromium (measured) | WebKit (measured) | iOS simulator, whole app |
|---|---|---|---|---|---|
| Emerald walking | 8.3% vs 9.5% | 12.0% vs 12.9% | 24.2% vs 23.8% | 18.9% vs 20.3% | 40.2% vs 39.1% |
| F-Zero racing | 11.9% vs 15.3% | 15.7% vs 18.0% | 23.5% vs 26.3% | 20.7% vs 22.2% | 43.6% vs 46.6% |
| FireRed menu | 7.8% vs 8.2% | 11.3% vs 11.7% | 23.3% vs 23.3% | 17.4% vs 18.2% | 38.5% vs 33.9% |
| Blue walking | 2.9% vs 3.1% | 3.4% vs 3.5% | 8.2% vs 8.6% | 8.5% vs 8.5% | 36.5% vs 37.9% |

The browsers' and the simulator's own clocks are noisier than the effect
(the 1x control, where nothing is skipped, read -7% to +7% in Chromium);
the instruction counts are the reliable column. In the simulator the app's
own work (Metal, SwiftUI) is most of a core either way.

At 1x nothing is marked: 0% of frames undrawn in every web run at 1x, and
the iOS and web loops mark only frames before a tick's last. Chromium's
1x A/B read -7% to +7% (noise around 0); the pacing probe's frames per
callback match main's (below).

### Run-ahead

Per emulated frame, `DINGBAT_BENCH_RUNAHEAD=n` (the frontends' sequence:
the frame, a snapshot, n silent lookahead frames, the restore), M host
instructions, minimum of 5:

| scene | no run-ahead | run-ahead 1 (skip = all) | run-ahead 2, skip vs all |
|---|---|---|---|
| Emerald walking | 13.15 | 26.54 | 35.88 vs 39.34 (-8.8%) |
| FireRed walking | 14.27 | 29.01 | 39.60 vs 42.97 (-7.8%) |
| FireRed menu | 11.23 | 24.89 | 34.84 vs 35.76 (-2.6%) |
| F-Zero racing | 21.37 | 42.77 | 54.73 vs 63.76 (-14.2%) |
| Metroid intro | 7.89 | 15.88 | 20.32 vs 23.41 (-13.2%) |
| Kirby text | 5.27 | 15.24 | 20.13 vs 20.15 (-0.1%) |
| Blue walking | 4.88 | 9.86 | 13.96 vs 14.61 (-4.4%) |
| Silver walking | 6.94 | 13.97 | 20.24 vs 20.78 (-2.6%) |

Run-ahead 1 gains nothing: its canonical frame is drawn (states,
thumbnails and the library picture read it) and its one lookahead frame is
the one shown. In the browsers run-ahead 2 read -1% to -10% of emulation
time (WebKit), -1% to -4% (Chromium), noise-level; iOS simulator 0-3%.

### Cadence (pacing probe, against main's build)

`web/e2e/pacing-probe.mjs`, virtual clock, Emerald, main b98294aa's web
build against this one and `?draw=all`. Frames per callback match main's
in every configuration run (30, 48, 50, 60 and 60 Hz with 2 ms jitter;
1x, 2x, run-ahead 2; 17 of the 52 in the `virt` set, the rest cut for
time): the skip changes no cadence on a fast machine. On the virtual
clock, fast-forward's frame rate is the cost model's, not a measurement.

On a slow device (the `phone` profile, ~5 ms a drawn GBA frame, 60 Hz),
the result depends on what an undrawn frame costs there. The model's 0.66
of a drawn frame (from the first prototype's browser numbers) gives the
original doc's picture; the wasm core measured above is nearer 0.84 on
Emerald, and with that:

| phone profile, 60 Hz | main | skip (undrawn 0.84) | skip (0.66, the model) |
|---|---|---|---|
| 2x: uneven refreshes a minute | 1934 | 1334 | 52 |
| run-ahead 2: game frame rate held (error sd, frames) | no (27.9) | yes (0.64) | yes (0.59) |

Run-ahead 2 on a device too slow for it is the one place it changes what
the player sees: when a refresh owes two frames the first is unseen and
runs no lookahead at all, so the device keeps up where main falls behind.

### What it buys over today's main

- Fast-forward: +20% on moving GBA scenes on the desktop (+59% on a mode-7
  racer), +12-29% in the browsers, +9-16% in the simulator; +4-8% on static
  scenes (main's render skip has them) and on GB/GBC.
- 2x: about a tenth less emulation work on moving GBA scenes (a fifth on
  mode 7), a few percent on GB/GBC and static scenes. At 120 frames a
  second on an M-series that is about 1 point of one core; on a phone
  ~6x slower (an iPhone SE-class device) about 7 points of a core on
  Emerald, ~20 on F-Zero, ~1 on Blue. Too small to see
  in a browser's or the simulator's own clock here.
- Run-ahead 2: 3-14% per frame (moving GBA scenes), none at run-ahead 1.
- 1x on a 60 Hz or faster display: nothing (by design).
- A slow device (phone profile): run-ahead 2 keeps 60 fps where main
  slows; 2x has fewer uneven refreshes (1334 against 1934 a minute), not
  the near-perfect cadence the first prototype's model suggested.

Cost: the diff against main (see the report with the branch) touches the
GBA and GB PPUs (an early return; three stores guarded on the GB FIFO),
rewind (frame stamps, put-off snapshots), both rollback sessions
(drawOnlyShown, peer_state_bytes for desync dumps), and every frame loop
(web, iOS, desktop, wasm/iOS clip pre-roll, Add pictures, the playtest
driver), with the edge-case table above as its surface: the tick's last
frame always drawn, rewind/clip anchors waiting for a drawn frame, the
LCD response, the SGB, link dumps, input-log and turbo exclusions.

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
existing whole-frame render skip never fires in gameplay. (Since then main's
render skip fires on far more frames, a4a2824d: a same-value store no
longer dirties the frame. The measurements above include it.)

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
| the A/B switch (`?draw=all`, Draw every frame, desktop `DINGBAT_DRAW_ALL=1`) | one core switch (`wasm_set_draw_all` / `dingbat_set_draw_all`): also run-ahead's lookahead frames, rollback, Add pictures and the clip pre-roll; the desktop's turns its batch off |
| Add pictures (web, iOS): ~600 frames a game for one picture | each 30-frame chunk draws only its last (a deadline can end the run between chunks) |
| a clip's silent pre-roll | only its last frame, the one presented, is drawn |
| desktop input log (playtest recordings) | no batching under it: its every-60-frames hash reads the previous frame's picture |
| desktop turbo/fast-forward: a changed frame left unpresented, then a static one presented | the texture is uploaded if any frame changed since the last upload (on main too; iOS had it fixed in dc1b85d0) |
| playtest driver `run N` | draws only the last frame, the one read (hashes and shots unchanged) |
| the SGB or the LCD response refusing a skip | `*_unseen_next` returns whether the frame will really go undrawn, so fast-forward's timing and the log count only real skips |
| input latency | the skip adds none: the same frames run at the same moments and read input as before (iOS's Start frames late, a latency experiment on the original branch, is not on frame-skip-2) |

Not done (each draws every frame, as before): rollback's ticks per refresh
(1-2 at 1x, up to 4 at 2x, each also converted to RGBA), local 2P (both
cores shown, up to 4 frames per refresh at 2x on iOS) and the lockstep
netlink's catch-up. A stall can end any of them early, so the last frame is
not known up front; rollback's stall test could be asked before each tick.

## Frame pacing

Cadence (each picture shown for the same number of refreshes) matters as
much as latency. Frame skip does not touch it: how many frames a tick runs
still comes from the display's timestamps alone, and the picture shown is
the same one main shows (600 tick-shaped groups on GBA and GB, unseen
against draw-all from one state: 0 picture hashes differ). The probe
(`web/e2e/pacing-probe.mjs`) runs main, this branch and `?draw=all` side by
side; on its virtual clock the game loop's own code decides and only time
is modelled (a cost per drawn and undrawn frame, present, tick, noise and
spikes), so a loaded machine does not move the result.

- 1x, 2x, slow motion, run-ahead 1 and 2, on 30, 48, 50, 60, 75, 90, 120
  and 144 Hz and variable-rate displays: frames per callback identical to
  main in every case.
- Slower devices (costs x4 and x6, an iPhone SE-class profile): the branch
  misses fewer refreshes. 2x at 60 Hz on the phone profile: 52 uneven
  refreshes a minute against main's 1700; run-ahead 2 no longer slows the
  game (main 39.5-44 fps, the branch 59.9). One borderline case reads both
  ways: 2x where a refresh just does not fit, main settles into an even
  30 Hz, the branch shows 60 Hz with occasional hitches.
- Fast-forward: the branch's tick aimed its frames at a number of refreshes
  from the mean of all its frames, drawn and undrawn. Each tick draws one,
  so the mean depended on how many the tick ran, and so on the aim itself:
  near 5 ms a frame (an iPhone SE) the aim flapped between 1 and 2
  refreshes and presents came 1 and 2 refreshes apart, mixed. Main flaps
  the same way at other speeds (3.6-3.8 and 7.6-8.0 ms at 60 Hz). Now four
  frames are estimated as they will run (three undrawn and one drawn), and
  the aim drops a refresh only clear of the boundary by a quarter of one.
  A sweep of the loop at 1-10 ms a frame leaves no flapping speed at 30, 50
  or 60 Hz (main: 6-10), one at 120 Hz (main: 31) and 14 at 144 Hz (main:
  44: a drawn frame there takes longer than a refresh, so its noise alone
  moves presents). The probe, phone profile, 60 Hz: 8.1 +/- 0.5 frames per
  present, every present 2 refreshes, 242 fps (was 6.0 +/- 2.6, mixed; main
  5.9 +/- 0.3 at 176 fps); 120 Hz: 5.7 +/- 0.5, every present 3 refreshes.
- Rewind: a snapshot due on an undrawn frame waited for a drawn one, about
  20 frames on under fast-forward, so rewinding through fast-forwarded
  history went at twice the rate, unevenly. Fast-forward now draws the frame
  a snapshot is due on (`snapshot_due`), one more drawn frame in 10.
- iOS (simulator, under heavy load from other jobs, 20 s runs, a DEBUG
  pacing test not carried to frame-skip-2): frames per refresh exactly 1
  at 1x and 2 at 2x, as without frame skip. iOS fast-forward fills a fixed share of the refresh, not an aim, so it
  has no flapping.
- Desktop: batching only under fast-forward, presenting on the same clock
  as main (main has since fixed its stale picture at turbo and
  fast-forward itself, a14908b1). Holding fast-forward on an analog trigger ends
  each batch after a frame (axis events count as input): throughput, not
  cadence.

Found on main, not changed here: web fast-forward learns the
refresh rate only at normal speed. Desktop has vsync off, paces 1x on a
16.743 ms counter slot (at 60 Hz, ~36 frames a minute never shown, each
with one doubled), paces turbo by the audio queue with a whole-millisecond
present interval, and reads the refresh rate once, from display 0.

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
- [x] edge-case mitigations (table above), GB, rollback, desktop; perf
      review (instructions); all tests above, web tests, tsc,
      desktop and iOS builds
- [ ] Matt's test at home (web on his devices, iOS on the phone): fast-
      forward, 2x, run-ahead, link play, Low Power Mode
- [x] round 4 (independent review): link dumps, the one A/B switch, Add
      pictures, clip pre-roll, desktop input log and stale texture,
      playtest driver; tools/ci_local.py 32/32,
      web link-rom-skip e2e 4/4, the browser tests, tsc
- [x] the playtest train (79ea2262 on origin/main dc1b85d0): CLEAN — none
      of the 140 games differs from the baseline in any hash (checkpoint
      frames, audio, battery files, load cells) in any of the four dingbat
      configurations; the corpus played in 25.7 min against the baseline's
      27.5 (the driver's `run N` now draws only its last frame)
- [x] round 5 (adversarial latency review): desktop turbo no longer batches, desktop fast-forward reads input
      after every frame again; `*_unseen_next` marks only frames that
      really go undrawn. iOS link e2e 6/6 and the FireRed/LeafGreen trade
      e2e (2% loss) pass with native and wasm states identical
- [x] round 6 (frame pacing, above): web fast-forward's aim no longer
      flaps; fast-forward draws rewind-due frames. render_skip, rewind (new spacing case), ios_api,
      rollback tests; web tests as above; tsc; wasm, desktop, iOS builds
- [x] desktop: run hidden with the GUI driver (frame-skip-2, below)
- [ ] if kept: drop the switches or keep `?draw=all` as a diagnostic; the
      iOS setting is a prototype toggle
