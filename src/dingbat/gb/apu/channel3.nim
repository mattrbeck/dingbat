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
  # Only the LAST read matters: wave_ram is immutable between catch-ups
  # (0xFF30-0xFF3F accesses catch up first), so the intermediate sample-buffer
  # loads a per-period loop would do are all overwritten.
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
  ## Half of CH3's 1 MHz sample cycle, in T-cycles: the wave pointer is clocked
  ## at 2 MHz, so each sample cycle splits into a fetch half and a half in which
  ## the fetched byte is simply held. Both ch3_wave_open and ch3_wave_fetching
  ## are one of those halves. Scaled by the speed shift at each use, as every
  ## other APU delay is.

proc ch3_wave_open*(ch: GbChannel3; gb: GB): bool {.inline.} =
  ## Whether a CPU access to 0xFF30-0xFF3F resolves at all. Callers must have
  ## caught the wave pointer up to the current cycle first, so the last fetch
  ## was at (next_step - period) and this is a question about how long ago that
  ## was.
  ##
  ## While CH3 is off, wave RAM is plain memory on every model ("Wave RAM can be
  ## accessed normally even if the DAC is on, as long as the channel is not
  ## active"). While it is on, the CGB always resolves the access against the
  ## byte being played, and the DMG only lets it through in the half of the
  ## sample cycle that follows a completed fetch. That asymmetry is the whole
  ## difference between blargg's cgb_sound 09/10/12 and dmg_sound 09/10/12.
  if not ch.enabled:  return true
  if gb.cgb_enabled:  return true
  if not ch.wave_fetched: return false
  if ch.next_step == GB_NO_STEP: return true
  let period = CycleCount(ch3_frequency_timer(ch)) shl gb.scheduler.speed
  let window = CycleCount(GB_WAVE_ACCESS_WINDOW) shl gb.scheduler.speed
  # next_step - now is in (0, period] after the catch-up, so
  # (period - (next_step - now)) is how long ago the fetch was.
  period - (ch.next_step - gb.scheduler.cycles) < window

proc ch3_wave_fetching*(ch: GbChannel3; gb: GB): bool {.inline.} =
  ## Whether CH3's own wave-RAM fetch is IN FLIGHT on this cycle -- the two
  ## T-cycles that end at next_step, when the pointer steps and the new byte is
  ## latched. Distinct from ch3_wave_open, which is the slot the CPU gets and
  ## which blargg's dmg_sound 09/12 place immediately AFTER a completed fetch:
  ## the two are adjacent halves of the same 1 MHz cycle, and separating them is
  ## what makes 09/12 and 10 agree at once. Used only for the DMG restart
  ## corruption; the CGB has none.
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
  # 0xFF30-0xFF3F while enabled returns the byte CH3 is currently playing, so
  # apu_read catches the wave pointer up before calling this.
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
    let len_enable = (val and 0x40) != 0
    if gb.apu.first_half_of_length_period and not ch.length_enable and len_enable and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:
      # Pan Docs, Wave RAM: "on monochrome consoles, if CH3 is restarted while
      # it's reading wave RAM, and within a specific window, then the first four
      # bytes of wave RAM will be corrupted: if the byte CH3 is currently
      # reading is within the first four bytes of wave RAM, the first byte is
      # replaced by that byte; otherwise the first four bytes are replaced by
      # the four-byte-aligned group of four containing the byte being read."
      # "Within a specific window" is the half of the sample cycle in which
      # the fetch is actually in flight -- NOT the half a CPU access gets. See
      # ch3_wave_fetching.
      if ch.enabled and not gb.cgb_enabled and ch3_wave_fetching(ch, gb):
        # The byte "CH3 is currently reading" is the one the in-flight fetch is
        # about to latch, i.e. the position it is stepping TO -- which is what
        # makes blargg's dmg_sound 10 land its corruption one iteration earlier
        # than the position counter alone would suggest.
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
      # Same as clear(etAPUChannel3) + schedule_gb(period + 6). The +6 is
      # inside the speed shift, as schedule_gb had it.
      ch.next_step = gb.scheduler.cycles +
        (CycleCount(ch3_frequency_timer(ch) + 6) shl gb.scheduler.speed)
      # Index resets, but wave_ram_sample_buffer deliberately does NOT: the
      # last byte read keeps being output until CH3 next reads one (Pan Docs),
      # so the pre-trigger buffer is observable and has to be materialized.
      ch.wave_ram_position = 0
      ch.wave_fetched = false
  of 0xFF30..0xFF3F:
    if not ch3_wave_open(ch, gb): discard   # DMG: dropped outside the window
    elif ch.enabled: ch.wave_ram[ch.wave_ram_position div 2] = val
    else:            ch.wave_ram[idx - 0xFF30] = val
  else: discard
