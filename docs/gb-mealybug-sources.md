# Mealybug Tearoom Tests, read from the source

The suite ships its `.asm` sources, and about a third of them carry a header
that states in prose what the ROM measures. The rest state it in code: a write
at a counted cycle, a register held constant as a control, and an object whose
OAM X advances one pixel per 8-line band so that one frame is eighteen
measurements of the fetch phase rather than one. This file is what those
sources say, whether dingbat agrees, and which scored rows each governs.

Sources read at `mattcurrie/mealybug-tearoom-tests` **`70e88fb`** ("Add test for
MBC3's RTC") — 39 `.asm` files under `src/ppu`, `src/dma`, `src/mbc` and `inc/`,
plus the repository's own `the-comprehensive-game-boy-ppu-documentation.md`,
which is the single densest hardware document in the suite and is **not** part
of any test.

Only the 24 DMG rows are scored (`mealybug.py` ends `all = dmgs`). Pixel counts
below are wrong-pixels out of 23040 on the `_dmg_blob` reference.

---

## 1. What the harness contributes, and it is not nothing

Every `m3_*` ROM is one shape: a STAT **mode 2** interrupt taken out of a field
of `nop`s, a handler that writes one register at a counted offset, and a
`ld b,b` breakpoint on the 10th VBlank. Three things about that shape are
load-bearing and are the same in all of them.

### 1.1 The handler's zero point is 32 T-cycles

> `; 20 cycles interrupt dispatch + 12 cycles to jump here: 32`
> — every `m3_*` handler; e.g. `src/ppu/m3_bgp_change.asm:107`

20 T of interrupt dispatch plus a 12 T `jp`. `m3_scx_low_3_bits.asm:114` is the
one exception and says so: its vector is a 4 T `jp hl`, so its handler starts at
**24**. Every "the write lands at dot N" statement in this file is 32 (or 24)
plus the counted instruction cycles, measured from the mode 2 interrupt.

### 1.2 Line 0 runs 4 T-cycles out of step with every other line

```asm
; line 0 timing is different by 4 cycles, so jump only
; when on line 0
; 24 cycles (or 28 cycles when LY = 0)
line_0_fix: MACRO
    ldh a, [rLY]
    and a
    jr nz, .target\@
.target\@
    ENDM
```
— `inc/utils.asm:193`

The parenthetical is transposed relative to the code: `and a` sets Z when
LY = 0, so the `jr nz` is **not** taken there and the macro costs 12 + 4 + 8 =
**24** T on line 0 against 12 + 4 + 12 = **28** everywhere else. The macro
exists to cancel a hardware difference, so what it asserts is that **on line 0
the mode 2 STAT interrupt arrives 4 T-cycles later, relative to the start of
drawing, than it does on lines 1..143** — burn 4 fewer and the write lands on
the same dot of the line.

**dingbat disagrees.** `-d:gb_m3_trace` on `m3_lcdc_tile_sel_change` puts the
handler's first LCDC write at **dot 101 on LY 0 and dot 105 on LY 1..143** —
i.e. dingbat's line-0 interrupt is at the same offset as everybody else's, so
the macro's 4-cycle correction is uncancelled and every mealybug ROM's line 0 is
4 dots early. It is visible as a line-0-only residual on
`m3_bgp_change` (21 of its 403 remaining), `m3_bgp_change_sprites` (20 of 124),
`m3_lcdc_bg_en_change` (8 of 67), `m3_scy_change` (51 of 417) and
`m3_lcdc_win_en_change_multiple_wx` (9 of 343) — call it 100–150 pixels across
the set. **Not changed here**: moving the line-0 mode 2 edge by 4 dots reaches
the STAT model that mooneye's `intr_2_*` and eight gambatte families pin, and
that trade has not been measured. It is the cheapest well-evidenced thing left
in this area and it is written down so the next pass starts from the ROM rather
than from a pixel.

### 1.3 The objects are the ruler, not scenery

Almost every `m3_*` OAM table is `Y = $10 + 8k, X = k` for k = 0..17 (identical
in `m3_lcdc_bg_en_change`, `m3_lcdc_tile_sel_change`, `m3_lcdc_bg_map_change`,
`m3_lcdc_win_map_change`, `m3_obp0_change`, …). The object costs
`6 + max(0, 5 - (X mod 8))` dots, so each 8-line band puts the handler's write
on a different T-cycle of the fetch, and the `2`-suffixed CGB ROMs say so
outright:

> `; Sprites are positioned to cause the write to occur on different T-cycles of`
> `; the background tile fetch, showing when the change to the bit takes effect.`
> — `m3_scy_change2.asm:22`, and identically in `m3_lcdc_bg_en_change2`,
>   `m3_lcdc_bg_map_change2`, `m3_lcdc_tile_sel_change2`,
>   `m3_lcdc_tile_sel_win_change2`, `m3_lcdc_win_map_change2`,
>   `m3_scx_high_5_bits_change2`

Consequence for measurement, already in `tools/gbppu/README.md` and confirmed
here: a whole-frame percentage averages eighteen independent measurements and
cannot decide anything. Score per band.

---

## 2. The suite's own PPU documentation

`the-comprehensive-game-boy-ppu-documentation.md` is 56 lines and every one is a
hardware claim. The two that matter for the scored set:

### TILE_SEL (LCDC.4)

> "`TILE_SEL` is read during the `0` and `1` stages of background tile data
> fetching. Changing its value during background tile data fetch allows for
> mixing tile bitplane data from two different tile patterns."

**dingbat agrees.** `tick_bg_fetcher`'s `fsGetTileDataLow` / `fsGetTileDataHigh`
each re-derive `bg_window_tile_data(ppu)` and the signed/unsigned tile-number
interpretation on their own dot, and `fsGetTile` does not read the bit at all.
The mixing is real and reproduced — `m3_lcdc_tile_sel_change`'s bands 5–7 are
exact, at shade 2 for the first tile (plane 1 new, plane 0 old) and shade 1 for
the next (plane 0 new, plane 1 old). See §4.3 for what is still wrong.

### SCY (`$FF42`)

> "The `SCY` register can be written to at any time. Writes will take effect
> immediately on the DMG. On CGB and AGB devices, writes appear to take effect
> 2 T-cycles later."
>
> "On the DMG and CGB revisions up to and including the 'CPU GBC C' revision,
> the `SCY` register is read during the background tile fetch `B`, `0` and `1`
> stages. … On the AGB and CGB revisions 'CPU GBC D' and greater, the `SCY`
> register is only read during the `B` stage, so no tile bitplane data mixing
> can occur."

**dingbat agrees on structure.** `fsGetTile` reads SCY for the map row
(`(ly + scy) shr 3`) and both data stages re-read it for the row inside the tile
(`(ly + scy) and 7`) — B, 0 and 1, exactly. `CGB_SCY_LATENCY` is the second
sentence. This is the only mechanism statement available for `m3_scy_change`,
which is **the one red DMG row with no hardware photograph**.

### WIN_EN (LCDC.5) — four sentences, all four implemented

> "WIN_EN can be disabled during mode 3. The disabling will take effect at the
> end of the current window tile being drawn. When the current window tile has
> finished being drawn, the PPU will start drawing background tiles again."
> "When the background resumes drawing it is on a tile boundary. The low 3 bits
> of SCX have no effect."
> "Setting WIN_EN again during mode 3 on the same scanline will have no effect
> unless WX has been updated to set the window to activate on a pixel that
> hasn't been drawn yet."
> "If WX has been updated correctly and WIN_EN is set again then the PPU stops
> drawing the background, and will activate the window again, but it will start
> drawing the **next row** of the window, on the same scanline."

**dingbat agrees**, and the first two are quoted verbatim at `WIN_EN_ABORT` in
`fifo_ppu.nim`. `m3_lcdc_win_en_change_multiple` is 100%.

---

## 3. Per-test catalogue

Rows are ordered by wrong pixels **before** this pass.

### 3.1 `m3_lcdc_bg_en_change` — 2193 → **67**

Source (`m3_lcdc_bg_en_change.asm:21`, handler at `:144`):

```asm
; Sets bit 0 (BG_EN) of LCDC register during mode 3 with sprites
; at different X coordinates
    line_0_fix
    REPT 9 / nop / ENDR
    ld [hl], c      ; BG off
    nop
    ld [hl], b      ; BG on
    ld [hl], c      ; BG off
    ld [hl], b      ; BG on
```

No prose beyond the first line — the *code* is the assertion. `ld [hl],r` is
8 T and `nop` is 4, so BG_EN is **low for exactly 12 dots, high for 8, low for
8**. The DMG reference answers with white runs of exactly **12** (x = −1..10,
clipped at the screen edge) and **8** (x = 19..26), over a background whose
`ABC…` glyphs are otherwise in their ordinary columns — verified by rendering
the same ROM with those five opcodes NOPped out and diffing.

Neither run is on a tile boundary, and 19 is not a multiple of 8.

**dingbat disagreed**, and this was the largest DMG residual in the suite:
LCDC.0 was sampled in `try_push_bg_pixels`, once per eight pixels, so a BG-off
window could only ever blank a whole tile. **Fixed** (`BG_EN_AT_MIX`, default
1): the bit is now read in `fifo_mix`, per emitted pixel, and it therefore
carries `MIXER_PRIORITY_BACK` with the rest of LCDC's priority half for free.
2193 → 67 DMG, 1824 → 11 on the CGB references, and
`m3_lcdc_bg_en_change2` 364 → 6.

Residual: one pixel per band at the leading edge of the first run on bands 2 and
9..17, plus line 0 (§1.2).

### 3.2 `m3_bgp_change` — 820 → **403**, and `m3_bgp_change_sprites` — 536 → **124**

`m3_bgp_change` is the cleanest instrument in the suite and nobody had read it
as one. It calls neither `reset_tile_maps` nor any VRAM fill, so **VRAM is all
zeroes: every pixel on the screen is colour 0, and the frame is literally BGP
bits 1:0 sampled once per dot.** There are no objects (OAM is `$FF`-filled) and
SCX = 0, so pixels run one per dot with no penalty anywhere.

The handler writes BGP seven times at counted offsets (`:106`–`:162`), all
`ld [c],a`:

| write | dot from the mode 2 IRQ | value (b = `swap(LY)`) |
|---|---|---|
| 1 | 80  | b     |
| 2 | 96  | b + 1 |
| 3 | 108 | b     |
| 4 | 168 | b + 2 |
| 5 | 180 | b     |
| 6 | 240 | b − 1 |
| 7 | 252 | b     |

Run-length the reference and the six edges land at x = 1, 13, 73, 85, 145, 157 —
**`dot − 95`, exactly, at all six**. And the edge is *three*-valued. LY 17
(b = `$11`):

| x | 0 | 1 | 2..12 | 13 | 14.. |
|---|---|---|---|---|---|
| BGP | `$11` | **`$13`** | `$12` | **`$13`** | `$11` |

`$13` is neither the old value nor the new one. It is `$11 or $12`. The same
holds at every one of the six writes on every one of the 144 lines: the pixel at
the far end of the mixer tail sees **`old or new`** for exactly one dot, and
every nearer pixel takes the new value cleanly. Lines where the OR happens to
equal one of the two (LY 1: `$10 or $11 = $11`) show a two-valued edge, which is
where the effect hid.

**Fixed** (`MIXER_PALETTE_OR`, default 1): the FF47/48/49 write paints
`MIXER_PALETTE_BACK` with `old or new` and the rest of the tail with `new`.
This has **no free parameter** — five columns × 144 lines = 720 cells with 144
different old/new pairs go from wrong to exact, and the two rows move +417 and
+412 together. `m3_obp0_change` stays at 100%, `age/m3-bg-bgp-dmgC` 62 → 2 and
`daid/ppu_scanline_bgp-dmg` +102.

It is **DMG only**. Running the same two carts on CGB against the suite's
`_cgb_c` references wants a clean edge (22732 with a clean edge, 22321 with an
OR pixel; `_sprites` 22948 against 22600), which is exactly what
`CGB_MIXER_LATENCY = 1` already says: the CGB's write reaches one pixel less far
down the tail, and the OR pixel sits at the far end.

**Adjudicated against the photograph**, per-column, on the 820 cells this row
started with (`tools/gbphoto`, `photos/DMG-blob/m3_bgp_change.jpg`):

| column | n | hardware ≈ reference | at > 2σ |
|---|---|---|---|
| 1   | 64  | 65.6% | 73.9% |
| 13  | 112 | 78.6% | 69.0% |
| 73  | 64  | 90.6% | 93.5% |
| 85  | 80  | 92.5% | 94.8% |
| 145 | 96  | 79.2% | 80.2% |
| 157 | 97  | 64.9% | 72.3% |
| 158 | 143 | 75.5% | 81.2% |
| 159 | 143 | 86.7% | 92.2% |

Every column, including all six OR columns, sides with the reference. These are
one-pixel-wide vertical features, which `tools/gbphoto/README.md` names as the
worst case for a photograph, so 65–93% is what a clear verdict looks like here.

**Cost, named:** gambatte's `dmgpalette_during_m3_4`, `_5`, `_scx1_4` and
`scx3/_5` go 8 → 150 wrong pixels (one pixel per line, at the one column where
their `old or new` differs from `new`), while `lycint_dmgpalette_during_m3_4`
goes 1284 → 1140. All five were already red and none is a pass/fail row. Those
PNGs are another emulator's output; the mealybug photograph is hardware, and it
is the only hardware in the argument.

**What is left (403 + 124):** `m3_bgp_change`'s residual is now *entirely*
`x = 157..159` — the last write lands on dot 252, which is the first dot of mode
0, and `fifo_recompose_last` is guarded on mode 3. Hardware clocks the line's
last pixels out of the mixer during the first dots of H-Blank and that write
reaches all three of them. Relaxing the guard alone is not the fix: the tail
burst (`fifo_burst_tail`) has already run `lx` to 160 by then, so the write
would land on 158/159 and not on 157. That is a change to where the tail is
accounted, i.e. to `M3_END_EARLY`'s neighbourhood, and it is not taken here.
`m3_bgp_change_sprites`'s remaining 124 are per-band left-edge pixels (x = 0..9),
a different mechanism.

This closes the open item in `docs/gb-failure-triage.md` that said
`m3_bgp_change` "is not a reliable vote on `MIXER_PALETTE_BACK` until that
~800-pixel residual has a name". It has two names now, one of them fixed.

### 3.3 `m3_lcdc_tile_sel_change` — 776 → **8**, and `m3_lcdc_bg_map_change` — 192 → **0**

Both handlers are the same six lines: `line_0_fix`, 9 `nop`s, `ld [hl],c`,
`ld [hl],b`. So **the changed bit is set for exactly 8 dots**, dots 105..112 by
dingbat's own trace. `m3_lcdc_tile_sel_change` fills both maps with tile 0 and
puts an all-`$00` tile at `$9000` and an all-`$FF` tile at `$8000`, so each tile
of the frame reports the *pair* (TILE_SEL at the plane-0 read, TILE_SEL at the
plane-1 read) as one of four shades. Eighteen bands × one pair each.

**The reference never reports a pair whose two reads are more than 2 dots
apart.** Bands 0–4 read shade 3 (both planes new); bands 5–7 read shade 2 then
shade 1 on the next tile (rising edge inside one tile's 2-dot gap, falling edge
inside the next one's); bands 8–12 put the whole pulse on tile 0.

**dingbat splits tiles.** On 13 of the 18 bands the object fetch lands between
the two bitplane reads and they come out **8 dots apart** — band 0 reads plane 0
at dot 98 and plane 1 at dot 106, straddling the write at 105, and reports
shade 2 where hardware reports shade 3. `m3_lcdc_bg_map_change` is the same
defect on a coarser instrument (two maps, white and black tiles), which is why
it moves in lockstep.

This is *not* fixed by any of the four rules for "which dots of the penalty the
BG fetcher may run on" — they were swept through the `-d:OBJ_BG_RUN` knob and
are 550072 / 550274 / 550590 / 550513 mealybug DMG pixels, all trading
`m3_lcdc_tile_sel_win_change` and `m3_lcdc_win_map_change` for what they buy.
In particular the literal reading of Pan Docs' "waiting for the BG fetch to
finish" (`OBJ_BG_RUN=3`: run only to complete a fetch already under way) does
not fix band 0, because at the trigger dot the fetcher has just pushed and there
is no fetch in flight. **The finding, stated precisely: hardware never puts an
object fetch between a background tile's two bitplane reads, dingbat does on 13
of 18 bands, and the cause is the phase of the penalty against the fetch cycle
rather than the penalty's own length** (which `objtab.py` against GBMicrotest
`ppu_spritex_vs_scx` pins at 0/153 mismatched cells and must not move).

#### 2026-08-09: read the whole frame back, and it names the boundary

The way through was to stop asking "which dots may the fetcher run on" and ask
the frame **which fetch the pulse landed on**, band by band. Write the pulse as
the dot window `W = [105, 112]` and the object-free schedule as tile *n*'s
B/0/1 reads on dots `8n+88`, `8n+90`, `8n+92` (tile 0's on 90/92/94), and all
eighteen bands of the reference say one thing:

| OAM X | the pulse falls on the fetch of | tile it displays |
|---|---|---|
| 0–7 | the tile drawn at x = 8..15 | shade 3, or 2 then 1 for X = 5..7 |
| 8–15 | the tile drawn at x = 16..23 | shade 0, then 1 from X = 13 |
| 16, 17 | the tile drawn at x = 16..23, **undisturbed** | shade 3 |

i.e. **the penalty is inserted after the fetch of tile `floor(X / 8)`**, while
The Pixel of an object at OAM X sits in tile `floor(X / 8) - 1`. The fetcher
runs a tile ahead of the shifter, so that is the fetch which was in flight while
The Pixel's own tile was on screen — Pan Docs' "waiting for the BG fetch to
finish", with the lead made explicit. A tile's three reads are never split.

**No rule phrased on the fetcher's phase can express this, and the frame proves
it rather than suggesting it.** X = 0 and X = 8 trigger on the same dot (the
first push, which fills the FIFO), cost the same 11 dots, and leave the fetcher
on the same counter — and the reference gives band 0 both planes inside the
pulse and band 8 neither. The only thing that differs between them is which
tile The Pixel is in, which is `idx` at the trigger, and `idx < 0` (an object
hanging off the left edge) is exactly the case where the fetch being waited for
finished *on the trigger dot itself*. Band 4 (X = 4, penalty 7) is the one band
that then separates whether the fetcher resumes with the shifter or one dot
after it: it wants one dot after, which is the dot the BG fetch had already
taken.

Landed as `OBJ_BG_RUN = 4`, derived at `tick_sprite_fetcher` in
`gb/fifo_ppu.nim`. `m3_lcdc_tile_sel_change` 776 → 8 (all eight on LY 0, i.e.
the line-0 offset of §1.2), `m3_lcdc_bg_map_change` 192 → **0**, `m3_scy_change`
417 → 83, mealybug DMG 550274 → 551568 and CGB 1852598 → 1854215, gambatte
3658 → 3659. Mode 3's length does not move anywhere: `objtab.py` stays 0/153 and
1660 ROM/device runs are line-for-line identical under `-d:gb_m3_len`.

### 3.4 `m3_scy_change` — 417 → **83**

> `; Changes the SCY register during mode 3, with SCX set to LY on each row.`
> — `m3_scy_change.asm:21`

The handler (`:117`) writes SCY 24 times back to back with `ld [hl],r`, cycling
0,1,2,3,4,3,2,1,0,1,… — one write every 8 dots across the whole visible width,
with a *distinct value per fetch cycle*. Combined with the doc's "read during
the B, 0 and 1 stages" this is a direct readout of which SCY value each of the
three reads of every tile saw. It is the only red DMG row with no photograph,
and the doc quoted in §2 is a better source than a photograph would have been.

dingbat's structure matches (B, 0 and 1, each on its own dot). The residual was
87 lines of a few pixels each, concentrated at tile boundaries, and moved with
`OBJ_BG_RUN` — i.e. it was the same split-fetch defect as §3.3, and four fifths
of it went with it (417 → 83 DMG, 534 → 348 CGB) for no change of its own.

### 3.5 `m3_window_timing` — 29, and `m3_window_timing_wx_0` — 4

`m3_window_timing.asm:21` is the most quantitative header in the suite:

> "For rows with smaller values of WX, there are fewer white pixels visible due
> to the palette change happening **after the 6 T-cycle window startup fetch**.
> For rows with larger values of WX, there are more white pixels visible due to
> the palette change happening **before** the 6 T-cycle window startup fetch.
> The stair step pattern is visible due to the palette being changed **during**
> the 6 T-cycle window startup fetch."

The handler sets `WX = LY` and drives BGP black at a fixed dot of every line, so
the x at which black begins is a count of dots consumed before it. The author
accounts for the entire WX-dependence of the frame with a **flat 6-dot startup
fetch** whose position moves with WX, and mentions no other per-WX term. Take
the write's unperturbed pixel as 9 and insert 6 dots at the window's first pixel
`w = WX − 7`:

| WX | 7..10 | 11 | 12 | 13 | 14 | 15 | 16 | 17+ |
|---|---|---|---|---|---|---|---|---|
| predicted black-x | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 9 |

which is the reference, row for row, including the six-wide stair. The rule
extends to WX < 7 (window on from the first pixel) as black-x = 3 as well, and
that is what the reference reads there too. **See §5 for what this settles.**

`m3_window_timing_wx_0.asm:21` adds the one term the other ROM cannot see:

> "The stair pattern is visible due to the delay from the lowest 3 bits of SCX,
> and due to **window activating one T-cycle later when WX = 0 and SCX > 0**."

**dingbat agrees** — both halves are in `fifo_sample_smooth_scroll`, quoted
there, and the row is 4 pixels from exact. Recorded here as a **confirmation**:
the `+= 1` / `-= 1` pair around `ppu.wx == 0` in that proc is the second clause
of that sentence and had the wrong sign until 2026-08-07. Do not "simplify" it.

### 3.6 `m3_scx_low_3_bits` — 0, and `m3_scx_high_5_bits` — 0

> "Tests how late SCX can be written to and have the lowest 3 bits of SCX still
> affect the rendering. **The lowest 3 bits appear to be read at the start of
> the 'B' of the first 'B01s' read cycle.**" — `m3_scx_low_3_bits.asm:21`
>
> `; delay 4 t-cycles on the first 72 rows of the screen,`
> `; causing the SCX = 2 write to fail.` — `:120`

The ROM brackets the latch to **one M-cycle**: with the handler starting at 24,
the `SCX = 2` write completes at dot 88 on rows LY ≥ 72 (where it must land) and
at dot 92 on rows LY < 72 (where it must not). Both rows are in the same frame.

> "Sets SCX to LY on each row during mode 3. Sprites are used to affect the
> timing. **SCX is read at the start of each tile fetch.**"
> — `m3_scx_high_5_bits.asm:21`

**dingbat agrees, both exact.** Confirmation, and an important one: the comment
at the `dropped_first_fetch` branch in `tick_bg_fetcher` says the fine-scroll
latch is the *fetcher's*, taken when the throw-away fetch completes, and cites
this ROM. That is the same statement as the header's "the start of the B of the
first B01s cycle". Anything that moves the latch to the shifter's first dot
breaks a two-sided bracket.

### 3.7 `m3_wx_4_change`, `m3_wx_5_change`, `m3_wx_6_change`, `m3_wx_4_change_sprites` — all 0

> "Window **reactivation zero pixels** should be present when window is already
> activated and the pixel that the window reactivates on is on the same cycle as
> the **window tile nametable read**."
> — `m3_wx_4_change.asm:21` and `m3_wx_5_change.asm:21`
>
> "Sprites with priority bit set should show through window reactivation zero
> pixels." — `m3_wx_4_change_sprites.asm:24`

This is the source for `window_reactivate` and for `WIN_REACT_PHASE`. The header
says the surviving phase **is the window tile-map read** and that the injected
pixels are **colour 0** (hence "zero pixels", and hence objects with the BG
priority bit set showing through them, which is exactly what colour 0 means to
`sprite_wins`). dingbat ships `WIN_REACT_PHASE = 7`, picked by a sweep, with a
comment that anchors it to the end of the fetcher's park.

**Confirmation with a caveat worth recording**: all four rows are pixel-exact,
so nothing needs to move — but the source names the *nametable read* as the
surviving step where the shipping constant names fetcher position 7. Those are
the same dot in this renderer (the park at position 7 ends on the dot the FIFO
is down to its last pixel, one fetch cycle ahead of the map read that follows),
and a future rewrite of the fetch cycle must keep the ROM's statement, not the
number.

`m3_wx_6_change` additionally brackets the window-start comparator one slot left
of the shifter's first pixel on three consecutive scanlines — that derivation is
already written up at `fifo_arm_window` and is not repeated here.

### 3.8 `m2_win_en_toggle` — 0, and `m3_lcdc_win_en_change_multiple` — 0

> "The current window line is only incremented when the window is actually
> activated, so on rows when the window is off, the window line should not be
> incremented." — `m2_win_en_toggle.asm:21`
>
> "The current row of the window is incremented each time the window is
> activated, so the second time the window is activated on the row, the next row
> of window pixels are displayed."
> "…it will always display a multiple of 8 pixels, **except when the window
> begins off the left edge of the screen**."
> — `m3_lcdc_win_en_change_multiple.asm:21`

**dingbat agrees**, `inc ppu.current_window_line` in `fifo_reset_bg` gated on
`fetching_window`, and both rows are 100%. Confirmation: the window-line counter
is incremented **per activation**, not per line, and not on lines where the
window never starts.

### 3.9 `m3_lcdc_win_en_change_multiple_wx` — 343, unchanged

Same test with `WX = LY`. Its diff is 8-pixel blocks on LY 2..6 starting at
x = LY + 1 — that is, exactly the header's stated exception ("except when the
window begins off the left edge"), on the five lines where `WX < 7`. It belongs
with §5, not with §3.8, and it is the row `WIN_HEAD_ABSORB` moves most (+32).

### 3.10 `m3_lcdc_obj_en_change` — 2, `m3_obp0_change` — 0

> `; 28 cycles`
> `; delay an extra 4 cycles when LY > 64`
> — `m3_lcdc_obj_en_change.asm:103`

The ROM moves its own write by one M-cycle at LY 64 so that one frame brackets
the answer from both sides. These two rows are what pinned `MIXER_PRIORITY_BACK`
(1) and `MIXER_PALETTE_BACK` (2); the derivation is at `fifo_recompose_last`.
Recorded as a confirmation: the two-stage mixer tail is measured, not assumed,
and `m3_obp0_change`'s 100% is a *tight* constraint — it is 32 pixels out at one
stage and 126 out on CGB at two.

### 3.11 The rest, briefly

| row | wrong px | what the source adds |
|---|---|---|
| `m3_lcdc_tile_sel_win_change` | 106 | header adds only "while displaying the window". Read as §3.3's split on window tiles until 2026-08-09; it is NOT — the fix there left it at 106 and the pixels are 8 on LY 0 plus 98 in band 8 alone, the same band, the same two tiles and the same WX = 7 tie as `m3_lcdc_win_map_change`'s 34 below |
| `m3_lcdc_obj_en_change_variant` | 102 | "Background palette is changed to see the effect disabling sprites has on **timing**" — it is a mode-3-length probe, not a priority probe |
| `m3_lcdc_obj_size_change` | 57 | nothing beyond "toggles bit 2 with sprites at different X"; the OAM table is the ruler |
| `m3_lcdc_win_map_change` | 34 | nothing; photograph says 100% reference at a 77× ratio |
| `m3_lcdc_obj_size_change_scx` | 30 | "while changing SCX value based on the row's LY value **to affect timing**" — SCX is the ruler here, not the subject |

---

## 4. Sources with nothing useful in them

A negative result, so the next person does not dig:

* **`m3_lcdc_obj_size_change`, `m3_lcdc_obj_size_change_scx`,
  `m3_lcdc_win_map_change`, `m3_lcdc_tile_sel_win_change`,
  `m3_bgp_change_sprites`, `m3_obp0_change`** — the header is a one-line
  restatement of the filename. Everything they assert is in the OAM table and
  the instruction cycles, both of which are covered by §1.3 and §3.
* **The seven `*2.asm` files** — `m3_lcdc_bg_en_change2`, `_bg_map_change2`,
  `_tile_sel_change2`, `_tile_sel_win_change2`, `_win_map_change2`,
  `m3_scx_high_5_bits_change2`, `m3_scy_change2` — are CGB-only re-runs through
  `inc/lcdc_stat_int_base.asm` and share one header (§1.3). They carry no DMG
  information at all, and CGB rows are unscored. Two of them note that X and Y
  glyph data is copied over I and J "so tile data mixing can be observed in the
  3rd toggle", which is a presentation detail.
* **`win_without_bg.asm`** — "Tests enabling LCDC bit 6 but not bit 0". Its
  useful content is about STAT IRQ blocking, not the PPU: *"due to STAT IRQ
  blocking, a mode 2 interrupt cannot trigger if mode 0 is also selected. LYC,
  however, can"*. **This ROM is not in the bundled `game-boy-test-roms` set and
  is not scored**; it postdates the snapshot the harness uses.
* **`src/dma/hdma_timing-C.asm`, `hdma_during_halt-C.asm`,
  `src/mbc/mbc3_rtc.asm`** — CGB/MBC, self-checking (they carry a
  `CorrectResults` table rather than a reference image), and not in the scored
  set. Two facts worth having anyway: HDMA **does not run during halt** — "the
  HDMA transfer occurs after exiting from halt" — and HDMA is **delayed by a
  longer mode 3** (the ROM's own two SCX cases, 1 and 2, differ only in that).
  Both are already dingbat's behaviour.
* **`inc/old_skool_outline_thick.asm`** is font data.

---

## 5. Verdict on `WIN_HEAD_ABSORB` (branch `agent-gbmealy`, unmerged)

The proposal: on a line that *starts* as a window line (`WX < 6`), the `7 − WX`
fine-scroll discard is paid **out of** the window's 6-dot startup fetch, so
mode 3 is `172 + 6` for every WX in 0..6 rather than `172 + 6 + (7 − WX)`.
It scores gambatte +9 (sprites +3, window +6), mealybug
`m3_lcdc_win_en_change_multiple_wx` +32 and `m3_window_timing` +10 DMG / +10
CGB, and costs GBMicrotest `win3_b`, `win4_b`, `win5_b` — which then read
`actual=0x83 expected=0x80`, the same signature and the same bucket-15 readback
lag as `win2_b` and `win6_b`, already red on either setting.

**The sources support it.** `m3_window_timing`'s header attributes the whole
WX-dependence of its frame to *where* a **6 T-cycle** window startup fetch falls
relative to a fixed write, and names no other per-WX term anywhere. Reconstruct
the frame from that one sentence and it reproduces the reference exactly for
WX ≥ 7, stair included (§3.5); the same sentence applied to WX < 7 gives the
flat black-x = 3 that the reference reads there, which is the arithmetic
`WIN_HEAD_ABSORB` implements. The branch derives it from a pixel ruler; the ROM
states it as a mechanism, and they agree.

**One refinement.** The source does not describe an absorbed discard — it
describes a startup fetch that is 6 dots whatever WX is. That is the same
arithmetic but a better name, and it makes the WX = 0 case fall out instead of
needing a clamp: `m3_window_timing_wx_0` documents "window activating one
T-cycle later when WX = 0 and SCX > 0", so the head is 6 at WX = 0 with
SCX & 7 = 0 and 7 + (SCX & 7) otherwise. The branch's `max(0, WX − 1)` produces
exactly that, but only because `fifo_sample_smooth_scroll` already carries the
`+1 / −1` pair for WX = 0. If the head is ever re-expressed as "6 dots, flat",
that pair has to be re-expressed with it or WX = 0 will silently change.

**Nothing in the sources refutes it**, and nothing in them speaks to the three
GBMicrotest rows it trades — those are STAT readback, which no mealybug ROM
touches.

---

## Reproducing

```sh
export DINGBAT_ROM_CACHE=/tmp/dingbat-test-roms
nimble test_build
python3 tools/gbppu/mbscore.py ./dingbat_test dmg      # per-row %
python3 tools/gbppu/mbshift.py m3_scy_change           # per-line shift

# the write dots and the fetcher's three reads, per line
nim c -d:test_harness -d:release -d:gb_px_trace -d:gb_m3_trace -d:GB_TRACE_LY=-1 \
  --path:src -o:/tmp/dt_px tests/dingbat_test.nim

# the control arms for this pass
nim c ... -d:BG_EN_AT_MIX=0      # LCDC.0 sampled at the push again
nim c ... -d:MIXER_PALETTE_OR=0  # clean palette edge again
nim c ... -d:OBJ_BG_RUN=0|2|3    # the BG fetcher during an object penalty
```

The sources themselves: `git clone https://github.com/mattcurrie/mealybug-tearoom-tests`
and `git checkout 70e88fb`.
