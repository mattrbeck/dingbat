# GB APU Channel 3 - Wave output (included by gb.nim)

proc new_channel3*(gb: GB): GbChannel3 =
  result = GbChannel3(enabled: false, dac_enabled: false, length_counter: 0)
  for i in 0 ..< 16:
    result.wave_ram[i] = if (i and 1) == 0: 0x00'u8 else: 0xFF'u8

proc ch3_frequency_timer(ch: GbChannel3): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 2

proc ch3_step*(ch: GbChannel3; gb: GB) =
  ch.wave_ram_position = (ch.wave_ram_position + 1) mod 32
  ch.wave_ram_sample_buffer = ch.wave_ram[ch.wave_ram_position div 2]
  gb.scheduler.schedule_gb(int(ch3_frequency_timer(ch)),
    etAPUChannel3)

proc ch3_dac_input*(ch: GbChannel3): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC — see ch1_dac_input.
  if ch.enabled and ch.dac_enabled:
    let nibble = if (ch.wave_ram_position and 1) == 0:
                   (ch.wave_ram_sample_buffer shr 4) and 0x0F
                 else:
                   ch.wave_ram_sample_buffer and 0x0F
    nibble shr ch.volume_code_shift
  else: 0'u8

proc ch3_get_amplitude*(ch: GbChannel3): float32 =
  if ch.enabled and ch.dac_enabled:
    float32(float64(ch.ch3_dac_input()) / 7.5 - 1.0)
  else: 0.0'f32

proc ch3_read*(ch: GbChannel3; idx: int): uint8 =
  case idx
  of 0xFF1A: 0x7F'u8 or (if ch.dac_enabled: 0x80'u8 else: 0'u8)
  of 0xFF1B: 0xFF'u8
  of 0xFF1C: 0x9F'u8 or (ch.volume_code shl 5)
  of 0xFF1D: 0xFF'u8
  of 0xFF1E: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  of 0xFF30..0xFF3F:
    if ch.enabled: ch.wave_ram[ch.wave_ram_position div 2]
    else:          ch.wave_ram[idx - 0xFF30]
  else: 0xFF'u8

proc ch3_write*(ch: GbChannel3; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF1A:
    ch.dac_enabled = (val and 0x80) != 0
    if not ch.dac_enabled: ch.enabled = false
  of 0xFF1B:
    ch.length_load    = val
    ch.length_counter = 0x100 - int(ch.length_load)
  of 0xFF1C:
    ch.volume_code = (val and 0x60) shr 5
    ch.volume_code_shift = case ch.volume_code
      of 0b00: 4'u8
      of 0b01: 0'u8
      of 0b10: 1'u8
      of 0b11: 2'u8
      else:    4'u8
  of 0xFF1D:
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
  of 0xFF1E:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    if ch.psg_write_nrx4(val, gb.apu.first_half_of_length_period, 0x100):
      gb.scheduler.clear(etAPUChannel3)
      gb.scheduler.schedule_gb(
        int(ch3_frequency_timer(ch)) + PSG_WAVE_TRIGGER_DELAY, etAPUChannel3)
      ch.wave_ram_position = 0
  of 0xFF30..0xFF3F:
    if ch.enabled: ch.wave_ram[ch.wave_ram_position div 2] = val
    else:          ch.wave_ram[idx - 0xFF30] = val
  else: discard
