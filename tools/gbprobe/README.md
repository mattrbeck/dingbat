# tools/gbprobe — hardware probe ROMs, and three engines to read them in

Three probe ROMs that measure the three open hardware questions at the end of
`docs/gb-failure-triage.md`, plus a harness that runs any GB ROM in **dingbat,
SameBoy and DocBoy** through one interface and reads the answer back off the
screen.

The ROMs are the permanent artifact. They report raw values and contain no
expectation, they render their results as hex on screen as well as storing them
to WRAM, and their cartridge headers are correct — so the same `.gb` that
produced the tables in `docs/gb-probe-oracle-results-2026-08-11.md` can be
burned to a flash cartridge and photographed on a real Game Boy, and the same
`readout.py` will read the photo.

**SameBoy and DocBoy are behavioural ORACLES.** We run ROMs in them and read
the pixels out. No constant and no line of either implementation is copied into
dingbat. Three oracles agreeing is corroborating evidence that justifies
building a mechanism behind a flag pending the hardware photo; it is never
itself the citable derivation.

## Build

```sh
./build.sh            # rgbds, the three engine runners, and all the ROMs
./build.sh roms       # just re-assemble the ROMs
./build.sh engines    # just the runners
```

Everything third-party lands under `<worktree>/.scratch` and nothing is
installed system-wide:

| piece | where it comes from | note |
|---|---|---|
| RGBDS 1.0.3 | the release zip | the release carries pre-generated parsers, so the system's bison 2.3 (too old for rgbds' own build) is not in the way |
| SameBoy | `$GBPROBE_SAMEBOY`, else `~/code/SameBoy`, else cloned | `make lib` + `make bootroms`, the latter assembled with the RGBDS above |
| DocBoy | cloned from `Docheinstein/docboy` | two builds, see below |

## Shooting a frame

```sh
./shoot.sh <rom.gb> <model> <frames> <outprefix> [engines...]
```

writes `<outprefix>.<engine>.ppm` and `.png` for each of dingbat, sameboy and
docboy. `./table.sh <rom.gb> <frames> <model>...` shoots and prints each
screen as text; `./readout.py` reads a numeric probe's hex grid, `./arbread.py`
reads probe (c)'s two staircases.

Model tokens are `dmg`, `cgb0`, `cgbAB`/`cgbA`, `cgbC`, `cgbD`, `cgbE`, `agb`.

### What each engine can actually be asked

* **dingbat** — every revision, straight from `src/` (`dingbat_shot.nim` calls
  `gb_set_revision`). Skip-boot, which is its shipping default.
* **SameBoy** — every revision (`GB_MODEL_*`). It has no skip-boot entry point,
  so this leg loads SameBoy's own boot ROM and burns the animation off before
  frame counting starts, which puts it on the same post-boot timeline as the
  other two.
* **DocBoy** — **DMG or CGB, and nothing finer**: CGB support is a compile-time
  option (`ENABLE_CGB`), not a runtime model selector, so DMG and CGB are two
  separate binaries and a DocBoy column in a results table is one number for
  all of CGB C/D/E by construction.

Two things about DocBoy needed handling and `build.sh` does both. Its
`third_party/CMakeLists.txt` `add_subdirectory()`s SDL and nativefiledialog
unconditionally, so a devtools-only build will not configure without those
large submodules — they get guarded behind `BUILD_SDL_FRONTEND` in the scratch
checkout. And its stock `devtools/runtakeframebuffer` links `testutils`, which
only exists under `BUILD_TESTS=ON`, which compiles the whole emulator with
`ENABLE_TESTS`; an oracle has to be the emulator as it ships, so
`docboy_shot.cpp` here talks to `Core` directly and counts frames rather than
ticks.

### Comparability

DMG output from all three legs is normalised to one four-shade grey ramp
(`FF/AD/52/00`), so a DMG picture is byte-comparable across engines. CGB output
is not: DocBoy stores its framebuffer as RGB565 where the other two keep RGB555,
so CGB frames are compared by structure — which column changes colour where —
and the probes are written so that every colour they use survives the round
trip distinctly.

## The ROMs

| ROM | question | header |
|---|---|---|
| `probe_a_statidiom.gb` | does the STAT mode FIELD report differently to `LD A,(C)` and `LDH A,($41)` at the mode-0 boundary? | CGB-compatible (`$80`) |
| `probe_b_scxm3.gb` | how much does a mid-line SCX store lengthen mode 3, and where in mode 3 does the store have to land? | CGB-compatible (`$80`) |
| `probe_c_arbitrate*.gb` | on ONE frame, where does the BGP band edge sit relative to the LCDC.4 glitched fetch column? | **no CGB flag** — see below |
| `scratch_font.gb` | not a probe: a smoke test for the shared video/readout path |  |

Probe (c) deliberately carries **no** CGB flag. The triage doc says "Setup.
CGB", but the emission ruler it names is BGP, and on a CGB running a
CGB-flagged cartridge BGP is dead, colour comes from CRAM, and CRAM is not
writable during mode 3 — so there is no mid-line emission ruler in true CGB
mode at all. The only machine that can carry both rulers on one frame is the
one `daid/ppu_scanline_bgp` itself runs on: a CGB executing a DMG cartridge, in
DMG-compatibility mode, where the PPU is CGB silicon and BGP is live. The same
cart runs natively on a DMG, so the DMG column is a control rather than an extra
build. Each probe's own header comment carries the rest of its design.

Each probe's numbers are all overridable at assembly time
(`./mk.sh probe_b_scxm3 -DBASE_M=8`), because the halt-wake latency is the one
quantity these ROMs cannot know in advance and it is what positions every sweep
window. On hardware, walk the base until the flip is inside the window.

## Results

`docs/gb-probe-oracle-results-2026-08-11.md`.
