# dingbat predictions for the v7 + v8 GBA probes — 2026-09

**Not hardware.** Every other directory under `expected/` holds hardware
truth transcribed from a console; this one holds what *dingbat* produces
for the probes written in 2026-09, before anyone has run them on silicon.
It exists so the hardware session has something to diff against, and so
the emulator's answer is on record with a date rather than reconstructed
afterwards.

Probe documentation, including what each outcome means:
`tests/roms/README-probes-gba.md`.

| file | what it is |
|---|---|
| `pages.txt` | all 50 gbaedge pages in `hwprobe_expected.py`'s transcription format. Pages 00-24 reproduce the AGS-001 session-4 values byte for byte; 25-27 are the v7 pages (OBJBUDGET / OBJGEOM / DMAOPENBUS) and 28-31 the v8 pages (IRQDECOMP through UNDMODE). The two visual pages carry a `visual` line instead of bytes |
| `lle-pages.txt` | the same run under the **real BIOS** (`--bios gba_bios.bin`). IWCYCLE (page 47) is the reason it exists: it measures the BIOS IntrWait path, which hardware always runs for real, so the HLE row and the LLE row are both on record. Pages 03 SWITIME / 0D SWIREGION / 02 BIOSPROT also differ |
| `p37.png` `p38.png` | the OBJBUDGET and OBJGEOM pictures as dingbat draws them |
| `p39.png` .. `p49.png` | the hex pages added in v7 and v8 |
| `psgbias-step00.png` | psgbias.gba's screen on step 0 (what a photograph should look like) |
| `psgbias-audio.txt` | per-step measurements of dingbat's audio output for `psgbias-auto.gba`, and the method |

Captured from `gbaedge-auto.gba` (`ALL BA6C` under the HLE BIOS, `53C7`
under the real one; the manual build is `ALL 5060`) with:

```
python3 tests/roms/hwprobe_capture.py ./dingbat_test \
        tests/roms/gbaedge-auto.gba tests/roms/expected/predicted-2026-09
python3 tests/roms/hwprobe_capture.py ./dingbat_test \
        tests/roms/gbaedge-auto.gba /tmp/lle \
        --bios /path/to/gba_bios.bin        # -> lle-pages.txt
```

The `.ppm` files that script also writes are not committed; the PNGs are
byte-identical renderings of them.

Two v8 pages measure phase against free-running clocks and so are **not
reproducible run to run**: TIMPHASE (43) and PSGPHASE (44) shift with the
absolute cycle at which the boot probes reach them, and their CRCs moved
between two builds that differ only in *other* probes' code. Read their
shape, not their bytes. IWCYCLE (47) drifts by a few cycles for the same
reason.

When hardware runs these pages, transcribe the photographs into a normal
`expected/agb-sp-N.txt` and render it with `hwprobe_expected.py` as usual.
This directory is then the record of what dingbat believed beforehand —
keep it, do not overwrite it with the hardware values.
