# Run-ahead

Settings → Controls → Run-ahead (Off/1/2/3, default Off; `runahead`
IndexedDB key, in `SETTINGS_KEYS`). `runahead_tick(n)` in
`src/dingbat_wasm.nim`; the tick loop in `web/index.js`.

## What it is

Most games have 1–3 frames of internal input latency between the keypad
poll and the visible result. Run-ahead always displays the frame the game
will render N frames from now, assuming the held buttons stay held, so a
press appears up to N frames sooner. Find N for a game: pause, hold a
direction, frame-advance until the character reacts, minus one.

## The algorithm (single instance)

1. `step_frame()` — the canonical frame; its audio is the only audio kept.
2. `snap = state_payload()` (the rewind snapshot path, no thumbnail).
3. `audioSuppressed = true`; run `n` more `step_frame()`s; restore. The APU
   must run (its state feeds timing); only the sample append is skipped — the
   mechanism 2P link uses to mute core 2.
4. Copy `ppu.framebuffer` to a retained buffer and present that.
5. `apply_state_payload(snap)`.

Authoritative state is frame F while the screen shows F+n. `n <= 0` is
exactly `loop_tick`. A misprediction costs one wrong frame, never a
correction.

## Facts that bite

* `ppu.framebuffer` is in the state payload, so step 5 reverts the pixels
  about to be displayed, and `prepare_game_frame` is zero-copy. The future
  frame must be copied out (`runaheadFrame`) or run-ahead silently shows the
  present frame.
* Audio is pop-free because APU state round-trips through the snapshot, so
  canonical samples are contiguous across ticks.
* Keypad state is in the snapshot and JS sets input before the tick, so
  lookahead frames inherit "buttons stay held" for free.
* Single-core only: link/rollback/net modes are frame-synced with a peer.
  Rewind pushes stay on the canonical step.
* Engaged only in the normal-speed single-core branch — never during
  fast-forward, 2x or slow motion, frame advance, or the FF loop.

## Cost

Off is free: the Off path calls the unchanged `loop_tick` (interleaved A/B
within the ~1.3 % noise floor; `runahead_tick(0)` is not slower than
`loop_tick`). Wasm, M-series, m7 demo: `loop_tick` 2.0 ms/frame,
`runahead_tick(2)` 6.5 ms — ≈2 ms per extra step plus ≈0.4 ms
snapshot+restore. Phones start near ~5 ms/frame on heavy GBA titles, so
n=2 may exceed budget there; unmeasured. Consider auto-disabling below a
headroom threshold. The native frontend could reuse the algorithm around its
own save/load.

A rebuild with a current emsdk measured ~12 % faster than the deployed
`em.wasm` of the time; rebuild before measuring anything.
