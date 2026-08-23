# APU Channel 1 (Square + sweep) (included by gba.nim)

const WAVE_DUTY_CH1*: array[4, array[8, int]] = [
  [-8, -8, -8, -8, -8, -8, -8, +8],  # 12.5%
  [+8, -8, -8, -8, -8, -8, -8, +8],  # 25%
  [+8, -8, -8, -8, -8, +8, +8, +8],  # 50%
  [-8, +8, +8, +8, +8, +8, +8, -8],  # 75%
]

const RANGE_CH1_LOW*  = 0x60'u32
const RANGE_CH1_HIGH* = 0x67'u32

proc ch1_in_range*(address: uint32): bool =
  address >= RANGE_CH1_LOW and address <= RANGE_CH1_HIGH

proc new_channel1*(gba: GBA): Channel1 =
  Channel1(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    starting_volume: 0, envelope_add_mode: false, period_ve: 0,
    volume_envelope_timer: 0, current_volume: 0, volume_envelope_is_updating: false,
    wave_duty_position: 0,
    sweep_period: 0, negate: false, shift_ch1: 0,
    sweep_timer: 0, frequency_shadow: 0, sweep_enabled: false, negate_has_been_used: false,
    duty: 0, length_load: 0, frequency_ch1: 0,
    next_step: GBA_NO_STEP, arm_delay: 0,
  )

proc ch1_frequency_timer*(ch: Channel1): uint32 =
  (0x800'u32 - uint32(ch.frequency_ch1)) * 4 * 4

proc ch1_catchup_slow(ch: Channel1; observer_period: uint32) =
  let now    = ch.gba.scheduler.cycles
  let period = CycleCount(ch.ch1_frequency_timer())
  # next_step is the absolute cycle of the FIRST pending step; every later step
  # is one CURRENT period apart, even across a frequency write (gba_steps_due).
  let steps = gba_steps_due(now - ch.next_step, period, ch.arm_delay,
                            observer_period)
  if steps == 0: return
  when defined(psgverify):
    var want = ch.wave_duty_position
    for _ in 0 ..< steps: want = (want + 1) and 7
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  when defined(psgverify):
    doAssert want == ch.wave_duty_position, "ch1 closed form != naive loop"
  ch.next_step += steps * period
  # The step now pending was armed by the one before it, i.e. one CURRENT
  # period ago.
  ch.arm_delay = uint32(period)

proc ch1_catchup_at*(ch: Channel1; observer_period: uint32) {.inline.} =
  ## Bring wave_duty_position up to scheduler.cycles in closed form (mod-8
  ## counter: (pos + N) and 7). Must run before anything observes the duty
  ## position or changes the period (observation points: apu.nim).
  ## observer_period (GBA_OBS_CPU for MMIO) only matters for a step landing on
  ## this exact cycle.
  if ch.next_step > ch.gba.scheduler.cycles: return   # not due (or parked)
  ch1_catchup_slow(ch, observer_period)

proc ch1_catchup*(ch: Channel1) {.inline.} =
  ch1_catchup_at(ch, GBA_OBS_CPU)

proc ch1_frequency_calculation*(ch: Channel1): uint16 =
  let shifted    = ch.frequency_shadow shr ch.shift_ch1
  var calculated = uint32(ch.frequency_shadow) + uint32(if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_has_been_used = true
  if calculated > 0x07FF: ch.enabled = false
  uint16(calculated)

proc sweep_step*(ch: Channel1) =
  # tick_frame_sequencer caught the duty counter up first: this can change
  # frequency_ch1, and elapsed cycles must be priced with the old period.
  if ch.sweep_timer > 0: ch.sweep_timer -= 1
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calculated = ch.ch1_frequency_calculation()
      if calculated <= 0x07FF and ch.shift_ch1 > 0:
        ch.frequency_shadow = calculated
        ch.frequency_ch1    = calculated
        discard ch.ch1_frequency_calculation()

proc ch1_get_amplitude*(ch: Channel1): int16 =
  if ch.enabled and ch.dac_enabled:
    int16(WAVE_DUTY_CH1[ch.duty][ch.wave_duty_position]) * int16(ch.current_volume)
  else:
    0'i16

proc ch1_read*(ch: Channel1; address: uint32): uint8 =
  case address
  of 0x60: (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift_ch1
  of 0x62: ch.duty shl 6
  of 0x63: ch.read_nrx2()
  of 0x65: (if ch.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc ch1_write*(ch: Channel1; address: uint32; value: uint8) =
  # apu[]= caught the duty counter up to the current cycle before getting here,
  # so a period/duty/trigger change below only affects steps from now on.
  case address
  of 0x60:
    ch.sweep_period = (value and 0x70) shr 4
    ch.negate       = (value and 0x08) > 0
    ch.shift_ch1    = value and 0x07
    if not ch.negate and ch.negate_has_been_used: ch.enabled = false
  of 0x61: discard
  of 0x62:
    ch.duty         = (value and 0xC0) shr 6
    ch.length_load  = value and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0x63: ch.write_nrx2(value)
  of 0x64: ch.frequency_ch1 = (ch.frequency_ch1 and 0x0700'u16) or uint16(value)
  of 0x65:
    ch.frequency_ch1 = (ch.frequency_ch1 and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    let triggered = (value and 0x80) > 0
    if triggered and ch.dac_enabled: ch.enabled = true
    ch.agb_length_on_nrx4(length_enable, triggered, 0x40)
    if triggered:
      # Re-arm a full period from now. The duty POSITION carries across a
      # trigger (Pan Docs: only APU power-off resets it), hence catch-up
      # rather than park.
      let arm1 = ch.ch1_frequency_timer()
      ch.next_step = ch.gba.scheduler.cycles + CycleCount(arm1)
      ch.arm_delay = arm1
      ch.init_volume_envelope()
      ch.frequency_shadow     = ch.frequency_ch1
      ch.sweep_timer          = if ch.sweep_period > 0: ch.sweep_period else: 8
      ch.sweep_enabled        = ch.sweep_period > 0 or ch.shift_ch1 > 0
      ch.negate_has_been_used = false
      if ch.shift_ch1 > 0:
        # The trigger overflow check runs TWICE (hardware: gbaedge SWEEPQ page
        # on AGS): shadow + offset, then the SAME offset again on that result
        # without writing it back, killing the channel iff > 2048 STRICTLY
        # (freq 1024 survives: 1536, 2048).
        let offset = int(ch.frequency_shadow shr ch.shift_ch1)
        let signed_off = if ch.negate: -offset else: offset
        if ch.negate: ch.negate_has_been_used = true
        let first = int(ch.frequency_shadow) + signed_off
        if first > 0x7FF or first + signed_off > 2048:
          ch.enabled = false
  of 0x66, 0x67: discard
  else: echo "Writing to invalid Channel1 register: ", hex_str(uint16(address))
