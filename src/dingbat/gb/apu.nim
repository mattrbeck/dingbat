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

when not defined(emscripten):
  # Debug instrumentation, env-gated and zero-cost when unset (one bool test in
  # get_sample). Mirrors the GBA APU's DINGBAT_AUDIO_DUMP:
  #   DINGBAT_GB_AUDIO_DUMP=<path>  writes every mixed sample as raw s16le
  #   stereo, interleaved L,R, at GB_SAMPLE_RATE (32768 Hz).
  # Unlike the GBA hook this one sits outside the test_harness gate and taps the
  # mixed sample before the output path, so the headless test build dumps too --
  # which is what makes it usable as an APU oracle (byte-comparing two builds'
  # audio is the audio equivalent of the byte-identical screenshot gate).
  var gb_audio_dump_file: File = nil
  var gb_audio_dump_on = false
  var gb_audio_dump_claimed = false
  var gb_audio_dump_pending = 0

  proc gb_audio_dump_claim() =
    ## Called once per APU construction. The first APU created claims the file,
    ## so a 2P link session dumps player 1 rather than interleaving both.
    if gb_audio_dump_claimed: return
    gb_audio_dump_claimed = true
    let path = getEnv("DINGBAT_GB_AUDIO_DUMP")
    if path.len > 0:
      gb_audio_dump_file = open(path, fmWrite)
      gb_audio_dump_on = true

  proc gb_audio_dump_write(left, right: float32) =
    var frame: array[2, int16]
    frame[0] = int16(clamp(left  * 32767.0'f32, -32768.0'f32, 32767.0'f32))
    frame[1] = int16(clamp(right * 32767.0'f32, -32768.0'f32, 32767.0'f32))
    discard gb_audio_dump_file.writeBuffer(addr frame[0], sizeof(frame))
    # stdio buffers the writes; flush about once a second so an interrupted run
    # still leaves a readable dump
    inc gb_audio_dump_pending
    if gb_audio_dump_pending >= GB_SAMPLE_RATE:
      gb_audio_dump_pending = 0
      gb_audio_dump_file.flushFile()

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

proc ensure_stretch(apu: GbApu) {.inline, used.} =  # audio emit paths only, compiled out under test_harness
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

# ---------------------------------------------------------------------------
# Lazy waveform catch-up
#
# Channels 1-4 used to schedule one scheduler event per waveform period. A
# square parked at frequency 0x7FF steps every 4 T-cycles = 17,556 events per
# frame per channel; Alone in the Dark leaves three DISABLED channels there and
# burned ~70k events/frame producing silence. Instead each channel now carries a
# `next_step` deadline and is advanced in closed form when something can observe
# it -- pos = (pos + N) and 7 for a square, (pos + N) mod 32 for the wave
# pointer. This is what mGBA (GBAudioRun, src/gb/audio.c:503) and Gambatte
# (DutyUnit::updatePos) do; it is phase-exact, so a trigger still inherits the
# free-running phase the way hardware does (hardware only resets the duty
# counter on an APU power-off), which parking the channels would not.
#
# The complete set of observation points, and where each is handled:
#
#   1. etAPUSample / get_sample -- reads every channel's amplitude.
#      Handled below. ~549/frame at 32768 Hz vs 70k channel events.
#   2. 0xFF30-0xFF3F wave RAM read AND write while CH3 is enabled -- resolves
#      against wave_ram_position, not the address. apu_read/apu_write.
#   3. 0xFF76/0xFF77 PCM12/PCM34 -- expose the raw per-channel digital output
#      at cycle resolution, so the catch-up is load-bearing. gb/memory.nim
#      syncs all four channels before assembling either register.
#   4. Any 0xFF10-0xFF26 register write -- may change the period, the duty, or
#      trigger. apu_write catches the target channel up first so collapsed
#      cycles always use the period that was actually in force for them.
#   5. Frame-sequencer ticks -- length_step can clear `enabled` (a CH4 park
#      point) and sweep_step rewrites ch1.frequency. tick_frame_sequencer.
#   6. NR52 channel-active bits -- report `enabled` only, which no catch-up
#      changes, so no sync is needed (documented at apu_read).
#   7. CGB speed switch -- rescales the deadline exactly as the scheduler
#      rescales pending events. gb/memory.nim stop_instr.
#   8. Per-frame scheduler rebase -- next_step is an ABSOLUTE cycle and has to
#      move with the events. gb_rebase below; also bounds how stale a deadline
#      can get, which keeps CH4's loop and the uint32 wasm CycleCount safe.
#   9. Save states / rollback+netplay snapshots -- savestate.nim converts
#      next_step to and from an etAPUChannel* event, so the state format is
#      byte-identical to the pre-catch-up one in both directions.
# ---------------------------------------------------------------------------

proc apu_catchup_all*(apu: GbApu; gb: GB) {.inline.} =
  ## Materialize all four channels at the current cycle. Used by the
  ## observation points that can touch any channel (frame sequencer, sample,
  ## NR52 writes, speed switch, rebase).
  ch1_catchup(apu.channel1, gb)
  ch2_catchup(apu.channel2, gb)
  ch3_catchup(apu.channel3, gb)
  ch4_catchup(apu.channel4, gb)

proc apu_rebase*(apu: GbApu; base: CycleCount) {.inline.} =
  ## Shift the channel deadlines down by the same base scheduler.rebase just
  ## subtracted from every pending event. Callers must have caught the channels
  ## up first, so each deadline is strictly in the future and cannot underflow.
  template adj(ch: untyped) =
    if ch.next_step != GB_NO_STEP: ch.next_step -= base
  adj(apu.channel1)
  adj(apu.channel2)
  adj(apu.channel3)
  adj(apu.channel4)

proc apu_rescale_speed*(apu: GbApu; gb: GB; old_speed, new_speed: uint8) =
  ## CGB speed switch. Mirrors Scheduler.`speed_mode=`: the remaining delay is
  ## stored in CPU cycles, so entering double speed doubles it and leaving
  ## halves it. Channels are caught up first so "remaining" is well defined.
  apu_catchup_all(apu, gb)
  let now = gb.scheduler.cycles
  template adj(ch: untyped) =
    if ch.next_step != GB_NO_STEP:
      let remaining = ch.next_step - now
      ch.next_step = now + (if new_speed > old_speed: remaining shl (new_speed - old_speed)
                            else:                     remaining shr (old_speed - new_speed))
  adj(apu.channel1)
  adj(apu.channel2)
  adj(apu.channel3)
  adj(apu.channel4)

proc gb_rebase*(gb: GB): CycleCount {.discardable.} =
  ## Frame-boundary scheduler rebase (see Scheduler.rebase). Catching the APU
  ## channels up first is what makes the subtraction safe AND doubles as the
  ## staleness valve: no deadline is ever more than one frame behind, which
  ## bounds CH4's shift loop and keeps the wasm build's uint32 cycle counter
  ## from wrapping under a channel nobody has looked at.
  gb.apu.apu_catchup_all(gb)
  result = gb.scheduler.rebase()
  gb.apu.apu_rebase(result)

proc tick_frame_sequencer*(apu: GbApu; gb: GB) =
  # length_step can clear `enabled` (parks CH4) and sweep_step rewrites
  # ch1.frequency, so every channel has to be current first.
  const OBS = uint32(GB_FRAME_SEQ_PERIOD)
  ch1_catchup_at(apu.channel1, gb, OBS)
  ch2_catchup_at(apu.channel2, gb, OBS)
  ch3_catchup_at(apu.channel3, gb, OBS)
  ch4_catchup_at(apu.channel4, gb, OBS)
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

proc get_sample*(apu: GbApu; gb: GB) =
  # Gated on `enabled` because a disabled channel's amplitude is 0 regardless
  # of phase (the header's Alone-in-the-Dark win) -- its steps simply accumulate
  # until the next thing that CAN see it (a trigger, or the frame-boundary
  # rebase), and the closed form then replays them exactly. NOT gated on
  # channel_mask: that is a debug mute, and skipping the catch-up would let
  # CH4's shift loop fall behind by more than a frame.
  const OBS = uint32(GB_SAMPLE_PERIOD)
  if apu.channel1.enabled: ch1_catchup_at(apu.channel1, gb, OBS)
  if apu.channel2.enabled: ch2_catchup_at(apu.channel2, gb, OBS)
  if apu.channel3.enabled: ch3_catchup_at(apu.channel3, gb, OBS)
  if apu.channel4.enabled: ch4_catchup_at(apu.channel4, gb, OBS)
  let c1 = if apu.channel_mask[0]: ch1_get_amplitude(apu.channel1) else: 0.0'f32
  let c2 = if apu.channel_mask[1]: ch2_get_amplitude(apu.channel2) else: 0.0'f32
  let c3 = if apu.channel_mask[2]: ch3_get_amplitude(apu.channel3) else: 0.0'f32
  let c4 = if apu.channel_mask[3]: ch4_get_amplitude(apu.channel4) else: 0.0'f32
  let mix_left =
    (float32(apu.left_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x80) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x40) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x20) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x10) != 0: c1 else: 0.0'f32)) / 4.0'f32
  let mix_right =
    (float32(apu.right_volume) / 7.0'f32) *
    ((if (apu.nr51 and 0x08) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x04) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x02) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x01) != 0: c1 else: 0.0'f32)) / 4.0'f32
  # Output-stage DC blocker, modelling the coupling capacitor between the mixer
  # and the output jack. See GB_DC_CHARGE for why this is not optional: the raw
  # DAC mix carries a large DC offset that steps every time a channel is
  # switched on or off, and each of those steps is an audible click. Applied
  # here, ahead of the dump hook and every output path, so the oracle sees what
  # the speaker sees.
  let sample_left  = mix_left  - apu.dc_cap_left
  let sample_right = mix_right - apu.dc_cap_right
  apu.dc_cap_left  = mix_left  - sample_left  * GB_DC_CHARGE
  apu.dc_cap_right = mix_right - sample_right * GB_DC_CHARGE
  when not defined(emscripten):
    # Before the output switch on purpose: the test_harness branch below drops
    # the sample, and the oracle needs it.
    if gb_audio_dump_on: gb_audio_dump_write(sample_left, sample_right)
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
  when not defined(emscripten):
    gb_audio_dump_claim()
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
  # The frame-sequencer event is primed in post_init instead of here: it is a
  # tap on the divider, so its phase comes from tdiv, which skip_boot seeds
  # per hardware model only after every component exists.
  get_sample(apu, gb)

proc apu_read*(apu: GbApu; idx: int; gb: GB): uint8 =
  # Only wave RAM needs a sync: 0xFF30-0xFF3F resolves against
  # wave_ram_position while CH3 is enabled. Everything else here reports
  # register bits or `enabled` (NR52), none of which a catch-up can change.
  if idx >= 0xFF30: ch3_catchup(apu.channel3, gb)
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
  # Materialize the target channel BEFORE the write lands, so any period /
  # duty / trigger change only affects steps from this cycle on, and so a
  # wave-RAM write resolves against the right wave_ram_position.
  case idx
  of 0xFF10..0xFF14: ch1_catchup(apu.channel1, gb)
  of 0xFF16..0xFF19: ch2_catchup(apu.channel2, gb)
  of 0xFF1A..0xFF1E, 0xFF30..0xFF3F: ch3_catchup(apu.channel3, gb)
  of 0xFF20..0xFF23: ch4_catchup(apu.channel4, gb)
  # NR52 power-off rewrites every channel register (recursing through the arms
  # above), but sync all four anyway: it is a rare write and it keeps the
  # power-on reset from depending on that recursion.
  of 0xFF26: apu_catchup_all(apu, gb)
  else: discard
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
      # Powering the APU off resets the channels' INTERNAL phase too, not just
      # their registers: the square channels' duty position, the wave channel's
      # sample position and the DIV-APU counter all restart from 0. Wave RAM
      # contents survive. Without this a channel retriggered after an off/on
      # resumes at whatever duty position happened to be current, so its output
      # is phase-shifted by an arbitrary amount — which is exactly what
      # SameSuite's channel_1/channel_2 tests measure, since every one of their
      # subtests brackets the setup with an APU off/on.
      apu.channel1.wave_duty_position = 0
      apu.channel2.wave_duty_position = 0
      apu.channel3.wave_ram_position = 0
    elif (val and 0x80) != 0 and not apu.sound_enabled:
      apu.sound_enabled = true
      apu.frame_sequencer_stage = 0
      apu.channel1.length_counter = 0; apu.channel2.length_counter = 0
      apu.channel3.length_counter = 0; apu.channel4.length_counter = 0
  of 0xFF30..0xFF3F: ch3_write(apu.channel3, idx, val, gb)
  else: discard
