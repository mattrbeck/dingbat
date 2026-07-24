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
    starting_volume: 0, envelope_add_mode: false, envelope_period: 0,
    envelope_timer: 0, current_volume: 0, envelope_is_updating: false,
    wave_duty_position: 0,
    sweep_period: 0, negate: false, shift: 0,
    sweep_timer: 0, frequency_shadow: 0, sweep_enabled: false, negate_used: false,
    duty: 0, length_load: 0, frequency: 0,
  )

proc ch1_step_wave*(ch: Channel1) =
  ch.wave_duty_position = (ch.wave_duty_position + 1) and 7

proc ch1_frequency_timer*(ch: Channel1): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4 * 4

proc ch1_step*(ch: Channel1) =
  ch.ch1_step_wave()
  let ft = ch.ch1_frequency_timer()
  ch.gba.scheduler.schedule(int(ft), etAPUChannel1)

proc ch1_frequency_calculation*(ch: Channel1): uint16 =
  let shifted    = ch.frequency_shadow shr ch.shift
  var calculated = uint32(ch.frequency_shadow) + uint32(if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calculated > 0x07FF: ch.enabled = false
  uint16(calculated)

proc sweep_step*(ch: Channel1) =
  if ch.sweep_timer > 0: ch.sweep_timer -= 1
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calculated = ch.ch1_frequency_calculation()
      if calculated <= 0x07FF and ch.shift > 0:
        ch.frequency_shadow = calculated
        ch.frequency    = calculated
        discard ch.ch1_frequency_calculation()

proc ch1_get_amplitude*(ch: Channel1): int16 =
  if ch.enabled and ch.dac_enabled:
    int16(WAVE_DUTY_CH1[ch.duty][ch.wave_duty_position]) * int16(ch.current_volume)
  else:
    0'i16

proc ch1_read*(ch: Channel1; address: uint32): uint8 =
  case address
  of 0x60: (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift
  of 0x62: ch.duty shl 6
  of 0x63: ch.read_nrx2()
  of 0x65: (if ch.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc ch1_write*(ch: Channel1; address: uint32; value: uint8) =
  case address
  of 0x60:
    ch.sweep_period = (value and 0x70) shr 4
    ch.negate       = (value and 0x08) > 0
    ch.shift    = value and 0x07
    if not ch.negate and ch.negate_used: ch.enabled = false
  of 0x61: discard
  of 0x62:
    ch.duty         = (value and 0xC0) shr 6
    ch.length_load  = value and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0x63: ch.write_nrx2(value)
  of 0x64: ch.frequency = (ch.frequency and 0x0700'u16) or uint16(value)
  of 0x65:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    if ch.gba.apu.first_half_of_length_period and not ch.length_enable and length_enable and ch.length_counter > 0:
      ch.length_counter -= 1
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = length_enable
    if (value and 0x80) > 0:
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and ch.gba.apu.first_half_of_length_period:
          ch.length_counter -= 1
      ch.gba.scheduler.clear(etAPUChannel1)
      let ft = ch.ch1_frequency_timer()
      ch.gba.scheduler.schedule(int(ft), etAPUChannel1)
      ch.init_volume_envelope()
      ch.frequency_shadow     = ch.frequency
      ch.sweep_timer          = if ch.sweep_period > 0: ch.sweep_period else: 8
      ch.sweep_enabled        = ch.sweep_period > 0 or ch.shift > 0
      ch.negate_used = false
      if ch.shift > 0:
        discard ch.ch1_frequency_calculation()
  of 0x66, 0x67: discard
  else: echo "Writing to invalid Channel1 register: ", hex_str(uint16(address))
