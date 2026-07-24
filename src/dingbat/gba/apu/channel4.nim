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
    starting_volume: 0, envelope_add_mode: false, envelope_period: 0,
    envelope_timer: 0, current_volume: 0, envelope_is_updating: false,
    lfsr: 0,
    length_load_ch4: 0,
    clock_shift: 0, width_mode: 0, divisor_code: 0,
  )

proc ch4_step_wave*(ch: Channel4) =
  let new_bit = uint16(ch.lfsr and 0b01) xor uint16((ch.lfsr and 0b10) shr 1)
  ch.lfsr = ch.lfsr shr 1
  ch.lfsr = ch.lfsr or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = ch.lfsr and not (1'u16 shl 6)
    ch.lfsr = ch.lfsr or (new_bit shl 6)

proc ch4_frequency_timer*(ch: Channel4): uint32 =
  ((if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift) * 4

proc ch4_step*(ch: Channel4) =
  ch.ch4_step_wave()
  let ft = ch.ch4_frequency_timer()
  ch.gba.scheduler.schedule(int(ft), etAPUChannel4)

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
      ch.gba.scheduler.clear(etAPUChannel4)
      let ft = ch.ch4_frequency_timer()
      ch.gba.scheduler.schedule(int(ft), etAPUChannel4)
      ch.init_volume_envelope()
      ch.lfsr = 0x7FFF'u16
  of 0x7E, 0x7F: discard
  else: echo "Writing to invalid Channel4 register: ", hex_str(uint16(address))
