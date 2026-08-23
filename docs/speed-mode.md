# Speed mode (low-end devices)

One advertised-as-less-accurate switch: web Settings → General ("Speed
mode", `"system"` IDB record, `wasm_set_speed_mode`); native Emulation menu,
`speed_mode` config key. Off by default; the off path is bit-identical.

## What it does

GBA:

* **Frameskip** (`ppu.frameskip = 1`): every other frame's rendering is
  skipped through the existing `skip_render` / `render_dirty` machinery. A
  skipped frame does not consume `render_dirty`, so the next rendered frame
  repaints everything that changed and is bit-identical to an unskipped
  run's frame. `frame_static` is set on skipped frames so frontends skip the
  upload.
* **Underclock** (`set_underclock(1)`): every memory access costs 2x, by
  scaling the waitstate tables in `update_waitcnt` — the per-instruction hot
  path pays nothing (a `shl` in `cpu.tick` cost +0.57 % on everyone). The
  emulated CPU runs at half speed against an unchanged video/timer clock:
  idle-bound games are unaffected, CPU-bound games drop internal frames.
  `set_underclock` clamps at 2 (int8 table headroom).

GB/GBC:

* **Frameskip** (`gb.ppu.frameskip = 1`), honoured only by the scanline
  renderer, decided once per frame at LY 0. That renderer's mode/LY/STAT/HDMA
  timing is analytic, so the skip is timing-neutral (total emulated cycles
  identical on and off over 1200 Crystal frames). The FIFO renderer's mode-3
  length comes from running the pipeline, so it cannot skip; speed mode
  forces the scanline renderer at the next load and restores the FIFO
  preference when it goes off.
* GB underclock is not worth it: the SM83 interpreter is ~8 % of GB time and
  per-dot stepping scales with the fixed 70,224 dots per frame.

Suspended (never overwritten) while the mode is on, and greyed in the UI:
rewind, run-ahead, MP2K HLE, FIFO interpolation, analog low-pass,
pitch-correct fast-forward, the whole Filter selector (smoothing filters and
screen looks; the RGB look also inflates the backing store 4x→6x per axis),
ambient glow, LCD response. Not suspended, measured below the ~1 % bar:
colour correction, integer scaling, volume. Link/rollback/netlink cores are
exempt — two peers with different settings would desync.

## Cost

Retired instructions, FireRed gameplay, 600 frames (`docs/performance.md`):
frameskip −8.8 % (scene-dependent: PPU share is 9–44 % by game), underclock
−20.5 %, both −29.2 %. Stacked with rewind suspended, ≈1.45x GBA throughput.
GB: the renderer swap plus frameskip is ≈1.5–1.7x over the stock FIFO
baseline. Flat ROM timing (`-d:flatrom`, −7.7 %) is compile-time only: a
runtime flag re-rolls the `mem_read`/`mem_write` inline cliff, and a second
wasm bundle splits the service-worker precache. Parked.

## The accuracy trade

* Frameskip: 30 Hz updates; games that strobe sprites every other frame can
  render always-visible or always-invisible (cadence aligned to even frames).
* Underclock: CPU-heavy games stutter or drop internal frames; anything
  calibrated against real time misbehaves; timing test ROMs fail.
* GB scanline renderer: mode 3 is a fixed 172 dots, so mealybug-class
  mid-line effects render differently.
* Save states made in the mode load normally; nothing new is serialized and
  `update_waitcnt` on load applies the loading session's mode.

Possible extensions: frameskip tiers (render 1 of N — the machinery allows
it), underclock 2 (quarter speed), a "fast timing" bundle for detected-slow
devices if the precache split is accepted.
