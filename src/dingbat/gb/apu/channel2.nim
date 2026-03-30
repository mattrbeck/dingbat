# GB APU Channel 2 - Square wave (included by gb.nim)

const WAVE_DUTY2: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],
  [1'u8, 0, 0, 0, 0, 0, 0, 1],
  [1'u8, 0, 0, 0, 0, 1, 1, 1],
  [0'u8, 1, 1, 1, 1, 1, 1, 0],
]

proc new_channel2*(gb: GB): GbChannel2 =
  GbChannel2(enabled: false, dac_enabled: false, length_counter: 0)

proc ch2_frequency_timer(ch: GbChannel2): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4

proc ch2_step*(ch: GbChannel2; gb: GB) =
  ch.wave_duty_position = (ch.wave_duty_position + 1) and 7
  gb.scheduler.schedule_gb(int(ch2_frequency_timer(ch)),
    etAPUChannel2)

proc ch2_get_amplitude*(ch: GbChannel2): float32 =
  if ch.enabled and ch.dac_enabled:
    let dac_in = int(WAVE_DUTY2[ch.duty][ch.wave_duty_position]) * int(ch.current_volume)
    float32(float64(dac_in) / 7.5 - 1.0)
  else: 0.0'f32

proc ch2_read*(ch: GbChannel2; idx: int): uint8 =
  case idx
  of 0xFF16: 0x3F'u8 or (ch.duty shl 6)
  of 0xFF17: read_NRx2(ch)
  of 0xFF18: 0xFF'u8
  of 0xFF19: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch2_write*(ch: GbChannel2; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF16:
    ch.duty         = (val and 0xC0) shr 6
    ch.length_load  = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0xFF17:
    write_NRx2(ch, val)
  of 0xFF18:
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
  of 0xFF19:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
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
      gb.scheduler.clear(etAPUChannel2)
      gb.scheduler.schedule_gb(int(ch2_frequency_timer(ch)),
        etAPUChannel2)
      init_volume_envelope(ch)
  else: discard
