# GB APU master (included by gb.nim)

when defined(emscripten):
  proc appendAudioSample(left, right: float32) {.importc, cdecl.}

# SDL2 audio bindings
when not defined(test_harness):
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

proc set_master_volume*(apu: GbApu; volume: int; mute: bool) =
  ## volume is 0..100; 100 maps to exactly 1.0 so the unity-passthrough
  ## branch in get_sample keeps samples bit-identical
  apu.master_volume_factor = float32(clamp(volume, 0, 100)) / 100.0'f32
  apu.master_muted = mute

proc set_pitch_correct_ff*(apu: GbApu; on: bool) =
  ## Toggle WSOLA pitch-preserving 2x (see the GBA APU). The stretcher resets
  ## on the stretch-path rising edge in get_sample.
  apu.pitch_correct_ff = on

proc ensure_stretch(apu: GbApu) {.inline.} =
  if not apu.stretch_engaged:
    if apu.stretch == nil: apu.stretch = new_time_stretch()
    else: apu.stretch.reset()
    apu.stretch_engaged = true

proc audio_ahead*(apu: GbApu): bool =
  ## See the GBA APU's audio_ahead: lets the frontend pace synced emulation
  ## without blocking inside the sample callback
  when defined(test_harness):
    false
  else:
    apu.sync and apu.audio_dev != 0 and
      sdl_get_queued_audio_size_gb(apu.audio_dev) > GB_SYNC_AHEAD_BYTES

when not defined(test_harness):
  proc audio_queued_bytes*(apu: GbApu): uint32 =
    ## Bytes currently queued to the SDL audio device (frame-scheduler input)
    if apu.audio_dev != 0: sdl_get_queued_audio_size_gb(apu.audio_dev) else: 0

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
  gb.scheduler.schedule_gb(GB_FRAME_SEQ_PERIOD, etAPUFrameSeq)

proc get_sample*(apu: GbApu; gb: GB) =
  let c1 = if apu.channel_mask[0]: ch1_get_amplitude(apu.channel1) else: 0.0'f32
  let c2 = if apu.channel_mask[1]: ch2_get_amplitude(apu.channel2) else: 0.0'f32
  let c3 = if apu.channel_mask[2]: ch3_get_amplitude(apu.channel3) else: 0.0'f32
  let c4 = if apu.channel_mask[3]: ch4_get_amplitude(apu.channel4) else: 0.0'f32
  let sample_left =
    (float32(apu.left_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x80) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x40) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x20) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x10) != 0: c1 else: 0.0'f32)) / 4.0'f32
  let sample_right =
    (float32(apu.right_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x08) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x04) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x02) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x01) != 0: c1 else: 0.0'f32)) / 4.0'f32
  when defined(test_harness):
    discard
  elif defined(emscripten):
    if not apu.turbo:
      apu.stretch_engaged = false
      appendAudioSample(sample_left, sample_right)   # 1x bit-identical
    elif apu.pitch_correct_ff:
      # Pitch-correct 2x: WSOLA, pull every OTHER frame (same count as the
      # decimation below, so pacing is unchanged).
      apu.ensure_stretch()
      apu.stretch.push(sample_left, sample_right)
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        let (ol, orr) = apu.stretch.pull()
        appendAudioSample(ol, orr)
    else:
      apu.stretch_engaged = false
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        appendAudioSample(sample_left, sample_right)  # classic octave-up
  else:
    apu.buffer[apu.buffer_pos]     = sample_left
    apu.buffer[apu.buffer_pos + 1] = sample_right
    apu.buffer_pos += 2
    if apu.buffer_pos >= GB_APU_BUFFER_SIZE:
      # Master volume at the queue point; mute still queues (zeroed)
      # samples because SDL queue depth paces emulation. Volume 100 unmuted
      # skips this entirely — bit-identical passthrough.
      if apu.master_muted:
        for i in 0 ..< GB_APU_BUFFER_SIZE:
          apu.buffer[i] = 0.0'f32
      elif apu.master_volume_factor != 1.0'f32:
        let vf = apu.master_volume_factor
        for i in 0 ..< GB_APU_BUFFER_SIZE:
          apu.buffer[i] = apu.buffer[i] * vf
      # 2x speed: emit half the frames (see the GBA APU comment). WSOLA when
      # pitch-correct is on, else keep every other frame. Both halve the count.
      var queue_len = GB_APU_BUFFER_SIZE
      if apu.turbo:
        if apu.pitch_correct_ff:
          apu.ensure_stretch()
          var i = 0
          while i < GB_APU_BUFFER_SIZE:
            apu.stretch.push(apu.buffer[i], apu.buffer[i + 1])
            i += 2
          var o = 0
          for f in 0 ..< (GB_APU_BUFFER_SIZE div 4):   # half
            let (l, r) = apu.stretch.pull()
            apu.buffer[o]     = l
            apu.buffer[o + 1] = r
            o += 2
          queue_len = o
        else:
          apu.stretch_engaged = false
          var o = 0
          var i = 0
          while i < GB_APU_BUFFER_SIZE:
            apu.buffer[o]     = apu.buffer[i]
            apu.buffer[o + 1] = apu.buffer[i + 1]
            o += 2
            i += 4
          queue_len = o
      else:
        apu.stretch_engaged = false
      if apu.audio_dev != 0:
        if not apu.sync: sdl_clear_queued_audio_gb(apu.audio_dev)
        while sdl_get_queued_audio_size_gb(apu.audio_dev) >
              GB_SYNC_BACKSTOP_BYTES: sdl_delay_gb(1)
        discard sdl_queue_audio_gb(apu.audio_dev,
          addr apu.buffer[0], uint32(queue_len * 4))
      apu.buffer_pos = 0
  gb.scheduler.schedule_gb(GB_SAMPLE_PERIOD, etAPUSample)

proc new_gb_apu*(gb: GB; headless: bool): GbApu =
  result = GbApu(
    sound_enabled: false, buffer_pos: 0,
    frame_sequencer_stage: 0, first_half_of_length_period: false,
    sync: not headless,
    channel_mask: [true, true, true, true],
    master_volume_factor: 1.0'f32,
  )
  result.buffer   = newSeq[float32](GB_APU_BUFFER_SIZE)
  result.channel1 = new_channel1(gb)
  result.channel2 = new_channel2(gb)
  result.channel3 = new_channel3(gb)
  result.channel4 = new_channel4(gb)
  when defined(test_harness):
    result.audio_dev = 0
  elif defined(emscripten):
    result.audio_dev = 0  # JS handles playback via Web Audio API
  else:
    # samples: small device buffer so audio-sync pacing releases emulated
    # frames on a fine-grained drain clock; see the matching comment in
    # gba/apu.nim (cuts up to a frame of cadence jitter / input latency)
    var desired = SDL_AudioSpec(
      freq:     cint(GB_SAMPLE_RATE), format: AUDIO_F32LSB,
      channels: 2'u8, samples: 128,
      callback: nil, userdata: nil,
    )
    sdl_close_audio_gb()
    # obtained must be nil so SDL converts to exactly this spec; see the
    # matching comment in gba/apu.nim (Windows WASAPI otherwise changes the
    # spec and audio-sync paces emulation at ~2x real time)
    if sdl_open_audio_gb(addr desired, nil) == 0:
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
