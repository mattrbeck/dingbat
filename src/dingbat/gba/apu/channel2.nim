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
    starting_volume: 0, envelope_add_mode: false, envelope_period: 0,
    envelope_timer: 0, current_volume: 0, envelope_is_updating: false,
    wave_duty_position: 0,
    duty: 0, length_load: 0, frequency: 0,
  )

proc ch2_step_wave*(ch: Channel2) =
  ch.wave_duty_position = (ch.wave_duty_position + 1) and 7

proc ch2_frequency_timer*(ch: Channel2): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4 * 4

proc ch2_step*(ch: Channel2) =
  ch.ch2_step_wave()
  let ft = ch.ch2_frequency_timer()
  ch.gba.scheduler.schedule(int(ft), etAPUChannel2)

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
  case address
  of 0x68:
    ch.duty        = (value and 0xC0) shr 6
    ch.length_load = value and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0x69: ch.write_nrx2(value)
  of 0x6A, 0x6B: discard
  of 0x6C: ch.frequency = (ch.frequency and 0x0700'u16) or uint16(value)
  of 0x6D:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    if ch.psg_write_nrx4(value, ch.gba.apu.first_half_of_length_period, 0x40):
      ch.gba.scheduler.clear(etAPUChannel2)
      ch.gba.scheduler.schedule(int(ch.ch2_frequency_timer()), etAPUChannel2)
      ch.init_volume_envelope()
  of 0x6E, 0x6F: discard
  else: echo "Writing to invalid Channel2 register: ", hex_str(uint16(address))
