# Cubic interpolation resampler for audio.
# Adapted from reference/gba/src/gba/apu/resampler.nim

type
  Resampler*[T] = object
    data: array[4, T]
    ratio: float32
    mu: float32
    output*: seq[T]

proc new_resampler*[T](): Resampler[T] =
  result.mu = 0
  result.ratio = 1

proc set_freqs*[T](resampler: var Resampler[T]; input_freq, output_freq: int) =
  resampler.ratio = float32(input_freq / output_freq)

proc reset*[T](resampler: var Resampler[T]; input_freq, output_freq: int) =
  resampler.set_freqs(input_freq, output_freq)
  resampler.mu = 0
  resampler.data = default(array[4, T])
  resampler.output.setLen(0)

proc write*[T](resampler: var Resampler[T]; sample: T) =
  resampler.data[0] = resampler.data[1]
  resampler.data[1] = resampler.data[2]
  resampler.data[2] = resampler.data[3]
  resampler.data[3] = sample
  while resampler.mu <= 1:
    let
      a = resampler.data[3] - resampler.data[2] - resampler.data[0] + resampler.data[1]
      b = resampler.data[0] - resampler.data[1] - a
      c = resampler.data[2] - resampler.data[0]
      d = resampler.data[1]
    resampler.output.add(a * resampler.mu * resampler.mu * resampler.mu +
                         b * resampler.mu * resampler.mu +
                         c * resampler.mu + d)
    resampler.mu += resampler.ratio
  resampler.mu -= 1
