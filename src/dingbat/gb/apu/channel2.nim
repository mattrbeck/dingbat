# GB APU Channel 2 - Square wave (included by gb.nim)

const WAVE_DUTY2: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],
  [1'u8, 0, 0, 0, 0, 0, 0, 1],
  [1'u8, 0, 0, 0, 0, 1, 1, 1],
  [0'u8, 1, 1, 1, 1, 1, 1, 0],
]

proc new_channel2*(gb: GB): GbChannel2 =
  GbChannel2(enabled: false, dac_enabled: false, length_counter: 0,
             next_step: GB_NO_STEP, last_step_at: GB_NO_STEP)

proc ch2_frequency_timer(ch: GbChannel2): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4

proc ch2_period(ch: GbChannel2; gb: GB): CycleCount {.inline.} =
  CycleCount(ch2_frequency_timer(ch)) shl gb.scheduler.speed

proc ch2_catchup_slow(ch: GbChannel2; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch2_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  if steps == 0: return
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  # see ch1_catchup_slow
  ch.sample_bit = WAVE_DUTY2[ch.duty][ch.wave_duty_position]
  ch.next_step += steps * period
  ch.last_step_at = ch.next_step - period

proc ch2_catchup_at*(ch: GbChannel2; gb: GB; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at.
  if not ch.enabled:
    ch.next_step = GB_NO_STEP
    return
  if ch.next_step > gb.scheduler.cycles: return
  ch2_catchup_slow(ch, gb, observer_period)

proc ch2_catchup*(ch: GbChannel2; gb: GB) {.inline.} =
  ch2_catchup_at(ch, gb, GB_OBS_CPU)

proc ch2_reload_is_now(ch: GbChannel2; gb: GB): bool {.inline.} =
  ## See ch1_reload_is_now. No channel_2 build of freq_change_timing exists;
  ## mirrored because CH2 is the same duty hardware as CH1 minus the sweep.
  ch.enabled and ch.last_step_at == gb.scheduler.cycles

proc ch2_dac_input*(ch: GbChannel2): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC — see ch1_dac_input.
  if ch.enabled and ch.dac_enabled:
    uint8(int(ch.sample_bit) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc ch2_pcm_edge_zero*(ch: GbChannel2; gb: GB): bool {.inline.} =
  ## See ch1_pcm_edge_zero, mirrored for the same duty hardware; no channel_2
  ## build of the ROM measures it. Assumed; no ROM pins this.
  ch.enabled and ch.dac_enabled and ch.last_step_at == gb.scheduler.cycles and
    int(WAVE_DUTY2[ch.duty][(ch.wave_duty_position + 7) and 7]) *
      int(ch.current_volume) == 0

proc ch2_get_amplitude*(ch: GbChannel2): float32 =
  ## See ch1_get_amplitude: DAC-gated, and the slope is negative.
  if ch.dac_enabled: GB_DAC_LUT[ch.ch2_dac_input()] else: 0.0'f32

proc ch2_read*(ch: GbChannel2; idx: int): uint8 =
  case idx
  of 0xFF16: 0x3F'u8 or (ch.duty shl 6)
  of 0xFF17: read_NRx2(ch)
  of 0xFF18: 0xFF'u8
  of 0xFF19: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch2_write*(ch: GbChannel2; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF16:
    ch.duty         = (val and 0xC0) shr 6
    ch.length_load  = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0xFF17:
    write_NRx2(ch, val)
  of 0xFF18:
    let reload_now = ch2_reload_is_now(ch, gb)
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
    if reload_now: ch.next_step = gb.scheduler.cycles + ch2_period(ch, gb)
  of 0xFF19:
    let reload_now = ch2_reload_is_now(ch, gb)
    # CGB D/E's extra half-tick backstep window; see the same arm in ch1_write.
    if gb.quirks.square_freq_backstep_halftick and (val and 0x80) == 0 and
       ch.enabled and (ch.frequency and 0x0700'u16) == 0x0700'u16 and
       (val and 0x07) != 0x07 and not reload_now and
       ch.last_step_at != GB_NO_STEP and
       gb.scheduler.cycles - ch.last_step_at == gb_apu_tick(gb) div 2:
      # Only the position moves; the latched sample stays (see ch1_write).
      ch.wave_duty_position = (ch.wave_duty_position + 7) and 7
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    if reload_now: ch.next_step = gb.scheduler.cycles + ch2_period(ch, gb)
    let len_enable = (val and 0x40) != 0
    # length_clock_any_nrx4: CGB 0 / A-B clock length on any NRx4 write, not
    # only one turning it on (GbQuirks).
    if gb.apu.first_half_of_length_period and not ch.length_enable and
       (len_enable or gb.quirks.length_clock_any_nrx4) and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:
      let was_enabled = ch.enabled          # see ch1_write's trigger arm
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      if not was_enabled: ch.sample_bit = 0
      ch.next_step = gb_trigger_deadline(gb, ch2_period(ch, gb),
                                         if was_enabled: 1 else: 2)
      init_volume_envelope(ch)
  else: discard
