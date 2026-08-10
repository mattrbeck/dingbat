# hwprobe expected results

One directory per **real-hardware run** of a probe ROM, rendered as PNGs
by `../hwprobe_expected.py` from the transcription `.txt` beside it.  The
images are drawn with the ROM's own font and layout and are **pixel-
identical to what the ROM's viewer displays** — the renderer is verified
byte-for-byte against emulator screenshots on hardware-matching pages.

These are *hardware truth*, not emulator output: on pages an emulator
gets wrong, the PNG shows what the console displayed.

## Comparing an emulator against them

Screenshot the same (manual) build's page and diff the images.  Rules:

- Page image identical → the emulator matches hardware on every byte of
  that probe, including the slot CRC.
- Only the `ALL` line differs → this page matches but some *other* page
  in the run doesn't (`ALL` is the whole-run CRC).
- `MODEL` differs → different BIOS/console family than the transcribed
  run (compare against a matching console's directory).

Flashcart caveat: WAITSTATE/PFPHASE pages and ROM-open-bus bytes are
cart-influenced; each run's `.txt` header names the cart used.

## Runs

- `agb-sp-1/` — GBA SP AGS-001 + EverDrive GBA, 2026-08-10 (gbaedge,
  all 16 pages + MSRTBIT post-START; `ALL F54C`, post-START `1512`).
  Analysis: `docs/hwprobe-results-agb.md`.

gbedge (GB/GBC) runs land here the same way once a GB-slot cart run is
transcribed; `hwprobe_expected.py` grows the 160x144 renderer then.

## Regenerating

```
python3 tests/roms/hwprobe_expected.py tests/roms/expected/agb-sp-1.txt
```
