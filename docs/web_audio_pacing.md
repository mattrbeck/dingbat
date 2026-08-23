# Web audio dropouts: the scheduler's cushion is spent but never rebuilt

**Status: diagnosed and measured, fix deliberately deferred.** Nothing in this
document is implemented. It exists so the next person does not have to re-derive
the measurements, and so the obvious one-line fix is not applied without knowing
what it costs.

## The bug

`pushAudio()` in `web/index.js` keeps a `playTime` cursor — when the next chunk
of audio should start — and schedules each buffer slightly ahead of the audio
clock. That gap is the **cushion**, and it is what absorbs a late frame.

The cursor is only ever clamped *upward*:

```js
if (playTime < now) playTime = now;
```

So the cushion can be spent but never rebuilt. A main-thread hitch makes one
rAF tick long; the emulator loop runs at most `maxFrames` and then discards the
remaining debt (`accumulator = 0`), so the audio for those frames is **never
produced at all**. Each hitch knocks the cushion down permanently. Once it
reaches zero the next buffer starts late, and the silence is heard as a click.

Scheduling exactly at `now` is already a gap: the buffer that should have
covered that instant never existed.

## Measurements

Every scheduled buffer instrumented at `AudioBufferSourceNode.start`, reading
`when - context.currentTime`. Pokémon Crystal, real audio, headless.

**Chrome, 191 s clean:** 2 buffers at zero lead out of 11412. With a synthetic
45 ms main-thread block every 2 s: **1 gap per 12 s**. Median lead ~20 ms
(p5 9.7, p25 15.1).

**WebKit — the engine Safari uses — 90 s clean:**

| | zero-lead buffers | min lead | median | max |
|---|---|---|---|---|
| today | **26** | **−0.2 ms** | 10.9 ms | 22.5 ms |
| with a 12 ms floor | **0** | 12.0 ms | 29.4 ms | 41.9 ms |

Two things follow.

**WebKit is worse than Chrome, and needs no synthetic hitch to show it.** 26
dropouts in 90 s of ordinary play, and a *negative* minimum lead — buffers
scheduled in the past. WebKit's median cushion is about half Chrome's, so it
falls through zero far more easily. Any future audio-pacing work should be
measured on WebKit, not Chrome.

**The obvious fix costs more latency than it looks like it should.** Rebuilding
the cushion (`playTime = now + 12ms`) eliminates the gaps completely — but the
median lead goes 10.9 → 29.4 ms, about **+18 ms**, not the +12 ms the floor
nominally adds. The tempting argument — "only the bottom ~8% of buffers are
under 12 ms, so the floor only touches those" — reasons from the *before*
distribution. Pushing the cursor forward compounds with a pre-existing upward
drift, so the whole distribution shifts, not just its tail.

It is a fixed cost, not a leak: over 90 s the lead is stable (first third
27.7 ms, last third 29.7 ms).

## Why it is deferred

The trade is 26+ dropouts per 90 s against ~18 ms of added audio latency, in a
project where input latency was hard-won at ~11 ms (see `input-latency`
notes). Roughly tripling the audio cushion is not free, and nobody has judged
by ear whether the added lag is perceptible or whether the dropouts are worse.

## Better fixes, at the source

Both were identified and measured-adjacent, neither implemented. Both address
the cause rather than cushioning the symptom, and neither costs latency.

- **`accumulator = 0` at the discard is what loses the audio.** Clamping it to
  `step * 2`, or raising `maxFrames` from 2 to 3, produces the missing audio
  instead of covering for its absence. Not done because there is no measurement
  of what either does to pacing feel.
- **A smaller floor may be sufficient.** The gaps come from reaching *zero*,
  not from being under 12 ms. 6 ms was never tried.

## Separate, related, also unfixed

The lead drifts *upward* about 1.1 ms/s — audio is produced marginally faster
than the context consumes it. `playTime` therefore climbs until
`MAX_AUDIO_LEAD` (250 ms) forces a whole frame of audio to be dropped, roughly
every 3–4 minutes. That is its own click, a floor cannot fix it, and it wants a
soft resync that nudges `playTime` down once the lead passes ~60 ms.

Note this interacts with the floor: today the drift is periodically reset by
hitches punching the lead down. Remove the dropouts and nothing resets it, so
the 250 ms ceiling would be reached more predictably.

## What is still unvalidated

Everything above is a Mac. iOS has a different audio stack, stricter
interruption handling, and buffer sizes that cannot be reproduced here, and a
phone is far noisier than this machine — so the WebKit dropout rate is a
**floor, not an estimate**. A real-device pass is required before any of this
ships.
