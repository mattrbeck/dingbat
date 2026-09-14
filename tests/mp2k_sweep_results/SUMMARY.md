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

## 2026-09-14 (evening): the listening set, the level dead band, the quality tier

Matt asked for A/B WAVs (hardware mix and HLE alternating every 6 s in one file) and why the
HLE now sounds "correct" rather than markedly better than the game. Building the WAVs from
final-output dumps of the same deterministic run (`tools/mp2kprobe/abmix.py`) exposed two things
the sweep's metrics had averaged over.

**The HLE sat 11–28 samples off on every title, with the latency model exact.** The frame FIFO's
level control trimmed one output sample per frame only once the averaged level error exceeded
24 samples and stopped the moment it fell back to 24, so every title parked near the band's edge
on whichever side it approached from (Emerald 11 early, Minish Cap 20, Metal Max 28, Castlevania
24 late; lag-0 waveform correlation 0.0–0.5 with 0.98 one shift away). The band is now 6 with a
run-to-zero hysteresis. Two more things surfaced once the level held its target: the vintages
that reprogram the sound DMA every V-blank (Estopolis, Metal Max, Beast Shooter, Super
Dodgeball) never measured a latency at all — their cursor sits *at* the slot start at the hook,
which the crossing test computed as a negative latency and dropped; the transfer carrying that
slot is the next one, not the last. And the "pipeline" constant had been fitted against the
parked level: in hold-mode replay ten titles at four rates land within ±2 output samples with a
pipeline of 2 DMA-rate samples; against the cubic FIFO reconstruction the emulator plays (and the
sweep scores), 4 is best at every engine rate from 5.7 to 27 kHz (2 above 35 kHz), and neither a
different source-sample constant nor an output-sample constant beats it (runs 20–24).

Sweep, round 4 → now: lag-0 waveform correlation above 0.5 on 422 → 711 of 780 music titles,
median 0.55 → 0.85, lower quartile 0.23 → 0.70, upper 0.80 → 0.92; envelope lag within ±64 on
767 → 778; loudness unchanged (779). Per rate: 13.4 kHz 0.59 → 0.88 (121 improved, 36 worse),
21 kHz 0.54 → 0.85 (144/23), 10.5 kHz 0.55 → 0.85, 15.8 kHz 0.51 → 0.79, 42 kHz −0.57 → 0.58.

**Why it sounded "closer to the game".** The render's output was truncated to the driver's byte
scale and then went through the 10-bit DAC stage like the hardware's own stream, its gains
stepped once per V-blank like the driver's, and its echo was held per engine-rate cell like the
DMA's replay — each faithful, each a limit of the hardware rather than of the music. A quality
tier (on by default; `DINGBAT_MP2K_QUALITY=0` for parity checks) now ramps a continuing note's
gain over the frame's first 96 output samples, interpolates the echo between cells, and carries
the sub-LSB remainder past the DAC stage (apu.nim adds it after the clamp). On the same 50 s
runs it changes the waveform by 4–7 % RMS and lowers the above-6 kHz floor of quiet passages by
1.5–3× against the parity render (Emerald 64 → 40, Minish Cap 26 → 8, Beast Shooter 50 → 24 on
the emitted scale; the hardware path reads 56, 43, 58). The sweep's fidelity metrics are
unchanged by it (run 19 = run 18 to three decimals). The hardware path's DC offset (the driver's
per-voice floor, amplified up to 3× by the reverb comb: about 40 DAC steps on Beast Shooter) is
absent from the HLE; whole-run RMS comparisons read that as the HLE being quieter (−0.6 dB
Emerald, −1.7 dB Beast Shooter), while per-second windowed loudness matches within 0.1 dB.

Matt then set the goal explicitly: the HLE should *improve* on the hardware — the artist's intent
without the hardware's limits — never merely mimic it, and never add sounds or prolong voices.
Two more limits were lifted in the tier on that basis. Gains are the un-truncated product (the
driver's twice-shifted byte steps a quiet tail by 5–10 % a frame). Voices are resampled with a
windowed sinc stretched by the playback step: Breath of Fire plays every voice above the output
rate (up to 107 kHz) and Beast Shooter a fifth of its, and Catmull-Rom decimated those without a
filter, so part of BoF's "brightness" was aliasing; band-limited at the output Nyquist its
above-8 kHz share falls from 6.0 % to 4.7 % (hardware: 0.9 %), the rest being the samples' own
content. Slow-played voices lose the interpolation images above their own band. A census of the
mono vintages (Minish Cap, Beast Shooter, Metal Max) found their song data centre-panned (right
and left volumes differ by at most 1 in 16–20 k channel-frames), so there is no stereo to restore
there. Fidelity metrics within noise of the hardware-stream comparison (run 26: 708 above 0.5, median 0.844, against run 25's 711 and 0.847 — the sinc removes images the hardware stream still has), loudness unchanged; worst-case cost 5 % (Beast Shooter).

Last, the envelope: the tier's 3 ms ramp became the continuous curve. Each frame's gain now
runs linearly from this pass's value to the next pass's, predicted by the same P3 rules applied
once more (attack into decay, decay to sustain, release toward zero with the pseudo-echo floor),
so a released note runs down to zero across the frame before the driver drops it instead of
ending on a step. The prediction bytes checked one hook later are unchanged, and so is the
sweep (run 27). The indicator in the top bar went back to a plain icon at Matt's request; it
still toggles the HLE for the loaded game when tapped.

The listening set (12 titles, hardware/HLE alternating plus both full tracks, and four
parity/quality tier files) lives outside the repo in `~/Documents/emu/gba/mp2k-ab/`.

## Why span-matched

`-d:mp2kwav` (`src/dingbat/gba/apu.nim`) gates the REAL FIFO capture on the same
predicate as the HLE render, so a run's HLE and REAL RMS cover the same audio span. Games
whose engine engages late (Mother 3 holds `SoundInfo.ident` at ID_NUMBER+10 through a
~10 s intro) otherwise pad REAL with leading silence and make the HLE read ~+23% hot when
the matched streams agree within a few percent.
