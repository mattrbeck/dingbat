# dingbat predictions for the 2026-09 gbedge APU probes

**Not hardware.** Every other directory under `expected/` holds hardware
truth transcribed from a console. This one holds what *dingbat* produces for
`gbedge.gb` after the six APU pages added in 2026-09 (`CH2PHASE`, `SWPPHASE`,
`NOISEWAVE`, `ENVPHASE`, `NR10PACE`, `SEQRESET`), before anyone has run them
on silicon. It exists so the hardware session has something to diff against,
and so the emulator's answer is on record with a date rather than
reconstructed afterwards.

What each page and each byte means, and what each outcome would pin:
`tests/roms/gbedge_apu_notes.md`.

| file | run |
|---|---|
| `pages.txt` | `--cgb` (dingbat's default CGB revision is **C**) |
| `pages-cgbE.txt` | `--cgb --cgb-rev=E` — also the closest column to an AGB/AGS GB slot |
| `pages-dmg.txt` | `--dmg` |

Captured from `gbedge-auto.gb` with a GB sibling of
`tests/roms/hwprobe_capture.py` (same OCR, same transcription format; the
`.ppm`/`.png` files it also writes are not committed, and the hex pages do
not need pictures). The viewer comes up on frame **273** (`--cgb`) / **243**
(`--dmg`) — the `console:` lines below quote the capture script's own
4-frame-granular estimate — 214 of those frames are the 27 older pages and the rest the six
new ones, which is inside the 420-frame window `tests/clip_replay_test.nim`
runs this ROM for.

Pages 00-1A are the pre-2026-09 probes and are unchanged by this work:
captured before and after adding the six pages, all 27 are byte-identical on
both `--dmg` and `--cgb`. The per-page `CRC` lines are therefore unchanged
too; only the `ALL` line moves, because six more slots now feed the global
CRC16.

The three runs differ on the new pages in exactly two places:

- `CH2PHASE` (1B): CGB-C's PCM read glitch (`GbQuirks.pcm_read_edge_zero`)
  zeroes the read that lands on the first duty step, so both of its rows'
  edges sit one k later than on CGB-E. On DMG the page is skipped (`EE` at
  `+1F`): no PCM readback.
- `NOISEWAVE` (1D): the wave-RAM half is a DMG measurement. On CGB every read
  resolves and the row shows the pointer walking; on DMG only every third
  read is inside the access window and the rest read `$FF`.

`SWPPHASE` (1C) rows 00-0F and `NR10PACE` (1F) and `SEQRESET` (20) are
NR52-only and read the same on every model in dingbat — any per-model
difference on hardware is itself a finding.
