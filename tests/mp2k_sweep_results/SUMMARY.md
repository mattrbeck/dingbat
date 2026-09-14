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

## 2026-09-14: the rig, the mixer-finding rework, Castlevania

`tools/mp2kprobe/rig.py` drives a game's mixer with WaveData of our own through a host whose
songs are all silent, so channel-struct behaviour could be tested without a sequencer in the way:
it settled that per-side bytes written at the hook do nothing, that the pseudo-echo hold ends when
its length reads 0 at the hook, and that the note-on count field is a start offset on Emerald's
mixer but not on Minish Cap's (and set by no sequencer in the library).

The hook learner was rebuilt. The old one hooked the first RAM instruction seen with the SoundInfo
pointer in r0 under the engine lock, which on builds that keep all of SoundMain in RAM (EZ-Talk,
Super Dodgeball Advance, Mega Man Battle Network, Castlevania, Advance GTA, Hudson Best Collection)
is SoundMain itself, before its sequencer: every note-on reached the render a frame late. The new
one keeps only call targets (a BL aimed at the instruction, a BL to a `bx rN` stub — how every
compiled SoundMain reaches its RAM mixer — or `mov lr, pc; bx rN`), tallies eight passes, hooks
the first candidate that fired in all of them, and moves to the next call target of the pass when
the channel table shows the hook sits before the sequencer (an envelope that does not match one
hook later, or a channel first seen ON without its START bit). Castlevania's +640 turned out to be
three things stacked: its 42 kHz configuration inherited the intro's nine-slot ring period (now
re-learnt whenever the rate or frame length changes), its hook preceded the sequencer, and the FIFO
pipeline was a fixed 68 output samples where it is 28 source-rate samples at every engine rate
(measured 22–32 on six titles at each of nine rates).

| | round 2 | round 3 |
|---|---|---|
| within ±20 % loudness (DC-free) | 779 / 780 | 779 / 780 |
| within ±64 APU samples of hardware timing (envelope) | 756 (96.9 %) | 773 (99.1 %) |
| beyond ±300 | 20 | 5 |
| lag-0 waveform correlation > 0.5 | 259 | 403 |
| median lag-0 waveform correlation | 0.306 | 0.528 |

The waveform correlation is the metric that sees sub-millisecond placement; it improved at every
engine rate but 42 kHz (four Castlevania dumps, whose streamed track correlates poorly at any
sub-sample offset; by envelope they sit at 0, by waveform +24 samples). The five titles still
beyond ±300 by envelope (Cinnamon Fuwafuwa, Winning Post, The Bible Game, Breath of Fire II, GT
Advance 3) are the envelope estimator aliasing on periodic music — by waveform Cinnamon correlates
at 0.97 within 30 samples and GT Advance 3 at 0.998 — apart from Winning Post (+512), unexamined.

### Round 4: the slot crossing dated from the FIFO transfer

The latency measurement assumed the sound DMA's cursor moved continuously; it moves 16 bytes at
a time, so the crossing of a slot's start was mis-dated by up to 16 source samples, a fixed
error per title (the hook and the DMA schedule are both locked to V-blank) that the old
"pipeline" constant could only average. The DMA now stamps each FIFO transfer's cycle, the
crossing is dated from the transfer that carried the slot's first byte, and that byte's place in
the FIFO (15 deep after a refill) is counted; the residual is 10 source samples at every rate
(6–14 measured on six titles at each of nine rates). Per-title spread within a rate fell from
about ±20 to about ±7 output samples. Sweep: loudness unchanged; lag-0 waveform correlation above
0.5 on 422 titles (was 403), median 0.547, upper quartile 0.73 → 0.80; the 13.4 kHz family
(178 titles) went from a median of 0.49 to 0.59.

What remains by waveform is small and vintage-specific: Estopolis and Ochaken restart the DMA
every V-blank on the previous pass's slot, so a pass plays when the next handler runs and
inherits its jitter (bimodal ±5 samples against the HLE's jitter-absorbing FIFO); the 42 kHz
Castlevania sits +27 samples, which at that rate is enough to turn its lag-0 correlation
negative. The envelope-based lag estimator aliases on periodic music (Cinnamon, GT Advance 3,
Winning Post read hundreds of samples off while their waveforms correlate at 0.95 within 30).
Camelot's driver (Golden Sun, Mario Golf/Tennis) never takes the engine lock and is not handled.

## Why span-matched

`-d:mp2kwav` (`src/dingbat/gba/apu.nim`) gates the REAL FIFO capture on the same
predicate as the HLE render, so a run's HLE and REAL RMS cover the same audio span. Games
whose engine engages late (Mother 3 holds `SoundInfo.ident` at ID_NUMBER+10 through a
~10 s intro) otherwise pad REAL with leading silence and make the HLE read ~+23% hot when
the matched streams agree within a few percent.
