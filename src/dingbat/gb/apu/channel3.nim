# GB APU Channel 3 - Wave output (included by gb.nim)

proc new_channel3*(gb: GB): GbChannel3 =
  result = GbChannel3(enabled: false, dac_enabled: false, length_counter: 0,
                      next_step: GB_NO_STEP)
  for i in 0 ..< 16:
    result.wave_ram[i] = if (i and 1) == 0: 0x00'u8 else: 0xFF'u8

proc ch3_frequency_timer(ch: GbChannel3): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 2

proc ch3_catchup_slow(ch: GbChannel3; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch3_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  if steps == 0: return
  # Only the last fetch matters: wave_ram is immutable between catch-ups.
  ch.wave_ram_position = uint8((int(ch.wave_ram_position) + int(steps mod 32)) mod 32)
  ch.wave_fetched = true
  ch.wave_ram_sample_buffer = ch.wave_ram[ch.wave_ram_position div 2]
  ch.next_step += steps * period

proc ch3_catchup_at*(ch: GbChannel3; gb: GB; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at. The wave pointer is a free-running mod-32 counter.
  if ch.next_step > gb.scheduler.cycles: return
  ch3_catchup_slow(ch, gb, observer_period)

proc ch3_catchup*(ch: GbChannel3; gb: GB) {.inline.} =
  ch3_catchup_at(ch, gb, GB_OBS_CPU)

const GB_WAVE_ACCESS_WINDOW = 2
  ## Half of CH3's 1 MHz sample cycle in T-cycles: the pointer is clocked at
  ## 2 MHz, so each sample cycle has a fetch half and a hold half.
  ## Speed-shifted at each use.

proc ch3_wave_open*(ch: GbChannel3; gb: GB): bool {.inline.} =
  ## Whether a CPU access to 0xFF30-0xFF3F resolves. Callers must have caught
  ## the pointer up. While CH3 is off wave RAM is plain memory; while on, CGB
  ## resolves the access against the byte being played and DMG only lets it
  ## through in the half-cycle after a completed fetch (blargg cgb_sound vs
  ## dmg_sound 09/10/12).
  if not ch.enabled:  return true
  if gb.cgb_enabled:  return true
  if not ch.wave_fetched: return false
  if ch.next_step == GB_NO_STEP: return true
  let period = CycleCount(ch3_frequency_timer(ch)) shl gb.scheduler.speed
  let window = CycleCount(GB_WAVE_ACCESS_WINDOW) shl gb.scheduler.speed
  # next_step - now is in (0, period] after the catch-up.
  period - (ch.next_step - gb.scheduler.cycles) < window

proc ch3_wave_fetching*(ch: GbChannel3; gb: GB): bool {.inline.} =
  ## Whether CH3's own fetch is in flight on this cycle (the two T-cycles
  ## ending at next_step): the half-cycle adjacent to ch3_wave_open's CPU slot
  ## (blargg dmg_sound 09/10/12). DMG restart corruption only.
  if ch.next_step == GB_NO_STEP: return false
  let window = CycleCount(GB_WAVE_ACCESS_WINDOW) shl gb.scheduler.speed
  ch.next_step - gb.scheduler.cycles <= window

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
  ## See ch1_get_amplitude: DAC-gated, and the slope is negative.
  if ch.dac_enabled: GB_DAC_LUT[ch.ch3_dac_input()] else: 0.0'f32

proc ch3_read*(ch: GbChannel3; idx: int; gb: GB): uint8 =
  # 0xFF30-0xFF3F while enabled returns the byte being played; apu_read
  # catches the pointer up first.
  case idx
  of 0xFF1A: 0x7F'u8 or (if ch.dac_enabled: 0x80'u8 else: 0'u8)
  of 0xFF1B: 0xFF'u8
  of 0xFF1C: 0x9F'u8 or (ch.volume_code shl 5)
  of 0xFF1D: 0xFF'u8
  of 0xFF1E: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  of 0xFF30..0xFF3F:
    if not ch3_wave_open(ch, gb): 0xFF'u8
    elif ch.enabled:              ch.wave_ram[ch.wave_ram_position div 2]
    else:                         ch.wave_ram[idx - 0xFF30]
  else: 0xFF'u8

proc ch3_write*(ch: GbChannel3; idx: int; val: uint8; gb: GB) =
  case idx
  of 0xFF1A:
    ch.dac_enabled = (val and 0x80) != 0
    if not ch.dac_enabled:
      ch.enabled = false
      # The sample buffer clears with the DAC: SameSuite
      # channel_3_restart_stop_delay (restart after an NR30 stop is silent
      # through the startup delay) vs channel_3_restart_delay (a plain restart
      # keeps the old sample). Power-off reaches here through NR30 = 0.
      ch.wave_ram_sample_buffer = 0
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
    let len_enable = (val and 0x40) != 0
    # length_clock_any_nrx4: CGB 0 / A-B clock length on any NRx4 write, not
    # only one turning it on (GbQuirks). CGB A/B additionally defer the
    # switch-off by one such clock, on the wave channel only: SameSuite
    # channel_3_extra_length_clocking-cgb0 and -cgbB differ only in their
    # expected tables, and every CGB-B cell is the CGB-0 answer for one fewer
    # write. `enabled and length_counter == 0` is reachable by no other path,
    # so the pending switch-off needs no state of its own.
    let defer_off = gb.revision == grCgbAB
    if gb.apu.first_half_of_length_period and not ch.length_enable and
       (len_enable or gb.quirks.length_clock_any_nrx4) and
       (ch.length_counter > 0 or (defer_off and ch.enabled)):
      if ch.length_counter == 0:
        ch.enabled = false            # the deferred switch-off, one clock late
      else:
        dec ch.length_counter
        if ch.length_counter == 0 and not defer_off: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:
      # Pan Docs, Wave RAM: a DMG restart while CH3 is reading wave RAM
      # corrupts the first four bytes (byte 0 from the byte being read if it is
      # in the first four, else the aligned group of four). The window is the
      # half-cycle in which the fetch is in flight: ch3_wave_fetching.
      if ch.enabled and not gb.cgb_enabled and ch3_wave_fetching(ch, gb):
        # The byte being read is the one the fetch is about to latch (blargg
        # dmg_sound 10).
        let byte_idx = ((int(ch.wave_ram_position) + 1) mod 32) div 2
        if byte_idx < 4:
          ch.wave_ram[0] = ch.wave_ram[byte_idx]
        else:
          let base = byte_idx and not 3
          for i in 0 ..< 4: ch.wave_ram[i] = ch.wave_ram[base + i]
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x100
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      # Period plus a 6 T-cycle startup, inside the speed shift.
      ch.next_step = gb.scheduler.cycles +
        (CycleCount(ch3_frequency_timer(ch) + 6) shl gb.scheduler.speed)
      # wave_ram_sample_buffer is not reset: the last byte read keeps being
      # output until the next fetch (Pan Docs).
      ch.wave_ram_position = 0
      ch.wave_fetched = false
  of 0xFF30..0xFF3F:
    if not ch3_wave_open(ch, gb): discard   # DMG: dropped outside the window
    elif ch.enabled: ch.wave_ram[ch.wave_ram_position div 2] = val
    else:            ch.wave_ram[idx - 0xFF30] = val
  else: discard
