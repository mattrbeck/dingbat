# Frame skip: frames nobody sees are not drawn

Status: prototype on branch `frame-skip`, for Matt to try. Not on main.

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

`ppu.no_draw` (gba.nim): set by the frontend between frames for a frame it
will not show. `scanline` returns at once and marks the frame dirty, so the
next drawn frame is drawn whole. It is never serialized: drawing changes no
emulated state (the OAM and line latches live in `latch_oam` and
`latch_line_start`, outside `scanline`), so a skipped frame runs exactly as a
drawn one. Two things only drawing writes do go stale in a skipped frame:
the framebuffer itself (also saved in a state) and the mosaic's latched
affine point (latched again on line 0 of every drawn frame).

GBA only: the GB PPU draws as part of its timing. Off while the LCD response
is on (its panel model takes every frame).

## Proof

`tests/render_skip_test.nim`: on every ROM a third machine skips drawing
runs of up to six frames; after every frame its state must equal a machine
that draws everything (but the two fields above), and every frame it draws
must match. Passes on all of tests/roms plus FireRed and LeafGreen for 1500
frames from boot (`DINGBAT_RENDER_SKIP_ROMS`, `DINGBAT_RENDER_SKIP_FRAMES`).

## Progress

- [x] core flag + test
- [ ] web: tick loops (normal/2x/slow, fast-forward), run-ahead in wasm
- [ ] iOS: GameSession tick, dingbat_run_frame_ahead
- [ ] A/B switch for testing (web `?draw=all`, iOS setting)
- [ ] measurements
