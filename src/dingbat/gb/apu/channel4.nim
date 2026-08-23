# GB APU Channel 4 - LFSR Noise (included by gb.nim)

proc new_channel4*(gb: GB): GbChannel4 =
  GbChannel4(enabled: false, dac_enabled: false, length_counter: 0,
             next_step: GB_NO_STEP, div_next: GB_NO_STEP)

# Two-stage frequency timer. NR43's `divisor << shift` is the LFSR period, not
# the counter: SameSuite channel_4_freq_change switches between two encodings
# of the same period mid-note and gets different answers, so an NR43 write
# re-interprets existing state. Model: a divisor stage that increments a
# counter every 4 T-cycles for code 0 and every 8*code otherwise (half the
# quoted divisor), and a free-running counter whose bit `clock_shift` clocks
# the LFSR on its rising edge. A write selects a different bit of the same
# counter and leaves the stage's countdown running; only a write landing on
# the cycle of an increment reloads with the new divisor, rounded up to the
# 512 kHz grid (a code != 0 stage can only reload on a grid edge).

proc ch4_lfsr_frozen(ch: GbChannel4): bool {.inline.} =
  ## Shifts 14 and 15 tap a bit the counter does not have, so the LFSR is never
  ## clocked (Pan Docs, NR43). next_step parks at GB_NO_STEP while the divisor
  ## stage keeps counting, so a later NR43 write that lowers the shift resumes
  ## from the held count. A state saved while frozen loses that count
  ## (ch4_resync_divisor).
  ch.clock_shift >= 14'u8

proc ch4_frequency_timer(ch: GbChannel4): uint32 =
  ## Full LFSR period in T-cycles.
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift

proc ch4_period(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  CycleCount(ch4_frequency_timer(ch)) shl gb.scheduler.speed

proc ch4_inc_period(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  ## One divisor-stage increment, in scheduler cycles.
  CycleCount(if ch.divisor_code == 0: 4'u32 else: uint32(ch.divisor_code) shl 3) shl
    gb.scheduler.speed

proc ch4_steps_to_rise(counter: uint16; shift: uint8): uint32 =
  ## Increments until bit `shift` of `counter` rises; 1 .. 2^(shift+1), so a
  ## counter sitting on the edge waits a full period.
  let m = 1'u32 shl (int(shift) + 1)
  let t = 1'u32 shl int(shift)
  let c = uint32(counter) and (m - 1)
  ((t + m - c - 1) and (m - 1)) + 1

proc ch4_next_shift(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  ## Rebuild the derived LFSR deadline from the two stages.
  ch.div_next + CycleCount(ch4_steps_to_rise(ch.div_counter, ch.clock_shift) - 1) *
                ch4_inc_period(ch, gb)

proc ch4_grid_up(gb: GB; t: CycleCount; divisor_code: uint8): CycleCount {.inline.} =
  ## Round a divisor-stage reload up onto the 512 kHz grid GbApu.noise_phase
  ## anchors. Divisor code 0 taps the 1 MHz half-step and has no grid to miss.
  if divisor_code == 0: return t
  let tick = gb_apu_tick(gb)
  let half = 2 * tick
  t + ((tick + gb.apu.noise_phase + half - (t mod half)) mod half)

proc ch4_advance_divisor(ch: GbChannel4; gb: GB) =
  ## Run the divisor stage to the current cycle without touching the LFSR.
  ## `div_next` is exact at every point the increment period could have
  ## changed, so the increments since are one division away. Callers must have
  ## run ch4_catchup first (next rising edge strictly in the future).
  ## apu_rebase calls it once a frame, bounding `now - div_next`.
  if ch.div_next == GB_NO_STEP: return
  let now = gb.scheduler.cycles
  if ch.div_next > now: return
  let inc = ch4_inc_period(ch, gb)
  let n   = (now - ch.div_next) div inc + 1
  ch.div_counter += uint16(n and CycleCount(0xFFFF))
  ch.div_next    += n * inc

proc ch4_shift(ch: GbChannel4) {.inline.} =
  let new_bit = (ch.lfsr and 0b01'u16) xor ((ch.lfsr and 0b10'u16) shr 1)
  ch.lfsr = ch.lfsr shr 1
  ch.lfsr = ch.lfsr or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = ch.lfsr and not (1'u16 shl 6)
    ch.lfsr = ch.lfsr or (new_bit shl 6)

proc ch4_catchup_slow(ch: GbChannel4; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch4_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  # steps == 0: the tie went to the observer; checking `enabled` first would
  # park the channel a step early.
  if steps == 0: return
  # A disabled channel shifts once more, then parks. Every path that clears
  # `enabled` catches this channel up first, so next_step is past the moment
  # of disabling.
  if not ch.enabled:
    ch4_shift(ch)
    ch.next_step = GB_NO_STEP
    ch.div_next  = GB_NO_STEP
    return
  # No cheap closed form for the LFSR, so this iterates; bounded by the
  # per-frame apu_catchup_all (<= 8778 shifts at the shortest divisor). The
  # divisor stage is not advanced here: it only changes at NR43 writes,
  # triggers and speed switches, each of which settles it
  # (ch4_advance_divisor); advancing it per sample would cost every sample.
  for _ in 0 ..< steps: ch4_shift(ch)
  ch.next_step += steps * period

proc ch4_resync_divisor*(ch: GbChannel4; gb: GB) =
  ## Rebuild the two stages from `next_step` alone after a state load (the
  ## counter and divisor deadline are not serialized, see
  ## GbChannel4.div_counter): counter one increment short of the rising edge,
  ## that increment due on the deadline. Only an NR43 write inside the first
  ## period after the load could tell. An assignment, not a subtraction, so it
  ## cannot underflow.
  if ch.next_step == GB_NO_STEP:
    ch.div_next = GB_NO_STEP
    ch.div_counter = 0
    return
  ch.div_counter = (1'u16 shl int(ch.clock_shift)) - 1
  ch.div_next = ch.next_step

proc ch4_catchup_at*(ch: GbChannel4; gb: GB; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at. Unlike the other three this is O(steps), not O(1).
  if ch.next_step > gb.scheduler.cycles: return
  ch4_catchup_slow(ch, gb, observer_period)

proc ch4_catchup*(ch: GbChannel4; gb: GB) {.inline.} =
  ch4_catchup_at(ch, gb, GB_OBS_CPU)

proc ch4_dac_input*(ch: GbChannel4): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC — see ch1_dac_input.
  if ch.enabled and ch.dac_enabled:
    uint8(int(not ch.lfsr and 1'u16) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc ch4_get_amplitude*(ch: GbChannel4): float32 =
  ## See ch1_get_amplitude: DAC-gated, and the slope is negative.
  if ch.dac_enabled: GB_DAC_LUT[ch.ch4_dac_input()] else: 0.0'f32

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
    # apu_write caught the channel up (no rising edge pending); bring the
    # divisor stage the rest of the way.
    let old_inc = ch4_inc_period(ch, gb)
    ch4_advance_divisor(ch, gb)
    let running = ch.div_next != GB_NO_STEP
    # `== old_inc`: an increment landed on this very cycle, so the countdown
    # sits at a fresh reload and the reload rule applies.
    let on_reload = running and ch.div_next - gb.scheduler.cycles == old_inc
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
    if running:
      if on_reload:
        ch.div_next = ch4_grid_up(gb, gb.scheduler.cycles + ch4_inc_period(ch, gb),
                                  ch.divisor_code)
      # Shift 14/15 parks the LFSR (ch4_lfsr_frozen); the divisor stage keeps
      # running so a later write can thaw it.
      ch.next_step = if ch4_lfsr_frozen(ch): GB_NO_STEP
                     else: ch4_next_shift(ch, gb)
  of 0xFF23:
    let len_enable = (val and 0x40) != 0
    # length_clock_any_nrx4: CGB 0 / A-B clock length on any NRx4 write, not
    # only one turning it on (GbQuirks).
    if gb.apu.first_half_of_length_period and not ch.length_enable and
       (len_enable or gb.quirks.length_clock_any_nrx4) and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:
      let was_enabled = ch.enabled
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      # Noise startup: half a period plus two ticks off the 512 kHz grid, a
      # full period on a restart; see gb_noise_deadline.
      let deadline = gb_noise_deadline(gb, ch4_period(ch, gb),
                                       ch.divisor_code, was_enabled)
      # Shift 14/15: the divisor stage starts but the LFSR never fires.
      ch.next_step = if ch4_lfsr_frozen(ch): GB_NO_STEP else: deadline
      # Split the deadline into its two stages: a fresh start leaves the
      # counter at 0 (half a period from the rising edge), a restart leaves it
      # on the edge it just produced (a full period). Both put the first
      # increment at the same place, so the subtraction is exact.
      ch.div_counter = (if was_enabled: 1'u16 shl int(ch.clock_shift) else: 0'u16)
      ch.div_next = deadline -
        CycleCount(ch4_steps_to_rise(ch.div_counter, ch.clock_shift) - 1) *
        ch4_inc_period(ch, gb)
      init_volume_envelope(ch)
      ch.lfsr = 0x7FFF'u16
  else: discard
