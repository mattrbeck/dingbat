# What each web setting costs (2026-09-30)

Every user-facing setting in the web build, measured through the shipping
paths on an M2 (Chrome 154), before and after the optimisation round on
branch `worktree-settings-cost`. "Before" is origin/main `f36831d4`. Scenes:
Pokémon FireRed overworld (the long-standing bench state), Pokémon Silver
in-game (Pokémon Center), Pokémon Blue in-game for Super Game Boy mode.
Standing still is a cheap frame, so percentages here are the high end;
walking and battles dilute them.

"Emulator CPU" is the per-frame work of `loop_tick` / `runahead_tick` plus
the app's audio drain: what sets how slow a phone can be and still hold
60 fps. FireRed defaults cost 1.16 ms of it per frame on the M2 (about 7 % of
a 60 Hz frame); the 1st-gen iPhone SE is roughly 6.7x slower (Emerald
fast-forward ~125 fps), so there the same frame is ~8 ms.

## The table

Costs are against the shipping defaults with only that setting changed.
Browser numbers are the mean of two alternating before/after sweeps, each
the median of per-round ratios over 11 interleaved rounds; the A/A control
read within 0.1 % on FireRed.

| Setting | Default | Runs on | FireRed before | FireRed after | GBC (Silver) before → after |
|---|---|---|---|---|---|
| Rewind | **on** | emulator CPU | +2.1 % (native instr +2.32 %) | +1.7 % (native +2.20 %) | ~+1.1 % (native) |
| Run-ahead 1 / 2 / 3 | off (0) | emulator CPU | +118 / +213 / +308 % | **+104 / +199 / +294 %** | +133 / +240 / +325 % → **+101 / +200 / +290 %** |
| Enhanced music (MP2K HLE) | off | emulator CPU | +3.4 % (native +3.8 %) | unchanged | n/a |
| Audio interpolation | **on** | emulator CPU | +0.3 % (native +0.34 %) | unchanged | n/a |
| Pitch-correct fast-forward | **on** (was off) | emulator CPU, FF only | +3.1 % of FF speed, 0 at 1x | **+1.1 %** of FF speed, 0 at 1x | +7.0 % → **+2.9 %** of FF speed |
| LCD response | off | emulator CPU | +3.4 % | **+0.6 %** standing (walking −4 % only) | +4.5 % → **+0.6 %** |
| Colour correction | **on** | GPU shader | 0 CPU; +0.013 ms/present | unchanged | 0 CPU |
| Filter: LCD grid | none | GPU | +0.001 ms/present | unchanged | |
| Filter: hq4x | none | GPU | +0.04 ms/present | unchanged | |
| Filter: RGB subpixels | none | GPU (6x backing) | +0.17 ms/present | unchanged | |
| Filter: xBR | none | GPU | +0.23 ms/present | unchanged | |
| Ambient glow | off | GPU process / main thread | +0.40–0.64 ms/frame GPU process (blur + mask recomposited every frame) | **+0.07–0.08 ms/frame** GPU process; main thread 0.007 ms/frame, 0 while the picture is still | |
| Analog filter | **on** (was off) | audio thread, GBA games only | 0.013 ms per frame-equivalent, off the emulation thread | unchanged | n/a (Game Boy games are not filtered) |
| GBA BIOS: real BIOS | HLE | emulator CPU | +5.7 % (native +6.0 %) | unchanged (inherent) | n/a |
| GBA BIOS: real boot, HLE calls | HLE | one-time | 0 after boot | | n/a |
| Play BIOS intro | **on** | one-time | 0 after boot (needs a BIOS file) | | n/a |
| Super Game Boy mode | off | emulator CPU | n/a | | Blue: +59 % → **+1.4 %** (native instr +83 % → +6 %) |
| Show SGB border | **on** | GPU / on change | border uploads only when it changes | | |
| Integer scaling | off | CSS | nothing per frame | | |
| GB palette | default | one shader uniform | nothing measurable | | |
| GB rumble | **on** | one wasm call per frame | nothing measurable | | |
| Input display, large / opaque controls, hide touch on gamepad (**on**), theme, volume | | DOM / CSS | nothing per frame | | |

### The same on one scale

For the rows that do not run in the emulation loop, the ms they add per
frame as a share of the default FireRed frame's emulation time (1.16 ms on
the M2), with the share of the resource they actually load second:

| Setting | Before | After |
|---|---|---|
| Ambient glow | +22–55 % (GPU process +63–156 %) | +6–7 % (GPU process +16–18 %), main thread +0.6 %, 0 while still |
| Colour correction | +1.1 % (13 % of drawing the frame) | unchanged |
| Filter: grid / hq4x / RGB / xBR | +0.1 / 3.6 / 14.5 / 19.8 % (1 / 37 / 150 / 205 % of drawing the frame) | unchanged |
| Analog filter | +1.1 %, on the audio thread | unchanged |

These run beside emulation, so they slow a game only on a device whose GPU
or spare cores are already saturated. `web/bench/glowshots.mjs` captures
the real app with the glow on, at an identical held frame per build, for
before/after pictures.

## Defaults changed on 2026-09-30

Decided on the numbers above; every other default stayed.

* **Pitch-correct fast-forward: on.** Both APUs reach the stretcher only
  while turbo is set (and allocate it only then), so it costs nothing at
  normal speed; in fast-forward it costs ~1 % (GBA) to ~3 % (GB) of
  fast-forward speed.
* **Analog filter: on, GBA games only.** It runs on the audio thread on the
  web (a `BiquadFilterNode`) and once per output sample natively, never in
  the emulation loop. The web build used to filter Game Boy games too,
  against its own label and the desktop build; it is now routed out of the
  graph for them.
* **Existing settings.** Web and desktop both saved every audio field with
  any change, so a stored `false` for these two from before could be the old
  default rather than a choice. Records from before the change take the new
  defaults once (web `audio` record `rev: 2`, desktop `defaults_rev: 2`);
  turned off after that, they stay off. Tests: `web/tests/audio-defaults.test.mjs`,
  `tests/desktop_settings_test.nim`.

## What changed (each commit on the branch)

* **SGB mode, +83 % → +6 % (native instr).** An active SGB attribute map
  sent every pixel through the general mixer and kept the deferred mode-3
  path off. The plain span now colours an object-free SGB pixel by its cell
  palette in its own static copy of the span, and an SGB packet syncs a
  deferred stretch before it changes a palette or the attribute map. The
  same change took the old `or sgb` test out of every other game's span:
  Blue without SGB −1.4 %, Silver −1.0 % instructions. Bit-identical
  per-frame hashes on four SGB runs and two controls; gb_plaincheck,
  gb_spancheck and gb_lazypoison clean; sgb_test passes; runner 1432/1443
  unchanged.
* **Ambient glow, GPU process −80–89 %.** The CSS `filter: blur(32px)` and
  radial `mask-image` were recomposited every frame because the game canvas
  repaints over the glow. `createGlowComposer` (glpresent.js) composes the
  same picture at the sampler's 10 Hz on a few-dozen-texel grid, and skips
  entirely once the picture holds still. Against Chrome's own blur + mask:
  mean error 0.6–1.1/255, max 14–16, at 375–1400 px boxes.
* **Pitch-correct, WSOLA search −76 % native / −80 % wasm.** The similarity
  search mixes to mono once per step, slides its window energy and runs
  eight independent sums. Output is bit-identical on 70 s of FireRed audio.
  What remains (~1 % of FF speed) is the search's arithmetic itself; wasm
  SIMD would roughly halve it again but the 1st-gen SE (iOS 15) has none.
* **LCD response, −81 % standing.** 32-pixel chunks that ended settled and
  get the same input again skip the model. Output identical over 1200
  frames; a scrolling screen changes every pixel, so walking is −4 %.
* **Run-ahead, restore 0.43 → 0.03 ms.** Every restore read multi-byte
  fields a byte at a time, the framebuffer element by element and the save
  RAM through a fresh seq, then marked the save dirty, so the next frame
  rewrote the .sav (fsync'd natively, MEMFS on the web). The reader now
  loads in bulk and the save is dirty only if the state's RAM differs (a
  slot load that changes it still overwrites the battery save, as before).
* **Rewind, 2.32 % → 2.20 % (native instr).** A push XORs and block-scans
  the two snapshots in one pass instead of copying 606 KB first; same
  bytes. The rest is zlib (~60 % of a push); a faster codec would trade
  history length (rewind_codecs.nim has the bake-off).

## Still worth knowing

* **Pitch-correct fast-forward now costs ~1 % of fast-forward speed on
  FireRed and ~3 % on Silver, and nothing at normal speed** (both APUs
  reach the stretcher only while turbo is set).
* **Run-ahead 1 still cannot hold 60 fps on the iPhone SE**: it is ~2x the
  per-frame work, ~16 ms on a phone that does a frame in ~8 ms.
* **Not touched:** MP2K HLE's resampler is already tabulated and
  vectorised, and what it costs is the mixing it exists to do; real BIOS is
  the BIOS's own code running; the xBR / RGB filters are GPU-only.
* **Native desktop lead:** `_tlv_get_addr` (thread-local lookups the Nim
  runtime inserts in threaded builds) is ~5 % of samples in plain native
  frames, spread across the CPU and bus procs. The wasm build is
  `threads:off` and does not pay it.

## Method

`web/bench/settings.html` (ROMs, states and `bios.bin` next to it,
gitignored; `?rom=`, `?state=`), driven with `web/bench/cdp.mjs`:

* `settingsCore(frames, rounds, warm, only?)` — each config flips one setting
  from the shipping defaults through the real exports, reloads the state,
  runs `warm` untimed frames (MP2K HLE engages on detection) and times
  `frames` of `loop_tick` (or `runahead_tick(n)`) with the app's audio copy
  into an `AudioBuffer`. Configs are interleaved and rotated each round; the
  cost is the median of per-round ratios against the reference. Pitch-correct
  is measured against fast-forward (`wasm_set_turbo(1)`).
* `settingsSgb()` and `settingsBios()` re-init the core for their
  construction-time setting (SGB needs `<name>.state` and `<name>SGB.state`).
* `settingsGpu(n, rounds)` — `createGlRenderer` at the app's backing size,
  `n` draws then a 1-px `readPixels`; per-draw wall time.
  `EXT_disjoint_timer_query_webgl2` does not reconcile with wall time on
  ANGLE Metal, so only deltas are quoted.
* `settingsGlowScene(mode)` runs a 60 Hz present loop with the glow `off`,
  as the old `css` or `composed`; `node web/bench/glowtrace.mjs` traces the
  GPU process across the three. `settingsGlowCompare` / `settingsGlowComposer`
  diff the composed picture against Chrome's own blur and time it.
* `settingsLowpass()` renders 60 s through an `OfflineAudioContext` with and
  without the `BiquadFilterNode`.
* Before/after: origin/main's wasm served from a second directory, the same
  page on both, sweeps alternated.
* Native instruction counts: `tests/dingbat_bench.nim` with
  `DINGBAT_BENCH_COUNTERS=1`, min of 4, using `DINGBAT_BENCH_REWIND=web`,
  `DINGBAT_MP2K=1`, `DINGBAT_BENCH_BIOS`, `DINGBAT_BENCH_FIFO_INTERP=0` and
  `DINGBAT_BENCH_SGB=1`. The harness drops audio samples before the output
  switch, so pitch-correct is measured in wasm.

Traps: a hidden or occluded tab clamps chained `setTimeout(0)` to once a
second and later once a minute (the bench yields through a `MessageChannel`);
load from parallel jobs (load average up to 70 during these runs) moves
absolute ms a lot, which the per-round ratio absorbs and the A/A control
checks; a GB cart with a clock needs `DINGBAT_BENCH_RTC_EPOCH` before two
runs can be hash-compared.
