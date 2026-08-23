# gbdiff — differential GB/GBC oracle against docboy

A black-box differential harness between dingbat and
[docboy](https://github.com/Docheinstein/docboy), the CGB-capable second opinion the
suite lacks (Mealybug and GBMicrotest references are DMG-only). Same shape as
`tools/gbfuzz` (cross-emulator screenshots) and `tools/gbgate` (two-build A/B); it reuses
gbfuzz's `dingbat_gb_nav` as the dingbat side.

Ground rules: no code is taken from docboy (`docboy_gb_runner.cpp` is written against its
public `Core`/`Lcd` interface and only drives frames and writes screenshots), and
"docboy does it this way" is never a reason for a change — a divergence is evidence that
something is worth looking at; what lands in `src/` is derived from Pan Docs, datasheets
and the test ROMs' own bracketing families, and the commit cites that.

## Build

    git clone https://github.com/Docheinstein/docboy --recurse-submodules ~/code/docboy
    tools/gbdiff/build.sh          # GBDIFF_DOCBOY=<path> to point elsewhere

Produces `docboy_gb_runner_dmg` and `docboy_gb_runner_cgb` (docboy picks its model at
compile time; the drivers route each ROM by the cart's CGB flag) and rebuilds
`tools/gbfuzz/dingbat_gb_nav`. The runner is staged into the docboy checkout as an extra
target so it inherits the exact compile definitions `libdocboy` was built with (several
change struct layouts). Two settings are correctness requirements:
`ENABLE_RTC_SYSTEM_TIME=OFF` (else an RTC title differs from itself between runs) and
`ENABLE_BOOTROM=ON`. Boot ROMs are never committed; pass their directory as `--boot`.

## What makes the comparison mean anything

- **Boot ROM parity.** Both emulators play the boot ROM from power-on and count frame 0
  from there; each emulator's skip-boot shortcut lands on a different cycle and the
  phase drift swamps every real difference.
- **Palette normalisation.** DMG: both sides emit the shared `FF/AD/52/00` grey ramp.
  CGB: both framebuffers are the raw palette word, red in the low 5 bits.
- **Determinism.** Both zero-fill power-up RAM.

## Tools

| | |
|---|---|
| `sweep.py` | run a ROM list in both, compare screenshots per frame, classify |
| `probe.py` | reduce one divergence: PHASE or CONTENT? |
| `ppmdiff.py` | differing pixel count, bounding box, 3-panel PNG |
| `readout.py` | read a gambatte ROM's on-screen hex out of a screenshot |
| `gambatte_ab.py` | cross-tabulate both emulators against gambatte's filename |
| `gdma_sweep.sh` | measure `GDMA_SETUP_MCYCLES` against its whole ROM family |

    tools/gbdiff/sweep.py roms.txt /tmp/w --frames 1200 --step 30 --keep-ppm
    tools/gbdiff/probe.py "$ROM" 420 --window 3 --png
    tools/gbdiff/gambatte_ab.py cgb-roms.txt /tmp/ab --dev cgb

## PHASE vs CONTENT

`probe.py` reports which dingbat frame equals which docboy frame: **PHASE** (frame `F`
equals `F+k` for constant `k`; one is running ahead) or **CONTENT** (no offset matches; a
candidate bug). A PHASE result is usually a harness artifact: real hardware produces no
frames with the LCD off, so how many "frames" pass while it is off is a front-end
convention on both sides, and a title that blanks the screen accumulates a frame of skew
that means nothing. Frame-indexed comparison is only sound while the LCD stays on; for
frame-pacing questions use `tools/gbfuzz/{sameboy,dingbat_gb}_fps`.

## gambatte ROMs: the filename is the oracle

gambatte ROMs encode the expected value per device in the filename, so `gambatte_ab.py`
scores both emulators against it: `BOTH_PASS`, `DOCBOY_ONLY` (correct behaviour is
reachable — investigate dingbat), `DINGBAT_ONLY` (a docboy bug), `BOTH_FAIL`. A
`BOTH_FAIL` on a `_1`/`_2` bracketing family where the two give the family's two answers
means they bracket the hardware transition and neither can correct the other
(`window/late_disable_ds_{1,2}`). A row is scored only if the reading is identical at two
frames; otherwise `UNSTABLE`.

When a divergence reduces to "N M-cycles off", the family measures N: `gdma_sweep.sh`
rebuilds at each `GDMA_SETUP_MCYCLES` and a value counts only if every `gdma_cycles_*`
pair lands on the right side of its own flip. `tools/gbppu/famflip.py` does the same for
the PPU write-latency families.

## Hygiene and limits

ROMs are symlinked per emulator (saves land next to the symlink) and deleted before every
ROM; each child has its own `TMPDIR`, a timeout, and is killed by process group; lists are
read line by line; parallel workers take scratch dirs from a free list.

docboy rejects cart types it lacks (Game Boy Camera → `ERROR`); SGB is not comparable;
audio is not compared (`tools/gbfuzz`'s PCM path and `tools/pcmdiff.py` cover it); the
`GBDIFF_DUMP=1` `.mem` dump omits palette blocks.
