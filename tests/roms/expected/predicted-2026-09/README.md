# dingbat predictions for the v7 GBA probes — 2026-09

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
| `pages.txt` | all 40 gbaedge pages in `hwprobe_expected.py`'s transcription format. Pages 00-24 reproduce the AGS-001 session-4 values byte for byte; 25-27 (OBJBUDGET / OBJGEOM / DMAOPENBUS) are the new ones. The two visual pages carry a `visual` line instead of bytes |
| `p37.png` `p38.png` | the OBJBUDGET and OBJGEOM pictures as dingbat draws them |
| `p39.png` | the DMAOPENBUS hex page |
| `psgbias-step00.png` | psgbias.gba's screen on step 0 (what a photograph should look like) |
| `psgbias-audio.txt` | per-step measurements of dingbat's audio output for `psgbias-auto.gba`, and the method |

Captured from `gbaedge-auto.gba` (`ALL 38FC`) with:

```
python3 tests/roms/hwprobe_capture.py ./dingbat_test \
        tests/roms/gbaedge-auto.gba tests/roms/expected/predicted-2026-09
```

The `.ppm` files that script also writes are not committed; the PNGs are
byte-identical renderings of them.

When hardware runs these pages, transcribe the photographs into a normal
`expected/agb-sp-N.txt` and render it with `hwprobe_expected.py` as usual.
This directory is then the record of what dingbat believed beforehand —
keep it, do not overwrite it with the hardware values.
