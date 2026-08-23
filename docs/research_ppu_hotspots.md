# Research: GBA PPU hotspots across real gameplay states

Per-component stub-out ceilings and leaf profiles on five in-game save
states (Emerald, FireRed, Kirby NiDL, Minish Cap, Golden Sun; all DISPCNT
mode 0, all 160 lines rendered every frame). Method: `tests/dingbat_bench.nim`,
600 frames after 120 warmup, best-of-9, one interleaved sweep per table,
per-build ROM copies; anything under ~1 % is noise. Probes are `when
defined(probeX)` guards in a throwaway copy of `src/dingbat/gba/ppu.nim`.
Pixel-exact probes were gated on `DINGBAT_BENCH_HASH=1`.

## Ceilings (mean over five games, spread in brackets)

| stage removed | ceiling |
|---|---|
| whole `scanline` body | +44 % [+32, +66] |
| `render_reg_bg` | **+15.2 %** [+12, +20] — the largest named PPU component in all five profiles (11–17 %), 1.4–2.6x the compositor |
| `composite` | +9.4 % [+7, +13] |
| `render_sprites` | +6.9 % [+5, +13] |
| per-scanline BG palette clears | +0.1 % (noise) |

Converting each ceiling to a time fraction reproduces the profile share
within ~1 %, which is the reason to trust either instrument. Boot-sequence
workloads are not a proxy: FireRed measures +20 % from boot and +32 % in game.

## Inside each component

* **`render_reg_bg` is ~60 % unpack, ~40 % walk.** Removing pixel emission
  but keeping the span walk and screen-entry fetch is +9.4 %. Counters: the
  4bpp inner loop almost always runs a whole tile-aligned 8-pixel span
  (`px_per_span` = 8.00 on four games, 7.80 on Golden Sun), so a SWAR
  "whole aligned 4bpp row" path (expand 8 nibbles from the already-loaded
  `uint32`, byte-reverse for flip, mask-and-add the palette bank except for
  index 0) covers ~97 % of spans. Realistic capture +4–6 %.
* **`render_sprites` is the OAM scan, not pixel work.** 128 entries examined
  per line for 0.2–1.7 sprites on the line. Deleting the per-pixel loop is
  noise on three games; visiting 8 entries instead of 128 is **+5.2 %**
  (76 % of the component). Hoisting the y-test above the affine loads is
  +0.8 % — the iteration count is the cost. Needs a per-line candidate list
  (bucket by y, rebuilt when OAM was written), keeping OAM order so
  `obj_cycles` charging is unchanged. Invalidation on mid-frame OAM writes
  (H-blank DMA) is the whole risk.
* **Compositor paths in gameplay:** both Pokémon titles take the windowed
  outer path on every line and resolve to one uniform 240-column span every
  time (win0 full-width, painted last); Kirby and Minish Cap are whole-line;
  Golden Sun runs 68 % of columns through the blend loop but only 0.9 % of
  those pixels search for a bottom layer. The shade loop was never entered.
  A pixel-exact uniform-window fast path (answer from the window registers)
  is +2.6 % / +1.9 % on the Pokémon titles, noise elsewhere; a shipped version
  needs the general uniformity test (win1, wrap-around `x1 > x2`, OBJ window).

## Negative results

* Per-scanline buffer clears: −0.1 % confound-free (a second identical clear
  into a dummy buffer). Removing the `sprite_pixels` clear *appears* worth
  +3.5 % only because stale sprite pixels short-circuit the layer walk.
* Forcing every span through `composite_span_opaque`: +0.0 % mean, +1.3 % on
  Golden Sun. The general loop's extra bookkeeping is free next to the walk.
* `render_aff_bg` / `render_bitmap`: not exercised by mode-0 gameplay.
* Every micro-optimisation-shaped probe (hoisting, a fourth inner loop,
  clears) came back as noise; the three surviving items are structural.

## Ranked

1. `render_reg_bg` whole-tile 4bpp unpack — ceiling +9.4 %, local contract,
   hash-gated.
2. Per-line OBJ candidate list — +5.2 % measured directly.
3. Uniform-window fast path — ~+2 % on the two best-selling titles.
4. Compositor rewrite — +9.4 % ceiling but three inner loops and the
   renderer's most correctness-sensitive code; do 1–3 first
   (`docs/performance.md`).
