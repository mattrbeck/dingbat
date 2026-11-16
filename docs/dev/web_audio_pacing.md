# Web audio pacing: the scheduling-lead servo

`pushAudio()` in `web/index.js`. Reference for why the cursor is managed the
way it is, and how to measure it.

## The mechanism

`playTime` is the cursor at which the next chunk of audio starts; each buffer
is scheduled slightly ahead of `audioCtx.currentTime`. That gap is the
**cushion** that absorbs a late rAF tick. Two faults produce clicks:

1. **A spent cushion.** A main-thread hitch makes one tick long; the emulator
   runs at most `maxFrames` and drops the rest of the debt. If the cursor is
   only ever clamped upward (`playTime = max(playTime, now)`) the cushion can
   be spent but never rebuilt, and once it reaches zero every subsequent
   hitch starts a buffer late.
2. **Upward drift.** Audio is produced ~1.1 ms/s faster than the context
   consumes it, so an unmanaged cursor climbs until `MAX_AUDIO_LEAD` (250 ms)
   forces a whole frame of audio to be dropped, every 3–4 minutes.

## What ships

* **Floor after a spend:** `if (playTime < now + AUDIO_LEAD_FLOOR) playTime =
  now + AUDIO_LEAD_FLOOR` (8 ms). It costs that much latency only right after
  a spend.
* **Micro playback-rate servo:** each `AudioBufferSourceNode` gets
  `playbackRate = 1 + clamp(0.15 · (lead − AUDIO_TARGET_LEAD), ±0.4 %)` and the
  cursor advances by `duration / rate`, so consecutive buffers stay gapless.
  Above target the audio plays marginally fast (drains the drift); below
  target it stretches to rebuild the cushion. No samples are skipped; ±0.4 %
  is ±7 cents, steady-state ~0.1 %. `MAX_AUDIO_LEAD` remains as a backstop.
* **Debt is clamped, not zeroed:** `accumulator = min(accumulator, 2·step)`.
  Zeroing deleted the audio for the skipped frames (the click at every big
  hitch); a clamped debt is produced over the next ticks.

A bare 12 ms floor without the servo was measured to add ~18 ms of median
lead, not 12: pushing the cursor forward compounds with the drift, so the
whole distribution shifts. The servo is what contains that.

## Measuring

Instrument `AudioBufferSourceNode.start` and read `when − context.currentTime`
per buffer; count zero-lead buffers and the lead distribution. **Measure on
WebKit, not Chrome**: in 90 s of Pokémon Crystal the unmanaged cursor showed
26 zero-lead buffers (minimum −0.2 ms) on WebKit against 2 in 191 s on
Chrome, whose median cushion is about twice WebKit's. A synthetic 45 ms
main-thread block every 2 s is the Chrome reproducer.

## Unvalidated

All measurements are a Mac. iOS has a different audio stack, stricter
interruption handling and different buffer sizes; the WebKit numbers are a
floor. Input latency is ~11 ms end to end, so any change
that adds audio lead should be judged by ear against that.
