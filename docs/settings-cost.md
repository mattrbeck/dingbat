# What each web setting costs (2026-09-30)

Every user-facing setting in the web build, measured through the shipping
paths on an M2 (Chrome 154) at origin/main `f36831d4`. Scenes: Pokémon
FireRed overworld (the long-standing bench state) and Pokémon Silver in-game
(Pokémon Center, standing). Standing in the overworld is a cheap frame, so
percentages here are the high end; walking or battles dilute them.

"Emulator CPU" is the per-frame work of `loop_tick` / `runahead_tick` plus
the app's audio drain, the thing that sets how slow a phone can be and still
hold 60 fps. FireRed defaults cost 1.20 ms of it per frame on the M2 (about
7 % of a 60 Hz frame); the 1st-gen iPhone SE is roughly 6.7x slower (Emerald
fast-forward ~125 fps), so there the same frame is ~8 ms.

## The table

| Setting | Default | Where it runs | FireRed | Silver (GBC) |
|---|---|---|---|---|
| Rewind | on | emulator CPU | **+2.2 %** (native instr +2.21 %) | +1.1 % (native), +1.6 % Chrome |
| Run-ahead 1 / 2 / 3 | off | emulator CPU | **+116 / +213 / +311 %** | +129 / +225 / +317 % |
| Enhanced music (MP2K HLE) | off | emulator CPU | **+3–4 %** (native +3.78 %) | n/a |
| Audio interpolation | on | emulator CPU | **+0.3–0.6 %** (native +0.34 %) | n/a |
| Pitch-correct fast-forward | off | emulator CPU, FF only | **+3 %** of FF speed; 0 at 1x | +8 % of FF speed; 0 at 1x |
| LCD response | off | emulator CPU (wasm) | **+2–3 %** (0.03–0.07 ms) | +5 % (same ms, cheaper frame) |
| Colour correction | on | GPU (shader) | 0 CPU; +0.013 ms/present | 0 CPU |
| Filter: LCD grid | none | GPU | +0.001 ms/present over none | |
| Filter: hq4x | none | GPU | +0.04 ms/present | |
| Filter: RGB subpixels | none | GPU (6x backing) | +0.17 ms/present | |
| Filter: xBR | none | GPU | +0.23 ms/present | |
| Ambient glow | off | compositor (GPU process) | +0.25 ms/frame GPU-process CPU, plus the blur's GPU time (unmeasured); sampler 0.001 ms | |
| Analog filter | off | audio thread | 0.013 ms per frame-equivalent, off the emulation thread | n/a |
| GBA BIOS: Real BIOS | HLE | emulator CPU | **+6.0 %** (native), +5.7 % Chrome | n/a |
| GBA BIOS: real boot, HLE calls | HLE | one-time | 0 after boot | n/a |
| Play BIOS intro | on | one-time | 0 after boot | n/a |
| Super Game Boy mode | off | emulator CPU | n/a | **+83 %** on Pokémon Blue (see below) |
| Integer scaling, GB palette, SGB border, theme, controls, input display, rumble, volume | | CSS / one uniform / on change | not measurable; nothing per frame | |

Noise: the browser runs carry an A/A control (defaults vs defaults) that
read +0.38 %, +0.46 % and −0.21 % on three sweeps; colour correction off,
which does no per-frame CPU work at all, read −0.02 % to −0.48 %. Treat
anything under ~0.5 % from Chrome alone as zero; the native retired-instruction
counts (A/A 0.03 %) settle those.

## Findings worth acting on

* **Pitch-correct fast-forward is not under 1 %.** ~3 % of fast-forward
  throughput on FireRed and ~8 % on Silver (0.035 / 0.058 ms per emulated
  frame of WSOLA), and exactly zero at normal speed — the stretcher is only
  reached when `apu.turbo` is set. Defaulting it on costs only fast-forward
  speed.
* **Audio interpolation is the one sub-1 % item** (0.34 % by instruction
  count) — already default-on.
* **Super Game Boy mode costs +83 %** on an SGB game because an active
  attribute map turns off the PPU's plain-span fast path: `fifo_ppu.nim`
  forces every pixel through `fifo_mix` when `sgb_attr != nil` (the
  `has_sp or sgb` test in the span loop and the `sgb_attr == nil` gate on the
  lazy span). SGB colour is per 8x8 cell, so a span could look up the
  palette once per cell instead; this is an implementation cost, not one SGB
  needs.
* **Run-ahead 1 cannot hold 60 fps on the iPhone SE**: it is ~2.15x the
  per-frame work, ~17 ms on a phone that does a frame in ~8 ms. Each further
  frame adds roughly one more frame of emulation (~1.2 ms on the M2) plus the
  state save/restore.
* **Rewind is down from 6 % (2026-08-07) to 2.2 %** on FireRed after the
  serializer and codec work.
* **Ambient glow is the most expensive video setting** on the compositor
  side: the game canvas repaints over the glow every frame, so the 32 px
  blur and radial mask are recomposited every frame, not at the sampler's
  10 Hz. On the M2 it raises the GPU process's main-thread busy time 61 %
  (18 → 29 ms per second).

## Method

`web/bench/settings.html` (ROM and state next to it, gitignored; `?rom=`,
`?state=`), driven with `web/bench/cdp.mjs`:

* `settingsCore(frames, rounds, warm, only?)` — each config flips one setting
  from the shipping defaults through the real exports, reloads the state,
  runs `warm` untimed frames (MP2K HLE engages on detection) and times
  `frames` of `loop_tick` (or `runahead_tick(n)`) with the app's audio copy
  into an `AudioBuffer`. Configs are interleaved, rotated each round; the
  reported cost is the median of per-round ratios against the reference,
  which cancels load drift. Pitch-correct is measured against fast-forward
  (`wasm_set_turbo(1)`), since that is the only time it runs.
* `settingsGpu(n, rounds)` — `createGlRenderer` from `web/glpresent.js` at the
  app's backing size (960x640, 1440x960 for RGB), `n` draws then a 1-px
  `readPixels`; per-draw wall time. `EXT_disjoint_timer_query_webgl2` is
  read too but its absolute values do not reconcile with wall time on ANGLE
  Metal, so only the deltas are quoted.
* `settingsGlow()` times the sampler; `node web/bench/glowtrace.mjs` runs a
  60 Hz present loop with the app's glow CSS and traces the GPU process with
  the glow shown and hidden.
* `settingsLowpass()` renders 60 s through an `OfflineAudioContext` with and
  without the `BiquadFilterNode`.
* `settingsBios()` re-inits the core with `bios.bin` in the FS.
* Native instruction counts: `tests/dingbat_bench.nim` with
  `DINGBAT_BENCH_COUNTERS=1`, min of 4, using `DINGBAT_BENCH_REWIND=web`,
  `DINGBAT_MP2K=1`, `DINGBAT_BENCH_BIOS`, `DINGBAT_BENCH_FIFO_INTERP=0` and
  `DINGBAT_BENCH_SGB=1`. The harness drops audio samples before the output
  switch, so pitch-correct can only be measured in wasm.

Two traps hit on the way: a hidden or occluded tab clamps chained
`setTimeout(0)` to once a second and later once a minute (the bench yields
through a `MessageChannel` instead), and machine load from parallel jobs
(load average 15–70 during these runs) moves absolute ms by 60 %, which the
per-round ratio absorbs and the A/A control checks.
