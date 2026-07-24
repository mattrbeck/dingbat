# APU Channel 3 (Wave) (included by gba.nim)

const RANGE_CH3_LOW*      = 0x70'u32
const RANGE_CH3_HIGH*     = 0x77'u32
const WAVE_RAM_LOW*       = 0x90'u32
const WAVE_RAM_HIGH*      = 0x9F'u32
const WAVE_RAM_SIZE*      = 16  # 0x90..0x9F = 16 bytes

proc ch3_in_range*(address: uint32): bool =
  (address >= RANGE_CH3_LOW and address <= RANGE_CH3_HIGH) or
  (address >= WAVE_RAM_LOW  and address <= WAVE_RAM_HIGH)

proc new_channel3*(gba: GBA): Channel3 =
  result = Channel3(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    wave_ram_position: 0,
    wave_ram_sample_buffer: 0,
    wave_ram_dimension: false,
    wave_ram_bank: 0,
    length_load: 0,
    volume_code: 0, volume_force: false,
    frequency: 0,
  )
  for bank in 0..1:
    result.wave_ram[bank] = newSeq[byte](WAVE_RAM_SIZE)
    for idx in 0 ..< WAVE_RAM_SIZE:
      result.wave_ram[bank][idx] = if (idx and 1) == 0: 0x00'u8 else: 0xFF'u8

proc ch3_step_wave*(ch: Channel3) =
  ch.wave_ram_position = uint8(int(ch.wave_ram_position + 1) mod (WAVE_RAM_SIZE * 2))
  if ch.wave_ram_position == 0 and ch.wave_ram_dimension:
    ch.wave_ram_bank = ch.wave_ram_bank xor 1
  let full_sample = ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2]
  ch.wave_ram_sample_buffer =
    (full_sample shr (if (ch.wave_ram_position and 1) == 0: 4 else: 0)) and 0xF

proc ch3_frequency_timer*(ch: Channel3): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 2 * 4

proc ch3_step*(ch: Channel3) =
  ch.ch3_step_wave()
  let ft = ch.ch3_frequency_timer()
  ch.gba.scheduler.schedule(int(ft), etAPUChannel3)

const CH3_VOLUME_TABLE = [0, 4, 2, 1]

proc ch3_get_amplitude*(ch: Channel3): int16 =
  if ch.enabled and ch.dac_enabled:
    let vol_mult = if ch.volume_force: 3 else: CH3_VOLUME_TABLE[ch.volume_code]
    int16(int(ch.wave_ram_sample_buffer) - 8) * 4 * int16(vol_mult)
  else:
    0'i16

proc ch3_read*(ch: Channel3; address: uint32): uint8 =
  case address
  of 0x70:
    (if ch.dac_enabled: 0x80'u8 else: 0'u8) or
    (ch.wave_ram_bank shl 6) or
    (if ch.wave_ram_dimension: 0x20'u8 else: 0'u8)
  of 0x73:
    (if ch.volume_force: 0x80'u8 else: 0'u8) or (ch.volume_code shl 5)
  of 0x75: (if ch.length_enable: 0x40'u8 else: 0'u8)
  of WAVE_RAM_LOW..WAVE_RAM_HIGH:
    if ch.enabled:
      ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2]
    else:
      ch.wave_ram[ch.wave_ram_bank][address - WAVE_RAM_LOW]
  else: 0'u8

proc ch3_write*(ch: Channel3; address: uint32; value: uint8) =
  case address
  of 0x70:
    ch.dac_enabled      = (value and 0x80) > 0
    if not ch.dac_enabled: ch.enabled = false
    ch.wave_ram_dimension = bit(value, 5)
    ch.wave_ram_bank    = bits_range(value, 6, 6)
  of 0x71: discard
  of 0x72:
    ch.length_load  = value
    ch.length_counter   = 0x100 - int(value)
  of 0x73:
    ch.volume_code  = (value and 0x60) shr 5
    ch.volume_force = bit(value, 7)
  of 0x74: ch.frequency = (ch.frequency and 0x0700'u16) or uint16(value)
  of 0x75:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    if ch.gba.apu.first_half_of_length_period and not ch.length_enable and length_enable and ch.length_counter > 0:
      ch.length_counter -= 1
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = length_enable
    if (value and 0x80) > 0:
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x100
        if ch.length_enable and ch.gba.apu.first_half_of_length_period:
          ch.length_counter -= 1
      ch.gba.scheduler.clear(etAPUChannel3)
      let ft = ch.ch3_frequency_timer() + 6
      ch.gba.scheduler.schedule(int(ft), etAPUChannel3)
      ch.wave_ram_position = 0
  of 0x76, 0x77: discard
  of WAVE_RAM_LOW..WAVE_RAM_HIGH:
    if ch.enabled:
      ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2] = value
    else:
      ch.wave_ram[ch.wave_ram_bank][address - WAVE_RAM_LOW] = value
  else: echo "Writing to invalid Channel3 register: ", hex_str(uint16(address))
