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

proc ch1_dac_input*(ch: GbChannel1): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC. This is what the CGB's
  ## PCM12 register exposes; 0 while the channel is off.
  if ch.enabled and ch.dac_enabled:
    uint8(int(WAVE_DUTY1[ch.duty][ch.wave_duty_position]) * int(ch.current_volume))
  else: 0'u8

proc ch1_get_amplitude*(ch: GbChannel1): float32 =
  if ch.enabled and ch.dac_enabled:
    float32(float64(ch.ch1_dac_input()) / 7.5 - 1.0)
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
    if ch.psg_write_nrx4(val, gb.apu.first_half_of_length_period, 0x40):
      gb.scheduler.clear(etAPUChannel1)
      gb.scheduler.schedule_gb(int(ch1_frequency_timer(ch)), etAPUChannel1)
      init_volume_envelope(ch)
      psg_sweep_trigger(ch)
  else: discard
