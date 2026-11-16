# Mealybug Tearoom Tests, read from the source

The suite ships its `.asm` sources; about a third carry a prose header, the
rest state the measurement in code (a write at a counted cycle, a register held
as a control, an object whose OAM X advances one pixel per 8-line band). This
file records what the sources assert and which dingbat mechanism models each
claim. Pass counts live in `tests/results.md`.

Sources: `mattcurrie/mealybug-tearoom-tests` `70e88fb` — 39 `.asm` under
`src/ppu`, `src/dma`, `src/mbc`, `inc/`, plus
`the-comprehensive-game-boy-ppu-documentation.md` (56 lines, every one a
hardware claim). Scoring: the shootout counts the 24 DMG rows (`mealybug.py`,
`all = dmgs`); the runner scores `_dmg_blob`, `_cgb_c` and `_cgb_d` references
(`build_mealybug_tests`), and the three self-checking `src/dma` / `src/mbc`
ROMs as `tmMooneye` rows.

## The harness shape every `m3_*` ROM shares

**Handler zero point is 32 T-cycles** — `; 20 cycles interrupt dispatch + 12
cycles to jump here: 32` (every handler, e.g. `m3_bgp_change.asm:107`).
`m3_scx_low_3_bits.asm:114` vectors through a 4 T `jp hl`, so its zero is 24.
"The write lands at dot N" below means 32 (or 24) plus the counted instruction
cycles, from the mode 2 interrupt.

**Line 0 runs 4 T-cycles out of step** — `inc/utils.asm:193`:

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

The parenthetical is transposed: `and a` sets Z on LY = 0, so the `jr nz` is
not taken there and the macro costs 24 T on line 0 against 28 elsewhere. The
macro cancels a hardware difference: on line 0 the handler's write must be
issued 4 T earlier to land on the same dot of drawing. dingbat:
`LY0_PIPE_MCYCLES` (`gb/fifo_ppu.nim`) — line 0's pixel pipeline runs one
M-cycle ahead of lines 1..143 with every mode flag and STAT source unchanged.
The alternative reading (line 0's mode 2 STAT interrupt is 4 T late) is
excluded by mooneye `acceptance/ppu/intr_1_2_timing-GS`, which times that
interrupt directly.

**The objects are the ruler.** Almost every OAM table is `Y = $10 + 8k, X = k`
for k = 0..17. An object costs `6 + max(0, 5 − (X mod 8))` dots, so each 8-line
band puts the handler's write on a different T-cycle of the fetch; the `*2.asm`
CGB variants say so: "Sprites are positioned to cause the write to occur on
different T-cycles of the background tile fetch, showing when the change to the
bit takes effect." A whole-frame percentage averages eighteen measurements;
score per band (`tools/gbppu/README.md`).

## The suite's PPU documentation

**TILE_SEL (LCDC.4)**: "read during the `0` and `1` stages of background tile
data fetching. Changing its value during background tile data fetch allows for
mixing tile bitplane data from two different tile patterns." dingbat:
`fsGetTileDataLow` / `fsGetTileDataHigh` each re-derive
`bg_window_tile_data(ppu)` on their own dot; `fsGetTile` does not read the bit.
The CGB-only glitch paragraph (substituting sprite/tile/index data when the bit
changes on a read's T-cycle, with a CPU CGB D split) is not modelled.

**SCY (`$FF42`)**: "Writes will take effect immediately on the DMG. On CGB and
AGB devices, writes appear to take effect 2 T-cycles later." / "On the DMG and
CGB revisions up to and including the 'CPU GBC C' revision, the `SCY` register
is read during the background tile fetch `B`, `0` and `1` stages. … On the AGB
and CGB revisions 'CPU GBC D' and greater, the `SCY` register is only read
during the `B` stage." dingbat: `fsGetTile` reads SCY for the map row and both
data stages re-read it for the row inside the tile; `CGB_SCY_LATENCY` is the
first sentence. The CGB D single-read behaviour is not modelled: dingbat draws
the `_cgb_c` picture of `m3_scy_change` at every revision, and the `_cgb_d`
reference differs from `_cgb_c` by 6217 px (`tools/gbppu/mbrevcheck.sh`; the
other six revision-carrying pairs — `m3_bgp_change`, `m3_bgp_change_sprites`,
`m3_lcdc_obj_en_change_variant`, `m3_obp0_change`, `m3_window_timing`,
`m3_window_timing_wx_0` — switch correctly).

**WIN_EN (LCDC.5)**: "WIN_EN can be disabled during mode 3. The disabling will
take effect at the end of the current window tile being drawn. When the current
window tile has finished being drawn, the PPU will start drawing background
tiles again." / "When the background resumes drawing it is on a tile boundary.
The low 3 bits of SCX have no effect." / "Setting WIN_EN again during mode 3 on
the same scanline will have no effect unless WX has been updated to set the
window to activate on a pixel that hasn't been drawn yet." / "…it will start
drawing the **next row** of the window, on the same scanline." dingbat:
`WIN_EN_ABORT` in `fifo_ppu.nim`; `current_window_line` increments in
`fifo_reset_bg` gated on `fetching_window`.

## Per-test: what the source asserts

### `m3_lcdc_bg_en_change`

Handler (`:144`): `line_0_fix`, 9 `nop`, `ld [hl],c` (BG off), `nop`,
`ld [hl],b`, `ld [hl],c`, `ld [hl],b`. `ld [hl],r` is 8 T, `nop` 4, so BG_EN is
low for 12 dots, high 8, low 8 — and the DMG reference shows white runs of
exactly 12 (x = −1..10) and 8 (x = 19..26), neither on a tile boundary. LCDC.0
is therefore sampled per emitted pixel, not per tile push: `BG_EN_AT_MIX`
(read in `fifo_mix`, carrying `MIXER_PRIORITY_BACK` with the rest of LCDC's
priority half).

The object sweeps its X so the dot pixel 0 leaves the FIFO moves one dot per
band (105, 104, 103, … under `-d:gb_px_trace`) while the write stays on dot
105; the reference blanks x = 0 in bands 0–2 only, so pixel 0 is reachable
exactly two dots after it leaves (`MIXER_HEAD_LINGER`; this ROM is its only
oracle, `m3_lcdc_obj_en_change`'s last two pixels confirm it).

### `m3_bgp_change`, `m3_bgp_change_sprites`

`m3_bgp_change` calls no VRAM fill: every pixel is colour 0, OAM is `$FF`, SCX
is 0, so the frame is literally BGP bits 1:0 sampled once per dot. Seven
`ld [c],a` writes (`:106`–`:162`):

| write | dot from the mode 2 IRQ | value (b = `swap(LY)`) |
|---|---|---|
| 1 | 80 | b |
| 2 | 96 | b + 1 |
| 3 | 108 | b |
| 4 | 168 | b + 2 |
| 5 | 180 | b |
| 6 | 240 | b − 1 |
| 7 | 252 | b |

Edges in the reference land at x = 1, 13, 73, 85, 145, 157 = `dot − 95`, and
each edge is three-valued: the pixel at the far end of the mixer tail reads
`old or new` for one dot (LY 17: `$11`, **`$13`**, `$12`, **`$13`**, `$11`).
`MIXER_PALETTE_OR`: the FF47/48/49 write paints `MIXER_PALETTE_BACK` with
`old or new` and the nearer tail with `new`; 720 cells with 144 old/new pairs,
no free parameter. DMG only — the `_cgb_c` references want a clean edge, which
is `CGB_MIXER_LATENCY = 1` (the write reaches one pixel less far down the
tail). The hardware photograph (`photos/DMG-blob/m3_bgp_change.jpg`, read with
`tools/gbphoto`) sides with the reference on all six OR columns at 65–93 %
agreement, which is what a clear verdict looks like for one-pixel-wide
features.

The seventh write lands on the first dot of mode 0 and still reaches pixels
157–159 (157 takes `old or new`): the line's last pixels clock out of the mixer
during the first dots of H-Blank. `MIXER_TAIL_HBLANK`: `tail_dot0` latched at
the tail burst as `cycle_counter − lx`, so the shifter's position keeps
counting after `lx` stops (`fifo_recompose_last`).

`_sprites`: the object stalls the shifter at the head of each band while the
write stays on a fixed dot, so the bands sweep the stall's age. The reference
gives zero pixels back for a stall older than the tail, one at a stall one dot
old, two for a running shifter — a write reaches a pixel iff that pixel left
the FIFO within `MIXER_PALETTE_BACK` *dots*, stall or no stall
(`MIXER_TAIL_DOTS`).

### `m3_lcdc_tile_sel_change`, `m3_lcdc_bg_map_change`

Same handler: `line_0_fix`, 9 `nop`, `ld [hl],c`, `ld [hl],b` — the bit is
set for exactly 8 dots (105..112). `tile_sel_change` fills both maps with tile
0, an all-`$00` tile at `$9000` and all-`$FF` at `$8000`, so each tile reports
the pair (TILE_SEL at the plane-0 read, at the plane-1 read) as a shade.

The reference never reports a pair whose two reads are more than 2 dots apart:
a tile's three reads are never split by an object fetch. Read per band, the
pulse lands on:

| OAM X | the fetch of | tile displays |
|---|---|---|
| 0–7 | the tile drawn at x = 8..15 | shade 3, or 2 then 1 for X = 5..7 |
| 8–15 | the tile drawn at x = 16..23 | shade 0, then 1 from X = 13 |
| 16, 17 | the tile drawn at x = 16..23, undisturbed | shade 3 |

i.e. the object penalty is inserted after the fetch of tile `floor(X / 8)`,
one tile ahead of the tile the object's pixel sits in — Pan Docs' "waiting for
the BG fetch to finish" with the fetcher's one-tile lead made explicit. X = 0
and X = 8 trigger on the same dot and cost the same 11 dots; only the tile index
at the trigger differs. Band 4 (X = 4, penalty 7) shows the fetcher resumes one
dot after the shifter. `OBJ_BG_RUN = 4`, derived at `tick_sprite_fetcher`.
Mode 3's length does not move (`objtab.py` against GBMicrotest
`ppu_spritex_vs_scx`).

### `m3_scy_change`

Header: "Changes the SCY register during mode 3, with SCX set to LY on each
row" — the second clause is copy-paste from `m3_scx_high_5_bits`; this ROM never
writes SCX. The handler writes SCY 24 times back to back (0,1,2,3,4,3,2,1,0,…),
one write every 8 dots, a distinct value per fetch cycle. Four properties make
the reference invertible into the (SCY at B, at 0, at 1) triple each tile saw:
the map is `map[row][col] = 65 + row + col` (the glyph names its map row),
`BGP = $E4`, SCX = 0, and every object is blank tile `$00`.

Decoded, all eighteen bands demand that tile 0's `B` read take the value
written at dot 81 and both bitplane reads the value written at dot 89: tile 0
reads at 88/90/92, tile 1 at 96/98/100. With mode 3 = 172 dots at SCX & 7 = 0
and 160 pixels, the discarded fetch plus the first real one are 12 dots; with
the 8-step cycle `s B s 0 s 1 s push` a discarded fetch of *n* dots puts the
first real reads at `d+n+1, d+n+3, d+n+5`:

| n | tile 0's B, 0, 1 | verdict |
|---|---|---|
| 6 (`B01`) | 90, 92, 94 | B one slot late |
| 4 (`B0`) | 88, 90, 92 | every band satisfied |
| 2 (`B`) | 86, 88, 90 | the `0` read lands before the dot-89 write |

`M3_THROWAWAY_DOTS = 4`, derived at `tick_bg_fetcher`; `-d:M3_THROWAWAY_DOTS=6`
is the control build. This is the only red-capable DMG row with no photograph;
the suite's SCY paragraph above is the mechanism statement.

### `m3_window_timing`, `m3_window_timing_wx_0`

`m3_window_timing.asm:21`: "For rows with smaller values of WX, there are fewer
white pixels visible due to the palette change happening **after the 6 T-cycle
window startup fetch**. For rows with larger values of WX, there are more white
pixels … **before** … The stair step pattern is visible due to the palette being
changed **during** the 6 T-cycle window startup fetch." The handler sets
`WX = LY` and drives BGP black at a fixed dot. A flat 6-dot startup fetch at
`w = WX − 7`, write pixel 9 unperturbed:

| WX | 7..10 | 11 | 12 | 13 | 14 | 15 | 16 | 17+ |
|---|---|---|---|---|---|---|---|---|
| black-x | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 9 |

is the reference row for row, and for WX < 7 it gives black-x = 3, which the
reference also reads. So a line that starts as a window line has a 6-dot head
whatever WX is; the `7 − WX` fine-scroll discard is paid out of those six
(`WIN_HEAD_ABSORB`), and at WX = 0 the idle term is −1, a startup fetch one dot
shorter (`WIN_WX0_PHASE`). `WX = LY` is written inside mode 3 (dot 81 on LY 0,
85 elsewhere), so the line-start decision is taken on the last dot of the
throw-away fetch, not at the mode 2→3 edge (`WIN_LINE_START_LATCH`).

`m3_window_timing_wx_0.asm:21`: "the delay from the lowest 3 bits of SCX, and
… **window activating one T-cycle later when WX = 0 and SCX > 0**." dingbat:
`fifo_sample_smooth_scroll`, spelled as the absence of a dot the WX = 0 head
otherwise skips. The `SCX & 7 = 0` test is taken on the dot SCX is latched, not
at the head two dots earlier: this ROM writes SCX = LY inside mode 3.

### `m3_scx_low_3_bits`, `m3_scx_high_5_bits`

"The lowest 3 bits appear to be read at the start of the 'B' of the first
'B01s' read cycle." / `; delay 4 t-cycles on the first 72 rows of the screen,
causing the SCX = 2 write to fail.` With the handler's zero at 24 the write
completes at dot 88 on LY ≥ 72 (must land) and dot 92 on LY < 72 (must not):
a one-M-cycle bracket. The latch is the fetcher's, at the first real tile's
`B` (dot 88); the discarded fetch is `B0`, not a `B01s` cycle, so the header is
true as written. "SCX is read at the start of each tile fetch" — map offset
computed fresh in `fsGetTile`.

### `m3_wx_4_change`, `m3_wx_5_change`, `m3_wx_6_change`, `m3_wx_4_change_sprites`

"Window reactivation zero pixels should be present when window is already
activated and the pixel that the window reactivates on is on the same cycle as
the window tile nametable read." / "Sprites with priority bit set should show
through window reactivation zero pixels." dingbat: `window_reactivate` inserts
colour-0 pixels (which is why OBJ-behind-BG sprites win there);
`WIN_REACT_PHASE = 7` names fetcher position 7, which in this renderer is the
same dot as the nametable read the header names — a rewrite of the fetch cycle
must keep the ROM's statement, not the number. `m3_wx_6_change` brackets the
window-start comparator one slot left of the shifter's first pixel on three
consecutive lines (`fifo_arm_window`). Nothing outside mealybug pins WX 4/5/6.

### `m2_win_en_toggle`, `m3_lcdc_win_en_change_multiple`, `_wx`

"The current window line is only incremented when the window is actually
activated" / "The current row of the window is incremented each time the window
is activated, so the second time the window is activated on the row, the next
row of window pixels are displayed" / "always display a multiple of 8 pixels,
except when the window begins off the left edge of the screen."

`_wx` (same test with `WX = LY`) measures the window's tile position: because
the background resumes on the window's tile boundary, the black run at the
head of each line is the phase of the window's first tile:

| WX (= LY) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| black run | 9 | 10 | 3 | 4 | 5 | 6 | 7 | 8 |
| first tile | −7..0 | −6..1 | −5..2 | −4..3 | −3..4 | −2..5 | −1..6 | 0..7 |

(WX = 0 and 1 read one tile past their boundary: the abort catches the fetch
after the next one.) `WIN_WX0_PHASE` and `WIN_PRE_PX_PHASE` in `gb/gb.nim`.

### `m3_lcdc_obj_en_change`, `m3_obp0_change`

`; 28 cycles` / `; delay an extra 4 cycles when LY > 64` — the ROM moves its
own write by one M-cycle at LY 64 so one frame brackets both sides. These two
rows pin `MIXER_PRIORITY_BACK = 1` and `MIXER_PALETTE_BACK = 2`
(`fifo_recompose_last`); `m3_obp0_change` is 32 px out at one stage, 126 on
CGB at two.

### `m3_lcdc_obj_size_change`, `_scx`

The OAM entry `DB $10, $20, $4c, $40` is Y = 16, **X = 32**, tile `$4C`,
Y-flip. Every object is tile `$4C`; with `BGP = $00` and `OBP0 = $E4` each
object is read out as raw bitplane, so the reference states which sprite height
each of the fetch's two bitplane reads used: LCDC.2 is read once per bitplane,
2 dots apart (`OBJ_PLANE1_LAG`). Band k carries three objects at X = k, 16+k,
32+k (the last Y-flipped); `_scx` carries two and moves the line with
`SCX = (LY >> 4) and 7`. The four writes are 24, 12 and 12 T apart (dots 101,
125, 137, 149).

### CGB: `m3_lcdc_bg_map_change`, `m3_lcdc_win_map_change` and their `2` variants

`bg_map_change` fills `$9800` with tile 0 and `$9C00` with tile 1 (all-`$00` at
`$9000`, all-`$FF` at `$9010`), `BGP = $E4`, SCX 0, so each tile column is one
bit — which map the B-stage read used — and the handler raises LCDC.3 for 8
dots. `win_map_change` is the same for LCDC.6 with `WY = 0`, `WX = 7`. The
black column per band:

| | DMG blob | CGB C and D |
|---|---|---|
| `bg_map_change`, tile 1 black | X = 0, 1, 2 | X = 0 |
| `bg_map_change`, tile 2 black | X = 3..7 | X = 1..7 |
| `bg_map_change`, nothing black | X = 8, 9, 10 | X = 8 |
| `bg_map_change`, tile 2 black | X = 11..15 | X = 9..15 |
| `win_map_change`, tile 0 black | X = 0, 1, 2 | X = 0 |
| `win_map_change`, tile 1 black | X = 1..7 | X = 0..7 |

Four edges, all moved by two bands, and a band is a dot: the write reaches the
map read two dots later on a CGB. `CGB_MAP_LATENCY = 2` (`gb.nim`, applied at
`fsGetTile`) — a per-reader delay on LCDC.3/LCDC.6 like `CGB_TDSEL_LATENCY`
(LCDC.4) and `CGB_OBJ_SIZE_LATENCY` (LCDC.2); `CGB_LCDC_LATENCY` ships 0.
gambatte's `bgtilemap` family brackets the same value, and its `_ds_` rows
require the delay to scale with the CPU clock (a CPU-clock delay, not a dot
count). The `_cgb_c` and `_cgb_d` references are identical for both ROMs.

### Headers that add one clause

- `m3_lcdc_tile_sel_win_change`: "while displaying the window".
- `m3_lcdc_obj_en_change_variant`: "Background palette is changed to see the
  effect disabling sprites has on **timing**" — a mode-3-length probe.
- `m3_lcdc_obj_size_change_scx`: SCX "based on the row's LY value **to affect
  timing**" — SCX is the ruler.
- `m3_lcdc_win_map_change`: nothing; the photograph agrees with the reference.

## Sources with nothing beyond the file name

- `m3_lcdc_obj_size_change`, `_scx`, `m3_lcdc_win_map_change`,
  `m3_lcdc_tile_sel_win_change`, `m3_bgp_change_sprites`, `m3_obp0_change`:
  the assertion is the OAM table and the instruction cycles. Read the table.
- The seven `*2.asm` CGB-only variants share one header (above) and carry no
  DMG information.
- `win_without_bg.asm` ("Tests enabling LCDC bit 6 but not bit 0") is not in
  the bundled set. Its useful sentence is about STAT: "due to STAT IRQ
  blocking, a mode 2 interrupt cannot trigger if mode 0 is also selected. LYC,
  however, can".
- `src/dma/hdma_timing-C.asm`, `hdma_during_halt-C.asm`, `src/mbc/mbc3_rtc.asm`
  are self-checking (`CorrectResults` table, `inc/base.asm` `CompareResults` →
  Fibonacci registers + `LD B,B`), scored as `tmMooneye`. Facts they state:
  HDMA does not run during halt ("the HDMA transfer occurs after exiting from
  halt"), and HDMA is delayed by a longer mode 3 (its two SCX cases differ only
  in that).
- `inc/old_skool_outline_thick.asm` is font data.

## Reproducing

```sh
export DINGBAT_ROM_CACHE=/tmp/dingbat-test-roms
nimble test_build
python3 tools/gbppu/mbscore.py ./dingbat_test dmg      # per-row %
python3 tools/gbppu/mbshift.py m3_scy_change           # per-line shift
tools/gbppu/mbrevcheck.sh                              # _cgb_c vs _cgb_d

# write dots and the fetcher's three reads, per line
nim c -d:test_harness -d:release -d:gb_px_trace -d:gb_m3_trace -d:GB_TRACE_LY=-1 \
  --path:src -o:/tmp/dt_px tests/dingbat_test.nim

# control builds
nim c ... -d:BG_EN_AT_MIX=0 -d:MIXER_PALETTE_OR=0 -d:OBJ_BG_RUN=0 \
          -d:M3_THROWAWAY_DOTS=6 -d:CGB_MAP_LATENCY=0 -d:MIXER_TAIL_DOTS=0
```

The `m3_scy_change` decode reads the `FTILE`/`FDATA`/`SCY` trace lines into
per-tile triples and searches `(map row, row at 0, row at 1)` against the
reference's eight pixels; it relies on the four ROM properties listed above,
three of which are true only of that ROM.

Sources: `git clone https://github.com/mattcurrie/mealybug-tearoom-tests && git checkout 70e88fb`.
