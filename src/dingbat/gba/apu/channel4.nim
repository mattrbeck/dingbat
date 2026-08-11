# APU Channel 4 (Noise) (included by gba.nim)

const RANGE_CH4_LOW*  = 0x78'u32
const RANGE_CH4_HIGH* = 0x7F'u32

proc ch4_in_range*(address: uint32): bool =
  address >= RANGE_CH4_LOW and address <= RANGE_CH4_HIGH

proc new_channel4*(gba: GBA): Channel4 =
  Channel4(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    starting_volume: 0, envelope_add_mode: false, period_ve: 0,
    volume_envelope_timer: 0, current_volume: 0, volume_envelope_is_updating: false,
    lfsr: 0,
    length_load_ch4: 0,
    clock_shift: 0, width_mode: 0, divisor_code: 0,
    next_step: GBA_NO_STEP, arm_delay: 0,
  )

proc ch4_shift(ch: Channel4) {.inline.} =
  let new_bit = uint16(ch.lfsr and 0b01) xor uint16((ch.lfsr and 0b10) shr 1)
  ch.lfsr = ch.lfsr shr 1
  ch.lfsr = ch.lfsr or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = ch.lfsr and not (1'u16 shl 6)
    ch.lfsr = ch.lfsr or (new_bit shl 6)

proc ch4_frequency_timer*(ch: Channel4): uint32 =
  ((if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift) * 4

proc ch4_catchup_slow(ch: Channel4; observer_period: uint32) =
  let now    = ch.gba.scheduler.cycles
  let period = CycleCount(ch.ch4_frequency_timer())
  let steps = gba_steps_due(now - ch.next_step, period, ch.arm_delay,
                            observer_period)
  if steps == 0: return
  # Unlike the other three this is O(steps): the LFSR has no cheap closed form.
  # The win is that it iterates in a tight loop instead of paying a scheduler
  # insert + heap pop + closure dispatch per shift — and that the scheduler's
  # event horizon is no longer pinned at 32 cycles, which is what defeated
  # HALT/fast_forward and bus.catch_up. Bounded because end_frame catches every
  # channel up, so at most one frame of shifts (<= 8778 at the power-on
  # divisor) can accumulate — exactly the number the old event chain ran anyway.
  #
  # NOTE the old ch4_step re-armed UNCONDITIONALLY, not gated on `enabled` the
  # way the GB core's did, so there is no park-when-disabled case to model here:
  # once triggered, this chain runs until RegisterRamReset or a re-trigger.
  for _ in 0 ..< steps: ch4_shift(ch)
  ch.next_step += steps * period
  # The step now pending was armed by the one before it, i.e. one CURRENT
  # period ago.
  ch.arm_delay = uint32(period)

proc ch4_catchup_at*(ch: Channel4; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at. O(steps), not O(1).
  if ch.next_step > ch.gba.scheduler.cycles: return
  ch4_catchup_slow(ch, observer_period)

proc ch4_catchup*(ch: Channel4) {.inline.} =
  ch4_catchup_at(ch, GBA_OBS_CPU)

proc ch4_get_amplitude*(ch: Channel4): int16 =
  if ch.enabled and ch.dac_enabled:
    (int16(not ch.lfsr and 1) * 16 - 8) * int16(ch.current_volume)
  else:
    0'i16

proc ch4_read*(ch: Channel4; address: uint32): uint8 =
  case address
  of 0x79: ch.read_nrx2()
  of 0x7C: (ch.clock_shift shl 4) or (ch.width_mode shl 3) or ch.divisor_code
  of 0x7D: (if ch.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc ch4_write*(ch: Channel4; address: uint32; value: uint8) =
  # apu[]= caught the LFSR up first, so a divisor/shift/width/trigger change
  # below only affects shifts from now on.
  case address
  of 0x78:
    ch.length_load_ch4  = value and 0x3F
    ch.length_counter   = 0x40 - int(ch.length_load_ch4)
  of 0x79: ch.write_nrx2(value)
  of 0x7A, 0x7B: discard
  of 0x7C:
    ch.clock_shift   = value shr 4
    ch.width_mode    = (value and 0x08) shr 3
    ch.divisor_code  = value and 0x07
  of 0x7D:
    let length_enable = (value and 0x40) > 0
    let triggered = (value and 0x80) > 0
    if triggered and ch.dac_enabled: ch.enabled = true
    ch.agb_length_on_nrx4(length_enable, triggered, 0x40)  # AGB order; see abstract_channels
    if triggered:
      # Same as clear(etAPUChannel4) + schedule(period); see ch1_write.
      let arm4 = ch.ch4_frequency_timer()
      ch.next_step = ch.gba.scheduler.cycles + CycleCount(arm4)
      ch.arm_delay = arm4
      ch.init_volume_envelope()
      ch.lfsr = 0x7FFF'u16
  of 0x7E, 0x7F: discard
  else: echo "Writing to invalid Channel4 register: ", hex_str(uint16(address))
