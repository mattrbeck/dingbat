# nbadiff — dingbat vs NanoBoyAdvance audio-sample comparison

Harness + method for comparing dingbat's mixed GBA audio against
NanoBoyAdvance's core mixer, sample by sample. Built 2026-08-13 to chase
"staticy / chunky" audio in the Golden Sun intro (MP2K/Bon HLE disabled).

## Findings (Golden Sun USA, real BIOS boot, 90 s undriven)

**Root cause of the static: the cubic FIFO reconstruction in
`src/dingbat/gba/apu/dma_channels.nim` (`fifo_interp`, default ON) injects
6–10 dB of broadband noise above 5 kHz for high-rate DirectSound streams —
it is worse than the zero-order hold it replaced.** Isolated (cubic-run minus
ZOH-run, deterministic timelines so the subtraction is exact), the injected
noise sits only ~12.6 dB below the music (RMS 0.040 vs 0.172 full-scale).

Mechanism: `dma_channels_get_amplitude` estimates the fractional phase
between FIFO latch updates as `samples_since / update_interval`, where
`update_interval` is the *integer count of 32768 Hz reads* spanned by the
previous update period. Golden Sun's Bon mixer feeds the FIFO at **21024 Hz**
(period ≈ 1.559 output samples), so the measured interval flaps between 1
(→ `denom <= 1.0` → raw latch hold) and 2 (→ cubic evaluated with a wrong
denominator), and the true fractional phase is discarded entirely. The
Catmull-Rom is therefore evaluated at essentially random phases with a
discontinuity at every latch update → broadband hiss.

A synthetic replay of the exact algorithm at 21024→32768 Hz reproduces the
measured noise (+10 dB over ZOH in 8–10.5 kHz), while the *same* Catmull-Rom
driven by the true fractional phase (derivable exactly from the timer period
in CPU cycles: `2^24 / (65536 - reload)` Hz) drops imaging ~10 dB *below*
ZOH — i.e. the filter is fine, the phase estimate is the bug. Fix direction:
compute phase from the FIFO timer's actual period/cycle position instead of
counting output reads.

## Fix (SHIPPED from this branch): true-phase cubic

The phase now comes from timer-overflow cycle timestamps
(`last_update_cycle`/`inv_period`, measured exactly, rebased with the frame
in `apu_rebase`, reset with the FIFO); the read-counting estimator is gone.
`fifo_interp=false` (config key / Audio settings "hardware-accurate" mode)
bypasses reconstruction entirely — bit-true DAC output. During evaluation
the modes below were compared (legacy/linear existed as `interp_mode` 1/3 in
branch history at 8365910); Welch band powers, same 20 s of the Golden Sun
intro, dB:

| mode              | 5–8k | 8–10.5k | 10.5–16.4k (imaging only) |
|-------------------|------|---------|---------------------------|
| legacy (shipping) |  6.3 |     7.6 |   4.1                     |
| true-phase cubic  |  0.1 |    −6.8 | −12.4                     |
| true-phase linear | −2.3 |    −9.4 | −14.3                     |
| ZOH (interp off)  |  0.0 |    −2.4 |  −2.2                     |
| gs_bon HLE        |  1.6 |    −3.3 |  −6.7                     |

True-phase cubic: −14 dB vs shipping in the imaging bands and 4–10 dB below
ZOH, at +0.21% retired instructions on Golden Sun (32.488G vs 32.420G per
2000 frames, hw cycles equal within noise — legacy early-outs to a plain
latch read about half the time at 21 kHz, true-phase always interpolates).
Linear is ~2 dB quieter still up top but rolls off real 5–8 kHz content
(sinc² response) — audibly duller.

Emerald cross-check (m4a at 13379 Hz, Nyquist ~6.7 kHz; imaging bands
6.7–10k / 10–16.4k dB): legacy 2.9/−0.7, true-phase cubic 0.6/−1.6, ZOH
4.7/3.8, MP2K HLE 1.6/−0.8. Two takeaways: the legacy bug was mild at
typical MP2K rates (2↔3 interval flap) — why Emerald never sounded staticy —
and **ZOH is the worst mode at low FIFO rates**, which is why "just remove
interpolation" was rejected: it would trade Golden Sun's static for aliasing
grit across the ~13 kHz majority of the library. True-phase cubic wins both
regimes; shipped as the default with interp-off as the hardware-accurate
option.

Ruled out in the same session:

- **FIFO underruns/drops**: `-d:mp2kwav` counters over the same 90 s run:
  1,863,406 samples served (exactly 21024 Hz), 0 drops, 7 empty pushes
  (boot only). No click source.
- **ZOH itself vs NBA**: dingbat with `fifo_interp` off has a noise floor
  within a few dB of NBA's core mix (NBA's non-MP2K path is also a plain
  latch read at the SOUNDBIAS rate) — the remaining difference is NBA's
  cubic 32768→48000 output resampler vs SDL's converter, minor by
  comparison.

## Pieces

- `gba_audiodump.nim` — headless dingbat capture. Boots the **real BIOS**
  (`run_bios=true`, matching NBA's default; `dingbat_bench` hardcodes false)
  and runs unthrottled. Optional `zoh` arg forces the pre-cubic zero-order
  hold for a same-binary A/B.

      nim c -d:test_harness -d:release --path:src -o:gba_audiodump tools/nbadiff/gba_audiodump.nim
      DINGBAT_GBA_AUDIO_DUMP=cubic.s16 ./gba_audiodump gba_bios.bin rom.gba 5400
      DINGBAT_GBA_AUDIO_DUMP=zoh.s16   ./gba_audiodump gba_bios.bin rom.gba 5400 zoh

- gs_bon (Golden Sun HLE) is dormant unless the emulator is built with
  `-d:gsbon` (compile-time gate, default off — its frame-quantized note
  attacks read as "crinkly"); `mp2k` mode on a default build affects only
  m4a/MP2K titles.
- NBA side: uncommitted `NBA_AUDIO_DUMP=<path>` patch in
  `~/code/NanoBoyAdvance` (`src/nba/src/hw/apu/apu.cpp`,
  `MaybeDumpAudioSample`) dumps the core mix pre-resampler as f32le stereo
  with a `.json` sidecar giving the rate (32768 for the non-MP2K path at
  SOUNDBIAS resolution 0; 65536 when NBA's MP2K HLE is engaged). Config at
  `build/bin/qt/config.toml` (PORTABLE_MODE; the app rewrites it on ROM load
  — edit only while closed). Set the same `bios_path` as the dingbat run,
  `bios_skip = false`, `mp2k_hle_enable = false`,
  `pause_emulator_when_inactive = false`; `volume = 0` mutes the speakers
  without affecting the dump. Muted, NBA free-runs ~2–3.5× realtime, so a
  105 s wall run captures 200 s+.

      NBA_AUDIO_DUMP=nba.f32 ./NanoBoyAdvance rom.gba &   # kill when done

- `compare_bands.py` — Welch band powers, exact-diff of two deterministic
  dingbat runs, WAV rendering. See its docstring for scale factors
  (**dingbat `.s16` dumps are DAC-scale ±512, divide by 512 not 32768**).

## Gotchas

- Cross-emulator sample alignment is a dead end for undriven boots: Golden
  Sun's timeline diverged ~7.5 s between dingbat and NBA and the local
  offset wandered by thousands of samples (different logo/menu pacing).
  Compare band statistics of matching passages, or listen. (The 2026-07
  goodboy-demo comparison aligned to 11 samples — a demo ROM's timeline is
  emulator-independent; a commercial boot's is not.)
- `DINGBAT_FIFO_INTERP=0` is compiled out under `-d:test_harness`; the
  harness pokes `emu.apu.dma_channels.fifo_interp` instead.
- Two dingbat test-harness runs of the same ROM/frame count are bit-
  deterministic — their dump difference isolates a mixer change exactly.
