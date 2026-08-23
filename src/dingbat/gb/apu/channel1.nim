# GB APU Channel 1 - Square wave with frequency sweep (included by gb.nim)

const WAVE_DUTY1: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],  # 12.5%
  [1'u8, 0, 0, 0, 0, 0, 0, 1],  # 25%
  [1'u8, 0, 0, 0, 0, 1, 1, 1],  # 50%
  [0'u8, 1, 1, 1, 1, 1, 1, 0],  # 75%
]

proc new_channel1*(gb: GB): GbChannel1 =
  GbChannel1(enabled: false, dac_enabled: false, length_counter: 0,
             sweep_period: 0, next_step: GB_NO_STEP,
             sweep_check_at: GB_NO_STEP, sweep_stop_at: GB_NO_STEP,
             sweep_load_at: GB_NO_STEP, last_step_at: GB_NO_STEP)

proc ch1_frequency_timer(ch: GbChannel1): uint32 =
  (0x800'u32 - uint32(ch.frequency)) * 4

proc ch1_period(ch: GbChannel1; gb: GB): CycleCount {.inline.} =
  ## Duty-step period in scheduler cycles (speed-shifted like every APU delay).
  CycleCount(ch1_frequency_timer(ch)) shl gb.scheduler.speed

const GB_SWEEP_STOP_DELAY* = CycleCount(4)
  ## Scheduler cycles (one APU tick) between a sweep overflow calculation and
  ## the stop becoming visible in NR52 / PCM12 / the mixer: SameSuite
  ## channel_1_sweep_restart_2's NR52 read landing on the sweep event still
  ## sees the channel on. Subtracted from the two delays below, not added.

const GB_SWEEP_CHECK_DELAY* = CycleCount(28)
  ## Scheduler cycles (7 M-cycles) between a sweep frequency writeback and the
  ## second overflow check that can stop the channel; plus GB_SWEEP_STOP_DELAY
  ## = the 8 M-cycles SameSuite channel_1_sweep / channel_1_sweep_restart
  ## rounds 3-5 measure. Pan Docs puts the second calculation in the same
  ## event; the check reads NR10 as it stands 7 M-cycles later. The first
  ## calculation is not delayed (channel_1_sweep_restart_2); a trigger's check
  ## adds one APU tick (channel_1_sweep_restart round 2).

const GB_SWEEP_SHADOW_DELAY* = CycleCount(8)
  ## Scheduler cycles (2 M-cycles) from a trigger reaching the sweep unit to
  ## the frequency shadow holding NR13/NR14 (SameSuite channel_1_sweep_restart_2:
  ## a restart leading a sweep event by 3 M-cycles is seen, by 2 is not). Only
  ## the shadow is deferred; the timer, `sweep_enabled` and `negate_used`
  ## reload on the write.

proc ch1_frequency_calc(ch: GbChannel1; gb: GB; at: CycleCount): uint16 =
  ## One sweep calculation at cycle `at` -- not always scheduler.cycles: the
  ## trailing check runs lazily, and its stop is dated from the check.
  let shifted = ch.frequency_shadow shr ch.shift
  var calc = int(ch.frequency_shadow) + (if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calc > 0x07FF:
    ch.sweep_stop_at = at + (GB_SWEEP_STOP_DELAY shl gb.scheduler.speed)
  result = uint16(calc and 0x7FFF)

proc ch1_sweep_run(ch: GbChannel1; gb: GB) =
  ## Not inline: the guard runs on every catch-up, this once per sweep period.
  ## Load, check and stop apply in deadline order (the check consumes the shadow).
  let now = gb.scheduler.cycles
  template do_load =
    if ch.sweep_load_at <= now:
      ch.sweep_load_at    = GB_NO_STEP
      ch.frequency_shadow = ch.sweep_load_value
  template do_check =
    if ch.sweep_check_at <= now:
      let at = ch.sweep_check_at
      ch.sweep_check_at = GB_NO_STEP
      # NR10 is re-read here, not captured when the check was armed
      # (channel_1_sweep_restart rounds 3-5). Gated on the shift, not the period:
      # a trigger arms this with sweep period 0 (blargg 06-overflow on trigger).
      if ch.sweep_enabled and ch.shift > 0:
        # One calculation whether armed by a trigger or a writeback. AGB
        # silicon adds a second at the trigger check (hardware: gbaedge
        # SWEEPQ/SWEEP2 on AGS-001); DMG/CGB do not (blargg 06-overflow on trigger).
        discard ch1_frequency_calc(ch, gb, at)
  if ch.sweep_check_at < ch.sweep_load_at:
    do_check(); do_load()
  else:
    do_load(); do_check()
  # Last: either calculation above can arm it.
  if ch.sweep_stop_at <= now:
    ch.sweep_stop_at = GB_NO_STEP
    ch.enabled = false

template ch1_sweep_due*(ch: GbChannel1; gb: GB) =
  ## Apply whatever the sweep unit has in flight that is due; runs on every
  ## observation point via ch1_catchup_at.
  if ch.sweep_load_at <= gb.scheduler.cycles or
     ch.sweep_check_at <= gb.scheduler.cycles or
     ch.sweep_stop_at <= gb.scheduler.cycles:
    ch1_sweep_run(ch, gb)

proc ch1_catchup_slow(ch: GbChannel1; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch1_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  # Later steps are one period apart, also across a mid-flight NR13/NR14 write.
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  if steps == 0: return
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  # Latching here (not in ch1_dac_input) makes a duty change take effect from
  # the next step and holds the pre-trigger sample through the startup delay.
  ch.sample_bit = WAVE_DUTY1[ch.duty][ch.wave_duty_position]
  ch.next_step += steps * period
  ch.last_step_at = ch.next_step - period

proc ch1_catchup_at*(ch: GbChannel1; gb: GB; observer_period: uint32) {.inline.} =
  ## Bring the duty position up to scheduler.cycles in closed form; must run
  ## before anything observes the position or changes the period.
  ## observer_period (GB_OBS_CPU for a CPU access) only affects a step landing
  ## on this exact cycle.
  ch1_sweep_due(ch, gb)
  if not ch.enabled:
    # Switching off freezes the phase; only an APU power-off resets it
    # (SameSuite channel_1_stop_restart). Parking the deadline keeps it from
    # going stale enough to underflow apu_rebase.
    ch.next_step = GB_NO_STEP
    return
  if ch.next_step > gb.scheduler.cycles: return   # not due (or never triggered)
  ch1_catchup_slow(ch, gb, observer_period)

proc ch1_catchup*(ch: GbChannel1; gb: GB) {.inline.} =
  ch1_catchup_at(ch, gb, GB_OBS_CPU)

proc ch1_reload_is_now(ch: GbChannel1; gb: GB): bool {.inline.} =
  ## True when a duty step landed on this cycle (the timer is reloading): an
  ## NR13/NR14 write landing here wins the reload (SameSuite
  ## channel_1_freq_change_timing); one M-cycle later it leaves the pending
  ## step alone (channel_1_freq_change). next_step alone will not do: a
  ## trigger's start delay makes a write two M-cycles after it look like one.
  ch.enabled and ch.last_step_at == gb.scheduler.cycles

proc sweep_step*(ch: GbChannel1; gb: GB) =
  # tick_frame_sequencer has caught the duty counter up: this changes ch.frequency.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calc = ch1_frequency_calc(ch, gb, gb.scheduler.cycles)
      if calc <= 0x07FF and ch.shift > 0:
        # The sweep's frequency write races the timer reload like an NR13/NR14
        # write (ch1_reload_is_now); at $7ff a step lands every M-cycle, so the
        # sweep tick always coincides (SameSuite channel_1_sweep_restart round 1).
        let reload_now = ch1_reload_is_now(ch, gb)
        ch.frequency_shadow = calc
        ch.frequency         = calc
        if reload_now: ch.next_step = gb.scheduler.cycles + ch1_period(ch, gb)
        # ...and the check on that value is 7 M-cycles away (GB_SWEEP_CHECK_DELAY).
        ch.sweep_check_at = gb.scheduler.cycles + (GB_SWEEP_CHECK_DELAY shl gb.scheduler.speed)

proc ch1_dac_input*(ch: GbChannel1): uint8 =
  ## 4-bit digital output (CGB PCM12); 0 while off. Masked to four bits: a
  ## hand-edited save state can hold a volume above 15 and this indexes GB_DAC_LUT.
  if ch.enabled and ch.dac_enabled:
    uint8(int(ch.sample_bit) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc ch1_pcm_edge_zero*(ch: GbChannel1; gb: GB): bool {.inline.} =
  ## Whether a PCM12 read on this cycle answers 0 for channel 1 (CGB 0/A/B/C
  ## read glitch, GbQuirks.pcm_read_edge_zero; the caller checks the quirk):
  ## the read sits on a duty step whose previous output was 0. The position is
  ## post-step, so the previous duty entry is the replaced output; the volume
  ## cannot move across a step without an envelope tick (an observation point).
  ch.enabled and ch.dac_enabled and ch.last_step_at == gb.scheduler.cycles and
    int(WAVE_DUTY1[ch.duty][(ch.wave_duty_position + 7) and 7]) *
      int(ch.current_volume) == 0

proc ch1_get_amplitude*(ch: GbChannel1): float32 =
  ## DAC-gated, not `enabled`-gated: a switched-off channel feeds digital 0
  ## (analog +1) to a powered DAC. See GB_DAC_LUT.
  if ch.dac_enabled: GB_DAC_LUT[ch.ch1_dac_input()] else: 0.0'f32

proc ch1_read*(ch: GbChannel1; idx: int): uint8 =
  case idx
  of 0xFF10: 0x80'u8 or (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift
  of 0xFF11: 0x3F'u8 or (ch.duty shl 6)
  of 0xFF12: read_NRx2(ch)
  of 0xFF13: 0xFF'u8  # write-only
  of 0xFF14: 0xBF'u8 or (if ch.length_enable: 0x40'u8 else: 0'u8)
  else:      0xFF'u8

proc ch1_write*(ch: GbChannel1; idx: int; val: uint8; gb: GB) =
  # apu_write caught the duty counter up; a period/duty change affects only
  # steps from now on.
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
    let reload_now = ch1_reload_is_now(ch, gb)
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
    if reload_now: ch.next_step = gb.scheduler.cycles + ch1_period(ch, gb)
  of 0xFF14:
    let reload_now = ch1_reload_is_now(ch, gb)
    # CGB D/E (GbQuirks.square_freq_backstep_halftick): a non-triggering write
    # dropping the frequency high bits out of 7 undoes the duty step it lands
    # within one 2 MHz tick of. `reload_now` covers the on-the-step half on
    # every revision; this is D/E's extra half tick. Unreachable at single speed.
    if gb.quirks.square_freq_backstep_halftick and (val and 0x80) == 0 and
       ch.enabled and (ch.frequency and 0x0700'u16) == 0x0700'u16 and
       (val and 0x07) != 0x07 and not reload_now and
       ch.last_step_at != GB_NO_STEP and
       gb.scheduler.cycles - ch.last_step_at == gb_apu_tick(gb) div 2:
      # Only the position moves; the latched sample stays where the undone
      # step put it. Assumed; no ROM pins this.
      ch.wave_duty_position = (ch.wave_duty_position + 7) and 7
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    if reload_now: ch.next_step = gb.scheduler.cycles + ch1_period(ch, gb)
    let len_enable = (val and 0x40) != 0
    # length_clock_any_nrx4: CGB 0 / A-B clock length on any NRx4 write, not
    # only one turning it on (GbQuirks).
    if gb.apu.first_half_of_length_period and not ch.length_enable and
       (len_enable or gb.quirks.length_clock_any_nrx4) and ch.length_counter > 0:
      dec ch.length_counter
      if ch.length_counter == 0: ch.enabled = false
    ch.length_enable = len_enable
    if (val and 0x80) != 0:  # trigger
      let was_enabled = ch.enabled
      if ch.dac_enabled: ch.enabled = true
      if ch.length_counter == 0:
        ch.length_counter = 0x40
        if ch.length_enable and gb.apu.first_half_of_length_period:
          dec ch.length_counter
      # The duty position carries across a trigger (only a power-off resets it);
      # so does the latched sample, so a channel that was off stays at 0 until
      # its first step.
      if not was_enabled: ch.sample_bit = 0
      ch.next_step = gb_trigger_deadline(gb, ch1_period(ch, gb),
                                         if was_enabled: 1 else: 2)
      init_volume_envelope(ch)
      ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
      ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
      ch.negate_used      = false
      # A pending sweep stop does not survive the restart (only reachable when
      # the trigger lands on the calculation's cycle). Assumed; no ROM pins this.
      ch.sweep_stop_at = GB_NO_STEP
      # The write reaches the sweep unit one tick after the one that latches it
      # (channel_1_sweep_restart round 2); the shadow load then takes
      # GB_SWEEP_SHADOW_DELAY (Pan Docs has it on the write; sweep_restart_2 not).
      let arrives = gb_apu_edge(gb) + gb_apu_tick(gb)
      ch.sweep_load_value = ch.frequency
      ch.sweep_load_at    = arrives + (GB_SWEEP_SHADOW_DELAY shl gb.scheduler.speed)
      # Pan Docs: with a non-zero shift the overflow check is immediate;
      # SameSuite channel_1_sweep_restart round 2 keeps the channel audible nine
      # more M-cycles, and the check reads the shadow loaded above by then.
      if ch.shift > 0:
        ch.sweep_check_at = arrives + (GB_SWEEP_CHECK_DELAY shl gb.scheduler.speed)
  else: discard
