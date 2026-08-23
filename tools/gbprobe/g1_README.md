# g1: does the CGB carry a halt-wake PPU phase?

Two ROMs, two photographs. They arbitrate `CGB_HALT_PPU_LEAD` (`gb/gb.nim`): the CGB's
PPU running an M-cycle ahead of the CPU after a STAT/LYC halt wake, except on the LY
153→0 snapback. `cgb-acid-hell` and daid's `ppu_scanline_bgp` agree with it; probe (e),
this ROM, does not, and carries an unexplained 2–3 M offset against the oracle.

## What to do

1. Flash `g1_scx0.gb`, run it on the GBA SP (the console of the probe (e)/(f) sessions).
   Do not touch the d-pad; the two hex bytes top-left should read `00 FF`. Photograph the
   whole screen square-on.
2. Flash `g1_scx4.gb`, confirm `04 FF`, photograph again.

## What it settles

The picture is a staircase of vertical bars; what matters is each bar's x column,
read relative to the header glyphs in the same frame, so a hand-held shot is fine. Three
candidates, 8 pixels apart (`predicted-*.png` in this folder at 3x):

| SCX | `CGB_HALT_PPU_LEAD=0` | `=1` (ships) | oracle prediction |
|---|---|---|---|
| 0 | `32 40 40 48 48 56 ...` | `40 40 48 48 56 56 ...` | `24 32 32 40 40 48 ...` |
| 4 | `28 36 36 44 44 52 ...` | `36 36 44 44 52 52 ...` | `20 28 28 36 36 44 ...` |

- reads 24 / 20 — both dingbat builds are wrong on this probe; chase probe (e)'s baseline.
- reads 32 / 28 — lead 0 is right; revert the constant and take `cgb-acid-hell` back to 2 px.
- reads 40 / 36 — the shipping build is right.

## Rebuilding and reading

    tools/gbprobe/mk.sh probe_e_objgrid -DSCX_DEFAULT=0 -DOBJX_DEFAULT='$FF'
    tools/gbprobe/mk.sh probe_e_objgrid -DSCX_DEFAULT=4 -DOBJX_DEFAULT='$FF'
    python3 tools/gbprobe/read_probe_e.py <photo.jpg>     # compare its `raw cols` line to the table

Everything else is the shipping default, including `ANCHOR_LINE = 16`, the STAT-LYC halt
whose phase is the question.
