# MP2K HLE archive sweep

2354 deduplicated ROMs (one per title from a 7,899-ROM archive; bad dumps and multiboot
conversions skipped), each booted 900 frames headless with the shadow HLE armed
(`tests/mp2k_sweep.nim` via `tools/mp2k_sweep.py`), span-matched HLE-vs-REAL DirectSound
RMS captured per run. The raw per-ROM results are no longer kept; these are the totals.

- **before the fix batch**: ok 2354/2354, crashes 0, timeouts 0; m4a-positive 1033,
  engaged 1013 (98.1%); music-playing engaged 808, within ±20% 689 (85.3%), median ratio 0.952
- **after** (foreign-feeder fallback, VSyncOff idents, FIFO DMA level-conditioned grants,
  attack frames, decimation backfill, ct position resync): ok 2354/2354; engaged 1013
  (98.1%), foreign-latched 75; music-playing engaged 738, within ±20% 724 (98.1%),
  median ratio 1.037

## 2026-09-13: the rewritten HLE, then the probe-driven restructure

The mixer had been rewritten from scratch (provenance audit). Re-swept as found and after
restructuring it on the probe-ROM facts (tools/mp2kprobe/README.md), 2354 titles, 900 frames:

| | as found | restructured |
|---|---|---|
| crashes / timeouts | 0 / 0 | 0 / 0 |
| m4a present / engaged | 1033 / 1014 | 1033 / 1014 |
| music-playing engaged | 780 | 780 |
| within ±20 % loudness | 773 (99.1 %) | 779 (99.9 %) |
| median loudness ratio | 0.995 | 1.004 |
| median envelope correlation (100 ms RMS) | 0.993 | 0.998 |

No title moved out of the ±20 % band; Van Helsing (0.70 → 0.97), Wings (1.33 → 0.99),
Kawaii Koinu (0.77 → 1.01), Breath of Fire (1.46 → 1.07), Beast Shooter (0.74 → 0.83) and
Ochaken (0.79 → 0.85) moved in. SMT II (0.78) remains: its FIFO carries ~12 % of audio the
game injects outside the driver. The loudness ratio is now DC-free (the driver's per-channel
floor truncation parks its stream at about −0.5 per active voice, which a raw RMS counted
against the HLE); against the driver's own buffer every probed title's energy is within
0.96–1.00 with DC removed.

The sweep's note-on census (start_honoured / start_ignored): 58,702 note-ons carried a
non-zero count and the engine started at sample 0 in every clear case (48 scattered
"honoured" hits across 9 titles, against hundreds of ignored ones in each), so the HLE no
longer reads that field as a start offset. With each pass's envelope predicted at the hook
and the frame held until the sound DMA reaches its slot (measured per title), the lag
estimate (RMS-envelope cross-correlation, 64-sample resolution) puts the HLE within ±64 APU
samples of the real stream for 97 % of music titles (median 0); 20 titles sit beyond ±300,
Castlevania: Circle of the Moon (42 kHz, two-slot ring, +640) the largest.

The RMS ratio cannot see waveform errors. Against the driver's own pcmBuffer (tests/
mp2k_probe.nim, Emerald title screen, per-frame correlation at the driver's sample
instants) the as-found HLE scored 0.47 over the run; the restructured one has a per-frame
median of 0.988 with 90 % of frames above 0.95.

## Why span-matched

`-d:mp2kwav` (`src/dingbat/gba/apu.nim`) gates the REAL FIFO capture on the same
predicate as the HLE render, so a run's HLE and REAL RMS cover the same audio span. Games
whose engine engages late (Mother 3 holds `SoundInfo.ident` at ID_NUMBER+10 through a
~10 s intro) otherwise pad REAL with leading silence and make the HLE read ~+23% hot when
the matched streams agree within a few percent.
