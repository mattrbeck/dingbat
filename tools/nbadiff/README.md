# nbadiff — dingbat vs NanoBoyAdvance audio-sample comparison

Harness for comparing dingbat's mixed GBA audio against a second emulator's core mixer by
band statistics. It is what diagnosed the Direct Sound FIFO reconstruction: the fractional
phase between FIFO latch updates must come from the FIFO timer's actual period
(`2^24 / (65536 - reload)` Hz, via `last_update_cycle`/`inv_period` in
`src/dingbat/gba/apu/dma_channels.nim`), not from counting 32768 Hz output reads — a
21024 Hz stream (Golden Sun's Bon mixer) makes a read-counted interval flap between 1 and
2 and evaluates the cubic at random phases. `fifo_interp=false` (config / Audio settings
"hardware-accurate") bypasses reconstruction for bit-true DAC output; zero-order hold is
the worst mode at the ~13 kHz rates most of the library uses, which is why it is not the
default.

## Pieces

- `gba_audiodump.nim` — headless dingbat capture; boots the real BIOS and runs
  unthrottled. `zoh` forces zero-order hold for a same-binary A/B.

      nim c -d:test_harness -d:release --path:src -o:gba_audiodump tools/nbadiff/gba_audiodump.nim
      DINGBAT_GBA_AUDIO_DUMP=cubic.s16 ./gba_audiodump gba_bios.bin rom.gba 5400
      DINGBAT_GBA_AUDIO_DUMP=zoh.s16   ./gba_audiodump gba_bios.bin rom.gba 5400 zoh

- `compare_bands.py` — Welch band powers, exact diff of two deterministic dingbat runs,
  WAV rendering. Dingbat `.s16` dumps are DAC-scale ±512: divide by 512, not 32768.
- Second-emulator side: an uncommitted `NBA_AUDIO_DUMP=<path>` patch in a local
  NanoBoyAdvance checkout dumps its core mix pre-resampler as f32le stereo with a `.json`
  rate sidecar. Match `bios_path`, set `bios_skip = false`, `mp2k_hle_enable = false`,
  `pause_emulator_when_inactive = false`; `volume = 0` mutes without affecting the dump.

      NBA_AUDIO_DUMP=nba.f32 ./NanoBoyAdvance rom.gba &

gs_bon (Golden Sun HLE) is dormant unless built with `-d:gsbon`; `mp2k` mode on a default
build affects only m4a/MP2K titles.

## Gotchas

- Cross-emulator sample alignment is a dead end for undriven commercial boots (logo/menu
  pacing differs by seconds and wanders). Compare band statistics of matching passages, or
  listen. A demo ROM's timeline is emulator-independent and does align.
- `DINGBAT_FIFO_INTERP=0` is compiled out under `-d:test_harness`; the harness pokes
  `emu.apu.dma_channels.fifo_interp` instead.
- Two dingbat runs of the same ROM/frame count are bit-deterministic; their dump
  difference isolates a mixer change exactly. `-d:mp2kwav` counters report FIFO drops and
  empty pushes.
