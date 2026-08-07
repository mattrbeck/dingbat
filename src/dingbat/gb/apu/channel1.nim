# GB APU Channel 1 - Square wave with frequency sweep (included by gb.nim)

const WAVE_DUTY1: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],  # 12.5%
  [1'u8, 0, 0, 0, 0, 0, 0, 1],  # 25%
  [1'u8, 0, 0, 0, 0, 1, 1, 1],  # 50%
  [0'u8, 1, 1, 1, 1, 1, 1, 0],  # 75%
]

proc new_channel1*(gb: GB): GbChannel1 =
  GbChannel1(enabled: false, dac_enabled: false, length_counter: 0,
             sweep_period: 0, next_step: GB_NO_STEP)

proc ch1_frequency_timer(ch: GbChannel1): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4

proc ch1_period(ch: GbChannel1; gb: GB): CycleCount {.inline.} =
  ## Duty-step period in SCHEDULER cycles (schedule_gb scaled every APU delay
  ## by the speed shift, so the deadline arithmetic has to as well).
  CycleCount(ch1_frequency_timer(ch)) shl gb.scheduler.speed

proc ch1_catchup_slow(ch: GbChannel1; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch1_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  # next_step is the absolute cycle of the FIRST pending step, so every step
  # after it is one period apart -- which is also true across a mid-flight
  # NR13/NR14 frequency write, because the old event would have fired at its
  # already-set target and only then reloaded with the new period.
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  if steps == 0: return
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  # Only the LAST step's bit matters: ch.duty is immutable between catch-ups
  # (an NR11 write catches the channel up first), so the intermediate latches a
  # per-step loop would do are all overwritten. Same argument as CH3's sample
  # buffer. Latching here rather than reading the table in ch1_dac_input is
  # what makes a duty change take effect only from the next sample on, and what
  # holds the pre-trigger sample through the startup delay.
  ch.sample_bit = WAVE_DUTY1[ch.duty][ch.wave_duty_position]
  ch.next_step += steps * period

proc ch1_catchup_at*(ch: GbChannel1; gb: GB; observer_period: uint32) {.inline.} =
  ## Bring wave_duty_position up to gb.scheduler.cycles. Closed form: while the
  ## channel is on the duty counter free-runs mod 8, so N periods of advance is
  ## (pos + N) and 7 -- no iteration, and cost independent of the frequency.
  ## Must be called before anything that can observe the duty position or
  ## change the period; see the observation-point list in apu.nim.
  ## observer_period is the caller's own T-cycle period (GB_OBS_CPU for a CPU
  ## access) and only affects a step landing on this exact cycle.
  if not ch.enabled:
    # The duty counter is clocked only while the channel is ON. Switching it
    # off freezes the phase where it stands -- SameSuite channel_1_stop_restart:
    # "even after stopping the channel, the current sample index/phase remains
    # unchanged. It is only reset by turning the APU off (NR52)." Parking the
    # deadline rather than merely skipping the advance keeps it from going stale
    # enough to underflow apu_rebase; the only route back on is a trigger, and
    # that re-arms next_step from the current cycle anyway.
    ch.next_step = GB_NO_STEP
    return
  if ch.next_step > gb.scheduler.cycles: return   # not due (or never triggered)
  ch1_catchup_slow(ch, gb, observer_period)

proc ch1_catchup*(ch: GbChannel1; gb: GB) {.inline.} =
  ch1_catchup_at(ch, gb, GB_OBS_CPU)

proc ch1_frequency_calc(ch: GbChannel1): uint16 =
  let shifted = ch.frequency_shadow shr ch.shift
  var calc = int(ch.frequency_shadow) + (if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calc > 0x07FF: ch.enabled = false
  result = uint16(calc and 0x7FFF)

proc sweep_step*(ch: GbChannel1; gb: GB) =
  # The caller (tick_frame_sequencer) has already caught the duty counter up:
  # this can change ch.frequency, and the catch-up period must be the one that
  # was in force for the cycles being collapsed.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calc = ch1_frequency_calc(ch)
      if calc <= 0x07FF and ch.shift > 0:
        ch.frequency_shadow = calc
        ch.frequency         = calc
        discard ch1_frequency_calc(ch)

proc ch1_dac_input*(ch: GbChannel1): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC. This is what the CGB's
  ## PCM12 register exposes; 0 while the channel is off. Masked to four bits
  ## because it indexes GB_DAC_LUT: emulation cannot produce a volume above 15,
  ## but a hand-edited or truncated save state can, and that must not become an
  ## out-of-bounds read.
  if ch.enabled and ch.dac_enabled:
    uint8(int(ch.sample_bit) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc ch1_get_amplitude*(ch: GbChannel1): float32 =
  ## Analog output. Gated on the DAC alone, NOT on `enabled`: a switched-off
  ## channel feeds digital 0 to a still-powered DAC, which is analog +1, not
  ## silence. Only a disabled DAC leaves analog 0. See GB_DAC_LUT.
  if ch.dac_enabled: GB_DAC_LUT[ch.ch1_dac_input()] else: 0.0'f32

proc ch1_read*(ch: GbChannel1; idx: int): uint8 =
  case idx
  of 0xFF10: 0x80'u8 or (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift
  of 0xFF11: 0x3F'u8 or (ch.duty shl 6)
  of 0xFF12: read_NRx2(ch)
  of 0xFF13: 0xFF'u8  # write-only
  of 0xFF14: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch1_write*(ch: GbChannel1; idx: int; val: uint8; gb: GB) =
  # apu_write caught the duty counter up to the current cycle before getting
  # here, so a period/duty change below only affects steps from now on.
  case idx
  of 0xFF10:
    ch.sweep_period = (val and 0x70) shr 4
    ch.negate       = (val and 0x08) != 0
    ch.shift        = val and 0x07
    if not ch.negate and ch.negate_used: ch.enabled = false
  of 0xFF11:
    ch.duty         = (val and 0xC0) shr 6
    ch.length_load  = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0xFF12:
    write_NRx2(ch, val)
  of 0xFF13:
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
  of 0xFF14:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    let len_enable = (val and 0x40) != 0
    if gb.apu.first_half_of_length_period and not ch.length_enable and len_enable and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:  # trigger
      let was_enabled = ch.enabled
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      # The duty POSITION deliberately carries across a trigger (hardware only
      # resets it when the APU is powered off) -- which is why the phase has to
      # be caught up rather than parked -- and so does the LATCHED sample: a
      # channel that was off was latching 0, so it emits nothing until its
      # first duty step, which is the pulse analogue of CH3's documented
      # "triggering does not immediately start playing wave RAM".
      if not was_enabled: ch.sample_bit = 0
      ch.next_step = gb_trigger_deadline(gb, ch1_period(ch, gb),
                                         if was_enabled: 1 else: 2)
      init_volume_envelope(ch)
      ch.frequency_shadow = ch.frequency
      ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
      ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
      ch.negate_used      = false
      if ch.shift > 0: discard ch1_frequency_calc(ch)
  else: discard
