# FIFO PPU: the model against Pan Docs' pixel FIFO

`src/dingbat/gb/fifo_ppu.nim`. Spec:
[Pan Docs, Pixel FIFO](https://gbdev.io/pandocs/pixel_fifo.html). The
per-dot derivations and every knob are in `docs/gb-derivations.md`; this
file lists where the renderer follows the page and where it departs.

## Background fetcher

* Five steps — get tile, data low, data high, sleep, push — the first four
  2 dots each, push attempted every dot until it succeeds (Pan Docs, "FIFO
  Pixel Fetcher"). `FETCHER_ORDER` spells each 2-dot step as `fsSleep` +
  step; its negative indices are the window startup fetch's idle head.
* "Get tile data high" also attempts a push, so there are three push chances
  per fetch cycle (Pan Docs, "Get Tile Data High"). A successful extra push
  sets `fetch_counter = 0` outright: the fetcher returns to step 1 the moment
  a push succeeds, which is the only way the 172-dot line adds up (6 dots of
  throw-away fetch + 6 of the real one + 160 pixels). Flagging the push and
  walking out the remaining steps instead put the two idle dots in the wrong
  place.
* Pixels are pushed only into an empty FIFO; horizontal flip (CGB attribute
  bit 5) pushes LSB first (Pan Docs, "Push").
* WX = 0 with `SCX & 7 > 0` shortens mode 3 by one dot (Pan Docs, "The
  Window").

## Objects

* The object check runs at the top of the shifter, before a pixel is popped:
  Pan Docs describes the fetch as happening when the scanline reaches the
  object's X, so its pixels must already be in the OAM FIFO when the
  background pixel is popped.
* Before mixing, the OAM FIFO is padded to 8 transparent lowest-priority
  pixels (`oam_idx = 0xFF`); an incoming pixel replaces the FIFO's if it is
  non-white and the FIFO's is white, or (CGB) it has the lower OAM index
  (Pan Docs, "Sprites").
* The BG fetcher keeps advancing while an object fetch waits for it (Pan
  Docs: "the fetcher is advanced one step until it's at step 5 or until the
  background FIFO is not empty"), and it is that wait that lengthens mode 3.
  The alternatives — freeze it, run it for the whole penalty, finish the
  fetch in flight — were swept against the mealybug set and trade rows
  rather than win; the comment at `tick_sprite_fetcher` records the sweep
  and what `m3_lcdc_tile_sel_change` says the answer must look like (an
  object fetch never lands between a tile's two bitplane reads).
* A second object at the same X does not repeat the wait; its fetch is
  6 dots: mooneye `acceptance/ppu/intr_2_mode0_timing_sprites` steps mode 3
  by exactly 6 dots per extra object stacked at X = 0.
* `SCX & 7 > 0` with an object at X = 0 lengthens mode 3 by `SCX & 7` dots;
  Pan Docs does not say whether it lands before or after the fetcher wait,
  and the renderer applies it after.
