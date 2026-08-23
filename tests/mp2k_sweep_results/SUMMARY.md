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

## Why span-matched

`-d:mp2kwav` (`src/dingbat/gba/apu.nim`) gates the REAL FIFO capture on the same
predicate as the HLE render, so a run's HLE and REAL RMS cover the same audio span. Games
whose engine engages late (Mother 3 holds `SoundInfo.ident` at ID_NUMBER+10 through a
~10 s intro) otherwise pad REAL with leading silence and make the HLE read ~+23% hot when
the matched streams agree within a few percent.
