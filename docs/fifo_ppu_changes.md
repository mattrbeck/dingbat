# FIFO PPU Changes — Detailed Explanation

Reference: [pandocs pixel_fifo.md](https://github.com/corybsa/pandocs/blob/develop/content/pixel_fifo.md)

---

## 1. Fetcher step count: 7 → 8 cycles

**`gb.nim:297-299`** — `FETCHER_ORDER` changed from 7 to 8 elements, adding `fsSleep` between `fsGetTileDataHigh` and `fsPushPixel`.

**`fifo_ppu.nim:136`** and **`fifo_ppu.nim:164`** — `mod 7` changed to `mod 8`.

**Pandocs reference** — Section "FIFO Pixel Fetcher":

> The pixel fetcher has 5 steps. The first four steps take 2 cycles each and the fifth step is attempted every cycle until it succeeds. The order of the steps are as follows:
> - Get tile
> - Get tile data low
> - Get tile data high
> - Sleep
> - Push

Each of the first four steps takes 2 cycles. We model this with a `fsSleep` before each real step, so each real step occupies 2 array positions. The old code was missing the Sleep step (step 4) between Get Tile Data High and Push, making the array only 7 elements (6 cycles for steps 1-3 + 1 for Push) instead of 8 (8 cycles for steps 1-4 + 1 for Push).

---

## 2. Extra push attempt during Get Tile Data High

**`fifo_ppu.nim:125-126`** — After reading the high byte and past the first-fetch discard, calls `try_push_bg_pixels`. If successful, sets `bg_pixels_pushed = true`.

**`fifo_ppu.nim:128-131`** — `fsPushPixel` checks `bg_pixels_pushed` first. If the extra push already succeeded, it advances `fetch_counter` without re-pushing.

**`fifo_ppu.nim:102`** — `bg_pixels_pushed` reset to `false` at `fsGetTile` (start of each fetch cycle).

**`fifo_ppu.nim:59`** — Also reset in `fifo_reset_bg`.

**Pandocs reference** — Section "Get Tile Data High":

> This also pushes a row of background/window pixels to the FIFO. This extra push is not part of the 8 steps, meaning there's 3 total chances to push pixels to the background FIFO every time the complete fetcher steps are performed.

The 3 chances are: (1) the extra push during Get Tile Data High, (2) the Sleep step that follows (a cycle where the Push could theoretically fire), and (3) the Push step itself. Once any push succeeds (FIFO was empty), the `bg_pixels_pushed` flag prevents a duplicate push. Without this flag, the Push step would wait for the FIFO to drain and then push the same tile data a second time, doubling every tile and skipping every other column.

---

## 3. `try_push_bg_pixels` extracted as a helper

**`fifo_ppu.nim:68-84`** — The push logic (check FIFO empty, push 8 pixels with color/palette/flip, increment `fetcher_x`) was extracted from the old inline `fsPushPixel` case into a reusable proc. Both `fsGetTileDataHigh` (line 125) and `fsPushPixel` (line 129) call it.

**Pandocs reference** — Section "Push":

> Pushes a row of background/window pixels to the FIFO. [...] Pixels are only pushed to the background FIFO if it's empty.

And the horizontal flip behavior:

> If the tile is flipped horizontally the pixels will be pushed LSB first. Otherwise they will be pushed MSB first.

This is at line 73: `if (tile_attrs and 0b0010_0000) != 0: col else: 7 - col` — bit 5 of the CGB tile attributes is horizontal flip. When set, iterate `col` (0→7, LSB first). Otherwise `7-col` (MSB first).

---

## 4. Sprite fetcher rewritten as multi-phase state machine

**`fifo_ppu.nim:168-213`** — The old sprite fetcher walked through the same `FETCHER_ORDER` array with no-op steps. The new one uses `sprite_fetch_phase` (0-6) with specific behaviors per phase.

**Pandocs reference** — Section "Sprites", which describes a sequential process:

**Phase 0** (line 177-186) — Advance BG fetcher until at Push or FIFO non-empty:

> At this point the fetcher is advanced one step until it's at step 5 or until the background FIFO is not empty. Advancing the fetcher one step here lengthens mode 3 by 1 cycle.

Each tick calls `tick_bg_fetcher`. The check `FETCHER_ORDER[ppu.fetch_counter] == fsPushPixel or ppu.fifo.size > 0` corresponds to "step 5" (Push) or "background FIFO is not empty." Each cycle spent in this phase is the +1 cycle penalty.

**Phase 1** (lines 187-189) — First extra BG fetcher advance:

> After checking for sprites at X coordinate 0 the fetcher is advanced two steps. The first advancement lengthens mode 3 by 1 cycle

One call to `tick_bg_fetcher`, consuming 1 cycle.

**Phase 2** (lines 191-196) — Second extra BG fetcher advance (+3 cycles):

> and the second advancement lengthens mode 3 by 3 cycles.

The BG fetcher is advanced on the first tick (`fetch_counter_sprite == 0`), then 2 idle ticks follow, totaling 3 cycles.

**Phase 3** (lines 197-198) — Lower sprite tile address (+1 cycle):

> The lower address for the row of pixels of the target object tile is now retrieved and lengthens mode 3 by 1 cycle.

One idle cycle representing the address retrieval.

**Phase 4** (lines 199-204) — Upper sprite tile address + data fetch:

> The upper address for the target object tile is now retrieved and does not shorten mode 3.

This is where `sprite_fetch_merge` runs — the actual sprite tile data is read and merged into the OAM FIFO. "Does not shorten mode 3" means no extra penalty cycle.

**Phase 5** (lines 205-206) — Exit penalty:

> Exiting object fetch lengthens mode 3 by 1 cycle.

One cycle, then `fetching_sprite = false`.

---

## 5. BG fetcher advances during sprite fetch (not frozen)

**`fifo_ppu.nim:178, 188, 192-193`** — Phases 0, 1, and 2 call `tick_bg_fetcher`.

**`fifo_ppu.nim:275-279`** — Mode 3 loop runs *either* `tick_sprite_fetcher` (which internally advances the BG fetcher) *or* `tick_bg_fetcher` + `tick_shifter`.

**Pandocs reference** — Section "Sprites":

> At this point the fetcher is advanced one step [...]
> After checking for sprites at X coordinate 0 the fetcher is advanced two steps.

"The fetcher" here refers to the BG pixel fetcher (the only fetcher described in the "FIFO Pixel Fetcher" section). The spec explicitly says the BG fetcher is advanced as part of the sprite encounter — it is not paused.

---

## 6. OAM FIFO pre-padded to 8 transparent pixels

**`fifo_ppu.nim:144-146`** — Before the sprite merge loop, pad with `GbPixel(color: 0, palette: 0, oam_idx: 0xFF, obj_to_bg: 0)`.

**Pandocs reference** — Section "Sprites":

> Before any mixing is done, if the OAM FIFO doesn't have at least 8 pixels in it then transparent pixels with the lowest priority are pushed onto the OAM FIFO.

`oam_idx: 0xFF` is the lowest priority (highest OAM index = least priority on CGB).

---

## 7. Sprite pixel merge logic

**`fifo_ppu.nim:155-160`** — Replace condition: `(px.color != 0 and existing.color == 0) or (CGB and px.oam_idx <= existing.oam_idx and px.color != 0)`.

**Pandocs reference** — Section "Sprites":

> If the target object pixel is not white and the pixel in the OAM FIFO *is* white, or if the pixel in the OAM FIFO has higher priority than the target object's pixel, then the pixel in the OAM FIFO is replaced with the target object's properties.

The old code had `existing.color == 0` without checking that the incoming pixel was non-zero. The spec says "target object pixel is not white **and** the pixel in the OAM FIFO is white" — both conditions must hold. The second clause ("higher priority" = higher OAM index) maps to `px.oam_idx <= existing.oam_idx` (lower index = higher priority, so the existing pixel has lower priority if its index is higher).

---

## 8. SCX penalty for sprites at X=0

**`fifo_ppu.nim:180-184`** — At the end of phase 0, checks if the sprite is at X=0 and SCX&7 > 0. If so, enters phase 6 which burns `SCX & 7` idle cycles.

**`fifo_ppu.nim:207-211`** — Phase 6 decrements the counter each cycle, then transitions to phase 1.

**Pandocs reference** — Section "Sprites":

> When SCX & 7 > 0 and there is a sprite at X coordinate 0 of the current scanline then mode 3 is lengthened. The amount of cycles this lengthens mode 3 by is whatever the lower 3 bits of SCX are. After this penalty is applied object fetching may be aborted. Note that the timing of the penalty is not confirmed. It may happen before or after waiting for the fetcher.

We placed the penalty after phase 0 (after waiting for the fetcher) and before phase 1, which is one of the two valid orderings the spec allows.

---

## 9. Same-X sprite optimization

**`fifo_ppu.nim:164-166`** — When the next sprite has the same X coordinate, `sprite_fetch_phase` is set to 3 (tile data fetch) instead of restarting at 0.

**Pandocs reference** — Section "Sprites":

> Everything in this section is repeated for every sprite on the current scanline unless it was decided that fetching should be aborted or the X coordinate is 160.

The spec describes the full process being "repeated" per sprite. However, for same-X sprites the BG fetcher is already in position (phases 0-2 achieved alignment for the previous sprite at this X). Skipping back to phase 3 avoids redundant BG fetcher advancement. This is consistent with how real hardware behaves — same-X sprites have lower overhead because the fetcher doesn't need repositioning.

---

## 10. WX=0 + SCX&7>0 mode 3 shortening

**`fifo_ppu.nim:49-50`** — In `fifo_sample_smooth_scroll`, when window is active with WX=0 and SCX&7>0, `lx` is incremented by 1 (discarding one fewer pixel, shortening mode 3 by 1 cycle).

**Pandocs reference** — Section "The Window":

> When WX is 0 and the SCX & 7 > 0 mode 3 is shortened by 1 cycle.

---

## 11. Sprite trigger moved before pixel pop/render

**`fifo_ppu.nim:226-233`** — The sprite trigger check now runs at the top of `tick_shifter`, before any pixel is popped from the FIFOs. If triggered, it returns early — the pixel waits until sprite data is fetched.

Previously the check was at the bottom, after the pixel had already been rendered and `lx` incremented. This caused the first overlapping pixel to be rendered without sprite data.

**Pandocs reference** — Section "Sprites":

> The following is performed for each sprite on the current scanline if LCDC.1 is enabled [...] and the X coordinate of the current scanline has a sprite on it.

The spec describes sprite fetching as happening *when the scanline reaches the sprite's position* — meaning before that pixel is output. Section "Pixel Rendering" also says:

> If there are pixels in the background and OAM FIFOs then a pixel is popped off each.

This implies sprite data must already be in the OAM FIFO when the pixel is popped. The old placement (check after render) violated this ordering.
