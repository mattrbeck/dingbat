## The web build's audio sink. The GB and GBA APUs append here; the page
## reads and clears the buffer after each frame (dingbat_wasm.nim's
## getAudioBufferPtr / getAudioBufferLen / clearAudioBuffer).

# float32 stereo samples for Web Audio.
var audioBuffer*: seq[float32] = @[]

# True while a muted core's etAPUSample is dispatched. The sample is still
# computed and rescheduled; only the append is dropped, so linked cores stay
# bit-identical.
var audioSuppressed* = false

# Slow motion: JS doubles the wall-clock step, so the core makes half the
# samples the AudioContext consumes; emitting each twice restores the rate an
# octave down.
var slowmoStretch* = false

proc appendAudioSample*(left, right: float32) =
  if audioSuppressed: return
  audioBuffer.add(left)
  audioBuffer.add(right)
  if slowmoStretch:
    audioBuffer.add(left)
    audioBuffer.add(right)
