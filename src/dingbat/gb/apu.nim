# GB APU master (included by gb.nim)

const APU_SPSW_TAP_LAG_T* {.intdefine.} = 4
  ## Divider counts added to every etAPUFrameSeq re-aim while
  ## GbApu.spsw_fs_lag is set: after an odd number of KEY1 switches into double
  ## speed the DIV-APU tap edge arrives one M-cycle late. Toggles per switch;
  ## only an APU power-off clears it (not a re-trigger, not a DIV write). AGE
  ## speed-switch/spsw-ch2-lc-delay-cgbBCE. 0 compiles the mechanism out.

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
  # DINGBAT_GB_AUDIO_DUMP=<path>: every mixed sample as raw s16le stereo at
  # GB_SAMPLE_RATE, tapped before the output path so the test build dumps too.
  var gb_audio_dump_file: File = nil
  var gb_audio_dump_on = false
  var gb_audio_dump_claimed = false
  var gb_audio_dump_pending = 0

  proc gb_audio_dump_claim() =
    ## The first APU constructed claims the file (2P link dumps player 1 only).
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
    # flush about once a second so an interrupted run leaves a readable dump
    inc gb_audio_dump_pending
    if gb_audio_dump_pending >= GB_SAMPLE_RATE:
      gb_audio_dump_pending = 0
      gb_audio_dump_file.flushFile()

proc toggle_sync*(apu: GbApu) =
  apu.sync = not apu.sync

proc set_master_volume*(apu: GbApu; volume: int; mute: bool) =
  ## 100 maps to exactly 1.0: get_sample's unity passthrough stays bit-identical.
  apu.master_volume_factor = float32(clamp(volume, 0, 100)) / 100.0'f32
  apu.master_muted = mute

proc set_pitch_correct_ff*(apu: GbApu; on: bool) =
  ## WSOLA 2x; the stretcher resets on the stretch-path rising edge in get_sample.
  apu.pitch_correct_ff = on

proc ensure_stretch(apu: GbApu) {.inline, used.} =  # audio emit paths only, compiled out under test_harness
  if not apu.stretch_engaged:
    if apu.stretch == nil: apu.stretch = new_time_stretch()
    else: apu.stretch.reset()
    apu.stretch_engaged = true

proc audio_ahead*(apu: GbApu): bool =
  ## Lets the frontend pace synced emulation without blocking in the callback.
  when defined(test_harness):
    false
  else:
    apu.sync and apu.audio_dev != 0 and
      sdl_get_queued_audio_size_gb(apu.audio_dev) > GB_SYNC_AHEAD_BYTES

when not defined(test_harness):
  proc audio_queued_bytes*(apu: GbApu): uint32 =
    ## Bytes currently queued to the SDL audio device (frame-scheduler input)
    if apu.audio_dev != 0: sdl_get_queued_audio_size_gb(apu.audio_dev) else: 0

# Lazy waveform catch-up: no channel schedules a per-period event. Each carries
# an absolute `next_step` deadline and is advanced in closed form (duty
# position mod 8, wave pointer mod 32; CH4 iterates) at every point that can
# observe it: get_sample, wave RAM access while CH3 is on, PCM12/PCM34
# (gb/memory.nim), any NR10-NR26 write, frame-sequencer ticks, the NR52 read
# (CH1's pending sweep check), the CGB speed switch, the per-frame scheduler
# rebase, and save states (savestate.nim converts next_step to and from an
# etAPUChannel* event). The frequency timer is clocked only while the channel
# is on: switching it off freezes the phase and only an APU power-off resets it
# (SameSuite channel_1_stop_restart), so both park next_step at GB_NO_STEP.

proc apu_catchup_all*(apu: GbApu; gb: GB) {.inline.} =
  ## Materialize all four channels at the current cycle.
  ch1_catchup(apu.channel1, gb)
  ch2_catchup(apu.channel2, gb)
  ch3_catchup(apu.channel3, gb)
  ch4_catchup(apu.channel4, gb)

proc apu_rebase*(apu: GbApu; gb: GB; base: CycleCount) {.inline.} =
  ## Shift every channel deadline by the base scheduler.rebase just subtracted
  ## from the events. Callers must have caught the channels up first.
  template adj(ch: untyped) =
    if ch.next_step != GB_NO_STEP: ch.next_step -= base
  # Channel 4's divisor deadline can be in the past (the catch-up stops at the
  # last LFSR shift); settle it so the subtraction cannot underflow.
  ch4_advance_divisor(apu.channel4, gb)
  if apu.channel4.div_next != GB_NO_STEP: apu.channel4.div_next -= base
  template adj_sweep(field: untyped) =
    if apu.channel1.field != GB_NO_STEP: apu.channel1.field -= base
  adj_sweep(sweep_check_at)
  adj_sweep(sweep_stop_at)
  adj_sweep(sweep_load_at)
  # last_step_at is in the past; losing a one-cycle tie at a frame boundary is
  # unobservable.
  apu.channel1.last_step_at = GB_NO_STEP
  apu.channel2.last_step_at = GB_NO_STEP
  adj(apu.channel1)
  adj(apu.channel2)
  adj(apu.channel3)
  adj(apu.channel4)
  # The tick grids are phases, not deadlines: move them modulo one tick.
  let tick = gb_apu_tick(gb)
  apu.tick_phase = (apu.tick_phase + tick - (base mod tick)) mod tick
  apu.noise_phase = (apu.noise_phase + 2 * tick - (base mod (2 * tick))) mod (2 * tick)

proc apu_rescale_speed*(apu: GbApu; gb: GB; old_speed, new_speed: uint8) =
  ## CGB speed switch: remaining delays are in CPU cycles, so entering double
  ## speed doubles them and leaving halves them (as Scheduler.`speed_mode=`).
  apu_catchup_all(apu, gb)
  let now = gb.scheduler.cycles
  template adj(ch: untyped) =
    if ch.next_step != GB_NO_STEP:
      let remaining = ch.next_step - now
      ch.next_step = now + (if new_speed > old_speed: remaining shl (new_speed - old_speed)
                            else:                     remaining shr (old_speed - new_speed))
  template adj_sweep(field: untyped) =
    if apu.channel1.field != GB_NO_STEP:
      let remaining = apu.channel1.field - now
      apu.channel1.field =
        now + (if new_speed > old_speed: remaining shl (new_speed - old_speed)
               else:                     remaining shr (old_speed - new_speed))
  adj_sweep(sweep_check_at)
  adj_sweep(sweep_stop_at)
  adj_sweep(sweep_load_at)
  adj(apu.channel1)
  adj(apu.channel2)
  adj(apu.channel3)
  adj(apu.channel4)
  # Settle the divisor stage first; it can be in the past (see apu_rebase).
  ch4_advance_divisor(apu.channel4, gb)
  if apu.channel4.div_next != GB_NO_STEP:
    let rem4 = apu.channel4.div_next - now
    apu.channel4.div_next =
      now + (if new_speed > old_speed: rem4 shl (new_speed - old_speed)
             else:                     rem4 shr (old_speed - new_speed))
  # The tick grids are re-anchored, not rescaled: the divider phase after a
  # speed switch is unpinned (SameSuite's APU tests switch speed before the APU
  # power-on that sets it).
  apu.tick_phase  = now mod (CycleCount(4) shl new_speed)
  apu.noise_phase = now mod (CycleCount(8) shl new_speed)

proc gb_rebase*(gb: GB): CycleCount {.discardable.} =
  ## Frame-boundary scheduler rebase. Catching the channels up first keeps every
  ## deadline within one frame of staleness (CH4's shift loop; wasm uint32).
  gb.apu.apu_catchup_all(gb)
  result = gb.scheduler.rebase()
  gb.apu.apu_rebase(gb, result)

proc tick_frame_sequencer*(apu: GbApu; gb: GB) =
  # length_step clears `enabled` and sweep_step rewrites ch1.frequency, so
  # every channel must be current first.
  const OBS = uint32(GB_FRAME_SEQ_PERIOD)
  ch1_catchup_at(apu.channel1, gb, OBS)
  ch2_catchup_at(apu.channel2, gb, OBS)
  ch3_catchup_at(apu.channel3, gb, OBS)
  ch4_catchup_at(apu.channel4, gb, OBS)
  if apu.div_skip:
    # The skipped edge (GbApu.div_skip) performs no step and does not advance
    # the sequencer (SameSuite div_write_trigger_volume_10).
    apu.div_skip = false
    apu.first_half_of_length_period = false
    return
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
  if (apu.frame_sequencer_stage and 1) == 1:
    # Envelope-enable glitch's extra tick; see GbVolumeEnvChannel.env_extra_tick.
    template extra(ch: untyped) =
      if ch.env_extra_tick:
        ch.env_extra_tick = false
        volume_step(ch)
    extra(apu.channel1)
    extra(apu.channel2)
    extra(apu.channel4)
  apu.frame_sequencer_stage += 1
  if apu.frame_sequencer_stage > 7: apu.frame_sequencer_stage = 0

proc get_sample*(apu: GbApu; gb: GB) =
  # Gated on `enabled` (a disabled channel's amplitude does not depend on its
  # phase; the steps replay exactly later), NOT on channel_mask (a debug mute;
  # skipping the catch-up would let CH4's shift loop fall a frame behind).
  const OBS = uint32(GB_SAMPLE_PERIOD)
  if apu.channel1.enabled: ch1_catchup_at(apu.channel1, gb, OBS)
  if apu.channel2.enabled: ch2_catchup_at(apu.channel2, gb, OBS)
  if apu.channel3.enabled: ch3_catchup_at(apu.channel3, gb, OBS)
  if apu.channel4.enabled: ch4_catchup_at(apu.channel4, gb, OBS)
  let c1 = if apu.channel_mask[0]: ch1_get_amplitude(apu.channel1) else: 0.0'f32
  let c2 = if apu.channel_mask[1]: ch2_get_amplitude(apu.channel2) else: 0.0'f32
  let c3 = if apu.channel_mask[2]: ch3_get_amplitude(apu.channel3) else: 0.0'f32
  let c4 = if apu.channel_mask[3]: ch4_get_amplitude(apu.channel4) else: 0.0'f32
  # Pan Docs, Audio Details: NR51 selects which analog outputs (-1..1 each)
  # each side sums; NR50 scales the sum by (V+1)/8, so volume 0 is one eighth,
  # not silence. GB_MASTER_VOLUME has GB_MIX_SCALE folded in.
  let mix_left =
    GB_MASTER_VOLUME[apu.left_volume] *
    ((if (apu.nr51 and 0x80) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x40) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x20) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x10) != 0: c1 else: 0.0'f32))
  let mix_right =
    GB_MASTER_VOLUME[apu.right_volume] *
    ((if (apu.nr51 and 0x08) != 0: c4 else: 0.0'f32) +
     (if (apu.nr51 and 0x04) != 0: c3 else: 0.0'f32) +
     (if (apu.nr51 and 0x02) != 0: c2 else: 0.0'f32) +
     (if (apu.nr51 and 0x01) != 0: c1 else: 0.0'f32))
  # Output coupling capacitor (see GB_DC_CHARGE), applied before the dump hook.
  let sample_left  = mix_left  - apu.dc_cap_left
  let sample_right = mix_right - apu.dc_cap_right
  apu.dc_cap_left  = mix_left  - sample_left  * GB_DC_CHARGE
  apu.dc_cap_right = mix_right - sample_right * GB_DC_CHARGE
  # Flush to zero once the charge decays into float32 denormal range: denormal
  # arithmetic is slow on x86 at 32768/s. The cutoff is far below one LSB.
  if abs(apu.dc_cap_left)  < 1e-30'f32: apu.dc_cap_left  = 0.0'f32
  if abs(apu.dc_cap_right) < 1e-30'f32: apu.dc_cap_right = 0.0'f32
  when not defined(emscripten):
    # Before the output switch: the test_harness branch drops the sample.
    if gb_audio_dump_on: gb_audio_dump_write(sample_left, sample_right)
  when defined(test_harness):
    discard
  elif defined(emscripten):
    if not apu.turbo:
      apu.stretch_engaged = false
      appendAudioSample(sample_left, sample_right)   # 1x bit-identical
    elif apu.pitch_correct_ff:
      # Pitch-correct 2x: WSOLA, pulling every other frame (pacing unchanged).
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
      # Mute still queues zeroed samples because SDL queue depth paces
      # emulation; volume 100 unmuted is a bit-identical passthrough.
      if apu.master_muted:
        for i in 0 ..< GB_APU_BUFFER_SIZE:
          apu.buffer[i] = 0.0'f32
      elif apu.master_volume_factor != 1.0'f32:
        let vf = apu.master_volume_factor
        for i in 0 ..< GB_APU_BUFFER_SIZE:
          apu.buffer[i] = apu.buffer[i] * vf
      # 2x speed: emit half the frames (WSOLA when pitch-correct, else decimate).
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
    # samples: small device buffer so audio-sync pacing has a fine drain clock.
    var desired = SDL_AudioSpec(
      freq:     cint(GB_SAMPLE_RATE), format: AUDIO_F32LSB,
      channels: 2'u8, samples: 128,
      callback: nil, userdata: nil,
    )
    sdl_close_audio_gb()
    # obtained must be nil so SDL converts to exactly this spec (Windows WASAPI
    # otherwise changes it and audio-sync paces emulation at ~2x).
    if sdl_open_audio_gb(addr desired, nil) == 0:
      result.audio_dev = 1
      if not headless: sdl_pause_audio_gb(0)
    else:
      echo "Warning: GB failed to open audio device"
      result.audio_dev = 0
  let apu = result
  # The frame-sequencer event is primed in post_init: it taps the divider,
  # whose phase skip_boot seeds per model only after every component exists.
  get_sample(apu, gb)

proc apu_read*(apu: GbApu; idx: int; gb: GB): uint8 =
  # Wave RAM resolves against wave_ram_position while CH3 is on. NR52's
  # channel-on flags need CH1's pending sweep overflow check run first: blargg
  # cgb_sound 07 sync_sweep polls NR52 waiting for it.
  if idx >= 0xFF30: ch3_catchup(apu.channel3, gb)
  elif idx == 0xFF26: ch1_sweep_due(apu.channel1, gb)
  case idx
  of 0xFF10..0xFF14: ch1_read(apu.channel1, idx)
  of 0xFF16..0xFF19: ch2_read(apu.channel2, idx)
  of 0xFF1A..0xFF1E: ch3_read(apu.channel3, idx, gb)
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
  of 0xFF30..0xFF3F: ch3_read(apu.channel3, idx, gb)
  else: 0xFF'u8

proc apu_drop_spsw_lag(apu: GbApu; gb: GB) =
  ## An APU power transition (either edge of NR52 bit 7) takes the speed-switch
  ## tap lag away, pending edge included: the edge already aimed with the lag
  ## is re-aimed from the divider's own phase. AGE spsw-ch2-lc-delay rows
  ## TEST_DS_OFF_ON (off edge) and TEST_DS_ON (on edge).
  when APU_SPSW_TAP_LAG_T != 0:
    if apu.spsw_fs_lag:
      apu.spsw_fs_lag = false
      gb.scheduler.clear(etAPUFrameSeq)
      gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)

proc apu_write*(apu: GbApu; idx: int; val: uint8; gb: GB) =
  if not apu.sound_enabled and idx != 0xFF26 and not (idx in 0xFF30..0xFF3F):
    # Pan Docs, Power Control: writes are ignored while the APU is off, except
    # that on DMG the length counters can still be written. Only the length
    # field lands, not NR11/NR21's duty bits (blargg dmg_sound
    # 11-regs_after_power).
    if not gb.cgb_enabled:
      case idx
      of 0xFF11:
        apu.channel1.length_load    = val and 0x3F
        apu.channel1.length_counter = 0x40 - int(val and 0x3F)
      of 0xFF16:
        apu.channel2.length_load    = val and 0x3F
        apu.channel2.length_counter = 0x40 - int(val and 0x3F)
      of 0xFF1B:
        apu.channel3.length_load    = val
        apu.channel3.length_counter = 0x100 - int(val)
      of 0xFF20:
        apu.channel4.length_load    = val and 0x3F
        apu.channel4.length_counter = 0x40 - int(val and 0x3F)
      else: discard
    return
  # Catch the target channel up first: a period / duty / trigger change
  # affects only steps from this cycle on.
  case idx
  of 0xFF10..0xFF14: ch1_catchup(apu.channel1, gb)
  of 0xFF16..0xFF19: ch2_catchup(apu.channel2, gb)
  of 0xFF1A..0xFF1E, 0xFF30..0xFF3F: ch3_catchup(apu.channel3, gb)
  of 0xFF20..0xFF23: ch4_catchup(apu.channel4, gb)
  # NR52 power-off rewrites every channel register; sync all four up front.
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
      # Zeroing NR10-NR51 reloads each length counter from the zeroed NRx1, so
      # they are decided separately: cleared on CGB, kept on DMG (Pan Docs).
      let len1 = apu.channel1.length_counter
      let len2 = apu.channel2.length_counter
      let len3 = apu.channel3.length_counter
      let len4 = apu.channel4.length_counter
      for i in 0xFF10..0xFF25: apu_write(apu, i, 0x00'u8, gb)
      if gb.cgb_enabled:
        apu.channel1.length_counter = 0; apu.channel2.length_counter = 0
        apu.channel3.length_counter = 0; apu.channel4.length_counter = 0
      else:
        apu.channel1.length_counter = len1; apu.channel2.length_counter = len2
        apu.channel3.length_counter = len3; apu.channel4.length_counter = len4
      apu.sound_enabled = false
      # Power-off resets the channels' internal phase; wave RAM survives
      # (SameSuite channel_1 / channel_2 bracket every subtest with an off/on).
      apu.channel1.wave_duty_position = 0
      apu.channel2.wave_duty_position = 0
      apu.channel3.wave_ram_position = 0
      # ...and stops the frequency timers (an armed deadline would drift the
      # cleared position again).
      apu.channel1.next_step = GB_NO_STEP
      # Anything in flight inside the sweep unit dies with the power.
      apu.channel1.sweep_check_at = GB_NO_STEP
      apu.channel1.sweep_stop_at  = GB_NO_STEP
      apu.channel1.sweep_load_at  = GB_NO_STEP
      apu.channel2.next_step = GB_NO_STEP
      apu.channel3.next_step = GB_NO_STEP
      apu.channel4.next_step = GB_NO_STEP
      # ...and the divisor stage behind it, counter and all (ch4_steps_to_rise).
      apu.channel4.div_next    = GB_NO_STEP
      apu.channel4.div_counter = 0
      apu_drop_spsw_lag(apu, gb)
    elif (val and 0x80) != 0 and not apu.sound_enabled:
      apu.sound_enabled = true
      apu.frame_sequencer_stage = 0
      apu_drop_spsw_lag(apu, gb)
      # The 1 MHz tick grid (GbApu.tick_phase) and channel 4's half-rate grid
      # (GbApu.noise_phase) restart here.
      apu.tick_phase = gb.scheduler.cycles mod gb_apu_tick(gb)
      apu.noise_phase = gb.scheduler.cycles mod (2 * gb_apu_tick(gb))
      # Pan Docs, Power Control: power-on resets the wave sample buffer. CH3
      # emits it through its trigger's startup delay, so it is visible in PCM34
      # (SameSuite channel_3_delay, _first_sample, _restart_stop_delay, ...).
      apu.channel3.wave_ram_sample_buffer = 0
      # SameSuite div_write_trigger_10: starting the APU while the DIV-APU tap
      # bit is set (internal divider bit 12, 13 in double speed; timer.nim
      # apu_div_bit) skips the first DIV-APU event.
      let tap = 12 + int(gb.scheduler.speed)
      apu.div_skip = ((gb.timer.tdiv shr tap) and 1) != 0
      apu.first_half_of_length_period = apu.div_skip
  of 0xFF30..0xFF3F: ch3_write(apu.channel3, idx, val, gb)
  else: discard
