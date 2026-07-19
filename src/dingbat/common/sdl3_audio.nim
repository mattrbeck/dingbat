# Minimal SDL3 audio bindings shared by the GBA and GB APUs (SDL3 is linked
# via nim.cfg; no Nim SDL package needed for audio).
#
# SDL3 replaced SDL2's per-device queue API (SDL_QueueAudio /
# SDL_GetQueuedAudioSize / SDL_ClearQueuedAudio) with audio STREAMS. An
# SDL_AudioStream opened with SDL_OpenAudioDeviceStream against the default
# playback device behaves like the old queue: put = queue bytes,
# SDL_GetAudioStreamQueued = bytes not yet consumed by the device — which is
# exactly what the APUs' audio-sync pacing reads. Two SDL2 quirks disappear:
# device-streams convert to the device's native format themselves (the old
# "obtained must be nil" WASAPI footgun is gone), and there is no legacy
# single-device API, so the GBA and GB APUs no longer need name-mangled
# duplicate bindings (sdl_open_audio vs sdl_open_audio_gb) to coexist.
#
# One global playback stream at a time: opening a new one (ROM switch, or
# switching cores) destroys the previous, mirroring how the SDL2 code called
# SDL_CloseAudio before every open.

type
  AudioStream* = pointer ## ptr SDL_AudioStream (nil = not open)
  SdlAudioSpec {.pure.} = object
    format:   cint
    channels: cint
    freq:     cint

const SDL_AUDIO_S16LE* = cint(0x8010)
const SDL_AUDIO_F32LE* = cint(0x8120)
const SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF'u32

proc sdl_open_audio_device_stream(devid: uint32; spec: ptr SdlAudioSpec;
    callback: pointer; userdata: pointer): AudioStream
  {.importc: "SDL_OpenAudioDeviceStream", cdecl.}
proc sdl_destroy_audio_stream(stream: AudioStream)
  {.importc: "SDL_DestroyAudioStream", cdecl.}
proc sdl_resume_audio_stream_device(stream: AudioStream): bool
  {.importc: "SDL_ResumeAudioStreamDevice", cdecl, discardable.}
proc sdl_put_audio_stream_data(stream: AudioStream; data: pointer;
    len: cint): bool
  {.importc: "SDL_PutAudioStreamData", cdecl, discardable.}
proc sdl_get_audio_stream_queued(stream: AudioStream): cint
  {.importc: "SDL_GetAudioStreamQueued", cdecl.}
proc sdl_clear_audio_stream(stream: AudioStream): bool
  {.importc: "SDL_ClearAudioStream", cdecl, discardable.}

proc sdl_delay*(ms: uint32) {.importc: "SDL_Delay", cdecl.}

var active_stream: AudioStream = nil

proc audio_open*(format: cint; channels, freq: int): AudioStream =
  ## Open (and start) a playback stream on the default device, replacing any
  ## stream a previous core opened. Returns nil on failure.
  if active_stream != nil:
    sdl_destroy_audio_stream(active_stream)
    active_stream = nil
  var spec = SdlAudioSpec(format: format, channels: cint(channels),
                          freq: cint(freq))
  result = sdl_open_audio_device_stream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
                                        addr spec, nil, nil)
  if result != nil:
    # Device-streams start paused; the SDL2 code's unpause-on-open equivalent.
    sdl_resume_audio_stream_device(result)
    active_stream = result

proc audio_put*(stream: AudioStream; data: pointer; len: uint32) =
  sdl_put_audio_stream_data(stream, data, cint(len))

proc audio_queued*(stream: AudioStream): uint32 =
  ## Bytes put but not yet consumed by the device (SDL2 GetQueuedAudioSize).
  uint32(max(0, sdl_get_audio_stream_queued(stream)))

proc audio_clear*(stream: AudioStream) =
  sdl_clear_audio_stream(stream)
