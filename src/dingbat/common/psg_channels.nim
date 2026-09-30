# The PSG's four channels, `include`d by BOTH cores (gb.nim, gba.nim).
#
# One copy of the channel logic, compiled once per core: each core defines
# the hooks below and then includes this file, so a host's constants fold
# into its copy and neither pays for the other's branches. The channel state
# and the host-free state machines are in psg.nim.
#
# Hooks every host defines before the include:
#   PsgHost                   the core's machine type (GB / GBA)
#   PSG_AGB                   true in the GBA core
#   psg_now(h)                the scheduler's cycle count
#   psg_shl(h)                T-cycles (4 MHz) -> scheduler cycles, a shift:
#                             GB 0 / 1 by CGB speed, GBA 2 (16 MHz)
#   psg_length_half(h)        an NRx4 length enable now gets the extra clock
#   psg_cgb(h)                CGB-family silicon (GBA: always)
#   psg_q_length_any(h)       GbQuirks.length_clock_any_nrx4 (GBA: never)
#   psg_q_length_defer(h)     CGB A/B's deferred wave length stop (GBA: never)
#   psg_tick(h), psg_edge(h)  one 1 MHz APU tick; the grid's next edge
#   psg_trigger_deadline      a square trigger's first step, on that grid
#   psg_noise_phase(h)        the 512 kHz grid's phase (noise divisor stage)
#   psg_q_backstep(h)         GbQuirks.square_freq_backstep_halftick
#   psg_fs_next_edge_in(h), psg_fs_next_stage(h)
#                             scheduler cycles to the frame sequencer's next
#                             step, and which step it is
# and, only where the GB model runs (the `when not PSG_AGB` arms):
#   psg_sweep_trigger_extra   a trigger's phase against the frame sequencer
# and the GBA's ch1_settle / ch1_s0_kill_at (its measured shift-0 law).
#
# `when PSG_AGB` gates the places the GBA instance runs its own model: the
# sweep unit's checks, which the AGB SP measured to differ in GBA mode from
# the GB's (and from the same console running a GB cartridge); the
# scheduler tie-break each core inherited from its old per-period events;
# and the hardware only the GBA has (the second wave bank, the forced 75%
# level). Everything else is the GB model SameSuite, blargg and gambatte
# pin. Each gate says what differs.

# ---- Timing ----

template psg_steps_due(ch: PsgChannel; d, period: CycleCount;
                       ticks, observer_period: uint32): CycleCount =
  ## Waveform steps due, given d = (now - next_step) >= 0 and the step period
  ## in scheduler cycles. A step landing EXACTLY on the observer's cycle
  ## reproduces the old per-period event's tie-break: the more recently
  ## scheduled event fires first, so the step is included when the channel's
  ## period is the shorter one and deferred when it is the longer.
  when PSG_AGB:
    # GBA: the pending step's delay is the one it was armed with (a trigger
    # arms it with the frequency timer at trigger time, +6 on the wave
    # channel), every later one the current period apart.
    block:
      let m = d div period
      var s = m + 1
      if (d mod period) == 0:
        let arm = if m == 0: ch.arm_delay else: uint32(period)
        if arm > observer_period: dec s
      s
  else:
    # GB: compared in T-cycles; equal periods resolve as "include".
    block:
      var s = d div period + 1
      if ticks > observer_period and (d mod period) == 0: dec s
      s

template psg_period(ticks: uint32; h: PsgHost): CycleCount =
  CycleCount(ticks) shl psg_shl(h)

# ---- NRx4: the length enable edge and a trigger's reload ----

proc psg_nrx4_length(ch: PsgChannel; h: PsgHost; val: uint8;
                     defer_off: bool) {.inline.} =
  ## Enabling the length counter in the first half of a length period clocks
  ## it once, and can switch the channel off (Pan Docs). `defer_off`: CGB A/B
  ## defer that stop by one such clock on the wave channel (ch3_write).
  let len_enable = (val and 0x40) != 0
  # psg_q_length_any: CGB 0 / A-B clock length on any NRx4 write, not only
  # one turning it on (GbQuirks).
  if psg_length_half(h) and not ch.length_enable and
     (len_enable or psg_q_length_any(h)) and
     (ch.length_counter > 0 or (defer_off and ch.enabled)):
    if ch.length_counter == 0:
      ch.enabled = false            # the deferred switch-off, one clock late
    else:
      dec ch.length_counter
      if ch.length_counter == 0 and not defer_off: ch.enabled = false
  ch.length_enable = len_enable

proc psg_trigger_length(ch: PsgChannel; h: PsgHost; max_len: int) {.inline.} =
  ## A trigger reloads a zero counter, less the extra clock in the first half.
  ## After psg_nrx4_length: that order is AGB-measured (AGB SP,
  ## payloads/fsfirst.s: ch2, counter 1, trigger + length enable just after a
  ## master-on reaches the 0x20000-poll cap in all 31 cells).
  if ch.dac_enabled: ch.enabled = true
  if ch.length_counter == 0:
    ch.length_counter = max_len
    if ch.length_enable and psg_length_half(h):
      dec ch.length_counter

# ---- Envelope ----

proc write_nrx2(ch: PsgEnvChannel; value: uint8) =
  # Can clear ch.enabled (DAC off); the caller caught the channel up first.
  let new_add_mode = (value and 0x08) != 0
  let new_period   = value and 0x07
  if ch.enabled:
    # "Zombie mode": an NRx2 write to a running channel perturbs the live
    # volume. Pan Docs' rule (+1 if old period 0 and still updating, else +2
    # if old direction was decrease, then 16 - volume on a direction flip) is
    # only the `new inc` column. The full increment `d`, applied before the
    # flip, solved from SameSuite channel_1_volume and channel_1_nrx2_glitch
    # (and their channel_2 twins); rows old period/direction, columns new:
    #
    #                 | new dec, per 0 | new dec, per != 0 | new inc |
    #   old per 0 dec |       0        |        -1         |   +1    |
    #   old per!=0 dec|       0        |         0         |   +2    |
    #   old per 0 inc |       0        |        +1         |   +1    |
    #   old per!=0 inc|       0        |         0         |    0    |
    var d = 0
    if new_add_mode:
      d = if ch.period == 0 and ch.vol_env_is_updating: 1
          elif not ch.envelope_add_mode: 2
          else: 0
    elif new_period != 0 and ch.period == 0:
      d = if ch.envelope_add_mode: 1 else: -1
    ch.current_volume = uint8((int(ch.current_volume) + d) and 0x0F)
    if new_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  # Envelope-enable glitch: taking the period from zero to non-zero costs one
  # extra envelope tick at the next odd frame-sequencer stage (psg_seq_step;
  # SameSuite channel_1_nrx2_speed_change tests 3/4/6/7).
  if ch.enabled and ch.period == 0 and new_period != 0:
    ch.env_extra_tick = true
  elif new_period == 0:
    ch.env_extra_tick = false
  ch.starting_volume   = value shr 4
  ch.envelope_add_mode = new_add_mode
  ch.period            = new_period
  ch.dac_enabled       = (value and 0xF8) != 0
  if not ch.dac_enabled: ch.enabled = false

proc psg_env_trigger_extra(h: PsgHost): int =
  ## Extra envelope clocks for a trigger now (ENV_TRIGGER_PRECLOCK_SKIP): one
  ## for a trigger inside step 6's period, or taken within 4 T-cycles of its
  ## edge.
  when ENV_TRIGGER_PRECLOCK_SKIP == 0:
    0
  else:
    let d = psg_fs_next_edge_in(h)
    let lead = 4 shl psg_shl(h)
    let stage = psg_fs_next_stage(h)
    if (stage == 7 and d > lead) or (stage == 6 and d <= lead): 1 else: 0

template psg_trigger_envelope(ch: PsgEnvChannel; h: PsgHost) =
  init_volume_envelope(ch, psg_env_trigger_extra(h))

# ---- Square channels (1 and 2) ----

proc sq_timer(ch: PsgSquare): uint32 {.inline.} =
  ## Duty-step period in T-cycles.
  (0x800'u32 - uint32(ch.frequency)) * 4

template sq_period(ch: PsgSquare; h: PsgHost): CycleCount =
  psg_period(sq_timer(ch), h)

proc sq_catchup_slow(ch: PsgSquare; h: PsgHost; observer_period: uint32) =
  let now    = psg_now(h)
  let ticks  = sq_timer(ch)
  let period = psg_period(ticks, h)
  # Later steps are one period apart, also across a mid-flight NR13/NR14
  # write.
  let steps = psg_steps_due(ch, now - ch.next_step, period, ticks,
                            observer_period)
  if steps == 0: return
  when defined(psgverify):
    var want = ch.wave_duty_position
    for _ in 0 ..< steps: want = (want + 1) and 7
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  when defined(psgverify):
    doAssert want == ch.wave_duty_position, "square closed form != naive loop"
  # Latching here (not in the DAC input) makes a duty change take effect
  # from the next step and holds the pre-trigger sample through the startup
  # delay.
  ch.sample_bit = PSG_DUTY[ch.duty][ch.wave_duty_position]
  ch.next_step += steps * period
  ch.last_step_at = ch.next_step - period
  when PSG_AGB:
    # The step now pending was armed by the one before it, i.e. one CURRENT
    # period ago.
    ch.arm_delay = uint32(period)

proc sq_catchup_at(ch: PsgSquare; h: PsgHost; observer_period: uint32) {.inline.} =
  ## Bring the duty position up to the current cycle in closed form; must run
  ## before anything observes the position or changes the period.
  ## observer_period (PSG_OBS_CPU for a CPU access) only affects a step
  ## landing on this exact cycle.
  if not ch.enabled:
    # Switching off freezes the phase: the frequency timer is only clocked
    # while the channel runs, and only an APU power-off resets the position
    # (SameSuite channel_1_stop_restart). Parking the deadline keeps it from
    # going stale enough to underflow apu_rebase.
    ch.next_step = PSG_NO_STEP
    return
  if ch.next_step > psg_now(h): return   # not due (or never triggered)
  sq_catchup_slow(ch, h, observer_period)

proc sq_reload_is_now(ch: PsgSquare; h: PsgHost): bool {.inline.} =
  ## True when a duty step landed on this cycle (the timer is reloading): an
  ## NR13/NR14 write landing here wins the reload (SameSuite
  ## channel_1_freq_change_timing); one M-cycle later it leaves the pending
  ## step alone (channel_1_freq_change). next_step alone will not do: a
  ## trigger's start delay makes a write two M-cycles after it look like one.
  ch.enabled and ch.last_step_at == psg_now(h)

template sq_reload(ch: PsgSquare; h: PsgHost) =
  ## The write won the reload: the next step is one new period from now.
  ch.next_step = psg_now(h) + sq_period(ch, h)
  when PSG_AGB: ch.arm_delay = uint32(sq_period(ch, h))

proc sq_write_freq_lo(ch: PsgSquare; h: PsgHost; val: uint8) =
  let reload_now = sq_reload_is_now(ch, h)
  ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
  if reload_now: sq_reload(ch, h)

proc sq_write_freq_hi(ch: PsgSquare; h: PsgHost; val: uint8) =
  ## NRx4's frequency bits and length enable; the trigger is the caller's.
  let reload_now = sq_reload_is_now(ch, h)
  # CGB D/E (GbQuirks.square_freq_backstep_halftick): a non-triggering write
  # dropping the frequency high bits out of 7 undoes the duty step it lands
  # within one 2 MHz tick of. `reload_now` covers the on-the-step half on
  # every revision; this is D/E's extra half tick. Unreachable at single
  # speed.
  if psg_q_backstep(h) and (val and 0x80) == 0 and
     ch.enabled and (ch.frequency and 0x0700'u16) == 0x0700'u16 and
     (val and 0x07) != 0x07 and not reload_now and
     ch.last_step_at != PSG_NO_STEP and
     psg_now(h) - ch.last_step_at == psg_tick(h) div 2:
    # Only the position moves; the latched sample stays where the undone
    # step put it. Assumed; no ROM pins this.
    ch.wave_duty_position = (ch.wave_duty_position + 7) and 7
  ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
  if reload_now: sq_reload(ch, h)
  psg_nrx4_length(ch, h, val, defer_off = false)

proc sq_trigger(ch: PsgSquare; h: PsgHost) =
  ## The duty position carries across a trigger (Pan Docs: only an APU
  ## power-off resets it).
  let was_enabled = ch.enabled
  psg_trigger_length(ch, h, 0x40)
  # The latched sample carries too, so a channel that was off stays at 0
  # until its first step.
  if not was_enabled: ch.sample_bit = 0
  ch.next_step = psg_trigger_deadline(h, sq_period(ch, h),
                                      if was_enabled: 1 else: 2)
  when PSG_AGB: ch.arm_delay = uint32(ch.next_step - psg_now(h))
  psg_trigger_envelope(ch, h)

proc sq_write_duty(ch: PsgSquare; val: uint8) =
  ch.duty           = (val and 0xC0) shr 6
  ch.length_load    = val and 0x3F
  ch.length_counter = 0x40 - int(ch.length_load)

# ---- Channel 1's sweep unit ----

when not PSG_AGB:
  const GB_SWEEP_STOP_DELAY* = CycleCount(4)
    ## T-cycles (one APU tick) between a sweep overflow calculation and the
    ## stop becoming visible in NR52 / PCM12 / the mixer: SameSuite
    ## channel_1_sweep_restart_2's NR52 read landing on the sweep event still
    ## sees the channel on. Subtracted from the two delays below, not added.

  const GB_SWEEP_CHECK_DELAY* = CycleCount(28)
    ## T-cycles (7 M-cycles) between a sweep frequency writeback and the
    ## second overflow check that can stop the channel; plus
    ## GB_SWEEP_STOP_DELAY = the 8 M-cycles SameSuite channel_1_sweep /
    ## channel_1_sweep_restart rounds 3-5 measure. Pan Docs puts the second
    ## calculation in the same event; the check reads NR10 as it stands 7
    ## M-cycles later. The first calculation is not delayed
    ## (channel_1_sweep_restart_2); a trigger's check adds one APU tick
    ## (channel_1_sweep_restart round 2).

  const GB_SWEEP_SHADOW_DELAY* = CycleCount(8)
    ## T-cycles (2 M-cycles) from a trigger reaching the sweep unit to the
    ## frequency shadow holding NR13/NR14 (SameSuite channel_1_sweep_restart_2:
    ## a restart leading a sweep event by 3 M-cycles is seen, by 2 is not).
    ## Only the shadow is deferred; the timer, `sweep_enabled` and
    ## `negate_used` reload on the write.

proc ch1_sweep_calc(ch: PsgSweepSquare; h: PsgHost; at: CycleCount): uint16 =
  ## One sweep calculation, run at cycle `at` -- not always now: the GB's
  ## trailing check runs lazily, and its stop is dated from the check.
  let shifted = ch.frequency_shadow shr ch.shift
  when PSG_AGB:
    # GBA: an overflow stops the channel on the spot.
    var calculated = uint32(ch.frequency_shadow) +
                     uint32(if ch.negate: -int(shifted) else: int(shifted))
    if ch.negate: ch.negate_used = true
    if calculated > 0x07FF: ch.enabled = false
    uint16(calculated)
  else:
    var calc = int(ch.frequency_shadow) + (if ch.negate: -int(shifted) else: int(shifted))
    if ch.negate: ch.negate_used = true
    if calc > 0x07FF:
      ch.sweep_stop_at = at + (GB_SWEEP_STOP_DELAY shl psg_shl(h))
    uint16(calc and 0x7FFF)

when not PSG_AGB:
  proc ch1_sweep_run(ch: PsgSweepSquare; h: PsgHost) =
    ## Not inline: the guard runs on every catch-up, this once per sweep
    ## period. Load, check and stop apply in deadline order (the check
    ## consumes the shadow).
    let now = psg_now(h)
    template do_load =
      if ch.sweep_load_at <= now:
        ch.sweep_load_at    = PSG_NO_STEP
        ch.frequency_shadow = ch.sweep_load_value
    template do_check =
      if ch.sweep_check_at <= now:
        let at = ch.sweep_check_at
        ch.sweep_check_at = PSG_NO_STEP
        # NR10 is re-read here, not captured when the check was armed
        # (channel_1_sweep_restart rounds 3-5). Gated on the shift, not the
        # period: a trigger arms this with sweep period 0 (blargg
        # 06-overflow on trigger).
        if ch.sweep_enabled and ch.shift > 0:
          # One calculation whether armed by a trigger or a writeback (blargg
          # 06-overflow on trigger).
          discard ch1_sweep_calc(ch, h, at)
    if ch.sweep_check_at < ch.sweep_load_at:
      do_check(); do_load()
    else:
      do_load(); do_check()
    # Last: either calculation above can arm it.
    if ch.sweep_stop_at <= now:
      ch.sweep_stop_at = PSG_NO_STEP
      ch.enabled = false

template ch1_sweep_due(ch: PsgSweepSquare; h: PsgHost) =
  ## Apply whatever the sweep unit has in flight that is due: every reader of
  ## the channel's enable runs this first.
  when PSG_AGB:
    # GBA: nothing in flight but a shift-0 kill, which each reader settles
    # itself (ch1_settle).
    discard
  else:
    if ch.sweep_load_at <= psg_now(h) or
       ch.sweep_check_at <= psg_now(h) or
       ch.sweep_stop_at <= psg_now(h):
      ch1_sweep_run(ch, h)

proc sweep_step(ch: PsgSweepSquare; h: PsgHost) =
  # psg_seq_step has caught the duty counter up: this changes ch.frequency.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      when PSG_AGB: ch.s0_slow = false   # a calculation has run (ch1_s0_kill_at)
      let calc = ch1_sweep_calc(ch, h, psg_now(h))
      if calc <= 0x07FF and ch.shift > 0:
        # The sweep's frequency write races the timer reload like an
        # NR13/NR14 write (sq_reload_is_now); at $7ff a step lands every
        # M-cycle, so the sweep tick always coincides (SameSuite
        # channel_1_sweep_restart round 1).
        let reload_now = sq_reload_is_now(ch, h)
        ch.frequency_shadow = calc
        ch.frequency        = calc
        if reload_now: sq_reload(ch, h)
        when PSG_AGB:
          # AGB-native, measured: the second calculation, for its overflow
          # check, runs at once on the new shadow (AGB SP page 1F SWEEP2:
          # 2018/s7 dies at tick 1, the tick check >= 2048). A GB cartridge on
          # the same console runs the GB's pipeline below -- the AGS GB-slot
          # page is byte-identical to the MGB's (docs/hwprobe-questions.md
          # row 16) -- so this is the GBA mode's own, not a port to make.
          discard ch1_sweep_calc(ch, h, psg_now(h))
        else:
          # ...and the check on that value is 7 M-cycles away
          # (GB_SWEEP_CHECK_DELAY).
          ch.sweep_check_at = psg_now(h) + (GB_SWEEP_CHECK_DELAY shl psg_shl(h))

proc ch1_trigger_sweep(ch: PsgSweepSquare; h: PsgHost) =
  when PSG_AGB:
    let stale = ch.frequency_shadow
    let slow = ch.s0_slow   # (ch1_s0_kill_at) as the trigger finds it
    ch.frequency_shadow = ch.frequency
    ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8
    ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
    ch.negate_used      = false
    # A pending shift-0 kill from an earlier trigger does not survive this one
    ch.kill_at = PSG_NO_STEP
    if ch.shift > 0:
      # The trigger's overflow check (Pan Docs: with a non-zero shift) runs
      # on the new frequency AND on the one the shadow still held (AGB SP,
      # link rig 2026-09-24, tests/roms/dbsuite/payloads/sweeptrig.s): sweep
      # 0x21 at 1300 lives to its first tick after a master off/on at every
      # 16-cycle phase, but straight after a 1400 note that overflowed it
      # dies at the trigger (hwverified/sweep, cartridge; half the phases
      # over the rig). That is 1400 + 700 still in the shadow, not a second
      # pass over 1300 (1950 + 650), which the lone rows rule out. The
      # hardware's stale view is phase-dependent; this takes it always.
      let offset = int(ch.frequency_shadow shr ch.shift)
      let stale_offset = int(stale shr ch.shift)
      if ch.negate: ch.negate_used = true
      let fresh = int(ch.frequency_shadow) + (if ch.negate: -offset else: offset)
      let old = int(stale) + (if ch.negate: -stale_offset else: stale_offset)
      if fresh > 0x7FF or old > 0x7FF:
        ch.enabled = false
      ch.sweep_armed = true
      ch.s0_slow = false
    elif ch.sweep_armed:
      # Shift 0. Pan Docs has no check here, and games retrigger shift-0
      # notes above 0x400 all the time; but the AGB runs it -- f + f, which
      # overflows from 0x400 -- while the unit is ARMED: from a master-on,
      # or from a trigger with a non-zero shift, until a trigger's check has
      # run at shift 0. AGB SP (link rig 2026-09-25, payloads/s0trig.s, 144
      # cells, all stable): f = 0x400 dies at every 16-cycle phase when it
      # is the first trigger after a master-on (a frame before it, or 40
      # cycles; the latter spares 2 phases in 16), and lives at every
      # phase after a f = 0x100 trigger (playing, or stopped by its DAC), at
      # f = 0x3FF and with negate. psgfirst.s's third ch1 trigger in a row
      # lives in all 9 runs; sweeptrig.s's shift-0 row dies after shift-1
      # rows; gbaedge SWEEPQ's length-63 controls (f = 1024, NR10 = 0, after
      # shift-1 rows) died at poll 0.
      let at = ch1_s0_kill_at(psg_now(h), slow, ch.s0_anchor)
      if at != PSG_NO_STEP:
        # The check ran (a trigger it missed leaves the unit armed); the
        # stop is not at once: the channel reads as on for a few cycles.
        let offset = int(ch.frequency_shadow)
        if ch.negate: ch.negate_used = true
        let calc = int(ch.frequency_shadow) + (if ch.negate: -offset else: offset)
        if calc > 0x7FF and ch.enabled: ch.kill_at = at
        ch.sweep_armed = false
        ch.s0_slow = false
  else:
    ch.sweep_timer      = (if ch.sweep_period > 0: ch.sweep_period else: 8'u8) +
                          psg_sweep_trigger_extra(h)
    ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
    ch.negate_used      = false
    # A pending sweep stop does not survive the restart (only reachable when
    # the trigger lands on the calculation's cycle). Assumed; no ROM pins
    # this.
    ch.sweep_stop_at = PSG_NO_STEP
    # The write reaches the sweep unit one tick after the one that latches
    # it (channel_1_sweep_restart round 2); the shadow load then takes
    # GB_SWEEP_SHADOW_DELAY (Pan Docs has it on the write; sweep_restart_2
    # not).
    let arrives = psg_edge(h) + psg_tick(h)
    ch.sweep_load_value = ch.frequency
    ch.sweep_load_at    = arrives + (GB_SWEEP_SHADOW_DELAY shl psg_shl(h))
    # Pan Docs: with a non-zero shift the overflow check is immediate;
    # SameSuite channel_1_sweep_restart round 2 keeps the channel audible
    # nine more M-cycles, and the check reads the shadow loaded above by
    # then.
    if ch.shift > 0:
      ch.sweep_check_at = arrives + (GB_SWEEP_CHECK_DELAY shl psg_shl(h))

proc ch1_catchup_at(ch: PsgSweepSquare; h: PsgHost; observer_period: uint32) {.inline.} =
  ## See sq_catchup_at.
  ch1_sweep_due(ch, h)
  sq_catchup_at(ch, h, observer_period)

template ch1_catchup(ch: PsgSweepSquare; h: PsgHost) =
  ch1_catchup_at(ch, h, PSG_OBS_CPU)

template ch2_catchup_at(ch: PsgSquare; h: PsgHost; observer_period: uint32) =
  sq_catchup_at(ch, h, observer_period)

template ch2_catchup(ch: PsgSquare; h: PsgHost) =
  sq_catchup_at(ch, h, PSG_OBS_CPU)

proc ch1_write(ch: PsgSweepSquare; nr: int; val: uint8; h: PsgHost) =
  # The caller caught the duty counter up; a period/duty change affects only
  # steps from now on.
  case nr
  of NR10:
    ch.sweep_period = (val and 0x70) shr 4
    ch.negate       = (val and 0x08) != 0
    ch.shift        = val and 0x07
    if not ch.negate and ch.negate_used: ch.enabled = false
  of NR11: sq_write_duty(ch, val)
  of NR12: write_nrx2(ch, val)
  of NR13: sq_write_freq_lo(ch, h, val)
  of NR14:
    sq_write_freq_hi(ch, h, val)
    if (val and 0x80) != 0:
      sq_trigger(ch, h)
      ch1_trigger_sweep(ch, h)
  else: discard

proc ch2_write(ch: PsgSquare; nr: int; val: uint8; h: PsgHost) =
  case nr
  of NR21: sq_write_duty(ch, val)
  of NR22: write_nrx2(ch, val)
  of NR23: sq_write_freq_lo(ch, h, val)
  of NR24:
    sq_write_freq_hi(ch, h, val)
    if (val and 0x80) != 0: sq_trigger(ch, h)
  else: discard

# ---- Channel 3 (wave) ----

proc ch3_timer(ch: PsgWave): uint32 {.inline.} =
  ## Sample period in T-cycles.
  (0x800'u32 - uint32(ch.frequency)) * 2

template ch3_bank_base(ch: PsgWave): int =
  ## Offset of the bank CH3 plays (GBA SOUND3CNT_L bit 6; the GB has one).
  when PSG_AGB: int(ch.wave_ram_bank) * PSG_WAVE_BANK
  else:         0

proc ch3_catchup_slow(ch: PsgWave; h: PsgHost; observer_period: uint32) =
  let now    = psg_now(h)
  let ticks  = ch3_timer(ch)
  let period = psg_period(ticks, h)
  let steps = psg_steps_due(ch, now - ch.next_step, period, ticks,
                            observer_period)
  if steps == 0: return
  when PSG_AGB:
    # The GBA wave channel is the CGB one with a second 32-nibble bank: the
    # pointer is a free-running mod-32 counter and, in 64-step mode
    # (dimension), the bank flips every time it wraps to 0 (GBATEK
    # SOUND3CNT_L bit 5). So N steps land at (pos + N) mod 32 with the bank
    # toggled once per wrap -- wraps = (pos + N) div 32, and only its parity
    # matters.
    when defined(psgverify):
      # Per-period loop the closed form must agree with.
      var wpos  = ch.wave_ram_position
      var wbank = ch.wave_ram_bank
      var wbuf  = ch.wave_ram_sample_buffer
      for _ in 0 ..< steps:
        wpos = uint8(int(wpos + 1) mod (PSG_WAVE_BANK * 2))
        if wpos == 0 and ch.wave_ram_dimension: wbank = wbank xor 1
        let fs = ch.wave_ram[int(wbank) * PSG_WAVE_BANK + int(wpos div 2)]
        wbuf = (fs shr (if (wpos and 1) == 0: 4 else: 0)) and 0xF
    let total = CycleCount(ch.wave_ram_position) + steps
    ch.wave_ram_position = uint8(total and 31)
    if ch.wave_ram_dimension and ((total shr 5) and 1) != 0:
      ch.wave_ram_bank = ch.wave_ram_bank xor 1
    # Only the LAST read matters: wave RAM and the dimension/bank bits cannot
    # change between catch-ups (every wave RAM access and SOUND3CNT write
    # catches this channel up first).
    let full_sample = ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)]
    ch.wave_ram_sample_buffer =
      (full_sample shr (if (ch.wave_ram_position and 1) == 0: 4 else: 0)) and 0xF
    when defined(psgverify):
      doAssert wpos  == ch.wave_ram_position, "ch3 pointer closed form != naive loop"
      doAssert wbank == ch.wave_ram_bank, "ch3 bank closed form != naive loop"
      doAssert wbuf  == ch.wave_ram_sample_buffer, "ch3 sample buffer != naive loop"
    ch.next_step += steps * period
    # The step now pending was armed by the one before it, i.e. one CURRENT
    # period ago.
    ch.arm_delay = uint32(period)
  else:
    # Only the last fetch matters: wave_ram is immutable between catch-ups.
    ch.wave_ram_position = uint8((int(ch.wave_ram_position) + int(steps mod 32)) mod 32)
    ch.wave_fetched = true
    ch.wave_ram_sample_buffer = ch.wave_ram[ch.wave_ram_position div 2]
    ch.next_step += steps * period

proc ch3_catchup_at(ch: PsgWave; h: PsgHost; observer_period: uint32) {.inline.} =
  ## See sq_catchup_at. The wave pointer is a free-running mod-32 counter.
  if ch.next_step > psg_now(h): return
  ch3_catchup_slow(ch, h, observer_period)

template ch3_catchup(ch: PsgWave; h: PsgHost) =
  ch3_catchup_at(ch, h, PSG_OBS_CPU)

const GB_WAVE_ACCESS_WINDOW = 2
  ## Half of CH3's 1 MHz sample cycle in T-cycles: the pointer is clocked at
  ## 2 MHz, so each sample cycle has a fetch half and a hold half.

proc ch3_wave_open(ch: PsgWave; h: PsgHost): bool {.inline.} =
  ## Whether a CPU access to wave RAM resolves. Callers must have caught the
  ## pointer up. While CH3 is off wave RAM is plain memory; while on, CGB
  ## resolves the access against the byte being played and DMG only lets it
  ## through in the half-cycle after a completed fetch (blargg cgb_sound vs
  ## dmg_sound 09/10/12).
  if not ch.enabled:  return true
  if psg_cgb(h):      return true
  if not ch.wave_fetched: return false
  if ch.next_step == PSG_NO_STEP: return true
  let period = psg_period(ch3_timer(ch), h)
  let window = CycleCount(GB_WAVE_ACCESS_WINDOW) shl psg_shl(h)
  # next_step - now is in (0, period] after the catch-up.
  period - (ch.next_step - psg_now(h)) < window

proc ch3_wave_fetching(ch: PsgWave; h: PsgHost): bool {.inline.} =
  ## Whether CH3's own fetch is in flight on this cycle (the two T-cycles
  ## ending at next_step): the half-cycle adjacent to ch3_wave_open's CPU
  ## slot (blargg dmg_sound 09/10/12). DMG restart corruption only.
  if ch.next_step == PSG_NO_STEP: return false
  let window = CycleCount(GB_WAVE_ACCESS_WINDOW) shl psg_shl(h)
  ch.next_step - psg_now(h) <= window

proc ch3_wave_read(ch: PsgWave; h: PsgHost; i: int): uint8 =
  ## CPU read of wave RAM byte i (0..15). While enabled it returns the byte
  ## being played; the caller caught the pointer up first.
  if not ch3_wave_open(ch, h): 0xFF'u8
  elif ch.enabled: ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)]
  else:            ch.wave_ram[ch3_bank_base(ch) + i]

proc ch3_wave_write(ch: PsgWave; h: PsgHost; i: int; val: uint8) =
  ## A write lands at the position CH3 is playing while enabled; a DMG write
  ## outside the access window is dropped.
  if not ch3_wave_open(ch, h): discard
  elif ch.enabled: ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)] = val
  else:            ch.wave_ram[ch3_bank_base(ch) + i] = val

proc ch3_write(ch: PsgWave; nr: int; val: uint8; h: PsgHost) =
  # The caller caught the wave pointer up, so a period/dimension/bank/trigger
  # change below only affects steps from now on.
  case nr
  of NR30:
    ch.dac_enabled = (val and 0x80) != 0
    if not ch.dac_enabled:
      ch.enabled = false
      when not PSG_AGB:
        # The sample buffer clears with the DAC: SameSuite
        # channel_3_restart_stop_delay (restart after an NR30 stop is silent
        # through the startup delay) vs channel_3_restart_delay (a plain
        # restart keeps the old sample). Power-off reaches here through
        # NR30 = 0.
        ch.wave_ram_sample_buffer = 0
    when PSG_AGB:
      ch.wave_ram_dimension = (val and 0x20) != 0
      ch.wave_ram_bank      = (val shr 6) and 1
  of NR31:
    ch.length_load    = val
    ch.length_counter = 0x100 - int(ch.length_load)
  of NR32:
    ch.volume_code = (val and 0x60) shr 5
    ch.volume_code_shift = case ch.volume_code
      of 0b00: 4'u8
      of 0b01: 0'u8
      of 0b10: 1'u8
      else:    2'u8
    when PSG_AGB: ch.volume_force = (val and 0x80) != 0
  of NR33:
    ch.frequency = (ch.frequency and 0x0700'u16) or uint16(val)
  of NR34:
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    # CGB A/B additionally defer the length switch-off by one such clock, on
    # the wave channel only: SameSuite channel_3_extra_length_clocking-cgb0
    # and -cgbB differ only in their expected tables, and every CGB-B cell is
    # the CGB-0 answer for one fewer write. `enabled and length_counter == 0`
    # is reachable by no other path, so the pending switch-off needs no state
    # of its own.
    psg_nrx4_length(ch, h, val, defer_off = psg_q_length_defer(h))
    if (val and 0x80) != 0:
      # Pan Docs, Wave RAM: a DMG restart while CH3 is reading wave RAM
      # corrupts the first four bytes (byte 0 from the byte being read if it
      # is in the first four, else the aligned group of four). The window is
      # the half-cycle in which the fetch is in flight: ch3_wave_fetching.
      if ch.enabled and not psg_cgb(h) and ch3_wave_fetching(ch, h):
        # The byte being read is the one the fetch is about to latch (blargg
        # dmg_sound 10).
        let byte_idx = ((int(ch.wave_ram_position) + 1) mod 32) div 2
        if byte_idx < 4:
          ch.wave_ram[0] = ch.wave_ram[byte_idx]
        else:
          let base = byte_idx and not 3
          for i in 0 ..< 4: ch.wave_ram[i] = ch.wave_ram[base + i]
      psg_trigger_length(ch, h, 0x100)
      when PSG_AGB:
        # GBA: period + 6 from now, the +6 outside the x4 clock scale.
        let arm = uint32(psg_period(ch3_timer(ch), h)) + 6
        ch.next_step = psg_now(h) + CycleCount(arm)
        ch.arm_delay = arm
      else:
        # Period plus a 6 T-cycle startup, inside the speed shift.
        ch.next_step = psg_now(h) + psg_period(ch3_timer(ch) + 6, h)
      # wave_ram_sample_buffer is not reset: the last byte read keeps being
      # output until the next fetch (Pan Docs).
      ch.wave_ram_position = 0
      ch.wave_fetched = false
  else: discard

# ---- Channel 4 (noise) ----

proc ch4_timer(ch: PsgNoise): uint32 {.inline.} =
  ## Full LFSR period in T-cycles.
  (if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift

# Two-stage frequency timer. NR43's `divisor << shift` is the LFSR period,
# not the counter: SameSuite channel_4_freq_change switches between two
# encodings of the same period mid-note and gets different answers, so an
# NR43 write re-interprets existing state. Model: a divisor stage that
# increments a counter every 4 T-cycles for code 0 and every 8*code
# otherwise (half the quoted divisor), and a free-running counter whose bit
# `clock_shift` clocks the LFSR on its rising edge. A write selects a
# different bit of the same counter and leaves the stage's countdown
# running; only a write landing on the cycle of an increment reloads with
# the new divisor, rounded up to the 512 kHz grid (a code != 0 stage can
# only reload on a grid edge).

proc ch4_lfsr_frozen(ch: PsgNoise): bool {.inline.} =
  ## Shifts 14 and 15 tap a bit the counter does not have, so the LFSR is
  ## never clocked (Pan Docs, NR43). next_step parks at PSG_NO_STEP while
  ## the divisor stage keeps counting, so a later NR43 write that lowers
  ## the shift resumes from the held count. A state saved while frozen
  ## loses that count (ch4_resync_divisor).
  ch.clock_shift >= 14'u8

proc ch4_inc_period(ch: PsgNoise; h: PsgHost): CycleCount {.inline.} =
  ## One divisor-stage increment, in scheduler cycles.
  psg_period(if ch.divisor_code == 0: 4'u32 else: uint32(ch.divisor_code) shl 3, h)

proc ch4_next_shift(ch: PsgNoise; h: PsgHost): CycleCount {.inline.} =
  ## Rebuild the derived LFSR deadline from the two stages.
  ch.div_next + CycleCount(ch4_steps_to_rise(ch.div_counter, ch.clock_shift) - 1) *
                ch4_inc_period(ch, h)

proc ch4_advance_divisor(ch: PsgNoise; h: PsgHost) =
  ## Run the divisor stage to the current cycle without touching the LFSR.
  ## `div_next` is exact at every point the increment period could have
  ## changed, so the increments since are one division away. Callers must
  ## have run ch4_catchup first (next rising edge strictly in the future).
  ## The frame rebase calls it once a frame, bounding `now - div_next`.
  if ch.div_next == PSG_NO_STEP: return
  let now = psg_now(h)
  if ch.div_next > now: return
  let inc = ch4_inc_period(ch, h)
  let n   = (now - ch.div_next) div inc + 1
  ch.div_counter += uint16(n and CycleCount(0xFFFF))
  ch.div_next    += n * inc

proc psg_noise_grid_up(h: PsgHost; t: CycleCount; divisor_code: uint8): CycleCount {.inline.} =
  ## Round a divisor-stage reload up onto the 512 kHz grid (psg_noise_phase).
  ## Divisor code 0 taps the 1 MHz half-step and has no grid to miss.
  if divisor_code == 0: return t
  let tick = psg_tick(h)
  let half = 2 * tick
  t + ((tick + psg_noise_phase(h) + half - (t mod half)) mod half)

proc psg_noise_deadline(h: PsgHost; period: CycleCount; divisor_code: uint8;
                        restarting: bool): CycleCount =
  ## Absolute cycle of channel 4's first LFSR shift after a trigger. Two
  ## parts: the first period is half-length (a trigger clears the
  ## divide-by-two on the divisor stage's output; a restart of a running
  ## channel leaves it alone and waits a full period) -- SameSuite
  ## channel_4_delay's rows are `period/2 + 2` M-cycles,
  ## channel_4_lfsr_restart pins the restart -- and the divisor stage is
  ## clocked by a 512 kHz grid a trigger cannot reset (psg_noise_phase):
  ## divisor code 0 starts on the 1 MHz tick, code 1 rounds it up to the
  ## grid, codes >= 2 round it down (channel_4_frequency_alignment;
  ## cross-checked by channel_4_equivalent_frequencies and channel_4_align).
  ## Codes 5-7 are not exercised by any test and follow the >= 2 case.
  let tick = psg_tick(h)
  let edge = psg_edge(h)
  var extra = 2 * tick
  if divisor_code != 0:
    let half = 2 * tick
    if ((edge + half - psg_noise_phase(h)) mod half) != tick:
      # Off the 512 kHz grid. Adjusting `extra` rather than `edge` keeps the
      # sum from underflowing in the down-rounding case.
      extra = (if divisor_code == 1: extra + tick else: extra - tick)
  edge + (if restarting: period else: period div 2) + extra

proc ch4_catchup_slow(ch: PsgNoise; h: PsgHost; observer_period: uint32) =
  let now    = psg_now(h)
  let ticks  = ch4_timer(ch)
  let period = psg_period(ticks, h)
  let steps = psg_steps_due(ch, now - ch.next_step, period, ticks,
                            observer_period)
  # steps == 0: the tie went to the observer; checking `enabled` first would
  # park the channel a step early.
  if steps == 0: return
  # A disabled channel shifts once more, then parks. Every path that clears
  # `enabled` catches this channel up first, so next_step is past the moment
  # of disabling. One call site for the shift: a second one tips clang into
  # outlining it, and this loop is the PSG's hottest (<= 8778 shifts a
  # frame at the shortest divisor, bounded by the per-frame catch-up). There
  # is no cheap closed form for the LFSR. A scheduler event per shift would
  # pin the event horizon at 32 cycles and defeat HALT/fast_forward. The
  # GB's divisor stage is not advanced here: it only changes at NR43 writes,
  # triggers and speed switches, each of which settles it
  # (ch4_advance_divisor); advancing it per sample would cost every sample.
  let running = ch.enabled
  for _ in 0 ..< (if running: steps else: 1): psg_lfsr_shift(ch)
  if not running:
    ch.next_step = PSG_NO_STEP
    ch.div_next  = PSG_NO_STEP
    return
  ch.next_step += steps * period
  when PSG_AGB:
    # The step now pending was armed by the one before it, i.e. one CURRENT
    # period ago.
    ch.arm_delay = uint32(period)

proc ch4_catchup_at(ch: PsgNoise; h: PsgHost; observer_period: uint32) {.inline.} =
  ## See sq_catchup_at. Unlike the other three this is O(steps), not O(1).
  if ch.next_step > psg_now(h): return
  ch4_catchup_slow(ch, h, observer_period)

template ch4_catchup(ch: PsgNoise; h: PsgHost) =
  ch4_catchup_at(ch, h, PSG_OBS_CPU)

proc ch4_write(ch: PsgNoise; nr: int; val: uint8; h: PsgHost) =
  case nr
  of NR41:
    ch.length_load    = val and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of NR42:
    write_nrx2(ch, val)
  of NR43:
    # The caller caught the channel up (no rising edge pending); bring the
    # divisor stage the rest of the way.
    let old_inc = ch4_inc_period(ch, h)
    ch4_advance_divisor(ch, h)
    let running = ch.div_next != PSG_NO_STEP
    # `== old_inc`: an increment landed on this very cycle, so the countdown
    # sits at a fresh reload and the reload rule applies.
    let on_reload = running and ch.div_next - psg_now(h) == old_inc
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
    if running:
      if on_reload:
        ch.div_next = psg_noise_grid_up(h, psg_now(h) + ch4_inc_period(ch, h),
                                        ch.divisor_code)
      # Shift 14/15 parks the LFSR (ch4_lfsr_frozen); the divisor stage keeps
      # running so a later write can thaw it.
      ch.next_step = if ch4_lfsr_frozen(ch): PSG_NO_STEP
                     else: ch4_next_shift(ch, h)
      when PSG_AGB: ch.arm_delay = uint32(ch4_timer(ch)) shl psg_shl(h)
  of NR44:
    psg_nrx4_length(ch, h, val, defer_off = false)
    if (val and 0x80) != 0:
      let was_enabled = ch.enabled
      psg_trigger_length(ch, h, 0x40)
      # Noise startup: half a period plus two ticks off the 512 kHz grid, a
      # full period on a restart; see psg_noise_deadline.
      let deadline = psg_noise_deadline(h, psg_period(ch4_timer(ch), h),
                                        ch.divisor_code, was_enabled)
      # Shift 14/15: the divisor stage starts but the LFSR never fires.
      ch.next_step = if ch4_lfsr_frozen(ch): PSG_NO_STEP else: deadline
      when PSG_AGB: ch.arm_delay = uint32(deadline - psg_now(h))
      # Split the deadline into its two stages: a fresh start leaves the
      # counter at 0 (half a period from the rising edge), a restart leaves
      # it on the edge it just produced (a full period). Both put the first
      # increment at the same place, so the subtraction is exact.
      ch.div_counter = (if was_enabled: 1'u16 shl int(ch.clock_shift) else: 0'u16)
      ch.div_next = deadline -
        CycleCount(ch4_steps_to_rise(ch.div_counter, ch.clock_shift) - 1) *
        ch4_inc_period(ch, h)
      psg_trigger_envelope(ch, h)
      ch.lfsr = 0x7FFF'u16
  else: discard

# ---- The register block ----

proc psg_read_bits(h: PsgHost; nr: int): uint8 =
  ## The readable bits of a channel register; each host ORs its own values
  ## for the rest (GB: ones; GBA: zeros, plus SOUND3CNT's bank/dimension and
  ## force bits).
  let apu = h.apu
  case nr
  of NR10:
    let ch = apu.channel1
    (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift
  of NR11: apu.channel1.duty shl 6
  of NR12: read_nrx2(apu.channel1)
  of NR14: (if apu.channel1.length_enable: 0x40'u8 else: 0'u8)
  of NR21: apu.channel2.duty shl 6
  of NR22: read_nrx2(apu.channel2)
  of NR24: (if apu.channel2.length_enable: 0x40'u8 else: 0'u8)
  of NR30: (if apu.channel3.dac_enabled: 0x80'u8 else: 0'u8)
  of NR32: apu.channel3.volume_code shl 5
  of NR34: (if apu.channel3.length_enable: 0x40'u8 else: 0'u8)
  of NR42: read_nrx2(apu.channel4)
  of NR43:
    let ch = apu.channel4
    (ch.clock_shift shl 4) or (ch.width_mode shl 3) or ch.divisor_code
  of NR44: (if apu.channel4.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc psg_write_reg(h: PsgHost; nr: int; val: uint8) =
  ## A write to channel register `nr`; the caller caught its channel up.
  let apu = h.apu
  case nr
  of NR10 .. NR14: ch1_write(apu.channel1, nr, val, h)
  of NR21 .. NR24: ch2_write(apu.channel2, nr, val, h)
  of NR30 .. NR34: ch3_write(apu.channel3, nr, val, h)
  of NR41 .. NR44: ch4_write(apu.channel4, nr, val, h)
  else: discard

# ---- The frame sequencer's step ----

proc psg_seq_step(apu: typeof(PsgHost().apu); h: PsgHost) =
  ## One 512 Hz step: length on the even steps, sweep on 2 and 6, the
  ## envelopes on 7. Every channel must be current first: length_step clears
  ## `enabled` and sweep_step rewrites channel 1's frequency. Each host's
  ## driver handles its own skipped edge and re-arms the next. `apu` rather
  ## than h.apu: the GBA's first step runs inside new_apu, before h.apu is
  ## set.
  apu.first_half_of_length_period = (apu.frame_sequencer_stage and 1) == 0
  case apu.frame_sequencer_stage
  of 0, 4:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
  of 2, 6:
    length_step(apu.channel1); length_step(apu.channel2)
    length_step(apu.channel3); length_step(apu.channel4)
    sweep_step(apu.channel1, h)
  of 7:
    volume_step(apu.channel1); volume_step(apu.channel2); volume_step(apu.channel4)
  else: discard
  if (apu.frame_sequencer_stage and 1) == 1:
    # Envelope-enable glitch's extra tick; see PsgEnvChannel.env_extra_tick.
    template extra(ch: untyped) =
      if ch.env_extra_tick:
        ch.env_extra_tick = false
        volume_step(ch)
    extra(apu.channel1)
    extra(apu.channel2)
    extra(apu.channel4)
  apu.frame_sequencer_stage += 1
  if apu.frame_sequencer_stage > 7: apu.frame_sequencer_stage = 0
