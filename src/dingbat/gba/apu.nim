# APU implementation (included by gba.nim)

const APU_CHANNELS*       = 2
# Queue-push block, in int16s (128 stereo frames = 3.9 ms). Kept small so the
# SDL queue level — which audio-sync pacing reads — moves in fine steps on the
# push side as well as the drain side; at the old 512-frame block the paced
# emulation cadence (and input latency) jittered by most of a frame.
const APU_BUFFER_SIZE*    = 256
# Audio-sync pacing levels, in bytes of queued s16 stereo (4 bytes/frame).
# Deliberately NOT derived from APU_BUFFER_SIZE: these set how much audio
# stays buffered (latency vs. underrun margin), not the push granularity.
# 2048 B = 512 frames ≈ 15.6 ms lead. The backstop only exists to stop a
# runaway queue if the frontend's frame scheduler misbehaves; it sits far
# above the normal operating range (2-8 KB) because blocking inside
# get_sample stalls emulation mid-frame — the old 4096 B value was routinely
# grazed by ordinary in-frame queue peaks and jittered the frame cadence.
const APU_SYNC_AHEAD_BYTES*    = 2048'u32
const APU_SYNC_BACKSTOP_BYTES* = 16384'u32
const APU_SAMPLE_RATE*    = 32768
const CPU_CLOCK_SPEED*    = 1 shl 24
const APU_SAMPLE_PERIOD*  = CPU_CLOCK_SPEED div APU_SAMPLE_RATE
const FRAME_SEQ_RATE*     = 512
const FRAME_SEQ_PERIOD*   = CPU_CLOCK_SPEED div FRAME_SEQ_RATE
# One-pole low-pass coefficient for the optional analog-output filter:
# alpha = 1 - exp(-2*pi*fc/fs) with fc ~= 12 kHz, fs = 32768 Hz. Conservative
# (nearly flat through the mids, a few dB down at the top octave).
const AUDIO_LOWPASS_ALPHA* = 0.90'f32

when defined(emscripten):
  # On emscripten, the APU pushes float32 samples to a global buffer
  # (in dingbat_wasm.nim) that JS consumes via the Web Audio API.
  proc appendAudioSample(left, right: float32) {.importc, cdecl.}

proc new_apu*(gba: GBA): APU =
  result = APU(
    gba: gba,
    soundcnt_l: SOUNDCNT_L(),
    soundcnt_h: SOUNDCNT_H(),
    sound_enabled: false,
    soundbias: cast[SOUNDBIAS](0x200'u16),
    buffer_pos: 0,
    frame_sequencer_stage: 0,
    first_half_of_length_period: false,
    sync: true,
    channel_mask: [true, true, true, true, true, true],
    master_volume_factor: 256,
  )
  result.buffer = newSeq[int16](APU_BUFFER_SIZE)
  result.channel1 = new_channel1(gba)
  result.channel2 = new_channel2(gba)
  result.channel3 = new_channel3(gba)
  result.channel4 = new_channel4(gba)
  result.dma_channels = new_dma_channels(gba)
  when defined(test_harness):
    result.audio_dev = 0
  elif defined(emscripten):
    # No SDL audio on emscripten — JS handles playback via Web Audio API
    result.audio_dev = 0
  else:
    var desired = SDL_AudioSpec(
      freq:     APU_SAMPLE_RATE.cint,
      format:   AUDIO_S16LSB,
      channels: APU_CHANNELS.uint8,
      # Device buffer deliberately much smaller than the queue-push block:
      # the device drains the queue in `samples`-frame steps, and audio-sync
      # pacing (audio_ahead) can only release the next emulated frame on one
      # of those steps. At 512 frames (15.6 ms) the emulation cadence -- and
      # so input latency -- jittered by up to a whole frame; 128 frames
      # (3.9 ms) keeps the cadence within ~4 ms of the hardware frame rate
      # and shaves ~12 ms off audio output latency as well.
      samples:  128,
      callback: nil,
      userdata: nil,
    )
    sdl_close_audio()
    # obtained must be nil: passing a non-nil obtained means
    # SDL_AUDIO_ALLOW_ANY_CHANGE, and on Windows WASAPI hands back the
    # mixer's native spec (float32, 44.1/48 kHz) with no conversion. The
    # device then drains bytes ~2x faster than the APU queues them and
    # audio-sync paces emulation at ~2x real time. nil makes SDL convert
    # to exactly the requested spec on every platform.
    if sdl_open_audio(addr desired, nil) == 0:
      result.audio_dev = 1
      sdl_pause_audio(0)
    else:
      echo "Warning: failed to open audio device"
      result.audio_dev = 0
  result.tick_frame_sequencer()
  result.get_sample()

proc toggle_sync*(apu: APU) =
  apu.sync = not apu.sync

proc set_master_volume*(apu: APU; volume: int; mute: bool) =
  ## volume is 0..100; 100 maps to exactly 256 so the unity-passthrough
  ## branch in get_sample keeps samples bit-identical
  apu.master_volume_factor = int32(clamp(volume, 0, 100) * 256 div 100)
  apu.master_muted = mute

proc set_audio_lowpass*(apu: APU; on: bool) =
  ## Toggle the optional analog-output low-pass. Resets the filter state on
  ## the OFF->? edge so a fresh enable never carries stale samples; off leaves
  ## the native emit path bit-identical to the unfiltered output.
  if not on:
    apu.lp_left = 0
    apu.lp_right = 0
  apu.audio_lowpass = on

proc set_pitch_correct_ff*(apu: APU; on: bool) =
  ## Toggle WSOLA pitch-preserving 2x. The stretcher itself resets on the
  ## stretch-path rising edge in get_sample, so this only flips the flag.
  apu.pitch_correct_ff = on

proc ensure_stretch(apu: APU) {.inline.} =
  ## Lazily allocate + reset the stretcher exactly when the pitch-correct
  ## path first engages (turbo AND pitch_correct_ff), so a fresh turbo
  ## engagement never overlap-adds a stale buffer tail.
  if not apu.stretch_engaged:
    if apu.stretch == nil: apu.stretch = new_time_stretch()
    else: apu.stretch.reset()
    apu.stretch_engaged = true

proc audio_ahead*(apu: APU): bool =
  ## True when synced audio is buffered comfortably ahead of playback. The
  ## frontend main loop uses this to pace emulation instead of blocking in
  ## get_sample, so the UI keeps running at the display's refresh rate while
  ## emulation waits for audio to drain. Half of get_sample's block
  ## threshold, so the blocking wait stays a rarely-hit backstop.
  when defined(test_harness):
    false
  else:
    apu.sync and apu.audio_dev != 0 and
      sdl_get_queued_audio_size(apu.audio_dev) > APU_SYNC_AHEAD_BYTES

when not defined(test_harness) and not defined(emscripten):
  # Debug instrumentation, env-gated and zero-cost when unset:
  #   DINGBAT_AUDIO_DUMP=<path>  writes every mixed sample as raw s16le stereo
  #   (exactly the bytes queued to SDL) for offline waveform comparison
  var audio_dump_file: File = nil
  var audio_dump_checked = false

  proc audio_dump_dest(): File =
    if not audio_dump_checked:
      audio_dump_checked = true
      let path = getEnv("DINGBAT_AUDIO_DUMP")
      if path.len > 0:
        audio_dump_file = open(path, fmWrite)
    audio_dump_file

  proc audio_queued_bytes*(apu: APU): uint32 =
    ## Bytes currently queued to the SDL audio device (pacing diagnostics)
    if apu.audio_dev != 0: sdl_get_queued_audio_size(apu.audio_dev) else: 0

proc timer_overflow*(apu: APU; timer: int) =
  apu.dma_channels.timer_overflow(timer)

proc tick_frame_sequencer*(apu: APU) =
  apu.first_half_of_length_period = (apu.frame_sequencer_stage and 1) == 0
  case apu.frame_sequencer_stage
  of 0:
    apu.channel1.length_step(); apu.channel2.length_step()
    apu.channel3.length_step(); apu.channel4.length_step()
  of 1: discard
  of 2:
    apu.channel1.length_step(); apu.channel2.length_step()
    apu.channel3.length_step(); apu.channel4.length_step()
    apu.channel1.sweep_step()
  of 3: discard
  of 4:
    apu.channel1.length_step(); apu.channel2.length_step()
    apu.channel3.length_step(); apu.channel4.length_step()
  of 5: discard
  of 6:
    apu.channel1.length_step(); apu.channel2.length_step()
    apu.channel3.length_step(); apu.channel4.length_step()
    apu.channel1.sweep_step()
  of 7:
    apu.channel1.volume_step()
    apu.channel2.volume_step()
    apu.channel4.volume_step()
  else: discard
  apu.frame_sequencer_stage += 1
  if apu.frame_sequencer_stage > 7: apu.frame_sequencer_stage = 0
  apu.gba.scheduler.schedule(FRAME_SEQ_PERIOD, etAPUFrameSeq)

proc get_sample*(apu: APU) =
  let ch1 = if apu.channel_mask[0]: apu.channel1.ch1_get_amplitude() else: 0'i16
  let ch2 = if apu.channel_mask[1]: apu.channel2.ch2_get_amplitude() else: 0'i16
  let ch3 = if apu.channel_mask[2]: apu.channel3.ch3_get_amplitude() else: 0'i16
  let ch4 = if apu.channel_mask[3]: apu.channel4.ch4_get_amplitude() else: 0'i16
  # PSG volume: 0=25%, 1=50%, 2=100%; the prohibited value 3 silences the
  # PSG channels (NanoBoyAdvance and SkyEmu agree; mGBA extrapolates to 200%)
  let psg_muted = apu.soundcnt_h.sound_volume == 3
  let psg_sound =
    if psg_muted: 0'i16
    else:
      ch1 * int16(apu.soundcnt_l.channel_1_left) +
      ch2 * int16(apu.soundcnt_l.channel_2_left) +
      ch3 * int16(apu.soundcnt_l.channel_3_left) +
      ch4 * int16(apu.soundcnt_l.channel_4_left)
  let shift = if psg_muted: 5 else: 5 - int(apu.soundcnt_h.sound_volume)
  let psg_left  = int32(psg_sound) * int32(apu.soundcnt_l.left_volume) shr shift
  let psg_right = int32(psg_sound) * int32(apu.soundcnt_l.right_volume) shr shift
  var (raw_dma_a, raw_dma_b) = apu.dma_channels.dma_channels_get_amplitude()
  # MP2K substitution predicate, shared by the capture below: engaged, not
  # latched foreign, and the engine mixer actually running (mixer_live — a
  # parked SoundMain cannot be producing the FIFO stream; see mp2k.nim).
  let mp2k_subst = apu.gba.mp2k_hle and apu.gba.mp2k != nil and
                   apu.gba.mp2k.engaged and not apu.gba.mp2k.fifo_foreign and
                   apu.gba.mp2k.mixer_live
  # Latched-foreign shadow watch (un-emitted render for the unlatch test).
  let mp2k_watch = apu.gba.mp2k_hle and apu.gba.mp2k != nil and
                   apu.gba.mp2k.engaged and apu.gba.mp2k.fifo_foreign and
                   apu.gba.mp2k.mixer_live and apu.gba.mp2k.unlatch_watch
  when defined(mp2kwav):
    # The game's OWN FIFO output, for A/B calibration against the HLE render.
    # When the HLE is enabled, capture over EXACTLY the span the HLE captures
    # (mp2kWavCapture only accumulates while engaged — render_sample below):
    # gating both streams on the same predicate keeps them sample-aligned, so
    # a single run's "HLE rms vs REAL rms" compares the same audio span. This
    # matters for games whose engine engages late: Mother 3's modified m4a
    # holds SoundInfo.ident at ID_NUMBER+10 through a ~10 s init/intro, and
    # capturing the real FIFO from power-on padded REAL with that leading
    # silence — deflating its RMS ~19% and making the HLE read "~+23% hot"
    # when the span-matched streams actually agree to within a few percent.
    # With the HLE disabled (e.g. DINGBAT_NOHLE=1 reference runs) there is no
    # HLE span to match, so capture the whole run as before. On Camelot "Bon"
    # driver games the MP2K HLE structurally never engages — there the span
    # gate is the gs_bon engagement instead (same alignment rationale).
    if not (apu.gba.mp2k_hle and apu.gba.mp2k != nil) or mp2k_subst or
       mp2k_watch or (apu.gba.gs_bon != nil and apu.gba.gs_bon.engaged):
      realDmaCapture.add raw_dma_a
      realDmaCapture.add raw_dma_b
  # EXPLORATORY: MP2K HLE replaces the DirectSound FIFO A/B latches with a
  # higher-quality mixed sample (L->A, R->B). The existing SOUNDCNT_H DirectSound
  # routing/volume path below (the GBATEK-documented FIFO sink) then applies
  # unchanged.
  # fifo_foreign: the game streams its own audio into pcmBuffer (m4a channels
  # all idle while the buffer carries sound — see mp2k.nim on_frame); the
  # shadow mixer cannot render that, so leave the real FIFO stream alone.
  if mp2k_subst:
    let (hl, hr) = apu.gba.mp2k.render_sample()
    # Feed the foreign-feeder / overlay energy comparisons (see mp2k.nim
    # on_frame) with the REAL drained FIFO stream vs the shadow render it
    # would replace, split per FIFO side.
    let m = apu.gba.mp2k
    m.real_abs_a += int64(abs(int(raw_dma_a)))
    m.real_abs_b += int64(abs(int(raw_dma_b)))
    m.hle_abs_l  += int64(abs(int(hl)))
    m.hle_abs_r  += int64(abs(int(hr)))
    inc m.ab_n
    if m.overlay_hold > 0:
      # Transient foreign overlay detected (announcer speech / voice-clip
      # stingers streamed around the engine — see mp2k.nim on_frame): emit
      # the game's real stream; the shadow above keeps rendering so its
      # samplers, delay ring and reverb history stay warm for a seamless
      # return to substitution.
      when defined(mp2kwav):
        # Keep the capture reflecting what is actually EMITTED (the A/B
        # metric measures the user-audible stream): render_sample appended
        # its own output; overwrite with the passthrough values.
        if mp2kWavCapture.len >= 2:
          mp2kWavCapture[mp2kWavCapture.len - 2] = raw_dma_a
          mp2kWavCapture[mp2kWavCapture.len - 1] = raw_dma_b
    else:
      raw_dma_a = hl
      raw_dma_b = hr
  elif mp2k_watch:
    # Latched-foreign but the engine's channels are ACTIVE: render the shadow
    # without emitting it and accumulate the same per-side energies, so
    # on_frame's unlatch test can measure sustained shadow-vs-real agreement
    # (see mp2k.nim — the EXE3-class boot-clip latch is reversed this way).
    let m = apu.gba.mp2k
    let (hl, hr) = m.render_sample()
    m.real_abs_a += int64(abs(int(raw_dma_a)))
    m.real_abs_b += int64(abs(int(raw_dma_b)))
    m.hle_abs_l  += int64(abs(int(hl)))
    m.hle_abs_r  += int64(abs(int(hr)))
    inc m.ab_n
    when defined(mp2kwav):
      # render_sample appended its (un-emitted) output to the HLE capture;
      # keep the A/B spans matched by capturing the real stream too, and make
      # the HLE capture reflect what is actually emitted (the real stream).
      if mp2kWavCapture.len >= 2:
        mp2kWavCapture[mp2kWavCapture.len - 2] = raw_dma_a
        mp2kWavCapture[mp2kWavCapture.len - 1] = raw_dma_b
  # Camelot "Bon" HLE (Golden Sun) — same substitution for its
  # own engine (structurally never engaged at the same time as the MP2K HLE).
  elif apu.gba.mp2k_hle and apu.gba.gs_bon != nil and apu.gba.gs_bon.engaged:
    let (hl, hr) = apu.gba.gs_bon.gs_render_sample()
    raw_dma_a = hl
    raw_dma_b = hr
  let dma_a = if apu.channel_mask[4]: raw_dma_a else: 0'i16
  let dma_b = if apu.channel_mask[5]: raw_dma_b else: 0'i16
  let dma_a_scaled = int32(dma_a) shl apu.soundcnt_h.dma_sound_a_volume
  let dma_b_scaled = int32(dma_b) shl apu.soundcnt_h.dma_sound_b_volume
  let dma_left  = dma_a_scaled * int32(apu.soundcnt_h.dma_sound_a_left)  + dma_b_scaled * int32(apu.soundcnt_h.dma_sound_b_left)
  let dma_right = dma_a_scaled * int32(apu.soundcnt_h.dma_sound_a_right) + dma_b_scaled * int32(apu.soundcnt_h.dma_sound_b_right)
  let bias = int32(apu.soundbias.bias_level)
  # SOUNDBIAS amplitude_resolution (bits 14-15) selects the DAC bit depth at
  # 32768<<res Hz: 0=9-bit, 1=8-bit, 2=7-bit, 3=6-bit (GBATEK, SOUNDBIAS). We
  # honor the depth by masking the low `res` bits of the biased 10-bit DAC
  # value — leaving ~2 guard bits below the nominal depth (as ares does) so
  # the truncation adds no audible quantization step. res=0 (the near-
  # universal default) masks nothing, keeping this path bit-identical.
  let dac_mask = int32(0x3FF) and
                 not int32((1 shl int(apu.soundbias.amplitude_resolution)) - 1)
  # Stop (sleep) mode halts the system clock, so the sound generators stop
  # advancing and the DAC produces no fresh output (GBATEK: entering Stop
  # stops sound; games are expected to blank video/sound themselves, but
  # Golden Sun relies on the clock halt and leaves SOUNDCNT_X enabled). Emit
  # silence instead of looping the last tone forever. We only gate the output
  # here — the scheduler keeps running so the keypad wake IRQ is still served.
  let stopped = apu.gba.cpu.stopped
  let total_left  = if stopped: 0'i16 else: int16((max(0, min(0x3FF, psg_left  + dma_left  + bias)) and dac_mask) - bias)
  let total_right = if stopped: 0'i16 else: int16((max(0, min(0x3FF, psg_right + dma_right + bias)) and dac_mask) - bias)
  when defined(test_harness):
    discard
  elif defined(emscripten):
    let sl = float32(total_left * 32) / 32768.0'f32
    let sr = float32(total_right * 32) / 32768.0'f32
    if not apu.turbo:
      # 1x: bit-identical passthrough, never routes through the stretcher.
      apu.stretch_engaged = false
      appendAudioSample(sl, sr)
    elif apu.pitch_correct_ff:
      # Pitch-correct 2x: feed every full-rate frame into WSOLA and emit its
      # half-count output. Pull on every OTHER call — exactly the count the
      # old decimation emitted, so pacing is unchanged.
      apu.ensure_stretch()
      apu.stretch.push(sl, sr)
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        let (ol, orr) = apu.stretch.pull()
        appendAudioSample(ol, orr)
    else:
      # 2x, pitch-correct off: historical every-other-sample decimation
      # (audio pitched up an octave).
      apu.stretch_engaged = false
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        appendAudioSample(sl, sr)
  else:
    var out_l = total_left  * 32
    var out_r = total_right * 32
    if apu.audio_lowpass:
      # Gentle one-pole low-pass (~12 kHz corner at 32768 Hz) modeling the
      # cap/speaker smoothing on real hardware. alpha = 1 - exp(-2*pi*fc/fs).
      # Guarded so the disabled path above stays bit-identical.
      apu.lp_left  += AUDIO_LOWPASS_ALPHA * (float32(out_l) - apu.lp_left)
      apu.lp_right += AUDIO_LOWPASS_ALPHA * (float32(out_r) - apu.lp_right)
      out_l = int16(clamp(apu.lp_left,  -32768.0'f32, 32767.0'f32))
      out_r = int16(clamp(apu.lp_right, -32768.0'f32, 32767.0'f32))
    apu.buffer[apu.buffer_pos]     = out_l
    apu.buffer[apu.buffer_pos + 1] = out_r
    apu.buffer_pos += 2
    if apu.buffer_pos >= APU_BUFFER_SIZE:
      # Master volume, applied per buffer at the queue point. Muting still
      # queues (zeroed) samples: emulation pacing is driven by the SDL queue
      # depth, so skipping the queue would break frame pacing. At volume 100
      # unmuted this branch is skipped entirely — bit-identical passthrough.
      if apu.master_muted:
        for i in 0 ..< APU_BUFFER_SIZE:
          apu.buffer[i] = 0'i16
      elif apu.master_volume_factor != 256:
        let vf = apu.master_volume_factor
        for i in 0 ..< APU_BUFFER_SIZE:
          apu.buffer[i] = int16(int32(apu.buffer[i]) * vf shr 8)
      # 2x speed: emit half the output frames so the queue fills at half rate
      # and audio-driven pacing runs emulation twice as fast. Two ways to halve:
      #   pitch_correct_ff on  -> WSOLA time-stretch (pitch preserved)
      #   pitch_correct_ff off -> keep every other frame (classic octave-up)
      # Both emit exactly APU_BUFFER_SIZE/2 int16, so pacing is identical.
      # At normal speed this is skipped entirely (1x bit-identical).
      var queue_len = APU_BUFFER_SIZE
      if apu.turbo:
        if apu.pitch_correct_ff:
          apu.ensure_stretch()
          var i = 0
          while i < APU_BUFFER_SIZE:
            apu.stretch.push(float32(apu.buffer[i]), float32(apu.buffer[i + 1]))
            i += 2
          var o = 0
          for f in 0 ..< (APU_BUFFER_SIZE div 4):   # 256 frames = half
            let (l, r) = apu.stretch.pull()
            apu.buffer[o]     = int16(clamp(l, -32768.0'f32, 32767.0'f32))
            apu.buffer[o + 1] = int16(clamp(r, -32768.0'f32, 32767.0'f32))
            o += 2
          queue_len = o
        else:
          apu.stretch_engaged = false
          var o = 0
          var i = 0
          while i < APU_BUFFER_SIZE:
            apu.buffer[o]     = apu.buffer[i]
            apu.buffer[o + 1] = apu.buffer[i + 1]
            o += 2
            i += 4
          queue_len = o
      else:
        apu.stretch_engaged = false
      let dump = audio_dump_dest()
      if dump != nil:
        discard dump.writeBuffer(addr apu.buffer[0],
                                 queue_len * sizeof(int16))
        dump.flushFile()
      if apu.audio_dev != 0:
        if not apu.sync:
          sdl_clear_queued_audio(apu.audio_dev)
        # Block until the queue drains below the backstop to stay in sync
        while sdl_get_queued_audio_size(apu.audio_dev) > APU_SYNC_BACKSTOP_BYTES:
          sdl_delay(1)
        discard sdl_queue_audio(apu.audio_dev,
                                 cast[pointer](addr apu.buffer[0]),
                                 uint32(queue_len * sizeof(int16)))
      apu.buffer_pos = 0
  apu.gba.scheduler.schedule(APU_SAMPLE_PERIOD, etAPUSample)

proc `[]`*(apu: APU; io_addr: uint32): uint8 =
  if ch1_in_range(io_addr):      apu.channel1.ch1_read(io_addr)
  elif ch2_in_range(io_addr):    apu.channel2.ch2_read(io_addr)
  elif ch3_in_range(io_addr):    apu.channel3.ch3_read(io_addr)
  elif ch4_in_range(io_addr):    apu.channel4.ch4_read(io_addr)
  elif dma_channels_in_range(io_addr): apu.dma_channels.dma_channels_read(io_addr)
  else:
    case io_addr
    of 0x80..0x81: read(apu.soundcnt_l, io_addr and 1)
    of 0x82..0x83: read(apu.soundcnt_h, io_addr and 1)
    of 0x84:
      (if apu.sound_enabled: 0x80'u8 else: 0'u8) or
      (if apu.channel4.enabled: 0b1000'u8 else: 0'u8) or
      (if apu.channel3.enabled: 0b0100'u8 else: 0'u8) or
      (if apu.channel2.enabled: 0b0010'u8 else: 0'u8) or
      (if apu.channel1.enabled: 0b0001'u8 else: 0'u8)
    of 0x85, 0x86, 0x87: 0'u8
    of 0x88..0x89: read(apu.soundbias, io_addr and 1)
    of 0x8A, 0x8B: 0'u8
    else: apu.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(apu: APU; io_addr: uint32; value: uint8) =
  if not (apu.sound_enabled or
          (io_addr >= 0x82 and io_addr <= 0x89) or
          (io_addr >= WAVE_RAM_LOW and io_addr <= WAVE_RAM_HIGH)):
    return
  if ch1_in_range(io_addr):      apu.channel1.ch1_write(io_addr, value)
  elif ch2_in_range(io_addr):    apu.channel2.ch2_write(io_addr, value)
  elif ch3_in_range(io_addr):    apu.channel3.ch3_write(io_addr, value)
  elif ch4_in_range(io_addr):    apu.channel4.ch4_write(io_addr, value)
  elif dma_channels_in_range(io_addr): apu.dma_channels.dma_channels_write(io_addr, value)
  else:
    case io_addr
    of 0x80: apu.soundcnt_l = cast[SOUNDCNT_L]((uint16(apu.soundcnt_l) and 0xFF00'u16) or (uint16(value) and 0x77'u16))  # bits 3,7 unused
    of 0x81: apu.soundcnt_l = cast[SOUNDCNT_L]((uint16(apu.soundcnt_l) and 0x00FF'u16) or (uint16(value) shl 8))
    of 0x82:
      apu.soundcnt_h = cast[SOUNDCNT_H]((uint16(apu.soundcnt_h) and 0xFF00'u16) or (uint16(value) and 0x0F'u16))  # bits 4-7 unused
    of 0x83:
      # Bits 3,7 (= register bits 11,15) are write-only FIFO reset triggers
      if bit(value, 3):  # FIFO A reset
        for i in 0..31: apu.dma_channels.fifos[0][i] = 0
        apu.dma_channels.positions[0] = 0
        apu.dma_channels.sizes[0] = 0
        apu.dma_channels.latches[0] = 0
        apu.dma_channels.hist[0] = [0'i16, 0, 0, 0]
        apu.dma_channels.samples_since[0] = 0
      if bit(value, 7):  # FIFO B reset
        for i in 0..31: apu.dma_channels.fifos[1][i] = 0
        apu.dma_channels.positions[1] = 0
        apu.dma_channels.sizes[1] = 0
        apu.dma_channels.latches[1] = 0
        apu.dma_channels.hist[1] = [0'i16, 0, 0, 0]
        apu.dma_channels.samples_since[1] = 0
      apu.soundcnt_h = cast[SOUNDCNT_H]((uint16(apu.soundcnt_h) and 0x00FF'u16) or ((uint16(value) and 0x77'u16) shl 8))
    of 0x84:
      if (value and 0x80) == 0 and apu.sound_enabled:
        for addr in 0x60'u32..0x81'u32:
          apu[addr] = 0x00'u8
        apu.sound_enabled = false
      elif (value and 0x80) > 0 and not apu.sound_enabled:
        apu.sound_enabled = true
        apu.frame_sequencer_stage = 0
        apu.channel1.length_counter = 0
        apu.channel2.length_counter = 0
        apu.channel3.length_counter = 0
        apu.channel4.length_counter = 0
    of 0x85: discard
    of 0x88..0x89: write(apu.soundbias, value, io_addr and 1)
    of 0xA8..0xAF: discard
    else: discard
