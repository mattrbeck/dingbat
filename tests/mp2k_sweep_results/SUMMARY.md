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

## 2026-09-14 (night): performance pass

The hook trigger moved from a per-instruction compare to the pipeline flush
for hooks learned at a branch target. The mixer renders a voice at a time,
and the unstretched sinc reads precomputed per-phase rows. Run 31 matches
run 28 on every summary figure: 1013 engaged, 780 music titles, 779 within
±20 %, median xcorr0 0.844, 708 above 0.5. All 780 music titles move by less
than 0.01. A flush-only probe (run 30) is the trap here. It moved 29 titles by more
than 0.01. Their vintages are entered through a stub before r0 holds
&SoundInfo, so the probe had learned
their hook a few instructions into the function, where no branch lands. The
flush-only probe learned a later helper instead, and Hudson Best Collection
fell from 0.95 to 0.17. Those hooks now keep the per-instruction compare.

## 2026-09-14 (late night): passes from the driver's writes

The HLE no longer learns a code address. A mixer pass is the driver's lock
write followed by its first store into a ring the sound DMA plays, taken
before that store lands (`mp2k.nim` "Runtime detection";
`tools/mp2kprobe/README.md` "Pass detection" has the archive census that
establishes the ordering). A driver must make two such passes in a row
before it engages, because initialisation takes the lock and clears the
buffer once without mixing (Golden Sun, Mother 3).

Changing the vantage exposed three level-control problems that the old
hook's timing had been hiding. Each was fixed and swept:

* **The 6-sample band parked titles.** Where a title settled inside the band
  depended only on the frame it engaged: Advance GTA +3, Emerald -2 on the
  same build. The trim now converges from any error for 128 frames after
  priming, or after the target moves by two samples or more, and the band
  outside that window is 1.5 samples. Sweeping 6, 3 and 1.5 changed only
  Steel Empire's two releases.
* **The pipeline constant** had been fitted while titles were parked. It is
  now 3.5 DMA-rate samples below 35 kHz, down from 4. The 3/3.5/4 sweep
  favoured 3.5 at every rate from 5.7 to 21 kHz, and the eleven 26.8 kHz
  titles prefer 4 by 0.01.
* **A skipped V-blank pass.** Santa Claus Saves the Earth's song start has a
  V-blank in which no SoundMain runs. Filling the FIFO back to its target
  then overshot by the next pass's lateness, and left it 36 samples late
  for two seconds. A level jump of half a frame or more under a steady
  target is now corrected in whole frames. A smaller jump, or a moved
  target, is still stepped exactly.

| Run | Engaged | Music | Within ±20 % | Median xcorr0 | xcorr0 > 0.5 |
|---|---|---|---|---|---|
| 31 (PC hook, committed) | 1013 | 780 | 779 | 0.844 | 708 |
| 43 (write trigger, all of the above) | 1013 | 780 | 779 | 0.924 | 750 |

Run 43 improves 420 titles and worsens 12. The larger regressions checked by
windowed lag:

* **Grandbo** has one glitched second (0.89); every other second matches at
  0.97–0.99.
* **Tarzan: Return to the Jungle** is off only in its first two seconds,
  where engaging seven frames earlier settles a 31-sample start. It then
  runs at 0.99, 0–1 samples from the stream where it was 2–3.
* **Steel Empire** is 2 samples late: 0.96 aligned, 0.64 at lag 0 on bright
  content.
* **Top Gear All Japan GT** and **Lilo & Stitch 2** were already below 0.3.

## 2026-09-14 (later): every pass rendered, latency restart on DMA re-timing, a CI test

**Every pass is rendered.** The old one-pass-per-frame rule was a guard the PC hook needed against helpers inside the mixer. Counting extra passes over the regression list found 170 in 875,126, so they are rare, and they come in two kinds:
* 139 find pcmDmaCounter unmoved, so they write the same ring slot again and the hardware plays the later mix. That pass's frame now replaces the unplayed part of the previous frame. GT Championship does this every twenty frames or so.
* 31 come after the counter moved, and they append a frame.

Run 50 replaced 448 passes in 39 ROMs. An ablation against skipping and appending measured it neutral on the titles that moved.

**The latency measurements restart when the game re-times its DMA.** The trigger is a jump of more than 96 samples in the phase estimate. Before, the average walked down from the old timing over about forty passes, and Tarzan: Return to the Jungle started 35 samples late for two seconds. Two variants were tried and dropped, using the 168 titles that moved between runs 43 and 47:

| Variant | Mean xcorr0 change | Better | Worse |
|---|---|---|---|
| Restart | +0.086 | 91 | 17 |
| Keep the old latency until four new crossings | +0.065 | 86 | 33 |
| Restart plus the level following target moves of 8 or more | +0.043 | 100 | 68 |

| Run | Engaged | Median xcorr0 | xcorr0 > 0.5 |
|---|---|---|---|
| 43 | 1013 | 0.924 | 750 |
| 50 | 1013 | 0.933 | 765 |

Run 50 against run 43: 93 titles better, 18 worse. The largest regressions checked by windowed lag:
* **Atlantis and Yu Yu Hakusho Tournament Tactics** have one audible second in the capture. It is unchanged on Atlantis and better on Yu Yu Hakusho (0.93 against 0.86).
* **Zettai Zetsumei Den Chara Suji-san** is a real timing regression. Its later seconds run 17–18 samples early after a re-timing sends the target back to the phase estimate.

`tests/mp2k_pass_test.nim` (`nimble test_mp2kpass`, in CI) drives the trigger and the level control with synthetic stores, no ROMs:
* lock and ring;
* a song-change lock, and ring stores with no lock;
* a mono driver's scratch half, and a DMA playing from outside pcmBuffer;
* a state load inside a pass;
* same-slot and new-slot passes;
* a skipped V-blank, a smaller level jump, and DMA re-timing.

Breaking the replacement or the two-pass engage rule fails seven of its 23 checks.

## 2026-09-15: slot timing heard at the FIFO, the timer's rate, and a one-sample capture bias

**The captures were a sample apart.** `post_init` emits one sample with the HLE still off, and the real-stream capture kept it, so every sweep until now compared the HLE against a reference shifted by one output sample: a time-aligned HLE read as lag −1, and lag-0 correlation rewarded being a sample late. The sweep and probe harnesses now clear both captures after arming the HLE (the HLE output is byte-identical; the reference loses its first sample). The runs below re-sweep the shipped build (15d418042, run 27f) and main before this change (dbc536e23, run 50f) with that fix and nothing else. Figures earlier in this file carry the bias, including the pipeline constant's fit.

**Frames go where their slot is heard.** Every byte a special-timing sound DMA moves into a FIFO is tagged with the address it came from, and the pass's first ring store (the slot start on every pass of the 38 titles checked) is watched: the output clock at which that byte leaves the FIFO, plus the cubic reconstruction's two DMA periods less half a stamp sample (fitted within ±0.3 samples on 22 titles from 5.7 to 21 kHz), is when the hardware plays the slot. Later passes are placed a whole number of frames after the last slot heard, so the pass's own lateness drops out. Errors over 8 samples are stepped at once (a DMA restart, a song start, a V-blank without a pass); a larger-than-half-frame error needs two passes in agreement. The phase estimate and measured-latency average only seed the first frames now. Before, Justice League's DMA re-timing at its song start (+47 samples) was followed by the 1/8 latency average and a one-sample-a-frame slide, and sat 45 → 6 samples early for a second; Summon Night, Momotarou, Kaeru, Pinobee and Scan Hunter had the same shape.

**The timer's rate.** The driver's timer reload is a whole number of cycles that makes a slot exactly one frame (18157 Hz: 924 cycles a byte, 304 bytes = 280896 cycles), so the hardware plays a few parts in 10^5 sharper than pcmFreq. Frames and voice steps now use that rate; at pcmFreq every frame was 0.01 samples long and the trim worked every 100–300 frames.

**Trims are averaged.** A stamp is a whole output sample, so a single reading carries half a sample of noise; trimming each one dropped or duplicated a sample every other frame (Don-chan Puzzle: 332 drops, 337 duplicates in 900 frames) for no net movement. The error is averaged (1/8 a pass) and trimmed at 0.6; frames move in whole samples, so thresholds of 0.5 and below dithered again.

| Build | Median xcorr0 | xcorr0 > 0.5 | Against 27f: better / worse (> 0.02) |
|---|---|---|---|
| 27f: shipped, 15d418042 | 0.838 | 699 | |
| 50f: dbc536e23 | 0.895 | 762 | 493 / 143 |
| 61: this change | 0.960 | 777 | 609 / 5 |

Engaged 1013 and 780 music titles in all three; 779 within ±20 % loudness, 779 with envelope correlation ≥ 0.9 (777 in 27f). At 0.01, 669 better and 8 worse.

The five (kept open in `tools/mp2kprobe/README.md` "Known limitations"; reproduce with `tools/mp2ksweep`, whose `build_at.sh` re-sweeps any commit with the capture fix, and `experiments/rate-lock.patch`):
* **Disney Sports American Football (0.982 → 0.915) and Skateboarding (0.951 → 0.890).** Placement holds to a sample, but the waveform walks 3 samples early in 12 s: the voice's cursor gains on the engine's (American Football's 21024 Hz voice advances 352 source samples a pass at 18157 Hz; the HLE's 352.0017). Following the engine's position rate fixed both (0.974, and Don-chan 0.991) but moved Bass Tsuri Shiyouze and J.League Winning Eleven 2002 the other way, whose count fields advance slower than the waveform they play, and pulling the cursor onto the engine's position moved Steel Empire a sample off (0.984 → 0.618). Dropped: the count field is not the playback cursor on every vintage.
* **Disney Princesse / Prinzessinnen (0.838 → 0.799).** A steady 1–2 samples early with placement holding.
* **Inuyasha Naraku no Wana (0.348 → 0.291).** A 26.8 kHz title that matches poorly in every build; its lag moves 4–6 samples from second to second.

Tried and dropped: no 1-sample trims at all (139 titles worse: the frame-length error accumulates), and trim deadbands of 2 and 3 (abandoned once averaging removed the dither).

`tests/mp2k_pass_test.nim` gains the slot timing: a 40-sample error stepped, a small one averaged then trimmed, a half-frame error needing two passes, a slot heard across a pause in the output clock ignored, and a state load forgetting the watches (30 checks).

## Why span-matched

`-d:mp2kwav` (`src/dingbat/gba/apu.nim`) gates the REAL FIFO capture on the same
predicate as the HLE render, so a run's HLE and REAL RMS cover the same audio span. Games
whose engine engages late (Mother 3 holds `SoundInfo.ident` at ID_NUMBER+10 through a
~10 s intro) otherwise pad REAL with leading silence and make the HLE read ~+23% hot when
the matched streams agree within a few percent.
