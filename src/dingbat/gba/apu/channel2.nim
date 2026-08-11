# APU Channel 2 (Square, no sweep) (included by gba.nim)

const WAVE_DUTY_CH2*: array[4, array[8, int]] = [
  [-8, -8, -8, -8, -8, -8, -8, +8],
  [+8, -8, -8, -8, -8, -8, -8, +8],
  [+8, -8, -8, -8, -8, +8, +8, +8],
  [-8, +8, +8, +8, +8, +8, +8, -8],
]

const RANGE_CH2_LOW*  = 0x68'u32
const RANGE_CH2_HIGH* = 0x6F'u32

proc ch2_in_range*(address: uint32): bool =
  address >= RANGE_CH2_LOW and address <= RANGE_CH2_HIGH

proc new_channel2*(gba: GBA): Channel2 =
  Channel2(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    starting_volume: 0, envelope_add_mode: false, period_ve: 0,
    volume_envelope_timer: 0, current_volume: 0, volume_envelope_is_updating: false,
    wave_duty_position: 0,
    duty: 0, length_load: 0, frequency_ch2: 0,
    next_step: GBA_NO_STEP, arm_delay: 0,
  )

proc ch2_frequency_timer*(ch: Channel2): uint32 =
  (0x800'u32 - uint32(ch.frequency_ch2)) * 4 * 4

proc ch2_catchup_slow(ch: Channel2; observer_period: uint32) =
  let now    = ch.gba.scheduler.cycles
  let period = CycleCount(ch.ch2_frequency_timer())
  let steps = gba_steps_due(now - ch.next_step, period, ch.arm_delay,
                            observer_period)
  if steps == 0: return
  when defined(psgverify):
    var want = ch.wave_duty_position
    for _ in 0 ..< steps: want = (want + 1) and 7
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  when defined(psgverify):
    doAssert want == ch.wave_duty_position, "ch2 closed form != naive loop"
  ch.next_step += steps * period
  # The step now pending was armed by the one before it, i.e. one CURRENT
  # period ago.
  ch.arm_delay = uint32(period)

proc ch2_catchup_at*(ch: Channel2; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at.
  if ch.next_step > ch.gba.scheduler.cycles: return
  ch2_catchup_slow(ch, observer_period)

proc ch2_catchup*(ch: Channel2) {.inline.} =
  ch2_catchup_at(ch, GBA_OBS_CPU)

proc ch2_get_amplitude*(ch: Channel2): int16 =
  if ch.enabled and ch.dac_enabled:
    int16(WAVE_DUTY_CH2[ch.duty][ch.wave_duty_position]) * int16(ch.current_volume)
  else:
    0'i16

proc ch2_read*(ch: Channel2; address: uint32): uint8 =
  case address
  of 0x68: ch.duty shl 6
  of 0x69: ch.read_nrx2()
  of 0x6D: (if ch.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc ch2_write*(ch: Channel2; address: uint32; value: uint8) =
  # apu[]= caught the duty counter up first; see ch1_write.
  case address
  of 0x68:
    ch.duty        = (value and 0xC0) shr 6
    ch.length_load = value and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0x69: ch.write_nrx2(value)
  of 0x6A, 0x6B: discard
  of 0x6C: ch.frequency_ch2 = (ch.frequency_ch2 and 0x0700'u16) or uint16(value)
  of 0x6D:
    ch.frequency_ch2 = (ch.frequency_ch2 and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    let triggered = (value and 0x80) > 0
    if triggered and ch.dac_enabled: ch.enabled = true
    ch.agb_length_on_nrx4(length_enable, triggered, 0x40)  # AGB order; see abstract_channels
    if triggered:
      # Same as clear(etAPUChannel2) + schedule(period); see ch1_write.
      let arm2 = ch.ch2_frequency_timer()
      ch.next_step = ch.gba.scheduler.cycles + CycleCount(arm2)
      ch.arm_delay = arm2
      ch.init_volume_envelope()
  of 0x6E, 0x6F: discard
  else: echo "Writing to invalid Channel2 register: ", hex_str(uint16(address))
