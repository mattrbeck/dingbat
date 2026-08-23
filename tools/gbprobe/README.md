# tools/gbprobe — hardware probe ROMs and the harness that runs them

Probe ROMs for the open GB PPU questions in `docs/gb-failure-triage.md` and
`docs/hwprobe-questions.md`, plus a harness that runs any GB ROM through dingbat and two
black-box oracle engines (SameBoy via `sameboy_shot.c`, DocBoy via `docboy_shot.cpp`) and
reads the answer off the screen. No constant from either oracle is copied into dingbat;
three engines agreeing justifies a mechanism behind a flag pending a hardware photo.

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

## Results

`docs/gb-probe-oracle-results-2026-08-11.md`; hardware runs in `docs/hwprobe.md` and
`docs/flashcart-runbook.md`.
