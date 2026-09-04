# tools/gbprobe — hardware probe ROMs and the harness that runs them

Probe ROMs for the open GB PPU questions in `docs/gb-failure-triage.md` and
`docs/hwprobe-questions.md`, plus a harness that runs any GB ROM through dingbat and two
black-box oracle engines (SameBoy via `sameboy_shot.c`, DocBoy via `docboy_shot.cpp`) and
reads the answer off the screen. No constant from either engine is copied into dingbat,
and three engines agreeing is a comparison, not evidence: a mechanism built on it ships
behind a flag and is listed in [`docs/oracles.md`](../../docs/oracles.md) until a
hardware photo settles it.

The ROMs are the permanent artifact: they report raw values, contain no expectation,
render results as hex and store them to WRAM, and carry correct cartridge headers, so the
same `.gb` can be burned to a flash cart and photographed (`readout.py` reads the photo).

## Build

```sh
./build.sh            # rgbds, the engine runners, and all the ROMs
./build.sh roms       # just re-assemble the ROMs (mk.sh <probe> -D<SYM>=<val> for one)
./build.sh engines    # just the runners
```

Third-party code lands under `<worktree>/.scratch`: RGBDS 1.0.3, SameBoy
(`$GBPROBE_SAMEBOY` / `~/code/SameBoy` / a clone), DocBoy (DMG and CGB are separate
builds there, so a DocBoy column is one number for all of CGB C/D/E).

## Shooting a frame

```sh
./shoot.sh <rom.gb> <model> <frames> <outprefix> [engines...]   # .<engine>.ppm/.png each
./table.sh <rom.gb> <frames> <model>...                         # screens as text
./readout.py <png>        # a numeric probe's hex grid
./arbread.py <png>        # probe (c)'s two staircases
```

Model tokens: `dmg`, `cgb0`, `cgbAB`/`cgbA`, `cgbC`, `cgbD`, `cgbE`, `agb`. dingbat
skips boot; the SameBoy leg plays the boot ROM and burns the animation off first. DMG
output is normalised to one grey ramp (`FF/AD/52/00`) and byte-comparable; CGB frames are
compared by structure, and the probes use colours that survive RGB555/RGB565 distinctly.

## The ROMs

| ROM | question | header |
|---|---|---|
| `probe_a_statidiom.gb` | does the STAT mode field differ between `LD A,(C)` and `LDH A,($41)` at the mode-0 boundary? | CGB-compatible |
| `probe_b_scxm3.gb` | how much does a mid-line SCX store lengthen mode 3, and where must it land? | CGB-compatible |
| `probe_c_arbitrate*.gb` | on one frame, where does the BGP band edge sit relative to the LCDC.4 glitched fetch column? | no CGB flag |
| `probe_d_tdsel*.gb` | the LCDC.4 mid-fetch tile-data-select glitch, per SCX and in compat mode | |
| `probe_e_objgrid.gb` | object-penalty grid vs SCX after a STAT/LYC halt wake (see `g1_README.md`) | |
| `probe_f_winbar.gb` | window re-trigger shape | |
| `rtcrate*.gb`, `wrambands.gb`, `wramscan.gb`, `probe_cart.gb` | RTC rate, WRAM banks, cart detection | |
| `scratch_font.gb` | smoke test for the shared video/readout path | |

Probe (c) carries no CGB flag on purpose: its ruler is BGP, dead on a CGB running a
CGB-flagged cart (CRAM is not writable in mode 3); the only machine with both rulers on
one frame is a CGB in DMG-compatibility mode, as `daid/ppu_scanline_bgp` runs. Each
probe's numbers are assembly-time overridable (`./mk.sh probe_b_scxm3 -DBASE_M=8`) because
the halt-wake latency positions every sweep window; on hardware, walk the base until the
flip is inside the window. Each probe's header comment carries its design.

## Photograph pages (probe_g / probe_h / probe_i)

Pages built to be photographed on a DMG, CGB and AGS and read against dingbat's
predictions in `expected/<rom>.<model>.png` (`./build.sh expected` regenerates them;
models `dmg cgbc cgbd agb`). Every page is a white 20x18-tile screen with black corner
marks (so `photowarp.py` can register it), a column ruler in row 0 (the digit is the
tile column) and a label in row 17: page code, version, the timing constants, the boot
value of A (`01` DMG, `FF` MGB, `11` CGB/AGB) and the cart's CGB flag (`80` native,
`00` compat). Photograph the whole screen square-on; then
`photowarp.py photo.jpg f.ppm && read_probe_h.py f.ppm <page>` gives one number per
band. Each page is deterministic from power-on and redrawn every frame (no buttons).

All pages sync on the LYC halt anchor (`hw.inc` ANCHOR). dingbat's wake is line dot 9
(DMG) / 13 (CGB) on the LY 153→0 snapback (probe_h) and dot 1 / 5 on a normal line
(probe_g, probe_i); the flashcart runbook's g1 run says dingbat's halt anchor is ~2 M
off the fetch grid on a GBA SP. So: **a CGB−DMG difference on one page = the register's
latency + the machines' wake-phase difference (dingbat: 4 dots)**, while differences
between pages on one machine, and the BGP page's absolute column, are anchor-free.

| ROM | header | question / constant | dingbat's prediction (DMG · CGB-C · CGB-D · AGB) |
|---|---|---|---|
| `probe_g_wy0.gb` | CGB | LCDC.5 set at line-64 dot 141 with WY = 64 (hwprobe row 19, `ppu.nim` ppu_store_lcdc) | window starts ON line 64, all models: the white line between the two rules stops at x = 80 |
| `probe_g_wy1.gb` | CGB | same store on line 65 (LY ≠ WY) | ON line 65, all models |
| `probe_h_scx.gb` | CGB | `CGB_SCX_LATENCY` (2) | top half 9→10 at band 3 · 10→11 at band 5 (bottom 10→11 at 9) · same · same |
| `probe_h_scy.gb` | CGB | `CGB_SCY_LATENCY` (2) | top all 9, bottom 9→10 at 11 · 9→10 at 1, bottom at 13 · **10→11 at 5, bottom at 9** · as C |
| `probe_h_lcdc3.gb` | CGB | `CGB_MAP_LATENCY` (2) | as `probe_h_scx` |
| `probe_h_lcdc4.gb` | CGB | `CGB_TDSEL_LATENCY` (1) | top all 9, bottom 9→10 at 11 · 9→10 at 2 (band 1 grey), bottom 10→11 at 13 · same · same |
| `probe_h_wx.gb` | CGB | `CGB_WX_LATENCY` (0) | window from band 6 (x = 75) · from band 10 (x = 79) · same · same |
| `probe_h_bgp.gb` | **compat** | `CGB_MIXER_LATENCY` (1 on C, 0 from D) | black from x = 73+4b · 78+4b · 77+4b · 78+4b |
| `probe_i_oamdma.gb` | CGB | OAM scan under an OAM DMA, entry 39 (row 17, `OAM_SCAN_DMA_LOCK`) | entry 0 (x 40) missing lines 67 and 68, entry 39 (x 80) missing 67 only, all models |

Reading the pages (each source's header carries the dot arithmetic):

- **probe_g**: two black rules at WLINE−1 and WLINE+1; the window (black, white column at
  each tile's right edge) from x = 80. White line between the rules stops at x = 80 →
  the window started on WLINE; runs the full width with the block level with the lower
  rule → next line; no block → not this frame. `wy0` next-line = hardware takes LCDC.5
  at the top of the line and the store does not re-check (drop the re-check); `wy1`
  no-block = the per-frame latch itself needs LCDC.5 (dingbat's `window_trigger`
  would be wrong, not just the re-check).
- **probe_h fetcher pages** (scx, scy, lcdc3, lcdc4): 16 bands, band b with one blank
  object at X = 32 + (b & 7) shifting the fetch grid 11 − min(5, b&7) dots; bands 8–15
  repeat 0–7 with the store one M-cycle later. Each band is a checker with one
  DOUBLED bar; read the column of its right half, n, in band 0 and the band p* (0–5)
  where it steps to n+1. Reading R = 8n − p*; bands 8–15 must give the same R as
  8n' − p'* − 4. CGB R − DMG R = latency + wake difference; SCX and LCDC.3 should
  agree with each other, LCDC.4 read one less, on any machine, or the six-numbers
  structure is wrong. A grey half-bar is the store landing between the two bitplane
  reads. dingbat's CGB-D SCY row (bolded) is a whole M-cycle off its CGB-C row on
  this page alone — a prediction worth the CGB-D photo on its own.
- **probe_h_wx**: band b stores WX = 76 + b at the same dot; the window catches from the
  first band whose x = WX − 7 is still ahead of the shifter. One band per dot.
- **probe_h_bgp**: band b stores an inverted BGP one M-cycle later than band b−1: a
  4-pixel staircase whose absolute column is the emission phase. Compat header: on a
  CGB it measures compat mode, as mealybug `m3_bgp_change _cgb_c` does.
- **probe_i**: a 2-px marker at x 8..31 names lines 67–68 (the DMA covers all of 67's
  scan and 68's up to ~dot 25). Entry 39 complete while entry 0 is gapped = row 17's
  strikethrough reference is right and the scan reads entry 39 after the DMA;
  both complete = the scan reads OAM through a DMA; both gapped on 67 and 68 = blind
  for the whole transfer.

Constants are overridable at assembly (`-DBASE= -DLEAD= -DWX0= -DOBJX0=` for probe_h,
`-DN=` for probe_g/probe_i); `GBPROBE_CGB=0` builds any page compat-flagged.

## Photograph pages (probe_j / probe_k)

Six more pages, each closing one **Assumed** in the source. Same conventions as above —
white 20x18 screen, corner marks, ruler in row 0, `PP VV .. .. AA HH` label in row 17,
CGB-flagged header, deterministic from power-on, LCD stopped only in VBlank — with one
difference: **the four probe (k) pages run a sweep before they draw**, so they are blank
for the first second or two and their `expected/` frame counts are not 40. On hardware
just wait for the picture; `build.sh expected` uses 60 (serialdiv), 100 (oamclass) and
200 (lcdon).

| ROM | page | question / constant | dingbat's prediction (DMG · CGB-C · CGB-D · AGB) |
|---|---|---|---|
| `probe_j_winrestart.gb` | 50 | `CGB_WIN_RESTART_COUNTER` (0): is a CGB's mid-line window restart six dots or five? | **6 dots on all four.** q\*(off) 7, q\*(on) 5 on DMG; 1 and 7 on every CGB |
| `probe_j_haltlead.gb` | 51 | `CGB_HALT_PPU_LEAD` / `LYC_SETTLE_HALT_SKIP` / `CGB_HALT_LEAD_SKIP_LYC0`: does the CGB lead hold on an ordinary line as on the snapback? | **8 dots on all four.** Half A's edge one whole tile right of half B's at every q; q\* 7 (DMG), 1 and 9 (CGB) |
| `probe_k_serialdiv.gb` | 52 | `SERIAL_TAP_DMG`/`SERIAL_TAP_CGB` vs `SERIAL_DIV_WRITE_LEAD_T` | **m\* = 22 on all four**: long bars for m = 0..21, short from 22 |
| `probe_k_winglitch_a0/a1/a2/scx.gb` | 53, 54 | hwprobe row 18: `WIN_EN_HOLD_ZERO`, its arming gate, insert-vs-replace, the WX×SCX phase | DMG: `a0` nothing anywhere; `a1` and `a2` a **replace** (one white pixel, rest of the line unshifted) in bands 0 and 8 only; `scx` in bands 0, 4 and 8. **Every CGB: nothing on any page** |
| `probe_k_lcdon.gb` | 55 | hwprobe row 10: `LCD_ON_LINE0_TRIM` / `LCD_ON_LINE1_TRIM` (both 0) | all four models: block `00` two columns short of blocks `01` and `28`, which are identical |
| `probe_k_oamclass.gb` | 56 | Pan Docs audit A8: which instruction classes corrupt OAM in mode 2 | DMG: bands 1–5 mark OAM row 11 (band 4 also 9), band 6 rows 11–13, band 7 rows 9, 11, 12; bands 0 and 8–F blank. **Every CGB/AGB: entirely blank** |

Reading the pages (each source's header carries the full arithmetic and the control
builds that were used to prove the page discriminates):

- **probe_j_winrestart** (16 bands of 8 lines): the top four lines of a band run with the
  window off (WX = 200) and the bottom four with it on from x = 32, so the restart cost is
  the NOTCH in the edge at the band's midline. Band b's blank object at X = 16 + (b & 7)
  walks the fetch grid a dot at a time and bands 8–15 repeat it with the store one M-cycle
  later, giving ten grid phases `q = 4*(b>>3) + min(5, b&7)`. Read the first non-white
  column e(q) in each half; e steps up one tile at exactly one q, and
  `restart = (q*_on − q*_off) mod 8`. A CGB shows a grey tile or a one-pixel sliver at the
  crossing q (the store between the two bitplane reads, LCDC.4 a dot late) — that sliver
  IS the crossing. `-d:CGB_WIN_RESTART_COUNTER=1` moves the CGB q\*(on) 7→6, i.e. the page
  reads 5 instead of 6.
- **probe_j_haltlead** (16 bands of 8 lines, same object/soff phases): bands 0–7 (lines
  8–71) are positioned by ONE halt on the LY 153→0 snapback and 112 M of straight-line
  code; bands 8–15 (lines 72–135) re-halt on LYC = LY for **every** line, so each carries
  its own ordinary-line wake. The lead M-cycles are matched (BASE_B = BASE_A − 2), so
  `answer = e_A(q) − e_B(q) + (q*_B − q*_A)` is the snapback wake minus the ordinary wake.
  The page CANNOT see a lead that applies equally to both wakes (`-d:CGB_HALT_PPU_LEAD=0`
  leaves it at 8); what it sees is the lead being anchor-dependent —
  `-d:CGB_HALT_LEAD_SKIP_LYC0=1` reads 4.
- **probe_k_serialdiv** (32 half-height bars, case 2r on top of screen row r+1): start an
  internal-clock transfer with no cable, write `$FF04` m M-cycles later, count M-cycles to
  IF bit 3. m\* is where the bar length changes. Rebuilding dingbat measured what m\*
  pins: phase 4/6/7 with LEAD_T = 4 all give 22, phase 0 gives 23, phase 7 with LEAD_T = 1
  gives 21 — so **m\* pins (phase − LEAD_T) to a multiple of four and not LEAD_T alone**.
  At the shipping phase of 4 the four LEAD_T values are indistinguishable from software,
  which is the page's finding: the constant cannot be pinned by any ROM while the phase is
  4. What it does settle is the phase, where the suites disagree (mooneye's [4,7] → 22,
  gambatte's [0,3] → 23), per machine. `-DM0=32` shifts the window if no step shows.
- **probe_k_winglitch** (16 bands of 8 lines, one ROM per arming regime): every line is
  entered from its own LYC halt and sets SCX and WX inside mode 2, so the page needs no dot
  precision at all. A band's top four lines carry the test WX and its bottom four WX = 200,
  on a 4-black/4-white stripe: **edges flush with one extra white pixel = replace; edges
  stepped one pixel right = insert; identical = no glitch**. `a0` (WY = 0, LCDC.5 never
  set) is Pan Docs' enable-free Y condition, `a1` a WY match seen with the window enabled
  but never started, `a2` full activation. `scx` (AXIS = 1) holds WX − SCX constant in
  bands 0–7 and WX constant in bands 8–15: dingbat fires exactly where
  `(WX & 7) == 7 − (SCX & 7)`, which is row 18's unpinned phase claim.
- **probe_k_lcdon** (three 4×8 blocks at rows 1–4, 6–9 and 11–14, columns 6–13): 96 LCD
  enables, each followed by an exact M-cycle delay and one STAT read; a cell is black when
  the line had already reached mode 0. Rows are n = 0..3 (4 dots each), columns s = SCX & 7
  (1 dot each), so the boundary is a staircase and `s*(0,n) − s*(40,n)` is line 0's edge in
  DOTS. `-d:LCD_ON_LINE0_TRIM=2 -d:LCD_ON_LINE1_TRIM=-2` moves block `01` two columns and
  leaves the other two, which is how the page was proved to discriminate.
- **probe_k_oamclass** (16 bands, one per instruction class): OAM is DMA-restored from a
  known pattern, one instruction of the class runs with `$FE10` (or SP = `$FE20`) on the
  bus at a fixed M-cycle inside line 100's mode 2, and byte 2 of all twenty OAM rows is
  compared in the next VBlank. Column 0 is the class digit, columns 1–19 are OAM rows 1–19.
  Classes 1–7 are the 16-bit IDU family dingbat wires, 8–F are plain memory accesses
  through the same address that Pan Docs' "any memory access instruction" also covers and
  dingbat does not. Bands 8–F marking anything is the A8 row's answer.

Constants are overridable at assembly: `-DBASE= -DLEAD= -DOBJX0= -DWXON=` (probe_j),
`-DM0= -DBARMUL=` (serialdiv), `-DARM= -DAXIS= -DWXG0=` (winglitch), `-DDBASE=` (lcdon),
`-DJ= -DALINE= -DBANDS=` (oamclass).

## Results

`docs/gb-probe-oracle-results-2026-08-11.md`; hardware runs in `docs/hwprobe.md` and
`docs/flashcart-runbook.md`.
