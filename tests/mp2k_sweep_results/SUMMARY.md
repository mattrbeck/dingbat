# MP2K HLE archive sweep — 2026-07-23

2354 deduplicated ROMs (from a 7,899-ROM archive; GoodGBA-style dedupe to one
per title, bad dumps and multiboot conversions skipped — see picked/skipped).
Each ROM booted 900 frames headless with the shadow HLE armed
(tests/mp2k_sweep.nim via tools/mp2k_sweep.py); span-matched HLE-vs-REAL
DirectSound RMS captured per run.

- sweep1: pre-fix baseline (main @ 7f69509)
- sweep2: after the fix batch (foreign-feeder fallback, VSyncOff idents,
  FIFO DMA level-conditioned grants, attack frames, decimation backfill,
  ct position resync) — before the final makeup 2.1->2.025 recentre.

**sweep1**: ok 2354/2354, crashes 0, timeouts 0, probe churn 0; m4a-positive 1033, engaged 1013 (98.1%), foreign-latched 0; music-playing engaged 808, within ±20% 689 (85.3%), median ratio 0.952

**sweep2**: ok 2354/2354, crashes 0, timeouts 0, probe churn 0; m4a-positive 1033, engaged 1013 (98.1%), foreign-latched 75; music-playing engaged 738, within ±20% 724 (98.1%), median ratio 1.037

