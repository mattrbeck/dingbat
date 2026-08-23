# LCD ghosting × upscale filters: the per-cell delta (parked)

Prototyped in commit `0698994` and reverted; re-apply it to bring the
implementation back. `tools/filtershot` (ghost-pair dumping, old/new-order
rendering) survives the revert. Code sites: `web/glpresent.js` (`u_ghost`),
`src/dingbat.nim` (`ghost_texture`, `upload_frame`), `src/dingbat_wasm.nim`
(`wasm_game_fb_raw_ptr`); the model in `src/dingbat/common/lcd_response.nim`
is unchanged. Tests: `web/render.test.mjs` (the two delta identities).

## The problem

The response model runs on the CPU at native resolution, and its output is
what the presenter uploads, so the upscale filters (hq4x / xBR / xBRZ)
classify edges on an already-ghosted picture. A settling pixel holds an
in-between colour for a few frames; the classifier reads the transient as
an edge or misses a real one, and flips frame to frame — moving edges
shimmer inside ghost trails. The physically right order is filter the clean
frame, then apply the panel response to what is displayed; but the response
is stateful per native cell and the filtered image exists only on the GPU.
A GPU port of the state machine was rejected (per-emulated-frame passes,
multiplied by fast-forward; resets on resize; link/rollback paths lose it).

## The design: CPU state, GPU display

`lcd_response.apply()` still advances every cell once per emulated frame.
The presenter uploads the **clean** frame as the filter source (`u_tex` /
`input_texture`, from `wasm_game_fb_raw_ptr`) and the **responded** frame as
a second native-res texture (`u_ghost` / `ghost_texture`, from
`wasm_game_fb_ptr`), and the shader re-applies the ghost after filtering as
a per-cell offset:

```
out = clamp(filtered + (responded[cell] − clean[cell]), 0, 1)
```

Both cell fetches use the picture's per-texel transform (DMG shade palette
when active). `apply()` returns its input pointer when the model is off, so
raw/responded pointer equality is the switch for the upload and uniform.

| situation | result |
|---|---|
| filter off | `filtered == clean[cell]` → `out == responded[cell]`, pixel-identical to the old pipeline (verified by `tools/filtershot` and the render test) |
| settled cell | delta 0, filter output untouched |
| settling cell, flat surroundings | exactly the panel's displayed value |
| settling cell inside a filtered edge band | the approximation: the fragment takes its cell's offset over a colour blended from two cells |

The last row is the whole error budget: the edge is drawn from clean pixels
(no shimmer) and the offset fades as the cell settles.

Unchanged: state advance stays on the CPU; `wasm_game_fb_ptr` keeps meaning
the responded frame for thumbnails, the paused card, bug reports and the
link/rollback blits; a stale `em.js` degrades to the old order; SGB never
engages it. Cost: one R16UI upload (≤ 77 KB) and one texel fetch per
fragment, noise next to the filters (`-d:gputime`).

`tools/filtershot/dump_frames <rom> <prefix> <script> <shots> <panel>` writes
clean/responded pairs; `render.mjs … <ghost dump>` renders every filter
through both orders (`*.old.*` responded-as-source, `*.new.*` clean + delta).
