# GB hardware session runbook (flash-cart day)

One page for the day the GB flash cart arrives. Everything here is a pointer —
the specs live in `docs/gb-failure-triage.md` ("The four hardware experiments"
section), the registered predictions in `docs/gb-probe-oracle-results-2026-08-11.md`,
and the rig in `tools/gbprobe/README.md`.

## What to bring

| device | needed for | notes |
|---|---|---|
| AGB SP (on hand) | (b), (c) CGB-class arms | boots GB carts in GB-compat mode; its GB core is the AGB revision (`--cgb-rev` axis: FEA0 nibble-echo class, late palette step) |
| DMG (not on hand yet) | (a)'s real target, (d) | the field tail is K=3 on DMG and 0 on CGB — (a) on the SP only confirms the CGB-side zero |
| GB-slot flash cart | all | a GBA-slot cart cannot run `.gb` in compat mode |

## The ROMs

Prebuilt and committed in `tools/gbprobe/`: `probe_a_statidiom.gb`,
`probe_b_scxm3.gb`, `probe_c_arbitrate.gb` (+ `_scx3`/`_scx7` variants).
Rebuild if needed: `tools/gbprobe/build.sh roms`. Headers validate; they run
on any GB device and render raw hex — no baked expectations.

## Procedure per ROM

1. Flash, boot, let it settle (each probe reaches a steady screen; a few
   seconds is plenty).
2. Photograph the screen: as square-on as possible, fill the frame, avoid
   glare on the hex digits; any modern phone camera resolution is fine. One
   photo per probe per device. Name them `probe_<x>.<device>.jpg`.
3. Readout: `tools/gbprobe/readout.py` reads the hex grids of (a)/(b);
   `tools/gbprobe/arbread.py` reads (c)'s two staircases. Both lift the font
   glyphs from the ROM image itself, so they read photos as well as emulator
   PPMs (see the README's readout section for invocation).
4. Compare against the oracle tables in
   `docs/gb-probe-oracle-results-2026-08-11.md` — the same tables were filled
   by dingbat/SameBoy/DocBoy before the hardware run, so every cell is a
   prediction with a name on it.

## What each outcome decides (the registered predictions)

* **(a) STAT read idiom** — both oracles predict the two idiom columns flip
  together. If the photo agrees: delete `STAT_M0_FIELD_TAIL` +
  `STAT_M0_TAIL_MAX_MC` (gb.nim) and reopen the ~60 rows they carry — the
  idiom/suite confound resolved against us. If `LD A,(C)` flips one step later
  than `LDH`: our round-4 rule is confirmed against both oracles. NOTE: run on
  DMG for the real question; the SP arm only checks the CGB-side K=0.
  A second reading rides along: the oracles put the CGB mode-0 boundary one
  M-cycle earlier than DMG; gambatte's suite (40/40 families, NOP→HALT control)
  says they're equal — the photo arbitrates the oracles vs gambatte.
* **(b) SCX mode-3 extension** — all extending engines agree on a single
  one-M-cycle window worth exactly 8 dots ($07→$07 control must not extend).
  What the photo pins is the window's POSITION (dingbat CGB dot 91 vs SameBoy
  CGB 87) and whether the DMG-side 11–14-dot gambatte bracket (which NO engine
  reproduces) is real.
* **(c) the 261st shootout row** — all three engines are identical cell for
  cell: none separates pixel emission from the fetch grid. If the photo
  matches the engines: acid-hell's 2 pixels become a REFERENCE question (which
  device/conditions produced the published capture), not a model question —
  and the answer likely closes the shootout at 261 by re-reading the
  reference, not by changing the renderer. If the photo shows the band edge
  and glitch column split by 4 dots: the renderer needs the emission/grid
  split no constant supplied, and the P-bracket sections of the triage doc
  become the implementation map. (c) is a DMG cart by necessity (BGP is inert
  in native-CGB mode) but runs on both devices — the SP arm is the CGB-compat
  reading.
* **(d) multi-unit DMG BGP OR** (opportunistic, needs ≥1 DMG): photograph the
  same mid-pixel BGP write on every DMG available; daid reports unit- and
  position-dependence, so each unit photo is a data point, not a verdict.

## Recording results

Transcribe each photo's values into a dated section of
`docs/gb-failure-triage.md` next to the experiment specs (the hwprobe
workstream's convention: raw transcription first, verdicts after), and keep
the photos. Then re-run the affected derivations — each experiment's
"what it decides" above names the constants and rows.

## Standing context (2026-08-11)

Shootout 260/261 (sole first; the one fail is acid-hell's 2 px). Local runner
781/981, gambatte 4131/5005, mGBA 6958/6998 (per-row verdicts in
docs/mgba-suite-verdicts.md). The ranked non-hardware backlog is at the end of
docs/gb-failure-triage.md (window/on_screen leads it).
