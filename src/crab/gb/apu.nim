# GB APU master (included by gb.nim)

# SDL2 audio bindings
when not declared(SDL_AudioSpec):
  type
    SDL_AudioSpec = object
      freq:      cint
      format:    uint16
      channels:  uint8
      silence:   uint8
      samples:   uint16
      padding:   uint16
      size:      uint32
      callback:  pointer
      userdata:  pointer

  const AUDIO_F32LSB = 0x8120'u16  # 32-bit float, little-endian (native on x86/ARM)

  proc sdl_open_audio_gb(desired: ptr SDL_AudioSpec; obtained: ptr SDL_AudioSpec): cint
    {.importc: "SDL_OpenAudio", cdecl.}
  proc sdl_close_audio_gb()
    {.importc: "SDL_CloseAudio", cdecl.}
  proc sdl_pause_audio_gb(pause_on: cint)
    {.importc: "SDL_PauseAudio", cdecl.}
  proc sdl_queue_audio_gb(dev: uint32; data: pointer; len: uint32): cint
    {.importc: "SDL_QueueAudio", cdecl.}
  proc sdl_get_queued_audio_size_gb(dev: uint32): uint32
    {.importc: "SDL_GetQueuedAudioSize", cdecl.}
  proc sdl_clear_queued_audio_gb(dev: uint32)
    {.importc: "SDL_ClearQueuedAudio", cdecl.}
  proc sdl_delay_gb(ms: uint32)
    {.importc: "SDL_Delay", cdecl.}

proc toggle_sync*(apu: GbApu) =
  apu.sync = not apu.sync

proc tick_frame_sequencer*(apu: GbApu; gb: GB) =
  apu.first_half_of_length_period = (apu.frame_sequencer_stage and 1) == 0
  case apu.frame_sequencer_stage
  of 0:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
  of 2:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
    sweep_step(apu.channel1, gb)
  of 4:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
  of 6:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
    sweep_step(apu.channel1, gb)
  of 7:
    volume_step(apu.channel1); volume_step(apu.channel2); volume_step(apu.channel4)
  else: discard
  apu.frame_sequencer_stage += 1
  if apu.frame_sequencer_stage > 7: apu.frame_sequencer_stage = 0
  gb.scheduler.schedule_gb(GB_FRAME_SEQ_PERIOD,
    proc() = tick_frame_sequencer(apu, gb), etAPU)

proc get_sample*(apu: GbApu; gb: GB) =
  let c1 = ch1_get_amplitude(apu.channel1)
  let c2 = ch2_get_amplitude(apu.channel2)
  let c3 = ch3_get_amplitude(apu.channel3)
  let c4 = ch4_get_amplitude(apu.channel4)
  apu.buffer[apu.buffer_pos] =
    (float32(apu.left_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x80) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x40) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x20) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x10) != 0: c1 else: 0.0'f32)) / 4.0'f32
  apu.buffer[apu.buffer_pos + 1] =
    (float32(apu.right_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x08) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x04) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x02) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x01) != 0: c1 else: 0.0'f32)) / 4.0'f32
  apu.buffer_pos += 2
  if apu.buffer_pos >= GB_APU_BUFFER_SIZE:
    if apu.audio_dev != 0:
      if not apu.sync: sdl_clear_queued_audio_gb(apu.audio_dev)
      while sdl_get_queued_audio_size_gb(apu.audio_dev) >
            uint32(GB_APU_BUFFER_SIZE * 4 * 2): sdl_delay_gb(1)
      discard sdl_queue_audio_gb(apu.audio_dev,
        addr apu.buffer[0], uint32(GB_APU_BUFFER_SIZE * 4))
    apu.buffer_pos = 0
  gb.scheduler.schedule_gb(GB_SAMPLE_PERIOD,
    proc() = get_sample(apu, gb), etAPU)

proc new_gb_apu*(gb: GB; headless: bool): GbApu =
  result = GbApu(
    sound_enabled: false, buffer_pos: 0,
    frame_sequencer_stage: 0, first_half_of_length_period: false,
    sync: not headless,
  )
  result.buffer   = newSeq[float32](GB_APU_BUFFER_SIZE)
  result.channel1 = new_channel1(gb)
  result.channel2 = new_channel2(gb)
  result.channel3 = new_channel3(gb)
  result.channel4 = new_channel4(gb)
  var desired = SDL_AudioSpec(
    freq:     cint(GB_SAMPLE_RATE), format: AUDIO_F32LSB,
    channels: 2'u8, samples: uint16(GB_APU_BUFFER_SIZE div 2),
    callback: nil, userdata: nil,
  )
  var obtained: SDL_AudioSpec
  sdl_close_audio_gb()
  if sdl_open_audio_gb(addr desired, addr obtained) == 0:
    result.audio_dev = 1
    if not headless: sdl_pause_audio_gb(0)
  else:
    echo "Warning: GB failed to open audio device"
    result.audio_dev = 0
  let apu = result
  tick_frame_sequencer(apu, gb)
  get_sample(apu, gb)

proc apu_read*(apu: GbApu; idx: int): uint8 =
  case idx
  of 0xFF10..0xFF14: ch1_read(apu.channel1, idx)
  of 0xFF16..0xFF19: ch2_read(apu.channel2, idx)
  of 0xFF1A..0xFF1E: ch3_read(apu.channel3, idx)
  of 0xFF20..0xFF23: ch4_read(apu.channel4, idx)
  of 0xFF24:
    (if apu.left_enable: 0x80'u8 else: 0'u8) or (apu.left_volume shl 4) or
    (if apu.right_enable: 0x08'u8 else: 0'u8) or apu.right_volume
  of 0xFF25: apu.nr51
  of 0xFF26:
    0x70'u8 or (if apu.sound_enabled: 0x80'u8 else: 0'u8) or
    (if apu.channel4.enabled: 0b1000'u8 else: 0'u8) or
    (if apu.channel3.enabled: 0b0100'u8 else: 0'u8) or
    (if apu.channel2.enabled: 0b0010'u8 else: 0'u8) or
    (if apu.channel1.enabled: 0b0001'u8 else: 0'u8)
  of 0xFF30..0xFF3F: ch3_read(apu.channel3, idx)
  else: 0xFF'u8

proc apu_write*(apu: GbApu; idx: int; val: uint8; gb: GB) =
  if not apu.sound_enabled and idx != 0xFF26 and not (idx in 0xFF30..0xFF3F): return
  case idx
  of 0xFF10..0xFF14: ch1_write(apu.channel1, idx, val, gb)
  of 0xFF16..0xFF19: ch2_write(apu.channel2, idx, val, gb)
  of 0xFF1A..0xFF1E: ch3_write(apu.channel3, idx, val, gb)
  of 0xFF20..0xFF23: ch4_write(apu.channel4, idx, val, gb)
  of 0xFF24:
    apu.left_enable  = (val and 0x80) != 0
    apu.left_volume  = (val and 0x70) shr 4
    apu.right_enable = (val and 0x08) != 0
    apu.right_volume = val and 0x07
  of 0xFF25: apu.nr51 = val
  of 0xFF26:
    if (val and 0x80) == 0 and apu.sound_enabled:
      for i in 0xFF10..0xFF25: apu_write(apu, i, 0x00'u8, gb)
      apu.sound_enabled = false
    elif (val and 0x80) != 0 and not apu.sound_enabled:
      apu.sound_enabled = true
      apu.frame_sequencer_stage = 0
      apu.channel1.length_counter = 0; apu.channel2.length_counter = 0
      apu.channel3.length_counter = 0; apu.channel4.length_counter = 0
  of 0xFF30..0xFF3F: ch3_write(apu.channel3, idx, val, gb)
  else: discard
