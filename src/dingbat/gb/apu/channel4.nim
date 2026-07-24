# GB APU Channel 4 - LFSR Noise (included by gb.nim)

proc new_channel4*(gb: GB): GbChannel4 =
  GbChannel4(enabled: false, dac_enabled: false, length_counter: 0)

proc ch4_frequency_timer(ch: GbChannel4): uint32 =
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift

proc ch4_step*(ch: GbChannel4; gb: GB) =
  psg_lfsr_step(ch)
  gb.scheduler.schedule_gb(int(ch4_frequency_timer(ch)), etAPUChannel4)

proc ch4_get_amplitude*(ch: GbChannel4): float32 =
  if ch.enabled and ch.dac_enabled:
    let dac_in = int(not ch.lfsr and 1'u16) * int(ch.current_volume)
    float32(float64(dac_in) / 7.5 - 1.0)
  else: 0.0'f32

proc ch4_read*(ch: GbChannel4; idx: int): uint8 =
  case idx
  of 0xFF20: 0xFF'u8
  of 0xFF21: read_NRx2(ch)
  of 0xFF22: (ch.clock_shift shl 4) or (ch.width_mode shl 3) or ch.divisor_code
  of 0xFF23: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch4_write*(ch: GbChannel4; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF20:
    ch.length_load    = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0xFF21:
    write_NRx2(ch, val)
  of 0xFF22:
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
  of 0xFF23:
    if ch.psg_write_nrx4(val, gb.apu.first_half_of_length_period, 0x40):
      gb.scheduler.clear(etAPUChannel4)
      gb.scheduler.schedule_gb(int(ch4_frequency_timer(ch)), etAPUChannel4)
      init_volume_envelope(ch)
      ch.lfsr = 0x7FFF'u16
  else: discard
