# GB hardware session runbook (probe carts)

How to run the `tools/gbprobe/` probe carts on real hardware. Questions:
docs/hwprobe-questions.md; predictions and results per probe:
docs/gb-probe-oracle-results-2026-08-11.md; the full kit (gbedge, suite ROMs,
folders): docs/flashcart-runbook.md.

| device | needed for |
|---|---|
| GBA SP / GBA (GB slot) | CGB-class arms of (b), (c), (e); its GB core is the AGB revision |
| DMG or MGB | (a)'s real target (field tail K=3 on DMG, 0 on CGB), (d), per-unit BGP OR photos |
| GB-slot flash cart | all — a GBA-slot cart cannot run `.gb` in compat mode |

ROMs, prebuilt and committed: `probe_a_statidiom.gb`, `probe_b_scxm3.gb`,
`probe_c_arbitrate.gb` (+ `_scx3`/`_scx7`), `probe_d_tdsel_*.gb`, `g1_scx0.gb`,
`g1_scx4.gb`. Rebuild with `tools/gbprobe/build.sh roms` (`mk.sh` fixes every
header to ROM-only; `mkcart.sh` for carts that need an MBC header). Every ROM
renders raw hex and bakes no expectation.

## Procedure per ROM

1. Flash, boot, let it reach its steady screen.
2. Photograph square-on, filling the frame, no glare on the digits; one photo
   per probe per device, `probe_<x>.<device>.jpg`, kept in `hwphotos/`.
3. Read out: `readout.py` for (a)/(b), `arbread.py` for (c), `read_g1.sh` for
   (e) (`find_panel.py` + `photowarp.py` + `read_probe_e.py`; a moire-hit shot
   needs the per-row median read). All lift the font glyphs from the ROM, so
   they read photos and emulator PPMs alike.
4. Transcribe the values into docs/gb-probe-oracle-results-2026-08-11.md next
   to the prediction.

## What each outcome decides

- **(a)** both idiom columns flip together → delete `STAT_M0_FIELD_TAIL` +
  `STAT_M0_TAIL_MAX_MC` (gb.nim), reopening ~60 rows; `LD A,(C)` one step
  later → the rule stands. Run on DMG/MGB.
- **(b)** the extension window's position (dingbat CGB dot 91) and whether a
  DMG has one (gambatte's 11–14-dot DMG bracket is reproduced by no engine).
- **(c)** band edge and glitch column together → acid-hell and daid cannot be
  read from one anchor; four dots apart → the emission/fetch-grid split is
  real. Needs corner registration marks in the ROM first.
- **(d)** per-DMG-unit BGP OR pixel: each unit is a data point. **(e)** done
  on the SP (docs/hwprobe-questions.md, g1); DMG/CGB arms unrun.
