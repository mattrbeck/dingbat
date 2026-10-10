## The sound output the GB and GBA APUs and a DS game queue their samples
## to: one stereo playback queue, which each core opens for itself when it
## is built (replacing the one before it). Audio-sync pacing reads how much
## is still queued, so the queue's depth is the clock emulation runs by.
##
## Desktop: an SDL 3 audio stream bound to the default playback device.
## The stream converts to whatever the device wants, so what is queued is
## always played at the rate and format it was opened with (SDL 2 needed
## `obtained = nil` for that; Windows WASAPI otherwise handed back its own
## float32 44.1/48 kHz and pacing ran at ~2x).
##
## iOS: src/dingbat_ios_audio.c, a ring buffer the shell's
## AVAudioSourceNode drains, behind the same calls. The test harness takes
## that branch too: the APUs and the desktop's DS game leave audio out
## there, so only the iOS C API reaches this module (tests/ios_api_test,
## whose DS sound goes to the ring), and src/dingbat_ios.nim compiles the
## ring in.
##
## Not compiled for the web (Web Audio, fed from the cores' own buffers).

type SampleFormat* = enum
  sfS16  ## interleaved int16 stereo (the GBA APU)
  sfF32  ## interleaved float32 stereo (the GB APU, the DS)

when defined(ios) or defined(test_harness):
  proc ios_audio_open(format, freq, play: cint)
    {.importc: "dingbat_audio_open", cdecl.}
  proc ios_audio_put(data: pointer; len: uint32)
    {.importc: "dingbat_audio_put", cdecl.}
  proc ios_audio_queued(): uint32 {.importc: "dingbat_audio_queued", cdecl.}
  proc ios_audio_clear() {.importc: "dingbat_audio_clear", cdecl.}
  proc ios_audio_wait(ms: uint32) {.importc: "dingbat_audio_wait", cdecl.}

  proc audio_open*(format: SampleFormat; freq: int; play = true): bool =
    ios_audio_open(cint(ord(format)), cint(freq), cint(ord(play)))
    true
  proc audio_put*(data: pointer; len: int) = ios_audio_put(data, uint32(len))
  proc audio_queued*(): uint32 = ios_audio_queued()
  proc audio_clear*() = ios_audio_clear()
  proc audio_wait*(ms: uint32) =
    ## Sleep while the queue drains. Breaks a stall (the audio engine
    ## stopped mid-frame) by dropping the queue after ~250 ms.
    ios_audio_wait(ms)

else:
  import sdl3

  var stream: AudioStream = nil

  proc audio_open*(format: SampleFormat; freq: int; play = true): bool =
    ## Replace the queue with a fresh one for this core; false (and no
    ## sound) if the device would not open.
    if stream != nil:
      destroyAudioStream(stream)
      stream = nil
    # The device takes this many frames from the stream at a time (3.9 ms
    # at 32768 Hz), so the queue the pacing reads drains in fine steps. Its
    # default (a 10-20 ms period) holds the next frame back a whole period.
    discard setHint(HINT_AUDIO_DEVICE_SAMPLE_FRAMES, "128")
    let spec = AudioSpec(format: (if format == sfS16: AUDIO_S16 else: AUDIO_F32),
                         channels: 2, freq: cint(freq))
    stream = openAudioDeviceStream(AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, nil, nil)
    if stream == nil: return false
    # A device stream opens paused
    if play: discard resumeAudioStreamDevice(stream)
    true

  proc audio_put*(data: pointer; len: int) =
    if stream != nil: discard putAudioStreamData(stream, data, cint(len))

  proc audio_queued*(): uint32 =
    ## Bytes queued and not yet taken by the device
    if stream == nil: 0'u32 else: uint32(max(0, getAudioStreamQueued(stream)))

  proc audio_clear*() =
    if stream != nil: discard clearAudioStream(stream)

  proc audio_wait*(ms: uint32) = delay(ms)
