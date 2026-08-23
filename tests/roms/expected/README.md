# hwprobe expected results

One transcription per real-hardware run of a probe ROM (`tests/roms/gbedge.py` /
`gbaedge.py`), with a directory of PNGs rendered from it by `../hwprobe_expected.py`.
The images use the ROM's own font and layout and are pixel-identical to what the ROM's
viewer displays, so an emulator screenshot of the same page diffs directly against them.
They are hardware truth, not emulator output.

## Comparing an emulator against them

- Page image identical → the emulator matches hardware on every byte of that probe,
  including the slot CRC.
- Only the `ALL` line differs → this page matches but another page in the run does not
  (`ALL` is the whole-run CRC).
- `MODEL` differs → different console family than the transcribed run.

WAITSTATE/PFPHASE pages and ROM-open-bus bytes are cart-influenced; each `.txt` header
names the cart used.

## Runs

- `agb-sp-1/` — GBA SP AGS-001 + EverDrive GBA: gbaedge pages 0–15 + MSRTBIT post-START
  (`ALL F54C`, post-START `1512`). Analysis: `docs/hwprobe-results-agb.md`.
- `agb-sp-2/` — same console: pages 16–24 (`ALL 4B70`; BXDECODE not run, it hangs the
  console). Partial runs omit page 0 and give `model:` in the `.txt`.
- `agb-sp-3/` — same console: the v5 pages (`ALL FDE5`; BXDECODE run one press at a time,
  candidate 2 wedges the console and is marked DD).
- `agb-sp-4/` — same console: the v6 isolation pages 28–36 (`ALL B473`).
- `gb-mgb-1.txt` — gbedge.gb on a Game Boy Pocket (MGB), GB flashcart; every page
  CRC-verified.
- `gb-agbsp-1.txt` — gbedge.gb on the GBA SP's GB slot (CGB-native mode).

## Regenerating

```
python3 tests/roms/hwprobe_expected.py tests/roms/expected/agb-sp-1.txt
```
