# Minimal SDL2 audio bindings, shared by both cores' APUs.
#
# SDL2 is already linked via nim.cfg, but the Nim sdl2 wrapper doesn't expose
# the queue API, so these are declared directly.
#
# This is a MODULE (imported), not an `include`: each core's includes share one
# flat namespace, so when both APUs declared their own copy the GB's had to be
# given a "_gb" suffix on every name to avoid colliding with the GBA's — and
# gb/apu.nim additionally needed a `when not declared(SDL_AudioSpec)` guard for
# builds that link both cores. Importing gives both cores the same symbols with
# neither workaround.
#
# Compiled out under test_harness: the headless harness opens no audio device
# (hence {.used.} — the import is then legitimately unused). NOT compiled out
# under emscripten: audio_ahead still references sdl_get_queued_audio_size.

{.used.}

when not defined(test_harness):
  type
    SDL_AudioDeviceID* = uint32

    SDL_AudioSpec* = object
      freq*:     cint
      format*:   uint16
      channels*: uint8
      silence*:  uint8
      samples*:  uint16
      padding*:  uint16
      size*:     uint32
      callback*: pointer
      userdata*: pointer

  const
    AUDIO_S16LSB* = 0x8010'u16  # signed 16-bit LE — the GBA APU mixes to s16
    AUDIO_F32LSB* = 0x8120'u16  # 32-bit float LE  — the GB APU mixes to f32

  proc sdl_open_audio*(desired: ptr SDL_AudioSpec;
                       obtained: ptr SDL_AudioSpec): cint
    {.importc: "SDL_OpenAudio", cdecl.}
  proc sdl_close_audio*()
    {.importc: "SDL_CloseAudio", cdecl.}
  proc sdl_pause_audio*(pause_on: cint)
    {.importc: "SDL_PauseAudio", cdecl.}
  proc sdl_queue_audio*(dev: SDL_AudioDeviceID; data: pointer; len: uint32): cint
    {.importc: "SDL_QueueAudio", cdecl.}
  proc sdl_get_queued_audio_size*(dev: SDL_AudioDeviceID): uint32
    {.importc: "SDL_GetQueuedAudioSize", cdecl.}
  proc sdl_clear_queued_audio*(dev: SDL_AudioDeviceID)
    {.importc: "SDL_ClearQueuedAudio", cdecl.}
  proc sdl_delay*(ms: uint32)
    {.importc: "SDL_Delay", cdecl.}
