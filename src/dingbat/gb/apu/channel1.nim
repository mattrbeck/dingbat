# GB APU Channel 1 - Square wave with frequency sweep (included by gb.nim)

const WAVE_DUTY1: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],  # 12.5%
  [1'u8, 0, 0, 0, 0, 0, 0, 1],  # 25%
  [1'u8, 0, 0, 0, 0, 1, 1, 1],  # 50%
  [0'u8, 1, 1, 1, 1, 1, 1, 0],  # 75%
]

proc new_channel1*(gb: GB): GbChannel1 =
  GbChannel1(enabled: false, dac_enabled: false, length_counter: 0,
             sweep_period: 0)

proc ch1_frequency_timer(ch: GbChannel1): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4

proc ch1_step*(ch: GbChannel1; gb: GB) =
  ch.wave_duty_position = (ch.wave_duty_position + 1) and 7
  gb.scheduler.schedule_gb(int(ch1_frequency_timer(ch)), etAPUChannel1)

proc ch1_frequency_calc(ch: GbChannel1): uint16 =
  let shifted = ch.frequency_shadow shr ch.shift
  var calc = int(ch.frequency_shadow) + (if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calc > 0x07FF: ch.enabled = false
  result = uint16(calc and 0x7FFF)

proc sweep_step*(ch: GbChannel1; gb: GB) =
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calc = ch1_frequency_calc(ch)
      if calc <= 0x07FF and ch.shift > 0:
        ch.frequency_shadow = calc
        ch.frequency         = calc
        discard ch1_frequency_calc(ch)

proc ch1_get_amplitude*(ch: GbChannel1): float32 =
  if ch.enabled and ch.dac_enabled:
    let dac_in = int(WAVE_DUTY1[ch.duty][ch.wave_duty_position]) * int(ch.current_volume)
    float32(float64(dac_in) / 7.5 - 1.0)
  else: 0.0'f32

proc ch1_read*(ch: GbChannel1; idx: int): uint8 =
  case idx
  of 0xFF10: 0x80'u8 or (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift
  of 0xFF11: 0x3F'u8 or (ch.duty shl 6)
  of 0xFF12: read_NRx2(ch)
  of 0xFF13: 0xFF'u8  # write-only
  of 0xFF14: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch1_write*(ch: GbChannel1; idx: int; val: uint8; gb: GB) =
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
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      gb.scheduler.clear(etAPUChannel1)
      gb.scheduler.schedule_gb(int(ch1_frequency_timer(ch)),
        etAPUChannel1)
      init_volume_envelope(ch)
      ch.frequency_shadow = ch.frequency
      ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
      ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
      ch.negate_used      = false
      if ch.shift > 0: discard ch1_frequency_calc(ch)
  else: discard
