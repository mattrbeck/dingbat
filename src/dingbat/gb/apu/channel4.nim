# GB APU Channel 4 - LFSR Noise (included by gb.nim)

proc new_channel4*(gb: GB): GbChannel4 =
  GbChannel4(enabled: false, dac_enabled: false, length_counter: 0,
             next_step: GB_NO_STEP)

proc ch4_frequency_timer(ch: GbChannel4): uint32 =
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift

proc ch4_period(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  CycleCount(ch4_frequency_timer(ch)) shl gb.scheduler.speed

proc ch4_shift(ch: GbChannel4) {.inline.} =
  let new_bit = (ch.lfsr and 0b01'u16) xor ((ch.lfsr and 0b10'u16) shr 1)
  ch.lfsr = ch.lfsr shr 1
  ch.lfsr = ch.lfsr or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = ch.lfsr and not (1'u16 shl 6)
    ch.lfsr = ch.lfsr or (new_bit shl 6)

proc ch4_catchup_slow(ch: GbChannel4; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch4_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  # steps == 0 means the tie went to the observer, so nothing has happened yet
  # -- checking `enabled` before this would park the channel a step early.
  if steps == 0: return
  # A disabled channel's chain dies after ONE more step: the old ch4_step did
  # the shift unconditionally and only the RESCHEDULE was gated on `enabled`.
  # Every path that clears ch4.enabled (length_step via the frame sequencer,
  # write_NRx2's DAC check, NR52 power-off) catches this channel up first, so
  # next_step is always past the moment of disabling when we get here.
  if not ch.enabled:
    ch4_shift(ch)
    ch.next_step = GB_NO_STEP
    return
  # The LFSR has no cheap closed form (Gambatte exploits reg^(reg>>1) == 15
  # shifts; not worth the divergence risk here), so this still iterates. The
  # win is that it iterates in a tight loop instead of paying a scheduler
  # insert + heap pop + closure dispatch per shift. Bounded because
  # apu_catchup_all runs at every frame boundary, so at most one frame of
  # shifts (<= 8778 at the shortest divisor) can accumulate -- exactly the
  # number the old event chain would have run anyway.
  for _ in 0 ..< steps: ch4_shift(ch)
  ch.next_step += steps * period

proc ch4_catchup_at*(ch: GbChannel4; gb: GB; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at. Unlike the other three this is O(steps), not O(1).
  if ch.next_step > gb.scheduler.cycles: return
  ch4_catchup_slow(ch, gb, observer_period)

proc ch4_catchup*(ch: GbChannel4; gb: GB) {.inline.} =
  ch4_catchup_at(ch, gb, GB_OBS_CPU)

proc ch4_get_amplitude*(ch: GbChannel4): float32 =
  if ch.enabled and ch.dac_enabled:
    let dac_in = int(not ch.lfsr and 1'u16) * int(ch.current_volume)
    float32(float64(dac_in) / 7.5 - 1.0)
  else: 0.0'f32

proc ch4_read*(ch: GbChannel4; idx: int): uint8 =
  case idx
  of 0xFF20: 0xFF'u8
  of 0xFF21: read_NRx2(ch)
  of 0xFF22: (ch.clock_shift shl 4) or (ch.width_mode shl 3) or ch.divisor_code
  of 0xFF23: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch4_write*(ch: GbChannel4; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF20:
    ch.length_load    = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0xFF21:
    write_NRx2(ch, val)
  of 0xFF22:
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
  of 0xFF23:
    let len_enable = (val and 0x40) != 0
    if gb.apu.first_half_of_length_period and not ch.length_enable and len_enable and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      ch.next_step = gb.scheduler.cycles + ch4_period(ch, gb)
      init_volume_envelope(ch)
      ch.lfsr = 0x7FFF'u16
  else: discard
