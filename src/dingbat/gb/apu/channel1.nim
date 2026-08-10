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
  ## Duty-step period in SCHEDULER cycles (schedule_gb scaled every APU delay
  ## by the speed shift, so the deadline arithmetic has to as well).
  CycleCount(ch1_frequency_timer(ch)) shl gb.scheduler.speed

const GB_SWEEP_STOP_DELAY* = CycleCount(4)
  ## Scheduler cycles (one APU tick) between a sweep overflow CALCULATION and the
  ## stop it produces becoming visible in NR52 / PCM12 / the mixer.
  ##
  ## channel_1_sweep_restart_2 is the only test that sees a sweep calculation and
  ## its stop separately, because it is the only one whose FIRST calculation
  ## overflows: NR10 = $10 (pace 1, add, shift 0) doubles the frequency, so a
  ## channel restarted at $7ff is killed by the very next DIV-APU sweep event
  ## rather than by the trailing check below. Its N = 0 column reads NR52 at 2, 3,
  ## 4... M-cycles after the restarting write, the DIV-APU sweep event falls 3
  ## M-cycles after that write, and the row is `f1 f1 f0 f0...` -- the read
  ## landing ON the sweep event still sees the channel on, and only the one after
  ## it sees the stop.
  ##
  ## Every other sweep stop in the suite reaches NR52 through this same tick, so
  ## it is subtracted from the two delays below rather than added on top: the
  ## totals those tests measure -- 8 M-cycles from a sweep writeback, 9 from a
  ## trigger -- are unchanged.

const GB_SWEEP_CHECK_DELAY* = CycleCount(28)
  ## Scheduler cycles (7 M-cycles at single speed) between a sweep writing a new
  ## frequency back and the second overflow check that can stop the channel. With
  ## GB_SWEEP_STOP_DELAY on top of it that is the 8 M-cycles the tests measure.
  ##
  ## Pan Docs describes the second calculation as part of the same event; three
  ## separate SameSuite sources say otherwise, in the same words each time.
  ## channel_1_sweep annotates the subtest where its round-3 channel finally goes
  ## quiet -- 8 nops past the DIV-APU tick that did the sweep -- with "8 cycles
  ## after trigger, the APU checks if the NEXT trigger overflows the frequency.
  ## If it does, stop the channel", and channel_1_sweep_restart's rounds 3, 4 and
  ## 5 each open with "the channel should stop after 8 cycles, but we <do
  ## something to NR10> before then". Those three rounds are what make the delay
  ## more than a curiosity: the check reads NR10 as it stands 7 M-cycles LATER,
  ## so clearing NR10 cancels the stop entirely, and changing the shift changes
  ## which frequency is tested.
  ##
  ## The first calculation is NOT delayed by this: channel_1_sweep_restart_2's
  ## sweep stops its channel with no 8-cycle grace at all, only the one tick of
  ## GB_SWEEP_STOP_DELAY.
  ##
  ## The same delay applies to the check an NRx4 TRIGGER performs, with one
  ## extra APU tick: the write is latched on a tick edge and the countdown
  ## starts on the tick after it. channel_1_sweep_restart round 2 is what
  ## measures that -- restart a channel whose next sweep overflows and it stays
  ## audible for nine more M-cycles, not eight. See the arm in ch1_write.

const GB_SWEEP_SHADOW_DELAY* = CycleCount(8)
  ## Scheduler cycles (2 M-cycles) from a TRIGGER reaching the sweep unit to the
  ## frequency shadow register actually holding NR13/NR14's value -- so 3
  ## M-cycles from the write itself, once the one-tick write->unit latency the
  ## check arm already models is counted in.
  ##
  ## channel_1_sweep_restart_2 is what forces it, and it is the whole of that
  ## test's second half. Each subtest triggers the channel at frequency $7ff, N =
  ## 0..7 M-cycles earlier than the last, so that the write falls 3, 2, 1, 0...
  ## M-cycles before a DIV-APU sweep event; the sweep doubles whatever the shadow
  ## holds and so stops the channel if -- and only if -- it is looking at the
  ## restarted $7ff rather than the $3ff the channel was triggered with before
  ## the DIV reset. Hardware stops it for N = 0 alone, i.e. the load has landed
  ## when the write leads the event by 3 M-cycles and has not when it leads by 2.
  ## Loading the shadow on the write instead kills N = 0, 1 and 2 alike, which is
  ## the 32-cell block this constant buys.
  ##
  ## Only the shadow is deferred. The sweep timer, `sweep_enabled` and
  ## `negate_used` are reloaded on the write, and no test here can tell: the
  ## channel is already sweeping with the same NR10 when it is restarted, so
  ## every one of those three is reloaded with the value it already had.

proc ch1_frequency_calc(ch: GbChannel1; gb: GB; at: CycleCount): uint16 =
  ## One sweep calculation, performed at cycle `at` -- which is NOT always
  ## gb.scheduler.cycles: the trailing check runs lazily at the first observation
  ## after it fell due, and the stop it produces has to be dated from the check,
  ## not from whoever happened to look.
  let shifted = ch.frequency_shadow shr ch.shift
  var calc = int(ch.frequency_shadow) + (if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calc > 0x07FF:
    ch.sweep_stop_at = at + (GB_SWEEP_STOP_DELAY shl gb.scheduler.speed)
  result = uint16(calc and 0x7FFF)

proc ch1_sweep_run(ch: GbChannel1; gb: GB) =
  ## The body of ch1_sweep_due, deliberately NOT inline: the guard is what runs
  ## on every catch-up and this runs once per sweep period, so inlining it only
  ## bloats ch1_catchup_at (see notes/perf-measurement-inline-cliff).
  ##
  ## Three things can be in flight inside the sweep unit at once -- a trigger's
  ## shadow load, the trailing overflow check and a stop one of them produced --
  ## and they are applied in deadline order because the check CONSUMES the
  ## shadow. In practice a trigger arms the load 5 M-cycles ahead of its own
  ## check, so the common order is load-then-check; the reverse is only reachable
  ## when a trigger with shift 0 leaves an older sweep-armed check standing.
  let now = gb.scheduler.cycles
  template do_load =
    if ch.sweep_load_at <= now:
      ch.sweep_load_at    = GB_NO_STEP
      ch.frequency_shadow = ch.sweep_load_value
  template do_check =
    if ch.sweep_check_at <= now:
      let at = ch.sweep_check_at
      ch.sweep_check_at = GB_NO_STEP
      # NR10 is re-read here, not captured when the check was armed: that is the
      # whole point of rounds 3-5 of channel_1_sweep_restart. Zeroing NR10
      # between the two calculations cancels the stop (round 3) while merely
      # changing the shift does not (round 4), so the gate is the shift, not the
      # period -- and it has to be the shift, because a trigger arms this check
      # with sweep period 0 (blargg's cgb_sound 06-overflow on trigger).
      if ch.sweep_enabled and ch.shift > 0:
        discard ch1_frequency_calc(ch, gb, at)
  if ch.sweep_check_at < ch.sweep_load_at:
    do_check(); do_load()
  else:
    do_load(); do_check()
  # Last, because either calculation above can arm it -- and the check's may
  # already be due when the check itself is being caught up late.
  if ch.sweep_stop_at <= now:
    ch.sweep_stop_at = GB_NO_STEP
    ch.enabled = false

template ch1_sweep_due*(ch: GbChannel1; gb: GB) =
  ## Apply whatever the sweep unit has in flight that is now due. Called from
  ## ch1_catchup_at, so it lands on every observation point rather than needing a
  ## scheduler event of its own; `enabled` is only visible through PCM12, NR52
  ## and the mixer, and all three catch the channel up first.
  if ch.sweep_load_at <= gb.scheduler.cycles or
     ch.sweep_check_at <= gb.scheduler.cycles or
     ch.sweep_stop_at <= gb.scheduler.cycles:
    ch1_sweep_run(ch, gb)

proc ch1_catchup_slow(ch: GbChannel1; gb: GB; observer_period: uint32) =
  let now    = gb.scheduler.cycles
  let ticks  = ch1_frequency_timer(ch)
  let period = CycleCount(ticks) shl gb.scheduler.speed
  # next_step is the absolute cycle of the FIRST pending step, so every step
  # after it is one period apart -- which is also true across a mid-flight
  # NR13/NR14 frequency write, because the old event would have fired at its
  # already-set target and only then reloaded with the new period.
  let steps = gb_steps_due(now - ch.next_step, period, ticks > observer_period)
  if steps == 0: return
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  # Only the LAST step's bit matters: ch.duty is immutable between catch-ups
  # (an NR11 write catches the channel up first), so the intermediate latches a
  # per-step loop would do are all overwritten. Same argument as CH3's sample
  # buffer. Latching here rather than reading the table in ch1_dac_input is
  # what makes a duty change take effect only from the next sample on, and what
  # holds the pre-trigger sample through the startup delay.
  ch.sample_bit = WAVE_DUTY1[ch.duty][ch.wave_duty_position]
  ch.next_step += steps * period
  ch.last_step_at = ch.next_step - period

proc ch1_catchup_at*(ch: GbChannel1; gb: GB; observer_period: uint32) {.inline.} =
  ## Bring wave_duty_position up to gb.scheduler.cycles. Closed form: while the
  ## channel is on the duty counter free-runs mod 8, so N periods of advance is
  ## (pos + N) and 7 -- no iteration, and cost independent of the frequency.
  ## Must be called before anything that can observe the duty position or
  ## change the period; see the observation-point list in apu.nim.
  ## observer_period is the caller's own T-cycle period (GB_OBS_CPU for a CPU
  ## access) and only affects a step landing on this exact cycle.
  ch1_sweep_due(ch, gb)
  if not ch.enabled:
    # The duty counter is clocked only while the channel is ON. Switching it
    # off freezes the phase where it stands -- SameSuite channel_1_stop_restart:
    # "even after stopping the channel, the current sample index/phase remains
    # unchanged. It is only reset by turning the APU off (NR52)." Parking the
    # deadline rather than merely skipping the advance keeps it from going stale
    # enough to underflow apu_rebase; the only route back on is a trigger, and
    # that re-arms next_step from the current cycle anyway.
    ch.next_step = GB_NO_STEP
    return
  if ch.next_step > gb.scheduler.cycles: return   # not due (or never triggered)
  ch1_catchup_slow(ch, gb, observer_period)

proc ch1_catchup*(ch: GbChannel1; gb: GB) {.inline.} =
  ch1_catchup_at(ch, gb, GB_OBS_CPU)

proc ch1_reload_is_now(ch: GbChannel1; gb: GB): bool {.inline.} =
  ## True when a duty step landed on THIS cycle, i.e. the frequency timer is
  ## reloading right now. apu_write catches the channel up before dispatching,
  ## so last_step_at is already current; next_step alone will not do, because
  ## the trigger's start delay puts the FIRST deadline one period plus two ticks
  ## out and a write two M-cycles after a trigger then looks like a reload.
  ##
  ## SameSuite channel_1_freq_change_timing measures what happens when an NR13 /
  ## NR14 write lands on that cycle, and the answer is that the write wins: the
  ## reload takes the value being written, not the one it is replacing. Its
  ## single-speed row falls out byte for byte, and no other reading of the row
  ## does -- a write one M-cycle later leaves the pending sample alone, which is
  ## channel_1_freq_change's "takes effect after the current sample finishes",
  ## so the two are the same rule seen from either side of one cycle.
  ch.enabled and ch.last_step_at == gb.scheduler.cycles

proc sweep_step*(ch: GbChannel1; gb: GB) =
  # The caller (tick_frame_sequencer) has already caught the duty counter up:
  # this can change ch.frequency, and the catch-up period must be the one that
  # was in force for the cycles being collapsed.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calc = ch1_frequency_calc(ch, gb, gb.scheduler.cycles)
      if calc <= 0x07FF and ch.shift > 0:
        # The sweep's own frequency write races the frequency timer's reload
        # exactly like an NR13/NR14 write does, and loses or wins on the same
        # terms: land on the reload cycle and the reload takes the NEW value.
        # See ch1_reload_is_now -- this is that rule, reached by the one writer
        # that does not go through ch1_write.
        #
        # channel_1_sweep_restart round 1 is where it shows. It runs the
        # channel at $7ff, where a duty step lands on EVERY M-cycle, so the
        # sweep tick that drops the frequency to $7f0 always coincides with a
        # reload; without this the pending sample keeps the 1 M-cycle period it
        # was armed with and the whole waveform after the sweep sits one
        # M-cycle early. Its restart then lands on a duty step that should not
        # have been there, which is the single byte ($c00f) that row was short.
        # Round 2 runs the same code the other way round -- $7f0 up to $7ff,
        # where a step coincides one M-cycle in sixteen -- and is unmoved.
        let reload_now = ch1_reload_is_now(ch, gb)
        ch.frequency_shadow = calc
        ch.frequency         = calc
        if reload_now: ch.next_step = gb.scheduler.cycles + ch1_period(ch, gb)
        # ...and the check on THAT value is 7 M-cycles away, not now. See
        # GB_SWEEP_CHECK_DELAY.
        ch.sweep_check_at = gb.scheduler.cycles + (GB_SWEEP_CHECK_DELAY shl gb.scheduler.speed)

proc ch1_dac_input*(ch: GbChannel1): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC. This is what the CGB's
  ## PCM12 register exposes; 0 while the channel is off. Masked to four bits
  ## because it indexes GB_DAC_LUT: emulation cannot produce a volume above 15,
  ## but a hand-edited or truncated save state can, and that must not become an
  ## out-of-bounds read.
  if ch.enabled and ch.dac_enabled:
    uint8(int(ch.sample_bit) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc ch1_get_amplitude*(ch: GbChannel1): float32 =
  ## Analog output. Gated on the DAC alone, NOT on `enabled`: a switched-off
  ## channel feeds digital 0 to a still-powered DAC, which is analog +1, not
  ## silence. Only a disabled DAC leaves analog 0. See GB_DAC_LUT.
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
  # apu_write caught the duty counter up to the current cycle before getting
  # here, so a period/duty change below only affects steps from now on.
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
    ch.frequency = (ch.frequency and 0x00FF'u16) or ((uint16(val) and 0x07'u16) shl 8)
    if reload_now: ch.next_step = gb.scheduler.cycles + ch1_period(ch, gb)
    let len_enable = (val and 0x40) != 0
    # `or gb.quirks.length_clock_any_nrx4` is the CGB 0 / CGB A-B extra-length
    # clocking rule, which drops the requirement that the write turn the
    # length counter ON; see GbQuirks in gb.nim.
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
      # The duty POSITION deliberately carries across a trigger (hardware only
      # resets it when the APU is powered off) -- which is why the phase has to
      # be caught up rather than parked -- and so does the LATCHED sample: a
      # channel that was off was latching 0, so it emits nothing until its
      # first duty step, which is the pulse analogue of CH3's documented
      # "triggering does not immediately start playing wave RAM".
      if not was_enabled: ch.sample_bit = 0
      ch.next_step = gb_trigger_deadline(gb, ch1_period(ch, gb),
                                         if was_enabled: 1 else: 2)
      init_volume_envelope(ch)
      ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
      ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
      ch.negate_used      = false
      # A stop the sweep unit had already decided on does not survive the
      # restart that re-enabled the channel. Only reachable when the trigger
      # lands on the very cycle of the calculation that produced it, which no
      # test covers; clearing it is what keeps the two indistinguishable.
      ch.sweep_stop_at = GB_NO_STEP
      # The write reaches the sweep unit on the tick after the one that latches
      # it -- channel_1_sweep_restart round 2's table is one M-cycle wider than
      # the sweep's own, which is where that tick comes from -- and from there
      # the two things a trigger does to the unit run on their own countdowns.
      #
      # The shadow load is the shorter of them (GB_SWEEP_SHADOW_DELAY). Pan Docs
      # would have it happen on the write, and channel_1_sweep_restart_2 says it
      # does not.
      let arrives = gb_apu_edge(gb) + gb_apu_tick(gb)
      ch.sweep_load_value = ch.frequency
      ch.sweep_load_at    = arrives + (GB_SWEEP_SHADOW_DELAY shl gb.scheduler.speed)
      # Pan Docs: "if the shift is non-zero, frequency calculation and the
      # overflow check are performed immediately". SameSuite
      # channel_1_sweep_restart round 2 says otherwise -- its channel, restarted
      # at a frequency whose next sweep overflows, stays audible for nine more
      # M-cycles -- and the check reads the shadow the load above has by then
      # delivered.
      if ch.shift > 0:
        ch.sweep_check_at = arrives + (GB_SWEEP_CHECK_DELAY shl gb.scheduler.speed)
  else: discard
