# LCD ghosting × upscale filters: the per-cell delta

**Status:** PARKED — prototyped in commit `0698994`, then reverted by
decision (the combined look needs another pass); re-apply that commit to
bring the implementation back. The design below is the record for the
revisit. The `tools/filtershot` ghost-pair dumping and old/new-order
rendering survive the revert (the tool's "new" mode needs the delta shader
from `0698994` to mean anything).
**Code:** `web/glpresent.js` (`u_ghost` / `game_color`), `src/dingbat.nim`
(`ghost_texture` / `game_color`, `upload_frame`), `src/dingbat_wasm.nim`
(`wasm_game_fb_raw_ptr`), unchanged model in
`src/dingbat/common/lcd_response.nim`.
**Tests:** `web/render.test.mjs` (the two delta identities, GL readback);
`tools/filtershot/` renders old-vs-new comparisons offline.

## The problem

The LCD response model runs on the CPU, per emulated frame, at native
resolution — and until this change its *output* was the only frame the
presenter ever saw. The upscale filters (hq4x / xBR / xBRZ) therefore
filtered the **already-ghosted** picture. That order is fine with no filter,
but the filters are edge classifiers: a settling pixel holds an in-between
colour for a few frames, the classifier reads that transient as an edge (or
misses a real one), and its decision flips frame to frame — moving edges
shimmer and grow brief false shapes inside ghost trails.

The physically-right order is the other one: filter each **clean** frame
(the artwork), then apply the panel response to what is displayed. But the
response is *stateful* — a per-cell settle position advanced once per
emulated frame — and the filtered image only exists on the GPU at output
resolution. Porting the whole state machine to the GPU (a ping-pong state
texture at backing-store resolution) would mean per-emulated-frame render
passes, fast-forward multiplying them, state resets on resize, and the
link/rollback blit paths silently losing the effect. That design was
considered and rejected; this file documents the cheap one.

## The design: CPU state, GPU display

Nothing about the model changes. `lcd_response.apply()` still advances every
native cell once per emulated frame and still produces the frame a real
panel would display. What changes is *what the presenter uploads* and *where
the ghost is put back*:

- the **clean** frame feeds the texture the filters sample
  (`u_tex` on web, `input_texture` on native, `wasm_game_fb_raw_ptr`);
- the **responded** frame rides along as a second native-res texture
  (`u_ghost` / `ghost_texture`, unit 2, `wasm_game_fb_ptr`);
- after the upscale filter has produced a colour for the fragment, the shader
  re-applies the ghost as a **per-cell offset**:

  ```
  out = clamp(filtered + (responded[cell] − clean[cell]), 0, 1)
  ```

  where `cell` is the fragment's own native pixel, and both cell fetches go
  through the same per-texel transform the picture is drawn with (the DMG
  shade-palette substitution when active — so the ghost plays out in the
  user's palette, not in panel green).

The response's on/off signal needs no extra plumbing: `apply()` returns the
input pointer unchanged (zero-copy) when the model is off, so **pointer
equality between the raw and responded frames** is the switch. Both
frontends key the second upload and the `lcd_ghost` uniform off that.

## Why a delta, and when it is exact

The naive move — show `LUT(state)` per fragment — would *replace* the
filtered colour with the cell's settle value and erase the filtering
wherever pixels settle. The delta form keeps both:

| situation | what the delta does |
|---|---|
| filter off | `filtered == clean[cell]`, so `out == responded[cell]` — **pixel-identical to the old pipeline** (verified byte-identical end to end by `tools/filtershot` and by the render test's solid-ghost case) |
| settled cell | `responded == clean`, delta 0 — the filter output passes through untouched |
| settling cell, flat surroundings | `filtered == clean[cell]`, so `out` is exactly the panel's displayed value |
| settling cell, inside a filtered edge band | the *approximation*: the fragment takes its own cell's settle offset while showing a colour blended from two cells |

That last row is the entire error budget, and it is the right trade: the
edge is drawn from clean pixels (no shimmer — the fix), and the offset it
carries fades to zero as the cell settles, so the trail still moves
smoothly. Per-native-cell trails are also what the hardware does — it is
the LCD's cells that settle, not some finer grid.

One second-order note: the CPU advances state from *raw* targets while the
displayed colour near an edge is blended, so a mid-edge fragment borrows its
cell's settle trajectory rather than owning one. Raw and filtered colours
only diverge inside an edge's blend band, which is exactly the region the
row above already covers.

## What deliberately did not change

- **State advance** stays per emulated frame on the CPU: fast-forward,
  120 Hz displays, dropped presents, rewind — all keep today's semantics.
- **`wasm_game_fb_ptr` keeps its meaning** (the responded frame) for every
  other consumer: thumbnails, the paused card, the bug-report preview, and
  the link/rollback blit paths all still show the panel's output.
- **A stale `em.js`** without the raw export degrades to the old behaviour
  (responded frame as the filter source, delta off) — nothing breaks.
- **SGB** is unaffected: the panel resolves to `off` under an adapter, the
  pointers stay equal, the delta never engages.

## Cost

One extra native-res R16UI upload per frame (≤ 77 KB), one extra texel fetch
plus the delta arithmetic per fragment, gated behind a uniform. No extra
passes, no framebuffer objects, no MRT. Not measured as distinguishable from
noise next to the filters themselves; the native `-d:gputime` sweep covers
the combination if numbers are ever wanted.

## Seeing it

`tools/filtershot/dump_frames <rom> <prefix> <script> <shots> <panel>`
writes clean/responded pairs; handing the pair to
`tools/filtershot/render.mjs … <ghost dump>` renders every filter through
both pipelines (`*.old.*` = responded-frame-as-source, the pre-fix order;
`*.new.*` = clean source + delta). The comparison artifact from this branch
uses Pokémon Blue's intro (DMG panel, the smeariest) mid-motion.
