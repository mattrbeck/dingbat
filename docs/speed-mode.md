# Speed mode (low-end devices)

A single advertised-as-less-accurate switch that trades emulation fidelity and
optional niceties for host CPU, aimed at phones/tablets that can't hold 60 fps.
Prototyped on branch `worktree-speed-mode`; OFF by default everywhere and the
default path is verified bit-identical (rolling framebuffer FNV over 300
walking frames matches main, and the mGBA suite matches the committed baseline
suite-for-suite).

## What the switch does

Core knobs (new, runtime, GBA):

- **Frameskip** (`ppu.frameskip = 1`): the PPU force-skips every other frame's
  rendering, piggybacking on the existing `skip_render`/`render_dirty`
  machinery. A skipped frame does not consume `render_dirty`, so the next
  rendered frame repaints everything that changed; rendered frames are
  bit-identical to what an unskipped run shows at that frame. `frame_static`
  is set on skipped frames so frontends skip the texture upload too.
- **Underclock** (`set_underclock(1)`): every memory access costs 2x its real
  cycles. Implemented by scaling the waitstate tables in `update_waitcnt` —
  "the whole bus got slower" — so the per-instruction hot path pays **zero**
  ambient cost (an earlier `remaining shl underclock` in `cpu.tick` measured
  +0.57% on everyone and was replaced). The emulated CPU runs at roughly half
  speed against an unchanged video/timer clock: idle-bound games are
  unaffected, CPU-bound games drop internal frames.

Core knob (new, runtime, GB/GBC):

- **GB frameskip** (`gb.ppu.frameskip = 1`, honored only by the scanline
  renderer): `do_scanline`'s pixel work is skipped for every other frame,
  decided once per frame at LY 0. The scanline PPU's mode/LY/STAT/HDMA timing
  is analytic and lives entirely in its `tick` — mode 3 is a fixed 172 dots —
  so the skip is **timing-neutral by construction**, verified: total emulated
  cycles are bit-identical with the knob on and off (`cycles=84268800` both
  ways over 1200 Crystal frames), and rendered frames match an unskipped
  run's even frames byte-for-byte. The FIFO renderer ignores the field (its
  mode-3 length comes from actually running the pixel pipeline, so its
  rendering cannot be skipped); speed mode forces the scanline renderer at
  load anyway. Measured: **−20.8% instructions (Crystal attract) / −22.1%
  (Blue)** on top of the renderer swap, bringing whole-mode GB savings vs the
  stock FIFO baseline to **−35% (CGB) / −42% (DMG) ≈ 1.5–1.7x throughput**.
  Off-cost gate: old-vs-new binary interleaved A/B measured −0.87% (scanline)
  / −0.03% (FIFO) — i.e. no regression, within layout luck; GBA arm ±0.005%.

Preset behavior (suspends, never overwrites, stored preferences):

- GB/GBC: next ROM load uses the **scanline renderer** (FIFO preference
  remembered and restored when the mode goes off) and frameskip=1 applies
  live via `apply_speed_mode_gb` / native `apply_speed_mode`.
- Rewind, run-ahead, and ALL perf-relevant audio niceties — MP2K HLE, FIFO
  interpolation, analog low-pass, pitch-correct fast-forward — are suspended
  while the mode is on (web `applySystemSettings` computes effective values;
  native apply procs do the same).
- Video costs above the ~1% bar are suspended too: the GPU upscale filter
  (hq4x +0.16 ms / xBR +0.58 ms per present @960×640 web, xBR +1.01 ms
  @2160p native — several percent of frame budget on weak GPUs), ambient
  glow (sampler + canvas fully off, canvas hidden), and LCD response (the
  per-pixel CPU panel model). Deliberately NOT suspended, measured below the
  bar: color correction (+0.033 ms GPU ≈ 0.2%, a shader bool in a pass that
  runs anyway), scanlines (same), integer scaling (layout only), volume/mute.
  The UI reflects every lock: affected web toggles/selects and native menu
  items / video-widget rows gray out while the mode is on, keeping their
  stored values.
- Link/rollback/netlink cores are **exempt** — they keep faithful timing, or
  two peers with different settings would desync (`make_gba` comment).

Surfaces: web Settings → General ("Speed mode", persisted in the `"system"`
IDB record, `wasm_set_speed_mode` export), native Emulation menu ("Speed mode
(less accurate)", `speed_mode` config key).

## Measured buckets

Method: `DINGBAT_BENCH_COUNTERS=1` instructions retired (min of 4), FireRed
Viridian-crossroads state, 600 frames after 120 warmup, native arm64
(`docs/research_firered_perf.md` method). Baseline 13.055e9 instructions.
Noise on this metric ≈0.02–0.1%; cross-build layout noise ≈±0.5%.

| Bucket | Δ instructions | Notes |
|---|---|---|
| Frameskip = 1 | **−8.8%** | scene-dependent (PPU share is 9–44% by game); verified identical-pair frame dumps |
| Underclock ×2 (waitstate tables) | **−20.5%** | FireRed gameplay pace unaffected (has CPU headroom); heavy games will lag internally |
| Frameskip + underclock | **−29.2%** | the shipping speed-mode pair |
| Rewind (web config, with thumbnails) | −3.0% | already a user toggle; suspended by the mode |
| MP2K HLE audio (if user enabled it) | −5.65% | suspended by the mode |
| Flat ROM timing (`-d:flatrom` probe) | −7.7% | **not shipped** — compile-time probe only; would tank the mGBA Timing suite and split the wasm bundle |
| GB scanline renderer (Crystal / Blue) | −17.5% / −24.3% | already a user setting; forced by the mode at next load |

Stacked web-realistic estimate (rewind on → speed mode on): ~13.45e9 →
~9.24e9 ≈ **31% less emulator CPU ≈ 1.45x throughput** on GBA, and
**1.2–1.3x on GB/GBC** from the renderer swap. On top of that, skipped frames
set `frame_static`, saving present/upload work where frontends honor it.

## Known accuracy costs (the advertised trade)

- Frameskip: 30 Hz visual updates; games that strobe sprites every other
  frame for pseudo-transparency can render always-visible or always-invisible
  instead of flickering (cadence is aligned to even frames).
- Underclock: CPU-heavy games (3D-ish renderers, busy battle scenes,
  streaming-audio titles) drop internal frames or stutter audio; anything
  that calibrates itself against real-time (raw-SIO peripherals, tight
  audio/video sync engines) can misbehave. Emulated timing is deliberately
  wrong, so timing-sensitive test ROMs will fail while the mode is on.
- GB scanline renderer: mode-3 length is analytic, not FIFO-exact — some
  mid-scanline effects (Mealybug-class) render differently, and CPU-visible
  timing shifts slightly.
- Save states made in speed mode restore correctly (nothing new is
  serialized; `update_waitcnt` on load re-applies whatever mode the *loading*
  session is in).

## Not pursued, and why

- **Cheaper compositing / no-blend PPU**: whole-compositor deletion ceiling is
  only ~9–11% and the blend path is a small share of it on most titles
  (docs/research_ppu_hotspots.md); frameskip already halves PPU cost with none
  of the per-path risk.
- **Flat ROM timing as a shipped runtime knob**: the fetch fast path is
  already flat when hot; the remaining −7.7% lives in the slow-path
  bookkeeping, and a runtime flag there re-rolls the `mem_read`/`mem_write`
  inline cliff (docs/gb_oam_dma_cost.md). Compile-time only → second wasm
  bundle → service-worker precache split. Parked.
- **GB underclock**: the SM83 interpreter is only ~8% of GB time and the
  dominant per-cycle stepping (`mem_tick_components` + PPU/timer ticks ≈ 40%)
  scales with the fixed 70,224 dots per frame, not with instruction count —
  slowing the emulated CPU would buy almost nothing. (GB *frameskip* was
  worth it and shipped; see above.)
- **`-d:danger` native** (+17%): previously rejected — bounds checks have
  caught real OOB on hostile ROMs; unchanged by this work.

## Follow-ups if the mode should go further

1. Frameskip = 2/3 tiers ("render 1 of N") — the machinery already supports it.
2. Underclock = 2 (quarter speed) for the truly desperate — `set_underclock`
   already clamps to ≤2 (int8 table headroom).
3. A "fast timing" compile-time web bundle (flatrom + simplified catch-up)
   served only to detected-slow devices, if the SW precache split is accepted.
4. Honor `frame_static` in the solo web present path if it doesn't already.
