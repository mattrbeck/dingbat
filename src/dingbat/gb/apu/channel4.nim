# GB APU Channel 4 - LFSR Noise (included by gb.nim)

proc new_channel4*(gb: GB): GbChannel4 =
  GbChannel4(enabled: false, dac_enabled: false, length_counter: 0,
             next_step: GB_NO_STEP, div_next: GB_NO_STEP)

# ---------------------------------------------------------------------------
# The two-stage frequency timer
#
# NR43's `divisor << shift` is a formula for the LFSR's PERIOD, not a
# description of the counter that produces it. SameSuite channel_4_freq_change
# is the test that tells the two apart: it plays the same two periods (4 and 16
# M-cycles) through four different NR43 encodings of them -- $18/$09 for the
# short one, $38/$1a for the long -- switches between them mid-note at two
# trigger phases, and reads PCM34 one M-cycle at a time to find the next LFSR
# shift. If the timer were a single counter with one deadline, all four
# encodings of a switch would land that shift on the same cycle. They do not:
# its 64 bytes need eight different answers, so the write is re-interpreting
# state that already exists rather than restarting a timer.
#
# What fits all 64 (and leaves the twelve channel_4 rows that were already
# green untouched) is the obvious hardware shape:
#
#   * a DIVISOR STAGE that increments a counter every `4` T-cycles for divisor
#     code 0 and every `8 * code` T-cycles otherwise -- exactly HALF the
#     "divisor" the period formula quotes;
#   * a free-running COUNTER whose bit `clock_shift` clocks the LFSR on its
#     RISING edge, i.e. once every 2^(shift+1) increments.
#
# The two multiply back to the documented period -- `4 * 2^(shift+1)` = `8 <<
# shift` for code 0, `8c * 2^(shift+1)` = `16c << shift` otherwise -- and the
# halving is what the divisor-code-0 carve-out in gb_noise_deadline has been
# describing all along: code 0 increments once per APU tick (1 MHz), every
# other code increments on a 512 kHz grid, which is why only code 0 escapes it.
#
# An NR43 write then re-interprets both stages instead of restarting them:
#
#   * `clock_shift` selects a different BIT of the same counter, so the next
#     shift is however far that bit's next rising edge is from the count the
#     channel has already reached -- not half a period, not a whole one;
#   * the divisor stage's countdown is left running, and only reloads with the
#     new divisor when it expires. The one exception is a write that lands on
#     the exact cycle an increment does: that increment consumes the countdown,
#     so the reload is the new divisor -- rounded UP to the 512 kHz grid,
#     because a code != 0 stage can only be reloaded on a grid edge.
#
# The rounding is the whole difference between the test's two trigger phases on
# the rows that switch INTO divisor code 2 ($1a): one nop moves the write off
# the grid and the first shift lands an M-cycle later.
# ---------------------------------------------------------------------------

proc ch4_lfsr_frozen(ch: GbChannel4): bool {.inline.} =
  ## NR43 clock shifts 14 and 15 tap a counter bit the divisor stage does not
  ## have: the LFSR receives no clocks at all (Pan Docs NR43, "shift being
  ## equal to 14 or 15 stops the channel from being clocked entirely") and the
  ## output holds whatever bit it was on. Modelled by parking `next_step` at
  ## GB_NO_STEP while the divisor stage keeps counting, so a later NR43 write
  ## that lowers the shift resumes from the count the hardware would hold.
  ## Caveat shared with ch4_resync_divisor: a state saved while frozen loses
  ## the divisor count, so the resume phase after a load is a reconstruction.
  ch.clock_shift >= 14'u8

proc ch4_frequency_timer(ch: GbChannel4): uint32 =
  ## The full LFSR period in T-cycles: 2^(shift+1) increments of the stage
  ## below.
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift

proc ch4_period(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  CycleCount(ch4_frequency_timer(ch)) shl gb.scheduler.speed

proc ch4_inc_period(ch: GbChannel4; gb: GB): CycleCount {.inline.} =
  ## One divisor-stage increment, in scheduler cycles.
  CycleCount(if ch.divisor_code == 0: 4'u32 else: uint32(ch.divisor_code) shl 3) shl
    gb.scheduler.speed

proc ch4_steps_to_rise(counter: uint16; shift: uint8): uint32 =
  ## Increments from `counter` until bit `shift` of it goes 0 -> 1. Always in
  ## 1 .. 2^(shift+1), so a counter sitting exactly ON the edge waits a full
  ## period rather than firing twice.
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
  ## Run the divisor stage up to the current cycle without touching the LFSR.
  ##
  ## This is the whole reason ch4_catchup_slow does not have to: `div_next` is
  ## exact at every point the increment period could have changed (trigger,
  ## NR43 write, speed switch), so however many shifts have gone by since, the
  ## increments in between are one division away. Callers must have run
  ## ch4_catchup first, which leaves the next rising edge strictly in the
  ## future -- so nothing here can have needed to clock the LFSR.
  ##
  ## apu_rebase calls it once a frame, which is also what keeps `now -
  ## div_next` from growing without bound.
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
  # steps == 0 means the tie went to the observer, so nothing has happened yet
  # -- checking `enabled` before this would park the channel a step early.
  if steps == 0: return
  # A disabled channel's chain dies after ONE more step: the old ch4_step did
  # the shift unconditionally and only the RESCHEDULE was gated on `enabled`.
  # Every path that clears ch4.enabled (length_step via the frame sequencer,
  # write_NRx2's DAC check, NR52 power-off) catches this channel up first, so
  # next_step is always past the moment of disabling when we get here.
  if not ch.enabled:
    ch4_shift(ch)
    ch.next_step = GB_NO_STEP
    ch.div_next  = GB_NO_STEP
    return
  # The LFSR has no cheap closed form (Gambatte exploits reg^(reg>>1) == 15
  # shifts; not worth the divergence risk here), so this still iterates. The
  # win is that it iterates in a tight loop instead of paying a scheduler
  # insert + heap pop + closure dispatch per shift. Bounded because
  # apu_catchup_all runs at every frame boundary, so at most one frame of
  # shifts (<= 8778 at the shortest divisor) can accumulate -- exactly the
  # number the old event chain would have run anyway.
  #
  # The divisor stage costs NOTHING here. Its increment period only ever
  # changes at an NR43 write, a trigger or a speed switch, and each of those
  # settles it first, so the count between two of them is a division away from
  # `div_next` whenever somebody asks -- see ch4_advance_divisor. Doing it here
  # instead measured +0.14% of retired instructions on Pokemon Crystal, paid on
  # every sample of every noise-using title to serve a register write.
  for _ in 0 ..< steps: ch4_shift(ch)
  ch.next_step += steps * period

proc ch4_resync_divisor*(ch: GbChannel4; gb: GB) =
  ## Rebuild the two stages from `next_step` alone. The counter and the divisor
  ## deadline are not in the save-state payload (see GbChannel4.div_counter), so
  ## a loaded state gets the one reconstruction that asserts nothing it cannot
  ## know: the counter one increment short of the rising edge, and that
  ## increment due exactly on the deadline. Every LFSR shift then lands where
  ## the state said it would; only an NR43 write inside the first period after
  ## the load could tell the difference. Written as an assignment rather than
  ## `next_step - (steps - 1) * inc` so it cannot underflow on a state whose
  ## deadline is nearer the origin than one period.
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
    # apu_write has already caught the channel up, so no rising edge is
    # pending; bring the divisor stage the rest of the way so the write sees
    # the count it is about to re-interpret.
    let old_inc = ch4_inc_period(ch, gb)
    ch4_advance_divisor(ch, gb)
    let running = ch.div_next != GB_NO_STEP
    # `== old_inc` is "an increment landed on this very cycle": the catch-up
    # consumed it, so the countdown is sitting at a fresh reload rather than
    # part-way through one, and this is the write the reload rule applies to.
    let on_reload = running and ch.div_next - gb.scheduler.cycles == old_inc
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
    if running:
      if on_reload:
        ch.div_next = ch4_grid_up(gb, gb.scheduler.cycles + ch4_inc_period(ch, gb),
                                  ch.divisor_code)
      # A shift of 14/15 freezes the LFSR chain (see ch4_lfsr_frozen); the
      # divisor stage above keeps running so a later write can thaw it.
      ch.next_step = if ch4_lfsr_frozen(ch): GB_NO_STEP
                     else: ch4_next_shift(ch, gb)
  of 0xFF23:
    let len_enable = (val and 0x40) != 0
    # `or gb.quirks.length_clock_any_nrx4` is the CGB 0 / CGB A-B extra-length
    # clocking rule, which drops the requirement that the write turn the
    # length counter ON; see GbQuirks in gb.nim.
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
      # Noise has its own startup rule -- half a period plus two ticks, off a
      # 512 kHz grid that only divisor code 0 escapes, and a full period instead
      # of a half one when the channel was already running. All three parts, and
      # the reason the tests' own "sample length + 3 M-cycles" is a special case
      # of the first, are derived at gb_noise_deadline.
      let deadline = gb_noise_deadline(gb, ch4_period(ch, gb),
                                       ch.divisor_code, was_enabled)
      # A trigger with shift 14/15 starts the divisor stage but the LFSR tap
      # never fires (ch4_lfsr_frozen): output holds the reset LFSR's bit.
      ch.next_step = if ch4_lfsr_frozen(ch): GB_NO_STEP else: deadline
      # Split that one deadline back into the two stages it is the product of.
      # The counter is what carries the trigger's two cases: a fresh start
      # leaves it at 0, half a period from the next rising edge, and a restart
      # of a running channel leaves it sitting ON the edge it just produced, a
      # full period from the next -- which is the same "the flip-flop is not
      # cleared twice" statement gb_noise_deadline derives, expressed as state
      # instead of as a special case. Both put the first increment at the same
      # place, so the subtraction below is exact and cannot underflow.
      ch.div_counter = (if was_enabled: 1'u16 shl int(ch.clock_shift) else: 0'u16)
      ch.div_next = deadline -
        CycleCount(ch4_steps_to_rise(ch.div_counter, ch.clock_shift) - 1) *
        ch4_inc_period(ch, gb)
      init_volume_envelope(ch)
      ch.lfsr = 0x7FFF'u16
  else: discard
