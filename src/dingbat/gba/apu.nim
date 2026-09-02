# APU implementation (included by gba.nim)

const APU_CHANNELS*       = 2
# Queue-push block in int16s (128 stereo frames = 3.9 ms); small so the SDL
# queue level that audio-sync pacing reads moves in fine steps
const APU_BUFFER_SIZE*    = 256
# Audio-sync pacing levels in bytes of queued s16 stereo (4 bytes/frame),
# independent of the push granularity: 2048 B = 512 frames = 15.6 ms lead.
# The backstop only stops a runaway queue; it sits far above the normal
# 2-8 KB range because blocking in get_sample stalls emulation mid-frame.
const APU_SYNC_AHEAD_BYTES*    = 2048'u32
const APU_SYNC_BACKSTOP_BYTES* = 16384'u32
const APU_SAMPLE_RATE*    = 32768
const CPU_CLOCK_SPEED*    = 1 shl 24
const APU_SAMPLE_PERIOD*  = CPU_CLOCK_SPEED div APU_SAMPLE_RATE
const FRAME_SEQ_RATE*     = 512
const FRAME_SEQ_PERIOD*   = CPU_CLOCK_SPEED div FRAME_SEQ_RATE
# One-pole low-pass coefficient for the optional analog-output filter:
# alpha = 1 - exp(-2*pi*fc/fs) with fc ~= 12 kHz, fs = 32768 Hz
const AUDIO_LOWPASS_ALPHA* = 0.90'f32

# Minimal SDL2 audio C bindings (SDL2 is already linked via nim.cfg)
when not defined(test_harness):
  type
    SDL_AudioDeviceID = uint32
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

  const AUDIO_S16LSB  = 0x8010'u16

  # Legacy (default-device) SDL audio API; apu.audio_dev is its implicit
  # device
  proc sdl_open_audio(desired: ptr SDL_AudioSpec; obtained: ptr SDL_AudioSpec): cint
    {.importc: "SDL_OpenAudio", cdecl.}
  proc sdl_close_audio()
    {.importc: "SDL_CloseAudio", cdecl.}
  proc sdl_pause_audio(pause_on: cint)
    {.importc: "SDL_PauseAudio", cdecl.}
  proc sdl_queue_audio(dev: SDL_AudioDeviceID; data: pointer; len: uint32): cint
    {.importc: "SDL_QueueAudio", cdecl.}
  proc sdl_get_queued_audio_size(dev: SDL_AudioDeviceID): uint32
    {.importc: "SDL_GetQueuedAudioSize", cdecl.}
  proc sdl_clear_queued_audio(dev: SDL_AudioDeviceID)
    {.importc: "SDL_ClearQueuedAudio", cdecl.}
  proc sdl_delay(ms: uint32)
    {.importc: "SDL_Delay", cdecl.}

when defined(emscripten):
  # Emscripten: float32 samples go to a global buffer (dingbat_wasm.nim)
  # that JS consumes via the Web Audio API
  proc appendAudioSample(left, right: float32) {.importc, cdecl.}

when not defined(emscripten):
  # DINGBAT_GBA_AUDIO_DUMP=<path>: every mixed sample as raw s16le stereo,
  # interleaved L,R, at 32768 Hz. Outside the test_harness gate and before
  # the output switch, so the headless test build dumps too (the APU
  # byte-compare oracle).
  var gba_audio_dump_file: File = nil
  var gba_audio_dump_on = false
  var gba_audio_dump_claimed = false
  var gba_audio_dump_pending = 0

  proc gba_audio_dump_claim() =
    ## The first APU created claims the file, so a 2P link session dumps
    ## player 1 rather than interleaving both.
    if gba_audio_dump_claimed: return
    gba_audio_dump_claimed = true
    let path = getEnv("DINGBAT_GBA_AUDIO_DUMP")
    if path.len > 0:
      gba_audio_dump_file = open(path, fmWrite)
      gba_audio_dump_on = true

  proc gba_audio_dump_write(left, right: int16) =
    var frame: array[2, int16]
    frame[0] = left
    frame[1] = right
    discard gba_audio_dump_file.writeBuffer(addr frame[0], sizeof(frame))
    # Flush about once a second so an interrupted run leaves a readable dump
    inc gba_audio_dump_pending
    if gba_audio_dump_pending >= APU_SAMPLE_RATE:
      gba_audio_dump_pending = 0
      gba_audio_dump_file.flushFile()

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
  when not defined(emscripten):
    gba_audio_dump_claim()
  when defined(test_harness):
    result.audio_dev = 0
  elif defined(emscripten):
    result.audio_dev = 0
  else:
    var desired = SDL_AudioSpec(
      freq:     APU_SAMPLE_RATE.cint,
      format:   AUDIO_S16LSB,
      channels: APU_CHANNELS.uint8,
      # Device buffer much smaller than the push block: audio-sync pacing
      # (audio_ahead) can only release the next frame on a device drain step,
      # and 128 frames (3.9 ms) keeps the cadence within ~4 ms
      samples:  128,
      callback: nil,
      userdata: nil,
    )
    sdl_close_audio()
    # obtained must be nil: non-nil means SDL_AUDIO_ALLOW_ANY_CHANGE, and
    # Windows WASAPI then hands back float32 44.1/48 kHz with no conversion,
    # draining ~2x faster than queued and pacing emulation at ~2x
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
  ## Toggle the optional analog-output low-pass; the filter state is reset
  ## when off so a fresh enable never carries stale samples.
  if not on:
    apu.lp_left = 0
    apu.lp_right = 0
  apu.audio_lowpass = on

proc set_fifo_interp*(apu: APU; on: bool) =
  ## Toggle DirectSound FIFO reconstruction (cubic). Off emits the raw held
  ## latch. The phase state keeps updating either way (push_fifo_sample).
  apu.dma_channels.fifo_interp = on

proc set_pitch_correct_ff*(apu: APU; on: bool) =
  ## Toggle WSOLA pitch-preserving 2x; the stretcher resets on the
  ## stretch-path rising edge in get_sample.
  apu.pitch_correct_ff = on

proc ensure_stretch(apu: APU) {.inline, used.} =  # audio emit paths only, compiled out under test_harness
  ## Allocate/reset the stretcher when the pitch-correct path engages, so a
  ## fresh turbo never overlap-adds a stale buffer tail.
  if not apu.stretch_engaged:
    if apu.stretch == nil: apu.stretch = new_time_stretch()
    else: apu.stretch.reset()
    apu.stretch_engaged = true

proc audio_ahead*(apu: APU): bool =
  ## True when synced audio is buffered comfortably ahead of playback; the
  ## frontend paces emulation on this instead of blocking in get_sample.
  when defined(test_harness):
    false
  else:
    apu.sync and apu.audio_dev != 0 and
      sdl_get_queued_audio_size(apu.audio_dev) > APU_SYNC_AHEAD_BYTES

when not defined(test_harness) and not defined(emscripten):
  # DINGBAT_AUDIO_DUMP=<path>: exactly the bytes queued to SDL, raw s16le
  # stereo
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

# Lazy waveform catch-up (the four PSG channels): no per-period scheduler
# events; each channel carries a `next_step` deadline advanced in closed form
# at its observation points (design and math: gb/apu.nim "Lazy waveform
# catch-up"). GBA deltas: CH3's closed form adds a bank flip per 32-entry
# wrap; the observation points are the register block 0x60-0x84 plus wave
# RAM 0x90-0x9F, SOUNDCNT_X writes (sync all four), get_sample,
# RegisterRamReset's sound phase (apu_park_steps) and the per-frame rebase
# (gba.end_frame); no PCM12/34 pair and no double-speed switch, so the
# deadlines never rescale.

proc apu_catchup_all*(apu: APU) {.inline.} =
  ## Materialize all four channels at the current cycle (frame sequencer,
  ## SOUNDCNT_X writes, the per-frame rebase, save states).
  apu.channel1.ch1_catchup()
  apu.channel2.ch2_catchup()
  apu.channel3.ch3_catchup()
  apu.channel4.ch4_catchup()

proc apu_next_step*(apu: APU): CycleCount {.inline.} =
  ## Soonest pending waveform step across the four channels, or GBA_NO_STEP.
  ## These are scheduler events in all but name: anything that skips the
  ## clock forward on "nothing is scheduled until X" must treat them as
  ## scheduled (cpu.tick's waitloop path).
  result = apu.channel1.next_step
  if apu.channel2.next_step < result: result = apu.channel2.next_step
  if apu.channel3.next_step < result: result = apu.channel3.next_step
  if apu.channel4.next_step < result: result = apu.channel4.next_step

proc apu_rebase*(apu: APU; base: CycleCount) {.inline.} =
  ## Shift the channel deadlines by the base scheduler.rebase just subtracted.
  ## Callers must have caught the channels up first so nothing underflows.
  template adj(ch: untyped) =
    if ch.next_step != GBA_NO_STEP: ch.next_step -= base
  adj(apu.channel1)
  adj(apu.channel2)
  adj(apu.channel3)
  adj(apu.channel4)
  # FIFO latch timestamps are on the same clock (signed: one just before the
  # base may go slightly negative)
  apu.dma_channels.last_update_cycle[0] -= int64(base)
  apu.dma_channels.last_update_cycle[1] -= int64(base)

proc apu_park_steps*(apu: APU) =
  ## Drop every pending waveform step without applying it. Only
  ## RegisterRamReset's sound phase does this; it then rewrites the whole
  ## register block and nothing re-arms a channel until the next trigger.
  apu.channel1.next_step = GBA_NO_STEP
  apu.channel2.next_step = GBA_NO_STEP
  apu.channel3.next_step = GBA_NO_STEP
  apu.channel4.next_step = GBA_NO_STEP

proc timer_overflow*(apu: APU; timer: int) =
  apu.dma_channels.timer_overflow(timer)

proc tick_frame_sequencer*(apu: APU) =
  # sweep_step rewrites CH1's frequency (its step period), so every channel
  # has to be current first
  const OBS = uint32(FRAME_SEQ_PERIOD)
  apu.channel1.ch1_catchup_at(OBS)
  apu.channel2.ch2_catchup_at(OBS)
  apu.channel3.ch3_catchup_at(OBS)
  apu.channel4.ch4_catchup_at(OBS)
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
  # Gated on `enabled`: a disabled channel's amplitude is 0 regardless of
  # phase and the closed form replays the skipped steps later. NOT gated on
  # channel_mask (a debug mute): CH4's shift loop relies on the once-a-frame
  # bound.
  const OBS = uint32(APU_SAMPLE_PERIOD)
  if apu.channel1.enabled: apu.channel1.ch1_catchup_at(OBS)
  if apu.channel2.enabled: apu.channel2.ch2_catchup_at(OBS)
  if apu.channel3.enabled: apu.channel3.ch3_catchup_at(OBS)
  if apu.channel4.enabled: apu.channel4.ch4_catchup_at(OBS)
  let ch1 = if apu.channel_mask[0]: apu.channel1.ch1_get_amplitude() else: 0'i16
  let ch2 = if apu.channel_mask[1]: apu.channel2.ch2_get_amplitude() else: 0'i16
  let ch3 = if apu.channel_mask[2]: apu.channel3.ch3_get_amplitude() else: 0'i16
  let ch4 = if apu.channel_mask[3]: apu.channel4.ch4_get_amplitude() else: 0'i16
  # PSG volume, GBATEK SOUNDCNT_H bits 0-1: "0=25%, 1=50%, 2=100%,
  # 3=Prohibited". Value 3 is modelled as silence: Assumed (prohibited value).
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
  # MP2K HLE (mp2k.nim): substitute the shadow render for the FIFO A/B
  # latches (L->A, R->B) while the engine mixer is live and owns the stream;
  # SOUNDCNT_H routing below applies unchanged. mp2k_watch renders un-emitted
  # for on_frame's unlatch test; both accumulate the real-vs-shadow energies.
  let mp2k_subst = apu.gba.mp2k_hle and apu.gba.mp2k != nil and
                   apu.gba.mp2k.engaged and not apu.gba.mp2k.fifo_foreign and
                   apu.gba.mp2k.mixer_live
  let mp2k_watch = apu.gba.mp2k_hle and apu.gba.mp2k != nil and
                   apu.gba.mp2k.engaged and apu.gba.mp2k.fifo_foreign and
                   apu.gba.mp2k.mixer_live and apu.gba.mp2k.unlatch_watch
  when defined(mp2kwav):
    # The game's own FIFO output for A/B calibration, gated on the same
    # predicate as the HLE capture so both cover the same span; with the HLE
    # disabled capture the whole run
    if not (apu.gba.mp2k_hle and apu.gba.mp2k != nil) or mp2k_subst or
       mp2k_watch or (apu.gba.gs_bon != nil and apu.gba.gs_bon.engaged):
      realDmaCapture.add raw_dma_a
      realDmaCapture.add raw_dma_b
  if mp2k_subst:
    let (hl, hr) = apu.gba.mp2k.render_sample()
    let m = apu.gba.mp2k
    m.real_abs_a += int64(abs(int(raw_dma_a)))
    m.real_abs_b += int64(abs(int(raw_dma_b)))
    m.hle_abs_l  += int64(abs(int(hl)))
    m.hle_abs_r  += int64(abs(int(hr)))
    inc m.ab_n
    if m.overlay_hold > 0:
      # Overlay passthrough (on_frame): emit the real stream, keep rendering
      when defined(mp2kwav):
        # The capture reflects what is actually emitted
        if mp2kWavCapture.len >= 2:
          mp2kWavCapture[mp2kWavCapture.len - 2] = raw_dma_a
          mp2kWavCapture[mp2kWavCapture.len - 1] = raw_dma_b
    else:
      raw_dma_a = hl
      raw_dma_b = hr
  elif mp2k_watch:
    let m = apu.gba.mp2k
    let (hl, hr) = m.render_sample()
    m.real_abs_a += int64(abs(int(raw_dma_a)))
    m.real_abs_b += int64(abs(int(raw_dma_b)))
    m.hle_abs_l  += int64(abs(int(hl)))
    m.hle_abs_r  += int64(abs(int(hr)))
    inc m.ab_n
    when defined(mp2kwav):
      # The capture reflects what is actually emitted (the real stream)
      if mp2kWavCapture.len >= 2:
        mp2kWavCapture[mp2kWavCapture.len - 2] = raw_dma_a
        mp2kWavCapture[mp2kWavCapture.len - 1] = raw_dma_b
  # Camelot "Bon" HLE (Golden Sun): same substitution for its own engine
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
  # SOUNDBIAS bits 14-15 "Amplitude Resolution/Sampling Cycle" (GBATEK):
  # "0 9bit/32.768kHz, 1 8bit/65.536kHz, 2 7bit/131.072kHz, 3 6bit/262.144kHz".
  # Modelled by masking the low `res` bits of the biased 10-bit sum (res=0
  # masks nothing); GBATEK's 9-bit output is that sum halved, so the model
  # keeps one more bit than the table at each step. Assumed (inaudible).
  let dac_mask = int32(0x3FF) and
                 not int32((1 shl int(apu.soundbias.amplitude_resolution)) - 1)
  # Stop mode halts the system clock, so the DAC produces no fresh output
  # (GBATEK: entering Stop stops sound; Golden Sun leaves SOUNDCNT_X enabled
  # and relies on it). Only the output is gated; the scheduler keeps running
  # for the keypad wake IRQ.
  let stopped = apu.gba.cpu.stopped
  let total_left  = if stopped: 0'i16 else: int16((max(0, min(0x3FF, psg_left  + dma_left  + bias)) and dac_mask) - bias)
  let total_right = if stopped: 0'i16 else: int16((max(0, min(0x3FF, psg_right + dma_right + bias)) and dac_mask) - bias)
  when not defined(emscripten):
    # Before the output switch: the test_harness branch drops the sample
    if gba_audio_dump_on: gba_audio_dump_write(total_left, total_right)
  when defined(test_harness):
    discard
  elif defined(emscripten):
    let sl = float32(total_left * 32) / 32768.0'f32
    let sr = float32(total_right * 32) / 32768.0'f32
    if not apu.turbo:
      # 1x: passthrough, never through the stretcher
      apu.stretch_engaged = false
      appendAudioSample(sl, sr)
    elif apu.pitch_correct_ff:
      # Pitch-correct 2x: feed every frame into WSOLA, pull on every other
      # call so the emitted count (and pacing) matches plain decimation
      apu.ensure_stretch()
      apu.stretch.push(sl, sr)
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        let (ol, orr) = apu.stretch.pull()
        appendAudioSample(ol, orr)
    else:
      # 2x, pitch-correct off: every-other-sample decimation (octave up)
      apu.stretch_engaged = false
      apu.turbo_parity = not apu.turbo_parity
      if apu.turbo_parity:
        appendAudioSample(sl, sr)
  else:
    var out_l = total_left  * 32
    var out_r = total_right * 32
    if apu.audio_lowpass:
      # One-pole low-pass (~12 kHz corner) modeling the cap/speaker smoothing
      apu.lp_left  += AUDIO_LOWPASS_ALPHA * (float32(out_l) - apu.lp_left)
      apu.lp_right += AUDIO_LOWPASS_ALPHA * (float32(out_r) - apu.lp_right)
      out_l = int16(clamp(apu.lp_left,  -32768.0'f32, 32767.0'f32))
      out_r = int16(clamp(apu.lp_right, -32768.0'f32, 32767.0'f32))
    apu.buffer[apu.buffer_pos]     = out_l
    apu.buffer[apu.buffer_pos + 1] = out_r
    apu.buffer_pos += 2
    if apu.buffer_pos >= APU_BUFFER_SIZE:
      # Master volume at the queue point. Muting still queues zeroed samples:
      # pacing is driven by the SDL queue depth
      if apu.master_muted:
        for i in 0 ..< APU_BUFFER_SIZE:
          apu.buffer[i] = 0'i16
      elif apu.master_volume_factor != 256:
        let vf = apu.master_volume_factor
        for i in 0 ..< APU_BUFFER_SIZE:
          apu.buffer[i] = int16(int32(apu.buffer[i]) * vf shr 8)
      # 2x speed: emit half the frames so audio-driven pacing runs emulation
      # twice as fast — WSOLA (pitch_correct_ff) or every other frame; both
      # emit exactly APU_BUFFER_SIZE/2 int16
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
  # Only wave RAM needs a sync (it resolves against wave_ram_position while
  # CH3 is enabled); no catch-up ever writes `enabled`
  if io_addr >= WAVE_RAM_LOW and io_addr <= WAVE_RAM_HIGH:
    apu.channel3.ch3_catchup()
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
  # Materialize the target channel BEFORE the write lands, so a period /
  # duty / bank / trigger change only affects steps from this cycle on
  if ch1_in_range(io_addr):      apu.channel1.ch1_catchup()
  elif ch2_in_range(io_addr):    apu.channel2.ch2_catchup()
  elif ch3_in_range(io_addr):    apu.channel3.ch3_catchup()
  elif ch4_in_range(io_addr):    apu.channel4.ch4_catchup()
  elif io_addr == 0x84:
    # SOUNDCNT_X: sync all four so the power-on reset does not depend on the
    # power-off arm's recursion through the branches above
    apu.apu_catchup_all()
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
        apu.dma_channels.inv_period[0] = 0.0'f32
      if bit(value, 7):  # FIFO B reset
        for i in 0..31: apu.dma_channels.fifos[1][i] = 0
        apu.dma_channels.positions[1] = 0
        apu.dma_channels.sizes[1] = 0
        apu.dma_channels.latches[1] = 0
        apu.dma_channels.hist[1] = [0'i16, 0, 0, 0]
        apu.dma_channels.inv_period[1] = 0.0'f32
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
