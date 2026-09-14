# MP2K probe song catalog

A sketch, not yet built. Each probe is a synthetic song assembled by
`songgen.py`, injected into a host game, and played by **Nintendo's own m4a
driver** under emulation. The driver's mixdown buffer (`pcmBuffer`, the RAM
area the DirectSound DMA reads from — [2] Appendix A, "Variables 1") is the
ground truth we compare our HLE against.

Each probe isolates exactly one driver behaviour, so a mismatch names its own
cause. They are ordered so that later probes may assume the earlier ones have
already pinned their quantity — P1 in particular calibrates the output scale
that every other probe's numbers are expressed in.

**Sources** — as in `songgen.py`: [1] loveemu's MP2K summary, [2] Bregalad &
ipatix's *GBA "Sappy" sound engine information*, [3] GBATEK. Nothing here is
derived from emulator source or from a decompilation.

## Method common to all probes

- **Host**: a real cartridge image whose m4a entry points are known (saptapper
  locates `m4aSongNumStart` etc., per [1]). The blob goes in free ROM space at
  a 4-byte-aligned address; `build(song, base_addr)` resolves every pointer to
  that address.
- **Capture**: dump the driver's mix buffer every frame, *before* the driver
  overwrites it, plus the frame counter. One frame of buffer at the default
  13379 Hz is ~224 samples; the exact length is a per-game constant ([2]
  Appendix A discusses buffer sizing).
- **Engine mode**: read the host's sound-driver operation-mode word first
  ([2] Appendix A / [3]) and record rate, channel count, DAC bits, master
  volume and reverb. Every measurement below is conditional on it. Where a
  probe needs a non-default mode, patch that word rather than changing the
  song.
- **Silence baseline**: every probe starts with a song that plays nothing, to
  capture the idle buffer contents (reverb tail, DC offset) as a reference.
- **Determinism**: `wave_noise()` is a seeded xorshift, and no probe uses the
  0x00–0x7F running status, so a probe's byte-code has exactly one reading.

---

## P1 — DC-sample volume staircase

**Pins**: the exact mixer output scale — how velocity, `VOL`, the voicegroup
sustain level and the global master volume combine into a buffer sample.

- **Wave**: `wave_dc(64, 64)`, looped at 0, so the source contributes a
  constant. ADSR "raw" (`0xFF, 0x00, 0xFF, 0x00`, [2] 2.2) so no envelope
  moves during the note.
- **Vary**: `VOL` over 0, 1, 2, 4, 8, …, 96, 112, 127 — one long tied note per
  step, `VOL` changed between steps while the note sustains, so only one
  variable moves. Then a second pass varying note **velocity** 1…127 with
  `VOL` pinned at 127, and a third varying the DC sample's own amplitude
  (−128, −64, −1, 0, 1, 64, 127).
- **Measure**: the steady-state buffer level for each step. Fit level against
  (velocity, VOL, sample). Expect a product of right-shifted multiplies, so
  look specifically for **where the truncation happens** — the difference
  between `(a*b)>>N` and rounding shows up as a ±1 staircase at low volumes.
- **Watch for**: the buffer is 8-bit-ish and [2] warns the driver does **not**
  saturate ("values will overflow and warp arround"). The −128 and amplitude
  127 × VOL 127 cases are the wrap test; a wrapping HLE and a clamping HLE
  differ dramatically here.

## P2 — Single impulse, one-shot

**Pins**: note-on timing relative to V-blank, and the resampling kernel.

- **Wave**: `wave_impulse(64, pos=0, amp=127)`, **unlooped**, so exactly one
  non-zero source sample exists.
- **Vary**: (a) the tick on which the note starts, sweeping the note across a
  whole frame at tempo 150 (`TEMPO` stores 75, which [2] says is exactly one
  tick per frame); (b) the voice type — plain `0x00` (resampled) against
  `TYPE_FIXED` (`0x08`, "never resampled, always playing at the engine's
  rate", [2] 2.1), which removes the resampler from the picture entirely.
- **Measure**: the buffer index of the first non-zero sample, and the shape
  around it. [1] says "Resampling with linear interpolation", so a single
  source sample should appear as a **triangle** spread over ⌈rate ratio⌉
  output samples, not a single spike. The triangle's width and asymmetry give
  the kernel; its position gives the note-on latency in samples.
- **Why it matters**: this is the cheapest possible test of the two things an
  HLE gets wrong most often — sub-sample phase accumulator initialisation, and
  whether note-on is applied at the top of `m4aSoundMain` or at the V-blank.

## P3 — ADSR shapes

**Pins**: the envelope generator's update rate, curve and per-stage arithmetic.

- **Wave**: the P1 DC sample, so the buffer level *is* the envelope value.
- **Vary**: one stage at a time against [2] 2.2's semantics — attack
  `0x01, 0x04, 0x10, 0x40, 0xFF`; decay `0x00, 0x40, 0xC0, 0xFF`; sustain
  `0x00, 0x40, 0x80, 0xFF`; release `0x00, 0x40, 0xFF`. Note lengths long
  enough for each stage to settle, then a gap long enough for release to reach
  silence.
- **Measure**: the level per frame. Extract (i) whether the envelope steps once
  per frame or once per mix block; (ii) whether attack is additive and
  decay/release multiplicative; (iii) the exact value at which decay stops and
  sustain begins; (iv) whether release resumes from the current level or from
  sustain.
- **Also settles ambiguity A5**: include notes whose length is *not* in the
  48-entry table (e.g. 25, 26, 99 ticks), which `songgen` emits as a table
  entry plus a gate argument. If the driver **adds** the gate ([2]) the note
  ends at the requested tick; if it replaces the length, it ends early.

## P4 — Pitch and the `freq` field

**Pins**: `pitch = 1024 × mid-C sample rate` ([2] §6), the key→ratio table, and
the tuning commands.

- **Wave**: `wave_sine(cycle_len=32, cycles=8)` looped on a whole number of
  cycles, so pitch is readable as a zero-crossing period.
- **Vary**: key across 0, 12, 24, …, 108, 127 at a fixed `freq`; then `freq`
  itself over the twelve engine rates ([2]'s table, which `songgen`'s
  `pitch_from_rate` reproduces exactly) at fixed key 60; then `KEYSH`,
  `BENDR`+`BEND` (0, 0x20, 0x40, 0x60, 0x7F), and `TUNE`.
- **Measure**: output period in samples. Expect an exact power-of-two doubling
  per octave, which tests whether the driver's key→ratio table is 12-TET or a
  rounded fixed-point table (the rounding error is the interesting part).
- **Also settles ambiguity A9**: [1] says `TUNE` spans ±1 semitone, [2] says
  ±2. Sweep `TUNE` 0 → 127 and read the ratio at the endpoints.

## P5 — Pan law sweep

**Pins**: how `PAN` maps to the two halves of a stereo mix buffer.

- **Wave**: the P1 DC sample, so each channel's level is the pan gain directly.
- **Vary**: `PAN` 0, 1, 32, 63, 64, 65, 96, 126, 127 ([1]/[2]: 0 left, 64
  centre, 127 right), each held for several frames on a sustained tied note.
  Second pass: the **voicegroup** pan byte with bit 7 set, which [2] 2.2 says
  forces the pan for that key — cross that against a track `PAN` to find which
  wins.
- **Measure**: left and right steady-state levels. Specifically whether centre
  is unity on both sides or −3 dB, whether the law is linear in the byte, and
  whether hard left leaves any bleed in the right half.
- **Note**: [2] documents a mono mixer variant with a single buffer. Record
  which variant the host uses before reading anything into a P5 result.

## P6 — Reverb impulse response

**Pins**: the "simple reverb (echo) effect with fixed delay" ([1]) — which [2]
describes as `NewSample = Feedback × OldSample` over the mix buffer itself, so
the **delay equals the buffer length**.

- **Song**: `Song(reverb=N)` sets the header byte to `0x80 | N` ([2] 7b: bit 7
  set = apply, low 7 bits = amount). One impulse note, then many frames of
  silence.
- **Vary**: N over 0, 16, 32, 64, 96, 127; plus a control song with
  `reverb=None` (bit 7 clear) to confirm the global value is left alone.
- **Measure**: the decaying echo train — inter-echo spacing (should equal the
  mix buffer length in samples, *not* a time constant), and the ratio between
  successive echoes as a function of N. Since reverb is global to all
  DirectSound channels ([2]), also check it applies to a note started *before*
  the reverb song did.
- **Settles ambiguity A8**: does `reverb=0` with bit 7 set actually clear a
  previously-set global feedback, or is 0 treated as "use the default"? [2]
  notes elsewhere that a 0 field in the mode word means "use the default",
  which makes this worth checking rather than assuming.

## P7 — Loop-point correctness

**Pins**: wrap arithmetic at the loop point, and ambiguity A1 (the `size` /
`loopStart` minus-one question).

- **Waves**: a 64-sample ramp (`wave_saw`) so every sample is individually
  identifiable in the output, with `loop_start` at 0, 1, 32, 63; plus
  degenerate cases — a 2-sample loop, a 1-sample loop, and `loop_start ==
  size - 1`.
- **Vary**: the same songs built with and without `songgen --bias`, i.e. the
  plain reading against Bregalad's "minus one" reading of both fields.
- **Measure**: the exact sample sequence across the wrap. Exactly one of the
  two readings produces a clean ramp with no repeated or skipped sample; that
  one is correct, and A1 closes. Also check whether the interpolator reads the
  guard sample past `size` (which `songgen` always appends) or wraps to
  `loopStart` — visible as a one-sample glitch at the seam.
- **Also**: an **unlooped** wave played past its end — does the channel go
  silent, hold the last sample, or run off into whatever follows in ROM?

## P8 — Compressed (BDPCM) sample vs its PCM twin

**Pins**: ambiguity A2 — the entire compressed codec, which no public doc
covers ([1] only says the Pokémon series "uses compressed samples").

- **Host**: must be a game with the extended driver; the stock driver rejects
  these type bits ([2] 2.1: "anything else = invalid").
- **Songs**: the *same* source samples twice — once as
  `Wave(..., compressed=True)` with `TYPE_COMPRESSED`, once as plain PCM — and
  played at the same key, velocity, `VOL` and pan.
- **Vary**: sources that stress each part of the codec — DC (must be exact),
  a unit ramp (exact), a sine (a few LSB), white noise (exceeds the ±64 slew
  limit by design), a sample whose length is *not* a multiple of 64, and one
  whose `loopStart` is a multiple of 64 against one that is not.
- **Measure**: sample-by-sample difference between the two mixdowns. It should
  equal the difference `songgen`'s own `bdpcm_decode(bdpcm_encode(x))` predicts
  — that is the whole point. Three specific things fall out: whether the first
  high nibble really is skipped, whether the accumulator wraps at 8 bits or
  saturates, and whether the delta table is the n² / −(16−n)² table we assume.
- **A4 falls out too**: whether a non-block-aligned loop is even legal.

## P9 — Reversed and fixed-rate type bits

**Pins**: ambiguity A3 — `TYPE_REVERSED` (0x10) and `TYPE_FIXED` (0x08).

- **Wave**: an asymmetric, position-identifiable ramp, so direction is obvious.
- **Vary**: type byte `0x00`, `0x08`, `0x10`, `0x18`, each at several keys.
- **Measure**: for `0x08`, that key has **no** effect on output rate ([2] 2.1:
  "always playing at the engine's rate") — this is also the clean control for
  P2's kernel measurement. For `0x10`, whether playback starts at `size-1` and
  walks down, where a reversed loop restarts, and what `loopStart` means in
  reverse. For `0x18`, whether the two bits compose.
- **Expect a crash** on a stock-driver host; that itself confirms [2]'s
  "anything else = invalid" and tells us which hosts can run P8/P9 at all.

## P10 — Many simultaneous voices

**Pins**: the channel cap, the priority/stealing rule, and per-channel mixing.

- **Song**: up to 16 tracks (more than the 12-channel maximum in [2] Appendix
  A), each a DC sample at a distinct level so the mix is decomposable by
  inspection.
- **Vary**: the number of simultaneous notes 1 → 16; the track order; `PRIO`
  per track; and the header priority byte. Include the case where notes start
  on the *same* tick and where they stagger by one tick.
- **Measure**: which notes survive. [2] states the rule to check: on
  DirectSound channels, when no free channel remains the higher-priority notes
  continue and lower-priority ones are "ignored or silenced out" — and **on a
  priority tie the lower track number wins**. Both halves of that are testable,
  and "ignored" vs "silenced out" is a real behavioural difference (does a
  stolen channel cut immediately or release?).
- **Also**: sum the individual single-note mixdowns and compare against the
  multi-note one. Any difference is the driver's per-channel accumulate/shift
  order — the second most common HLE error after P1's scale.

---

## Suggested build order

P1 → P2 → P7 → P3 → P4 → P5 → P10 → P6 → P8 → P9.

P1 and P2 are cheap and calibrate everything downstream. P7 is next because
ambiguity A1 affects every probe that uses a looped wave. P8 and P9 come last
because they need a host with the extended driver.
