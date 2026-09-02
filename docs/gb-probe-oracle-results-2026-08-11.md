# GB probe carts: what each measures, dingbat's prediction, hardware status

The probe carts in `tools/gbprobe/` report raw values and contain no
expectation; each renders its result on screen and to WRAM, and
`tools/gbprobe/readout.py` / `arbread.py` / `read_probe_e.py` read the
photograph. This is the table of probe → dingbat prediction → hardware. Rows
pinned only by comparison with another emulator are kept to one line each and
listed in [`docs/oracles.md`](oracles.md); the hardware column is the evidence.

## Summary

| probe | measures | dingbat | hardware |
|---|---|---|---|
| (a) `probe_a_statidiom.gb` | whether `LD A,(C)` and `LDH A,($41)` report the STAT mode field differently at the mode-0 edge (`STAT_M0_FIELD_TAIL`) | idiom matters on DMG at SCX=3 only (`LD A,(C)` flips one step later); never on CGB | **unrun on a DMG** (the SP arm only checks the CGB-side zero) |
| (b) `probe_b_scxm3.gb` | how a mid-line SCX store lengthens mode 3 | +8 dots in a single one-M-cycle window at store dot 95 (DMG) / 91 (CGB); the `$07→$07` control never extends | photographed on GBA SP (IMG_3807), **not machine-read** — `photowarp.py` registration too coarse for a 4-dot reading |
| (c) `probe_c_arbitrate.gb` (+`_scx3`, `_scx7`) | emission phase (BGP band edge) vs fetch-grid phase (LCDC.4 glitch column) on one frame | band edge and glitch column on one grid (table below) | photographed on GBA SP (IMG_3804–3806), **cannot be registered**: black background, no frame edge; needs corner marks in the ROM and a re-shoot |
| (d) `probe_d_tdsel_*.gb` | CGB TILE_SEL arrival (`CGB_TDSEL_LATENCY`) | — | unrun |
| (e) `g1_scx0.gb`, `g1_scx4.gb` | halt-wake PPU phase (`CGB_HALT_PPU_LEAD`), anchor line 16 | SCX 0 `32 40 40 48 …` (lead 0) / `40 40 48 48 …` (lead 1); SCX 4 `28 36 …` / `36 36 …` | **GBA SP: SCX 0 `24 32 32 40 40 48 48 56 56 64 64 71 71 79`; SCX 4 `20 28 28 36 36 45 45 53 53 61 61 69 69 77`** — dingbat 2 M out at lead 0, 4 M at lead 1 (docs/hwprobe-questions.md, g1) |

## (a) STAT read idiom

BG only, objects off, window parked, SCY = 0, one halt anchor per measurement
on line `$47`. The two idioms have their IO cycles equalised (`LD A,(C)` reads
on M2, `LDH A,($41)` on M3, so the `LD A,(C)` arm carries one more NOP) and
sample the same PPU dot. SCX = 3 is the measurement, SCX = 0 the control; the
sweep is 16 M-cycle steps about the mode-0 boundary and the readout is the step
at which each column first reads mode 0.

dingbat: DMG `0A / 09 / 09 / 09` (`LD A,(C)`@3, `LDH`@3, `LD A,(C)`@0,
`LDH`@0); every CGB revision and AGB `09` in all four. A hardware photo in which
both columns flip at the same step deletes `STAT_M0_FIELD_TAIL` and
`STAT_M0_TAIL_MAX_MC` and reopens the ~60 rows they reconcile. A CGB mode-0
boundary one M-cycle earlier than the DMG's is a refuted model in
`docs/gb-failure-triage.md` (40 device-equal gambatte families; dingbat: same
dot); the photo is the hardware word on it.

## (b) SCX mode-3 extension

SCX = 7 written in mode 2 so the line latches fine scroll 7; then from one
anchor a slide of `BASE_M + M` NOPs, the store (`ld a,$05` / `ldh [c],a`), a
slide carrying a `(7 − M)` term so the read lands on the same dot for every
row, and `LDH A,($41)`. Rows are store positions M = 0..7, row `$07` stores
the value SCX already holds, row `none` stores nothing. Readout is the sweep
step at which each row first reads mode 0.

dingbat (`BASE_M = 16`, store walking dots ~79→107): DMG `4 4 4 4 6 4 4 4 | 4 | 4`,
CGB `4 4 4 6 4 4 4 4 | 4 | 4`. Walking `BASE_M` over 8/12/16/20/24 hits the same
dot from two builds (DMG 95, CGB 91), which checks the sweep measures a dot of
the line: the extension is one M-cycle wide, worth exactly +2 M = 8 dots, and
fires only when the store changes the value. That is inside the gambatte
ROMs' CGB bracket of 7–10 dots; their DMG bracket is 11–14, which dingbat does
not reproduce. Open on hardware: the window's position on CGB and whether a
DMG has one at all.

## (c) emission vs fetch grid on one frame

One halt anchor at `LY = LYC = 0`, then a loop body of exactly 115 M-cycles so
each iteration starts four dots later in its line. Per line: one BGP write
against a flat background (band edge = emission phase, daid's ruler) and one
8-dot LCDC.4 pulse over a map whose tile index reads different data in the two
addressing modes (glitched column = fetch grid, acid-hell's residue). The
measurement is the map from one staircase to the other within a frame, not
either one's absolute position.

dingbat, band edge → glitch-column start, lines 2..9, SCX = 0:

| model | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|
| DMG | 5→56 | 9→56 | 13→64 | 17→64 | 21→72 | 25→72 | 29→80 | 33→80 |
| CGB-D, CGB-E | 9→56 | 13→64 | 17→64 | 21→72 | 25→72 | 29→80 | 33→80 | 37→88 |
| CGB-C | 10→56 | 14→64 | 18→64 | 22→72 | 26→72 | 30→80 | 34→80 | 38→88 |

SCX 3 and 7 shift both staircases left together. CGB-C puts the band edge one
pixel right of CGB-D/E with the glitch column unchanged — a one-dot
emission/fetch separation the probe resolves, so a four-dot one would be
unmissable. If hardware shows the staircases together, acid-hell and daid
cannot both be read out of one anchor; if four apart, the split is real and
this frame is its derivation. The g1 result (2 M between an emission-exact and
a fetch-grid-measured path on the same machine) makes this the next shot.

Caveats: probe (c) carries no CGB flag (BGP is inert in native CGB mode, where
CRAM is not writable in mode 3), so on a CGB it runs in compat mode — the
machine daid's ROM runs on. Its 8-dot pulse always redirects both bitplane
reads of one fetch; a half-glitched fetch would read out as index 1 or 2.
