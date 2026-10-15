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
# and the GBA's ch1_settle / ch1_s0_kill_at (its measured shift-0 law), and
# the GB's psg_cpu_bus_addr(h) (the CPU's next bus address, ch3_write).
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
    #
    # The AGB differs in the two `new inc` cells of period 0: a period-0
    # envelope is never "still updating" there, so they give +2 (decrease)
    # and 0 (increase). AGB SP, by ear (tests/roms/payloads/nrx2table.s,
    # tools/hwlink/nrx2table_listen.py, 2026-09-30): 0x88 over a volume-8
    # note 6 (CGB: 7), 0x68 over volume 6 decreasing 8 (CGB: 9), 0x68 over
    # volume 6 increasing 6 (CGB: 7), three rounds each; the cells both
    # tables agree on read as predicted.
    let still_updating = when PSG_AGB: false else: ch.vol_env_is_updating
    var d = 0
    if new_add_mode:
      d = if ch.period == 0 and still_updating: 1
          elif not ch.envelope_add_mode: 2
          else: 0
    elif new_period != 0 and ch.period == 0:
      d = if ch.envelope_add_mode: 1 else: -1
    ch.current_volume = uint8((int(ch.current_volume) + d) and 0x0F)
    if new_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  # Envelope-enable glitch: taking the period from zero to non-zero costs one
  # extra envelope tick at a later frame-sequencer step (psg_seq_step;
  # SameSuite channel_1_nrx2_speed_change tests 3/4/6/7). Armed here as one
  # step away; the GB's psg_write_nrx2 moves it to the step it lands on.
  if ch.enabled and ch.period == 0 and new_period != 0:
    ch.env_extra_tick = 1
  elif new_period == 0:
    ch.env_extra_tick = 0
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

when not PSG_AGB:
  # GB only: the AGB has no such lead (ch1_trigger_sweep).
  proc psg_sweep_trigger_extra(h: PsgHost): uint8 =
    ## Extra sweep clocks for a trigger now (SWEEP_TRIGGER_LEAD_T_*): one for a
    ## trigger within the lead before a sweep clock (steps 2 and 6).
    let lead_t = (if psg_cgb(h): SWEEP_TRIGGER_LEAD_T_CGB
                  else: SWEEP_TRIGGER_LEAD_T_DMG)
    if lead_t == 0: return 0
    let d = psg_fs_next_edge_in(h)
    let stage = psg_fs_next_stage(h)
    # The lead is CPU cycles (one or two M-cycles), not real time: at double
    # speed a CGB trigger 3 M-cycles (6 T) before the clock takes it (DocBoy
    # double_speed change_period_nr14_during_recalc{,_double_trigger_*}_
    # delay12240, step0_delay12240), so the 8 T lead is 4 T there.
    if (stage == 2 or stage == 6) and d <= lead_t: 1
    else: 0

when PSG_AGB:
  template psg_trigger_envelope(ch: PsgEnvChannel; h: PsgHost) =
    init_volume_envelope(ch, psg_env_trigger_extra(h))

  template psg_write_nrx2(ch: PsgEnvChannel; h: PsgHost; value: uint8) =
    write_nrx2(ch, value)

  template psg_volume_step(ch: PsgEnvChannel) = volume_step(ch)
else:
  # GB: the envelope timer counts whatever the period, a period of 0 counting
  # as 8 (Pan Docs, "Audio Details": "The volume envelope and sweep timers
  # treat a period of 0 as 8"); 0 only stops the volume moving. So a channel
  # triggered at period 0 and given a period later steps when the 8 clocks
  # run out, not at the next clock, and the new period loads only then
  # ("changes apply after the next tick", SameSuite channel_1_nrx2_speed_
  # change). DocBoy cgb/apu/ch1 ch1_change_volume_sweep_pace_*: a trigger at
  # $A8 and $A9..$AF written anywhere from 1 to 15 DIV-APU steps later all
  # step at the trigger's eighth envelope clock; SameBoy agrees.
  proc gb_env_expire(ch: PsgEnvChannel; extra: int) =
    ## The timer ran out (or the enable glitch stood in for it): reload, and
    ## move the volume one step if the period allows.
    ch.volume_envelope_timer = (if ch.period != 0: ch.period else: 8'u8) +
                               uint8(extra)
    if ch.period != 0:
      if (ch.current_volume < 0xF and ch.envelope_add_mode) or
         (ch.current_volume > 0 and not ch.envelope_add_mode):
        if ch.envelope_add_mode: inc ch.current_volume
        else:                    dec ch.current_volume
      else:
        ch.vol_env_is_updating = false

  proc psg_volume_step(ch: PsgEnvChannel) =
    ## One envelope clock (DIV-APU step 7).
    if ch.volume_envelope_timer > 0: dec ch.volume_envelope_timer
    if ch.volume_envelope_timer == 0: gb_env_expire(ch, 0)

  template psg_trigger_envelope(ch: PsgEnvChannel; h: PsgHost) =
    let extra = psg_env_trigger_extra(h)
    ch.volume_envelope_timer = (if ch.period != 0: ch.period else: 8'u8) +
                               uint8(extra)
    ch.current_volume        = ch.starting_volume
    ch.vol_env_is_updating   = true

  proc psg_write_nrx2(ch: PsgEnvChannel; h: PsgHost; value: uint8) =
    write_nrx2(ch, value)
    if ch.env_extra_tick != 0:
      # The enable glitch's tick lands on the first DIV-APU step after the
      # tap bit next rises: the next step if the bit is low now, else the
      # one after. SameSuite channel_1_nrx2_speed_change tests 6/7 (written
      # 5 M-cycles after a rise and after a fall) both tick on the second
      # step, the "next even" its header names; DocBoy ch1_change_volume_
      # sweep_pace_{1,2}_timer_0_div_apu_4 vs _alt, one M-cycle either side
      # of a rise, tick on the next step and on the one after (where it
      # meets the regular clock and is lost); SameBoy agrees, and moves the
      # tick with the rise in probe ROMs between (docs/gb-failure-triage.md
      # I8).
      let d = psg_fs_next_edge_in(h)
      let half = (2 shl (12 + int(psg_shl(h)))) div 2
      ch.env_extra_tick = (if d > half: 1'u8 else: 2'u8)

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
  # The GB's sweep unit computes shadow +/- (shadow >> step) one shift per
  # 1 MHz APU tick, so a calculation takes `step` ticks and its overflow
  # check lands half a tick after the last. The shifted operand is held
  # between calculations (`sweep_operand`) and the adder works on it live,
  # in NR10's current direction: a sweep clock writes back what the adder
  # shows and checks its overflow, then starts the next calculation on the
  # value it wrote. Pan Docs ("Frequency Sweep") has both calculations
  # happen at once and gives no timing; the timing and the corner cases
  # below are DocBoy's `ch1_period_sweep_*` rows (docs/gb-failure-triage.md
  # I2), each one SameBoy (black box) also passes unless marked, and
  # SameSuite's channel_1_sweep* (CGB hardware) fall out of it.
  const SWEEP_LOAD_ARRIVAL* = 1'u8
    ## sweep_load_at is a trigger reaching the sweep unit: one APU tick after
    ## the tick the NR14 write lands on.
  const SWEEP_LOAD_LATCH* = 2'u8
    ## sweep_load_at is a sweep clock's calculation latching its inputs, just
    ## after the clock's 1 MHz edge: a CPU write on that edge's M-cycle
    ## (NR10's step, NR13/NR14) is in the calculation (DocBoy
    ## change_step_during_recalc_*_round1, change_period_nr13_during_recalc_
    ## round2_*, double_speed change_period_nr14_during_recalc_no_retrigger_
    ## delay12244).
  const SWEEP_LOAD_REASSERT* = 3'u8
    ## sweep_load_at is a sweep clock's write-back reaching NR13/NR14 on the
    ## 1 MHz edge after the clock, at double speed half a tick past it: a CPU
    ## write in between is lost (double_speed change_period_nr14_during_
    ## recalc_no_retrigger_delay12243). The latch follows.
  const SWEEP_LOAD_REASSERT_ONLY* = 4'u8
    ## As SWEEP_LOAD_REASSERT, for a clock that writes 0 and starts nothing.
  const SWEEP_LOAD_LATCH_STEP0* = 5'u8
    ## As SWEEP_LOAD_LATCH, after a clock that wrote nothing back (step 0): a
    ## step written on the clock's own M-cycle, with no calculation ended
    ## since the trigger, makes it the clock that writes 0 (ch1_sweep_clock;
    ## DocBoy change_step_during_recalc_0_to_{4,6}_round1, DocBoy only).

  template sweep_tick_len(h: PsgHost): CycleCount = psg_tick(h)

  proc ch1_sweep_sum(ch: PsgSweepSquare): int {.inline.} =
    ## The adder's output now: the shadow plus or minus the held operand.
    int(ch.frequency_shadow) +
      (if ch.negate: -int(ch.sweep_operand) else: int(ch.sweep_operand))

  proc ch1_sweep_start(ch: PsgSweepSquare; h: PsgHost; t0: CycleCount) =
    ## A calculation starting at tick t0 with the step NR10 holds now. It
    ## ends `step` ticks later, half a tick past that edge: its stop is
    ## clocked on the 1 MHz clock's other edge, which double speed's reads,
    ## two per tick, tell from the next tick (DocBoy double_speed
    ## disable_on_trigger_step4_a1: off 2N + 5 M-cycles after the 1 MHz
    ## edge, not 2N + 6), and a CPU write on the edge's own M-cycle lands
    ## before it (change_direction_to_decrease_during_recalc_round1,
    ## change_direction_to_increase_step6_round1).
    ch.sweep_calc_n = ch.shift
    ch.sweep_load_value = ch.frequency_shadow
    ch.sweep_check_at = t0 + CycleCount(ch.shift) * sweep_tick_len(h) +
                        sweep_tick_len(h) div 2

  proc ch1_sweep_latch(ch: PsgSweepSquare; h: PsgHost; t0: CycleCount) =
    ## A sweep clock's calculation takes its inputs: the shadow from
    ## NR13/NR14 as they stand, the step from NR10.
    ch.frequency_shadow = ch.frequency
    ch1_sweep_start(ch, h, t0)

  template ch1_sweep_t0(ch: PsgSweepSquare; h: PsgHost): CycleCount =
    ## The tick the calculation in flight started on.
    ch.sweep_check_at - sweep_tick_len(h) div 2 -
      CycleCount(ch.sweep_calc_n) * sweep_tick_len(h)

  proc ch1_sweep_arrive(ch: PsgSweepSquare; h: PsgHost; at: CycleCount) =
    ## A trigger reaching the sweep unit at tick `at`: the shadow takes
    ## NR13/NR14, the operand clears, and the trigger's calculation (Pan
    ## Docs: the overflow check, which only stops the channel at a non-zero
    ## step) starts. From idle it starts a tick later (fresh: the stop is
    ## step + 3 M-cycles after the write, DocBoy disable_on_trigger_step1..7);
    ## a calculation still running is restarted on this tick (step + 2:
    ## DocBoy disable_on_double_trigger_*, SameSuite channel_1_sweep_restart
    ## round 2).
    let tick = sweep_tick_len(h)
    if ch.sweep_check_at != PSG_NO_STEP and at == ch1_sweep_t0(ch, h) + tick:
      # One tick into a calculation the trigger waits a tick
      # (disable_on_double_trigger_step{1,6}_delay0{0,}; DocBoy only: SameBoy
      # restarts at once).
      ch.sweep_load_at = at + tick + 1
      ch.sweep_load_kind = SWEEP_LOAD_ARRIVAL
      return
    ch.frequency_shadow = ch.frequency
    ch.sweep_operand = 0
    ch.sweep_operand_valid = false
    ch.sweep_frozen = 0
    ch.sweep_stop_at = PSG_NO_STEP
    if ch.shift == 0:
      # Step 0: no calculation (Pan Docs), and one in flight is dropped.
      ch.sweep_check_at = PSG_NO_STEP
    elif ch.sweep_check_at != PSG_NO_STEP:
      ch1_sweep_start(ch, h, at)
    else:
      ch1_sweep_start(ch, h, at + tick)

  template ch1_sweep_trigger_pending(ch: PsgSweepSquare): bool =
    ch.sweep_load_at != PSG_NO_STEP and ch.sweep_load_kind == SWEEP_LOAD_ARRIVAL

  proc ch1_sweep_complete(ch: PsgSweepSquare) =
    ## A calculation's end: the operand is shifted into place and the
    ## overflow check runs on the adder (in NR10's direction as it is now)
    ## while NR10's step is non-zero. A check in subtraction mode arms the
    ## direction-clear stop (Pan Docs, "Obscure Behavior"). A trigger still
    ## on its way to the sweep unit holds the channel on (DocBoy
    ## disable_on_double_trigger_step1_delay{0,1}, step6_delay5: the first
    ## trigger's calculation ends just as the second is written; DocBoy
    ## only, SameBoy stops the channel).
    ch.sweep_check_at = PSG_NO_STEP
    ch.sweep_operand = ch.sweep_load_value shr ch.sweep_calc_n
    ch.sweep_operand_valid = true
    if ch1_sweep_trigger_pending(ch) or ch.shift == 0: return
    if ch.negate: ch.negate_used = true
    if ch1_sweep_sum(ch) > 0x7FF:
      ch.enabled = false

  proc ch1_sweep_run(ch: PsgSweepSquare; h: PsgHost) =
    ## Not inline: the guard runs on every catch-up, this a few times per
    ## sweep period. Everything due runs in time order; on a tie a trigger's
    ## arrival goes first (it restarts the calculation ending on that tick),
    ## then a calculation's end, then a sweep clock's stop.
    let now = psg_now(h)
    while true:
      let l = ch.sweep_load_at
      let c = ch.sweep_check_at
      let s = ch.sweep_stop_at
      let m = min(l, min(c, s))
      if m > now: break
      if l == m:
        ch.sweep_load_at = PSG_NO_STEP
        case ch.sweep_load_kind
        of SWEEP_LOAD_ARRIVAL:
          ch1_sweep_arrive(ch, h, l - 1)
        of SWEEP_LOAD_REASSERT, SWEEP_LOAD_REASSERT_ONLY:
          ch.frequency = ch.frequency_shadow
          if ch.sweep_arrival_after:
            # A trigger written between the clock and this edge: its NR14
            # write is undone, and it reaches the unit a tick later, on the
            # value written back (DocBoy double_speed change_period_nr14_
            # during_recalc_delay12243: the note sweeps on from the clock's
            # value).
            ch.sweep_arrival_after = false
            ch.sweep_load_at = l + sweep_tick_len(h) + 1
            ch.sweep_load_kind = SWEEP_LOAD_ARRIVAL
          elif ch.sweep_load_kind == SWEEP_LOAD_REASSERT:
            ch.sweep_load_at = l + 1
            ch.sweep_load_kind = SWEEP_LOAD_LATCH
        of SWEEP_LOAD_LATCH_STEP0:
          if ch.shift != 0 and not ch.sweep_operand_valid:
            # A step written on a step-0 clock's own M-cycle with nothing to
            # write back: the clock becomes the one that writes 0 (below).
            ch.frequency = 0
            ch.frequency_shadow = 0
          else:
            ch1_sweep_latch(ch, h, psg_edge_at(h, l - 1))
        else:
          # The sweep clock's calculation counts from the 1 MHz edge at or
          # after the clock (at double speed the DIV-APU event sits half a
          # tick off it).
          ch1_sweep_latch(ch, h, psg_edge_at(h, l - 1))
      elif c == m:
        ch1_sweep_complete(ch)
      else:
        # A sweep clock's check on the adder it wrote back: at any step
        # (Pan Docs), in the direction NR10 holds now.
        ch.sweep_stop_at = PSG_NO_STEP
        if ch1_sweep_sum(ch) > 0x7FF and
           not ch1_sweep_trigger_pending(ch):
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

when PSG_AGB:
  proc ch1_sweep_calc(ch: PsgSweepSquare): uint16 =
    ## One sweep calculation; an overflow stops the channel on the spot.
    let shifted = ch.frequency_shadow shr ch.shift
    var calculated = uint32(ch.frequency_shadow) +
                     uint32(if ch.negate: -int(shifted) else: int(shifted))
    if ch.negate: ch.negate_used = true
    if calculated > 0x07FF: ch.enabled = false
    uint16(calculated)

when not PSG_AGB:
  proc ch1_sweep_clock(ch: PsgSweepSquare; h: PsgHost) =
    ## A sweep iteration: the frame sequencer's clock, or an NR10 write
    ## giving the pace a value while the timer stands at 0 (ch1_write).
    if ch.negate: ch.negate_used = true
    let edge = psg_edge(h)
    ch.sweep_frozen = 0
    if ch.sweep_check_at != PSG_NO_STEP and ch1_sweep_t0(ch, h) <= edge:
      # A clock cuts a running calculation short, as of the 1 MHz edge at or
      # after it (one a trigger has set up to start later runs on; at double
      # speed one starting on that edge is cut: DocBoy double_speed
      # change_period_nr14_during_recalc_delay12240).
      ch.sweep_check_at = PSG_NO_STEP
    if ch.shift > 0 and not ch.sweep_operand_valid:
      # No calculation has ended since the trigger (it had step 0, or a
      # clock cut it short), so the adder holds nothing: the clock
      # writes 0 to the frequency and checks and starts nothing, and so
      # does every clock after it until a trigger or a step-0 clock.
      # DocBoy change_step_0_to_1_pace4_*, change_step_during_recalc_
      # 0_to_{4,6}_round0 (alive for good; SameBoy agrees), change_step_
      # 0_to_1_after_recalc (PCM12: the duty steps 2048 M-cycles apart
      # after the clock), change_period_nr14_during_recalc_delay14279..
      # 14284 (a trigger 2..7 M-cycles before the clock; DocBoy only:
      # SameBoy differs).
      let reload_now = sq_reload_is_now(ch, h)
      ch.frequency = 0
      ch.frequency_shadow = 0
      if reload_now: sq_reload(ch, h)
      if edge > psg_now(h) and not ch1_sweep_trigger_pending(ch):
        # At double speed the 0 reaches NR13/NR14 on the edge after the
        # clock (SWEEP_LOAD_REASSERT; double_speed change_period_nr14_during_
        # recalc_double_trigger_delay{1,2}_delay12243: a trigger written on
        # the clock's own M-cycle then sweeps from 0).
        ch.sweep_load_at = edge
        ch.sweep_load_kind = SWEEP_LOAD_REASSERT_ONLY
      return
    # The adder's output is the new value; its operand was shifted by the
    # step of its own calculation (DocBoy change_step_6_to_5_period154).
    let sum = ch1_sweep_sum(ch)
    var latch_at = edge + 1
    let wrote_back = sum <= 0x07FF and ch.shift > 0
    if wrote_back:
      # The sweep's frequency write races the timer reload like an
      # NR13/NR14 write (sq_reload_is_now); at $7ff a step lands every
      # M-cycle, so the sweep tick always coincides (SameSuite
      # channel_1_sweep_restart round 1).
      let reload_now = sq_reload_is_now(ch, h)
      ch.frequency_shadow = uint16(sum)
      ch.frequency        = uint16(sum)
      if reload_now: sq_reload(ch, h)
      ch.sweep_operand = 0
      ch.sweep_operand_valid = false
      if edge > psg_now(h): latch_at = edge   # SWEEP_LOAD_REASSERT first
    # The next calculation starts on the 1 MHz edge, on NR13/NR14 as
    # they stand just after it (SWEEP_LOAD_LATCH): after a write-back,
    # on the value written; at step 0, on the frequency as it is (a
    # frequency written without a trigger just before a step-0 clock
    # counts: double_speed change_period_nr14_during_recalc_
    # no_retrigger_step0_*). A trigger on its way supersedes it.
    if not ch1_sweep_trigger_pending(ch):
      ch.sweep_load_at = latch_at
      ch.sweep_load_kind = if latch_at == edge: SWEEP_LOAD_REASSERT
                           elif wrote_back: SWEEP_LOAD_LATCH
                           else: SWEEP_LOAD_LATCH_STEP0
    # The clock's own overflow check stops the channel one tick after the
    # clock, at double speed one and a half (3 M-cycles: DocBoy double_speed
    # period_sweep_step0{,_a,_b,_c,_d}, the same whichever 1 MHz phase the
    # APU was powered on in), on the adder as it stands then: a step-0
    # calculation ending in that tick counts (change_period_nr14_during_
    # recalc_step0_delay14284), and after a write-back the adder shows the
    # value written.
    ch.sweep_stop_at = psg_now(h) + sweep_tick_len(h) +
                       (sweep_tick_len(h) div 2) * CycleCount(psg_shl(h))

proc sweep_step(ch: PsgSweepSquare; h: PsgHost) =
  # psg_seq_step has caught the duty counter up: this changes ch.frequency.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    # GB: no enabled flag latched at the trigger: a pace given later runs the
    # clocks (DocBoy change_pace_0_to_2_step0_delayed_more: pace and step 0
    # at the trigger, pace 2 written later, the eighth clock stops the
    # channel; SameBoy agrees).
    if (ch.sweep_enabled or not PSG_AGB) and ch.sweep_period > 0:
      when PSG_AGB:
        ch.s0_slow = false   # a calculation has run (ch1_s0_kill_at)
        let calc = ch1_sweep_calc(ch)
        if calc <= 0x07FF and ch.shift > 0:
          # The sweep's frequency write races the timer reload like an
          # NR13/NR14 write (sq_reload_is_now); at $7ff a step lands every
          # M-cycle, so the sweep tick always coincides (SameSuite
          # channel_1_sweep_restart round 1).
          let reload_now = sq_reload_is_now(ch, h)
          ch.frequency_shadow = calc
          ch.frequency        = calc
          if reload_now: sq_reload(ch, h)
          # AGB-native, measured: the second calculation, for its overflow
          # check, runs at once on the new shadow (AGB SP page 1F SWEEP2:
          # 2018/s7 dies at tick 1, the tick check >= 2048). A GB cartridge on
          # the same console runs the GB's pipeline (ch1_sweep_clock) -- the
          # AGS GB-slot page is byte-identical to the MGB's
          # (docs/hwprobe-questions.md row 16) -- so this is the GBA mode's
          # own, not a port to make.
          discard ch1_sweep_calc(ch)
      else:
        ch1_sweep_clock(ch, h)

proc ch1_trigger_sweep(ch: PsgSweepSquare; h: PsgHost) =
  when PSG_AGB:
    let stale = ch.frequency_shadow
    let slow = ch.s0_slow   # (ch1_s0_kill_at) as the trigger finds it
    ch.frequency_shadow = ch.frequency
    # No trigger lead before a sweep clock, unlike the CGB's 8 T-cycles (AGB
    # SP, payloads/swplead.s: a note triggered closer and closer to a clock
    # still takes it).
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
    # A trigger written while an earlier one's calculation has not started
    # rides on it: the timer keeps the earlier reload, lead and all (DocBoy
    # double_speed change_period_nr14_during_recalc_double_trigger_*: the
    # second trigger 1..3 M-cycles before the clock, the first 4..6, and
    # the clock still comes).
    let riding = ch1_sweep_trigger_pending(ch) or
                 (ch.sweep_check_at != PSG_NO_STEP and
                  ch1_sweep_t0(ch, h) >= psg_now(h))
    if not riding:
      ch.sweep_timer    = (if ch.sweep_period > 0: ch.sweep_period else: 8'u8) +
                          psg_sweep_trigger_extra(h)
    ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
    ch.negate_used      = false
    # A stop in flight dies with the restart (the channel is on again).
    ch.sweep_stop_at = PSG_NO_STEP
    # The write reaches the sweep unit on the APU tick after the one it lands
    # on (ch1_sweep_arrive); a second trigger before that rides on the first
    # (DocBoy double_speed disable_on_double_trigger_*_delay0: two writes one
    # M-cycle apart stop the channel when the first alone does).
    if ch.sweep_load_at != PSG_NO_STEP and
       ch.sweep_load_kind in {SWEEP_LOAD_REASSERT, SWEEP_LOAD_REASSERT_ONLY}:
      ch.sweep_arrival_after = true
    elif not ch1_sweep_trigger_pending(ch):
      ch.sweep_load_at   = psg_edge(h) + psg_tick(h) + 1
      ch.sweep_load_kind = SWEEP_LOAD_ARRIVAL

when not PSG_AGB:
  proc ch1_sweep_freq_written(ch: PsgSweepSquare; h: PsgHost) =
    ## An NR13/NR14 write without a trigger. Pan Docs: the shadow keeps its
    ## value, and the next clock's write-back overwrites the write. But from
    ## a calculation's start until its check (or a clock's) the adder's base
    ## follows the frequency, while the shifter keeps the value it latched
    ## (DocBoy double_speed change_period_nr14_during_recalc_no_retrigger_
    ## delay12245/6: $799 written half a tick into a step-5 calculation on
    ## 921 makes $799 + 921 >> 5; no_retrigger_step0_delay12245: written
    ## after a step-0 clock's calculation, before its check, it overflows).
    if ch.sweep_load_at != PSG_NO_STEP and ch.sweep_load_kind != SWEEP_LOAD_ARRIVAL:
      return                                 # the latch still to come reads it
    if ch.sweep_check_at != PSG_NO_STEP or ch.sweep_stop_at != PSG_NO_STEP:
      ch.frequency_shadow = ch.frequency

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
    when not PSG_AGB:
      let old_pace = ch.sweep_period
      let old_negate = ch.negate
      let old_shift = ch.shift
    ch.sweep_period = (val and 0x70) shr 4
    ch.negate       = (val and 0x08) != 0
    ch.shift        = val and 0x07
    if not ch.negate and ch.negate_used: ch.enabled = false
    when not PSG_AGB:
      # An add-mode NR10 write lets the adder's carry in through for a moment
      # where its direction changes from subtraction (both machines), or on
      # any write over a non-zero step (DMG): an adder at $7FF then
      # overflows and the channel stops (DocBoy change_direction_twice_
      # period_overflow_round2, $7F0 + $0F with the direction flipped back;
      # DMG write_nr10_overflow_period16_step7 / period32_step6, change_step_
      # 6_to_{4,5}_period32, change_pace_1_to_0_during_recalc; SameBoy
      # agrees on all of them, and keeps the CGB's channel on in the DMG
      # rows).
      if not ch.negate and
         (old_negate or (not psg_cgb(h) and old_shift != 0)) and
         ch1_sweep_sum(ch) + 1 > 0x7FF:
        ch.enabled = false
      # The pace's 3-bit timer stands at 0 from a trigger at pace 0 until the
      # first clock (Pan Docs: pace 0 counts as 8): giving the pace a value
      # then runs an iteration at once and reloads the timer (DocBoy
      # change_pace_0_to_2_step0{,_delayed}: the step-0 overflow stops the
      # channel 3 M-cycles after the write, but not once a clock has passed;
      # change_pace_0_to_2_step6: its clocks fall 2 apart from the write).
      if old_pace == 0 and ch.sweep_period != 0 and ch.sweep_timer == 8:
        ch.sweep_timer = ch.sweep_period
        ch1_sweep_clock(ch, h)
      # The calculation's tick counter only runs while NR10's step is
      # non-zero: a step of 0 written while one runs holds it where it is
      # (and so the check at its end), and a step written later lets it
      # count out the ticks it had left, whatever the new step (SameBoy,
      # black box: a step-7 trigger's calculation held 0..7 ticks in stops
      # the channel 6, 6, 5, 4, ... M-cycles after the step is given back,
      # for any step 1..7; DocBoy change_step_7_to_0_during_recalc_then_7
      # {,_delayed}, one M-cycle later on the CGB).
      elif old_shift != 0 and ch.shift == 0 and
           ch.sweep_check_at != PSG_NO_STEP:
        let tick = sweep_tick_len(h)
        let t0 = ch1_sweep_t0(ch, h)
        let d = if psg_now(h) > t0: int((psg_now(h) - t0) div tick) else: 0
        let done = min(int(ch.sweep_calc_n), max(1, d))
        ch.sweep_frozen = uint8(int(ch.sweep_calc_n) - done + 1)
        ch.sweep_check_at = PSG_NO_STEP
      elif old_shift == 0 and ch.shift != 0 and ch.sweep_frozen != 0:
        let tick = sweep_tick_len(h)
        let left = CycleCount(ch.sweep_frozen) - 1
        let wait = if psg_cgb(h): left * tick + tick div 2
                   else: max(left * tick, tick) - tick div 2
        ch.sweep_check_at = gb_apu_edge_before(h) + wait
        ch.sweep_frozen = 0
  of NR11: sq_write_duty(ch, val)
  of NR12: psg_write_nrx2(ch, h, val)
  of NR13:
    sq_write_freq_lo(ch, h, val)
    when not PSG_AGB: ch1_sweep_freq_written(ch, h)
  of NR14:
    sq_write_freq_hi(ch, h, val)
    if (val and 0x80) != 0:
      sq_trigger(ch, h)
      ch1_trigger_sweep(ch, h)
    else:
      when not PSG_AGB: ch1_sweep_freq_written(ch, h)
  else: discard

proc ch2_write(ch: PsgSquare; nr: int; val: uint8; h: PsgHost) =
  case nr
  of NR21: sq_write_duty(ch, val)
  of NR22: psg_write_nrx2(ch, h, val)
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
  ## Offset of the bank CH3 plays (GBA: PsgWave.wave_play_bank; the GB has
  ## one).
  when PSG_AGB: int(ch.wave_play_bank) * PSG_WAVE_BANK
  else:         0

proc ch3_catchup_slow(ch: PsgWave; h: PsgHost; observer_period: uint32) =
  let now    = psg_now(h)
  let ticks  = ch3_timer(ch)
  let period = psg_period(ticks, h)
  let steps = psg_steps_due(ch, now - ch.next_step, period, ticks,
                            observer_period)
  if steps == 0: return
  when defined(psgverify):
    # Per-period loop the closed form must agree with.
    var wpos  = ch.wave_ram_position
    var wbank = (when PSG_AGB: ch.wave_play_bank else: 0'u8)
    for _ in 0 ..< steps:
      wpos = uint8(int(wpos + 1) mod (PSG_WAVE_BANK * 2))
      when PSG_AGB:
        if wpos == 0 and ch.wave_ram_dimension: wbank = wbank xor 1
  # The pointer is a free-running mod-32 counter, so N steps land at
  # (pos + N) mod 32.
  let total = CycleCount(ch.wave_ram_position) + steps
  ch.wave_ram_position = uint8(total and 31)
  when PSG_AGB:
    # The GBA wave channel is the CGB one with a second 32-nibble bank: in
    # 64-step mode (dimension) the bank flips every time the pointer wraps to
    # 0 (GBATEK SOUND3CNT_L bit 5) -- once per wrap, wraps = (pos + N) div
    # 32, and only its parity matters.
    if ch.wave_ram_dimension and ((total shr 5) and 1) != 0:
      ch.wave_play_bank = ch.wave_play_bank xor 1
  when defined(psgverify):
    doAssert wpos  == ch.wave_ram_position, "ch3 pointer closed form != naive loop"
    when PSG_AGB:
      doAssert wbank == ch.wave_play_bank, "ch3 bank closed form != naive loop"
  # Only the last fetch matters: wave RAM and the dimension/bank bits cannot
  # change between catch-ups (every wave RAM access and NR30 write catches
  # this channel up first). The byte is held; the DAC picks its nibble.
  ch.wave_fetched = true
  ch.wave_ram_sample_buffer = ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)]
  ch.next_step += steps * period
  when PSG_AGB:
    # The step now pending was armed by the one before it, i.e. one CURRENT
    # period ago.
    ch.arm_delay = uint32(period)

proc ch3_catchup_at(ch: PsgWave; h: PsgHost; observer_period: uint32) {.inline.} =
  ## See sq_catchup_at. The wave pointer is a free-running mod-32 counter.
  when not PSG_AGB:
    # GB: a channel that is off reads no samples, so the sample buffer keeps
    # the last one read before the stop (Pan Docs, NR34: the last sample
    # read is output after a retrigger) and the phase freezes, as on the
    # pulse channels (sq_catchup_at). DocBoy cgb/apu/ch3
    # ch3_disable_channel_while_sampling_period_3_round0 and _4_round0b: off
    # through NR30 for 1,024 M-cycles, a retrigger still plays the byte read
    # before the stop. The GBA keeps its free-running pointer (unmeasured).
    if not ch.enabled:
      ch.next_step = PSG_NO_STEP
      return
  if ch.next_step > psg_now(h): return
  ch3_catchup_slow(ch, h, observer_period)

template ch3_catchup(ch: PsgWave; h: PsgHost) =
  ch3_catchup_at(ch, h, PSG_OBS_CPU)

const GB_WAVE_ACCESS_WINDOW = 2
  ## Half of CH3's 1 MHz sample cycle in T-cycles: the pointer is clocked at
  ## 2 MHz, so each sample cycle has a fetch half and a hold half.

when not PSG_AGB:
  # GB only: the GBA's CPU accesses the bank not playing (ch3_wave_read).
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
  ## CPU read of wave RAM byte i (0..15). GB: while CH3 plays it returns the
  ## byte being played; the caller caught the pointer up first. GBA: the
  ## access addresses the bank NOT selected in SOUND3CNT_L, playing or not,
  ## and never meets the byte being played (GBATEK; AGB SP,
  ## payloads/wavebank.s: a read while bank 0 plays returns all of bank 1).
  when PSG_AGB:
    ch.wave_ram[(int(ch.wave_ram_bank) xor 1) * PSG_WAVE_BANK + i]
  else:
    if not ch3_wave_open(ch, h): 0xFF'u8
    elif ch.enabled: ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)]
    else:            ch.wave_ram[ch3_bank_base(ch) + i]

proc ch3_wave_write(ch: PsgWave; h: PsgHost; i: int; val: uint8) =
  ## GB: a write lands at the position CH3 is playing while enabled; a DMG
  ## write outside the access window is dropped. GBA: the other bank, as a
  ## read.
  when PSG_AGB:
    ch.wave_ram[(int(ch.wave_ram_bank) xor 1) * PSG_WAVE_BANK + i] = val
  else:
    if not ch3_wave_open(ch, h): discard
    elif ch.enabled: ch.wave_ram[ch3_bank_base(ch) + int(ch.wave_ram_position div 2)] = val
    else:            ch.wave_ram[ch3_bank_base(ch) + i] = val

proc ch3_write(ch: PsgWave; nr: int; val: uint8; h: PsgHost) =
  # The caller caught the wave pointer up, so a period/dimension/bank/trigger
  # change below only affects steps from now on.
  case nr
  of NR30:
    let dac_on = (val and 0x80) != 0
    when not PSG_AGB:
      if not dac_on and ch.enabled and psg_cgb(h) and ch3_wave_fetching(ch, h):
        # CGB: a stop landing in the half-cycle before a sample read does not
        # cancel the read, but the channel no longer drives wave RAM's
        # address, the CPU does (Pan Docs, "Wave RAM": a CPU access while CH3
        # plays lands on the byte CH3 is reading, one address path for
        # both): the byte latched is the one at the low four bits of the
        # CPU's next bus address, its opcode fetch (DocBoy cgb/apu/ch3
        # ch3_disable_channel_while_sampling_*, 30 rows, and its double-speed
        # twin: the `_phaseN` and `_round0b..g` rows move the stop one byte
        # of code at a time and the byte read moves with it; SameBoy passes
        # all of them). The DMG is unmeasured; the AGB (psg_cgb) is assumed
        # to share the CGB's port.
        ch.wave_ram_position = (ch.wave_ram_position + 1) and 31
        ch.wave_ram_sample_buffer = ch.wave_ram[psg_cpu_bus_addr(h) and 0x0F]
    ch.dac_enabled = dac_on
    if not ch.dac_enabled:
      ch.enabled = false
      when PSG_AGB:
        # GBA: the sample buffer clears with the DAC (the AGB's buffer is not
        # visible to a ROM; kept as it was).
        ch.wave_ram_sample_buffer = 0
      else:
        # GB: the buffer survives the DAC (Pan Docs, NR34: only an APU
        # power-off resets it; apu.nim's power-on clears it). SameSuite
        # channel_3_restart_stop_delay, which looks like a stop clearing it,
        # triggers its first note with NR30 = $00 left by its fill loop, so
        # its channel never read a sample. The timer stops with the channel.
        ch.next_step = PSG_NO_STEP
    when PSG_AGB:
      ch.wave_ram_dimension = (val and 0x20) != 0
      ch.wave_ram_bank      = (val shr 6) and 1
      ch.wave_play_bank     = ch.wave_ram_bank
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
      let in_flight = ch.enabled and ch3_wave_fetching(ch, h)
      if in_flight and not psg_cgb(h):
        # The byte being read is the one the fetch is about to latch (blargg
        # dmg_sound 10).
        let byte_idx = ((int(ch.wave_ram_position) + 1) mod 32) div 2
        if byte_idx < 4:
          ch.wave_ram[0] = ch.wave_ram[byte_idx]
        else:
          let base = byte_idx and not 3
          for i in 0 ..< 4: ch.wave_ram[i] = ch.wave_ram[base + i]
      when not PSG_AGB:
        if in_flight and psg_cgb(h):
          # CGB: no corruption, but the read in flight finishes after the
          # restart has cleared the pointer, so it latches byte 0, not the
          # byte it was fetching (DocBoy cgb/double_speed/apu/ch3
          # double_speed_apu_ch3_retrigger_period_{4,6}_*: a retrigger one
          # 2 MHz tick before a read plays byte 0's high nibble through the
          # start-up delay, two ticks before plays the previous byte;
          # SameBoy agrees). The DMG's corruption above is the same race.
          ch.wave_ram_sample_buffer = ch.wave_ram[0]
      psg_trigger_length(ch, h, 0x100)
      # Period plus a 6 T-cycle start-up (SameSuite channel_3_restart_delay,
      # _shift_delay: 5 or 6 pass, nothing else), in the PSG's own clock like
      # every other PSG delay: 24 GBA cycles. The GBA cannot show it (its CPU
      # never reads the playing byte, and SOUND3CNT_L does not show the
      # playing bank: payloads/wavebank.s, wavedly.s).
      ch.next_step = psg_now(h) + psg_period(ch3_timer(ch) + 6, h)
      when PSG_AGB:
        ch.arm_delay = uint32(ch.next_step - psg_now(h))
        # Playback starts from the selected bank.
        ch.wave_play_bank = ch.wave_ram_bank
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
#
# Three consequences of that structure, pinned by DocBoy's double-speed CH4
# rows (cgb/double_speed/apu/ch4, which read PCM34 one M-cycle either side of
# the LFSR's 15th clock after the last write):
# * A trigger restarts the divisor stage but not the counter: on a running
#   channel the LFSR next clocks when the counter's tap bit next rises from
#   wherever the counter stands (`retrigger_*`: shift 0, a retrigger is half
#   a period when the counter is even and a full one when it is odd; the old
#   "always a full period" was the odd case). Only a fresh start (the
#   channel was off) begins from a zero counter.
# * The count already in progress finishes on the divisor it was loaded with;
#   an NR43 write changes the next one (`change_divider*_to_*`). A count of
#   code 0 left pending off the 512 kHz grid by a write selecting code >= 1
#   finishes on the next grid edge (`change_divider0_to_3`, writes 2 dots
#   before a code-0 increment).
# * The LFSR clock is the tap's rising edge, so an NR43 write that moves the
#   tap from a 0 bit of the counter to a 1 bit clocks the LFSR at once
#   (`change_shift1_to_3_divider0_delay{16..19,24..27}`: the counter is 8,
#   9, 12 or 13 there; a clock up to 8 scheduler cycles at double speed
#   (1 us) after the write also passes, 16 loses a row).

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

proc psg_noise_on_grid(h: PsgHost; t: CycleCount): bool {.inline.} =
  ## Whether `t` (on the 1 MHz grid) is an edge of the 512 kHz grid.
  let tick = psg_tick(h)
  ((t + 2 * tick - psg_noise_phase(h)) mod (2 * tick)) == tick

proc psg_noise_first_inc(h: PsgHost; inc: CycleCount; divisor_code: uint8;
                         counted: bool): CycleCount =
  ## Absolute cycle of the divisor stage's first increment after a trigger:
  ## one increment period plus two ticks from the point the trigger restarts
  ## the stage. That point is the 1 MHz edge at or after the write, moved onto
  ## the 512 kHz grid the stage is clocked by, which a trigger cannot reset
  ## (psg_noise_phase): divisor code 0 starts on the 1 MHz tick, code 1 rounds
  ## up to the grid, codes >= 2 round down (SameSuite channel_4_delay's rows
  ## are `period/2 + 2` M-cycles from a zero counter; channel_4_frequency_
  ## alignment for the grid, cross-checked by channel_4_equivalent_
  ## frequencies and channel_4_align; DocBoy's double-speed `divider*` and
  ## `retrigger_*` rows cover codes 0-7 at all four 2 MHz phases). A
  ## trigger leaves the counter alone (see the notes above ch4_lfsr_frozen).
  ## `counted`: the counter is not at zero. Code 1 rounds up only from a zero
  ## counter; a retrigger once it has counted rounds down like codes >= 2
  ## (DocBoy's `retrigger_shift{1,2}_divider1_*` off the grid, 10 rows, which
  ## SameBoy run on the same ROMs passes too; from a zero counter the two
  ## agree on rounding up, `ch4_width1_shift0_divider1_*`).
  let tick = psg_tick(h)
  let edge = psg_edge(h)
  var extra = 2 * tick
  if divisor_code != 0 and not psg_noise_on_grid(h, edge):
    # Off the 512 kHz grid. Adjusting `extra` rather than `edge` keeps the
    # sum from underflowing in the down-rounding case.
    extra = (if divisor_code == 1 and not counted: extra + tick else: extra - tick)
  edge + inc + extra

proc psg_noise_slow_restart(ch: PsgNoise; h: PsgHost): bool =
  ## Divisor code 0, a retrigger of a running channel. Code 0's half-period
  ## increments ride the 1 MHz grid, but a restart still goes through the
  ## 512 kHz stage: when the old stage's increment at the trigger's 1 MHz
  ## edge (or, before its first one, the pending one a tick later) lands off
  ## the 512 kHz grid, that increment still counts and the restarted stage
  ## makes a whole turn of its 3-bit count -- code 0 read as 8, eight 512 kHz
  ## periods (16 ticks) from the next grid edge -- before its first
  ## increment, after which it runs at the half period again. On the grid
  ## the restart is the ordinary one. DocBoy's double-speed
  ## `retrigger_shift{0..7}_divider0_*` rows (40, the 15th clock 28 M-cycles
  ## late) and the single-speed `ch4_retrigger_delay16_*_nops{0,2,4}`;
  ## SameBoy, run on the same ROMs as a black box, restarts as late at the
  ## same phases (passes 31 of those rows; it differs only before the first
  ## increment). Sets the counter and `div_next`; false leaves the ordinary
  ## restart to the caller.
  let tick = psg_tick(h)
  let edge = psg_edge(h)
  let p = (if ch.div_next <= edge: edge else: ch.div_next)
  if p > edge + tick or psg_noise_on_grid(h, p): return false
  ch.div_counter += uint16(((p - ch.div_next) div tick + 1) and CycleCount(0xFFFF))
  ch.div_next = p + 17 * tick
  true

proc ch4_tap(ch: PsgNoise): uint16 {.inline.} =
  ## The counter bit the LFSR clock follows; shifts 14/15 tap nothing.
  if ch4_lfsr_frozen(ch): 0'u16
  else: (ch.div_counter shr int(ch.clock_shift)) and 1'u16

proc ch4_catchup_slow(ch: PsgNoise; h: PsgHost; observer_period: uint32) {.inline.} =
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
    psg_write_nrx2(ch, h, val)
  of NR43:
    # The caller caught the channel up (no rising edge pending); bring the
    # divisor stage the rest of the way.
    let old_inc = ch4_inc_period(ch, h)
    let now = psg_now(h)
    # An increment landing on this very cycle leaves the countdown at a fresh
    # reload, which takes the new divisor. Asked before advancing: after a
    # trigger the first increment is also exactly one period off, with no
    # reload behind it (change_divider{3_to_0,3_to_5,0_to_3}_shift1_delay0).
    let landed = ch.div_next != PSG_NO_STEP and ch.div_next <= now and
                 (now - ch.div_next) mod old_inc == 0
    ch4_advance_divisor(ch, h)
    let running = ch.div_next != PSG_NO_STEP
    let old_tap = ch4_tap(ch)
    ch.clock_shift   = val shr 4
    ch.width_mode    = (val and 0x08) shr 3
    ch.divisor_code  = val and 0x07
    if running:
      if landed:
        ch.div_next = psg_noise_grid_up(h, now + ch4_inc_period(ch, h),
                                        ch.divisor_code)
      else:
        # The pending count finishes as loaded; a code >= 1 stage only
        # increments on the 512 kHz grid.
        ch.div_next = psg_noise_grid_up(h, ch.div_next, ch.divisor_code)
      # The tap moving onto a set bit is a rising edge: one LFSR clock now.
      if ch.enabled and old_tap == 0 and ch4_tap(ch) == 1: psg_lfsr_shift(ch)
      # Shift 14/15 parks the LFSR (ch4_lfsr_frozen); the divisor stage keeps
      # running so a later write can thaw it.
      ch.next_step = if ch4_lfsr_frozen(ch): PSG_NO_STEP
                     else: ch4_next_shift(ch, h)
      when PSG_AGB: ch.arm_delay = uint32(ch4_timer(ch)) shl psg_shl(h)
  of NR44:
    psg_nrx4_length(ch, h, val, defer_off = false)
    if (val and 0x80) != 0:
      let was_running = ch.enabled and ch.div_next != PSG_NO_STEP
      psg_trigger_length(ch, h, 0x40)
      # The divisor stage restarts (psg_noise_first_inc); the counter starts
      # from 0 only if the channel was off. On a running channel it keeps
      # its count, including increments up to the restart point, which can
      # be a tick past the write (one increment period plus two ticks before
      # the first new increment), so the LFSR waits for the tap's next
      # rising edge: half a period from an even count at shift 0, a full one
      # from an odd count.
      let inc = ch4_inc_period(ch, h)
      if was_running and ch.divisor_code == 0 and psg_noise_slow_restart(ch, h):
        discard
      elif was_running:
        ch4_advance_divisor(ch, h)
        let first = psg_noise_first_inc(h, inc, ch.divisor_code,
                                        ch.div_counter != 0)
        let lead = inc + 2 * psg_tick(h)
        if ch.div_next + lead <= first:
          let n = (first - lead - ch.div_next) div inc + 1
          ch.div_counter += uint16(n and CycleCount(0xFFFF))
        ch.div_next = first
      else:
        ch.div_counter = 0
        ch.div_next = psg_noise_first_inc(h, inc, ch.divisor_code, false)
      let deadline = ch4_next_shift(ch, h)
      # Shift 14/15: the divisor stage starts but the LFSR never fires.
      ch.next_step = if ch4_lfsr_frozen(ch): PSG_NO_STEP else: deadline
      when PSG_AGB: ch.arm_delay = uint32(deadline - psg_now(h))
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

when not PSG_AGB:
  proc psg_env_glitch(apu: typeof(PsgHost().apu); stage: int) =
    ## GB: the envelope-enable glitch's tick lands on its step
    ## (psg_write_nrx2) after any regular clock of that step, and acts only
    ## on a timer that has not counted since a period-0 load: it stands in
    ## for that timer running out (step the volume, load the new period, one
    ## more if step 7 is next, as a trigger's load: Pan Docs, "Audio
    ## Details"). Once the timer has counted it changes nothing. SameBoy,
    ## probing DocBoy's trigger-at-$A8 setup: a $A9 write before the first
    ## envelope clock ticks at the step the rule above picks, one after it
    ## never does, and a tick on step 6 delays the next by a clock (DocBoy
    ## ch1_change_volume_sweep_pace_2_timer_0_div_apu_4_round3/4: $D on the
    ## 24th step, not the 16th).
    template extra(ch: untyped) =
      if ch.env_extra_tick != 0:
        dec ch.env_extra_tick
        if ch.env_extra_tick == 0 and ch.period != 0 and
           (ch.volume_envelope_timer == 0 or ch.volume_envelope_timer >= 8):
          gb_env_expire(ch, if stage == 6: 1 else: 0)
    extra(apu.channel1)
    extra(apu.channel2)
    extra(apu.channel4)

  proc psg_env_step7(apu: typeof(PsgHost().apu)) =
    ## GB: step 7's envelope work: the regular clock, then the glitch.
    psg_volume_step(apu.channel1); psg_volume_step(apu.channel2)
    psg_volume_step(apu.channel4)
    psg_env_glitch(apu, 7)

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
    when PSG_AGB:
      psg_volume_step(apu.channel1); psg_volume_step(apu.channel2)
      psg_volume_step(apu.channel4)
  else: discard
  when PSG_AGB:
    if (apu.frame_sequencer_stage and 1) == 1:
      # Envelope-enable glitch's extra tick, at the next odd stage; see
      # PsgEnvChannel.env_extra_tick.
      template extra(ch: untyped) =
        if ch.env_extra_tick != 0:
          ch.env_extra_tick = 0
          volume_step(ch)
      extra(apu.channel1)
      extra(apu.channel2)
      extra(apu.channel4)
  else:
    # GB: the envelopes' share of the step (psg_env_glitch, psg_env_step7).
    if apu.frame_sequencer_stage != 7:
      psg_env_glitch(apu, apu.frame_sequencer_stage)
    elif psg_env_late(h):
      # Step 7 reaches the envelopes ENV_CLOCK_DS_LATE_T later
      # (GbQuirks.env_clock_ds_late); apu_env_late_due runs it.
      apu.env_late_pending = true
    else:
      psg_env_step7(apu)
  apu.frame_sequencer_stage += 1
  if apu.frame_sequencer_stage > 7: apu.frame_sequencer_stage = 0
