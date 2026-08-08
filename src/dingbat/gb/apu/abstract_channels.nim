# Abstract APU channel types (included by gb.nim)

const GB_OBS_CPU* = high(uint32)
  ## Observer period meaning "a CPU access, not a scheduler event". See
  ## gb_steps_due: by the time the CPU reads or writes a register, tick_slow has
  ## already dispatched every event due at or before scheduler.cycles, so a step
  ## landing on this exact cycle has definitely happened.

template gb_steps_due*(d, period: CycleCount; defer_tie: bool): CycleCount =
  ## How many waveform steps are due, given d = (now - next_step) >= 0 and the
  ## step period, both in scheduler cycles.
  ##
  ## The subtlety is what happens when a step lands on EXACTLY the cycle the
  ## observer runs on. The old per-period events and the observing event were
  ## then both due at the same cycle, and Scheduler.schedule breaks that tie in
  ## favour of the more recently scheduled event -- which is the one with the
  ## shorter period, since each re-arms itself one period ahead. So a channel
  ## whose period is shorter than the observer's stepped FIRST (include the
  ## step), and one whose period is longer stepped after (defer it to the next
  ## observation). Reproducing this is the difference between "phase-exact" and
  ## bit-identical output; a PCM diff against the pre-catch-up build catches it.
  ##
  ## Equal periods are a genuine knife edge -- both events were armed on the
  ## same cycle, so in the old code the winner alternated with every shared
  ## cycle (0 then 2 steps per sample rather than 1). The alternation phase
  ## depends on insertion history and cannot be reconstructed without new
  ## serialized state, so these resolve uniformly as "include" -- which is also
  ## the more defensible answer, since a period equal to the sample interval
  ## should advance one step per sample. Reachable at NR43 = 0x22 on channel 4,
  ## frequency 0x7E0 on a square and 0x7C0 on the wave channel; it is the one
  ## and only case where output is not bit-identical to the pre-catch-up build.
  ## See notes/progress.md for the measurement.
  block:
    var s = d div period + 1
    if defer_tie and (d mod period) == 0: dec s
    s

template gb_apu_tick*(gb: GB): CycleCount =
  ## One APU tick in scheduler cycles. The APU's frequency timers run at 1 MHz
  ## (SameSuite channel_1_align: "This test verifies that channel 1 ticks at
  ## 1MHz"), i.e. one tick per 4 CPU T-cycles at single speed. schedule_gb
  ## scales every APU delay by the speed shift, so this has to as well: at CGB
  ## double speed the CPU cycle halves but the APU tick does not, so it spans 8
  ## scheduler cycles = 2 CPU cycles.
  CycleCount(4) shl gb.scheduler.speed

proc gb_apu_edge*(gb: GB): CycleCount =
  ## The first edge of the APU's 1 MHz tick grid at or after the current cycle.
  ## A register write between two edges is not picked up until the next one.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  let past = (now + tick - (gb.apu.tick_phase mod tick)) mod tick
  if past == 0: now else: now + (tick - past)

proc gb_trigger_deadline*(gb: GB; period: CycleCount;
                          extra_ticks: int): CycleCount =
  ## Absolute scheduler cycle of a channel's first waveform step after a
  ## trigger. Two hardware behaviours, both measured by SameSuite and
  ## documented in its sources:
  ##
  ## 1. The trigger does not take effect between APU ticks. The write is picked
  ##    up on the next edge of the 1 MHz grid that GbApu.tick_phase tracks --
  ##    which is why channel_1_align's results move by one CPU cycle when a nop
  ##    is inserted before the trigger, and why channel_1_align_cpu's do NOT
  ##    move when the same nop is inserted before the APU power-on that
  ##    established the grid.
  ## 2. From that edge, the first sample is due one full period PLUS a fixed
  ##    startup delay of extra_ticks, which the caller supplies because it
  ##    differs per channel and per trigger:
  ##      * squares, channel off:   2 (channel_1_delay: "It takes (sample
  ##        length + 2) ticks from the moment channel 1 is enabled until PCM12
  ##        is affected")
  ##      * squares, channel on:    1 (channel_1_restart: "after restarting,
  ##        the start delay from the 'delay' test is actually 1 tick shorter")
  ##
  ## Channel 4 does NOT use this: its divisor stage runs off a half-rate grid of
  ## its own and its first period is half-length. See gb_noise_deadline.
  ##
  ## The waveform POSITION is untouched either way -- hardware only resets it on
  ## an APU power-off -- so the first sample after a restart is the one the old
  ## pulse would have played next, exactly as channel_1_restart describes.
  gb_apu_edge(gb) + period + CycleCount(extra_ticks) * gb_apu_tick(gb)

proc gb_noise_deadline*(gb: GB; period: CycleCount; divisor_code: uint8;
                        restarting: bool): CycleCount =
  ## Absolute scheduler cycle of channel 4's first LFSR shift after a trigger.
  ## The noise channel does NOT share gb_trigger_deadline's rule, and the three
  ## tests that measure it agree on every subtest of a model with two parts.
  ##
  ## **The first period is half-length.** SameSuite channel_4_delay states the
  ## delay as "`sample length + 3` M-cycles, but it might be one M-cycle more or
  ## less", and its author says outright that he is not sure of the logic. What
  ## its four rows actually show -- NR43 = $08, $00, $18, $28, i.e. sample
  ## lengths of 2, 2, 4 and 8 M-cycles, first sample at 3, 3, 4 and 6 M-cycles
  ## after the write -- is `period / 2 + 2` M-cycles, not `period + 1`. The two
  ## agree only at the 2 M-cycle sample the "+3" was read off. The natural
  ## reading is a divide-by-two on the divisor stage's output whose flip-flop a
  ## trigger clears, so that the first edge arrives after one half-period; a
  ## RESTART of an already-running channel leaves it alone and therefore waits a
  ## full period, which is what channel_4_lfsr_restart and _restart_fast want
  ## (their expected tables are channel_4_lfsr's shifted by exactly one LFSR
  ## step). Both of those use a 2 M-cycle sample, where `period` and
  ## `period/2 + one extra tick` are the same number, so they pin the SIZE of
  ## the restart penalty but not its form.
  ##
  ## **The divisor stage is clocked by a 512 kHz grid a trigger cannot reset.**
  ## channel_4_frequency_alignment annotates its expected table with which NR43
  ## encodings are "affected" by an extra nop inserted before the trigger and
  ## which are "not affected", and the split is exactly `divisor_code == 0`:
  ## $18/$28/$38 are not affected, $09/$0a/$0b/$0c/$1a/$29 are. Solving its 18
  ## rows (nine encodings x two trigger phases) for the effective start:
  ##
  ##   divisor_code == 0   start at the 1 MHz tick, like every other channel
  ##   divisor_code == 1   round the 1 MHz tick UP to the 512 kHz grid
  ##   divisor_code >= 2   round it DOWN to the 512 kHz grid
  ##
  ## The 512 kHz grid sits on the odd 1 MHz ticks counted from the APU power-on
  ## (GbApu.noise_phase), which is why a power-on and not a trigger is what
  ## makes these tests repeatable at all. Divisor code 0 escaping the grid is
  ## the "made out of two different values" remark in channel_4_delay: code 0
  ## means 8 T-cycles where every other code means 16*code, i.e. it taps the
  ## half-step of the same divider and so keeps 1 MHz resolution.
  ##
  ## Cross-checks, on tests no constant here was derived from:
  ## channel_4_equivalent_frequencies drives $0c, $1a, $29 and $38 -- one
  ## encoding per rounding case, all four with a 16 M-cycle sample -- 512 nops
  ## deep into the LFSR sequence, and all 128 of its bytes fall out of the rule
  ## above; channel_4_align ($08, double speed) and channel_4_delay are what fix
  ## the half-period.
  ##
  ## Divisor codes 5-7 are not exercised by any SameSuite test; they follow the
  ## `>= 2` case because that is the only evidence there is.
  let tick = gb_apu_tick(gb)
  let edge = gb_apu_edge(gb)
  var extra = 2 * tick
  if divisor_code != 0:
    let half = 2 * tick
    if ((edge + half - gb.apu.noise_phase) mod half) != tick:
      # Off the 512 kHz grid. Adding rather than clamping `edge` keeps the sum
      # from underflowing when the down-rounding case lands before it.
      extra = (if divisor_code == 1: extra + tick else: extra - tick)
  edge + (if restarting: period else: period div 2) + extra

const GB_NO_STEP* = high(CycleCount)
  ## "no pending waveform step" sentinel for the channels' next_step deadline.
  ## Every catch-up guard is `next_step > scheduler.cycles`, so this parks a
  ## channel without a second flag -- it matches the old behaviour of simply
  ## not having an etAPUChannel* event queued (which is the state every channel
  ## starts in: the old code only armed the chain on the first trigger).

# The channel DAC's transfer function: digital 0-15 to analog +1..-1.
#
# Pan Docs, Audio Details / DACs: "If a DAC is enabled, the digital range $0 to
# $F is linearly translated to the analog range -1 to 1... Importantly, the
# slope is NEGATIVE: 'digital 0' maps to 'analog 1', not 'analog -1'."
#
# The sign is not cosmetic, and it is not just a question of which way the
# speaker cone moves first. Only a DISABLED DAC sits at analog 0 (Pan Docs: it
# "fades to an analog value of 0, which corresponds to digital 7.5"); a channel
# that is merely switched OFF still feeds digital 0 into its still-enabled DAC,
# "which an enabled DAC will dutifully convert into analog 1". So the idle level
# of a live channel is a rail -- and it is the same rail its waveform already
# touches at every digital-0 step. That is why, on hardware, switching a channel
# on or off is continuous while switching its DAC on or off pops (Pan Docs,
# Mixer: "Enabling or disabling a DAC... will cause an audio pop"). Getting the
# slope backwards inverts that relationship. See chN_get_amplitude.
#
# A table rather than the arithmetic: exact at both endpoints, and one L1 load
# in a path that runs four times per output sample, 32768 times a second.
const GB_DAC_LUT* = block:
  var t: array[16, float32]
  for i in 0 .. 15: t[i] = float32(1.0 - float64(i) / 7.5)
  t

proc length_step*(ch: GbSoundChannel) =
  if ch.length_enable and ch.length_counter > 0:
    dec ch.length_counter
    if ch.length_counter == 0:
      ch.enabled = false

proc volume_step*(ch: GbVolumeEnvChannel) =
  if ch.period != 0:
    if ch.volume_envelope_timer > 0:
      dec ch.volume_envelope_timer
    if ch.volume_envelope_timer == 0:
      ch.volume_envelope_timer = ch.period
      if (ch.current_volume < 0xF and ch.envelope_add_mode) or
         (ch.current_volume > 0 and not ch.envelope_add_mode):
        if ch.envelope_add_mode: inc ch.current_volume
        else:                    dec ch.current_volume
      else:
        ch.vol_env_is_updating = false

proc init_volume_envelope*(ch: GbVolumeEnvChannel) =
  ch.volume_envelope_timer = ch.period
  ch.current_volume        = ch.starting_volume
  ch.vol_env_is_updating   = true

proc read_NRx2*(ch: GbVolumeEnvChannel): uint8 =
  (ch.starting_volume shl 4) or (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.period

proc write_NRx2*(ch: GbVolumeEnvChannel; value: uint8) =
  # Can clear ch.enabled (DAC off), which is a channel-4 park point -- safe
  # because apu_write catches the target channel up before dispatching here.
  let new_add_mode = (value and 0x08) != 0
  let new_period   = value and 0x07
  if ch.enabled:
    # "Zombie mode": an NRx2 write to a channel that is already on perturbs the
    # live volume. The rule usually quoted (Pan Docs, Obscure Behavior) is +1
    # when the old period was zero and the envelope was still updating, ELSE +2
    # when the old direction was decrease, then `16 - volume` if the direction
    # changed. That is only ONE THIRD of the truth, and which third depends on
    # the value being WRITTEN, not on the old one.
    #
    # SameSuite publishes the whole table. channel_1_volume triggers the channel
    # and writes NRx2 again two M-cycles later, for every combination of
    # {old volume 0,1,4,7,8,10,14,15} x {old period 0,1} x {old dir} x
    # {new value $F0,$F1,$F8,$F9}, and reads PCM12 immediately; its
    # `CorrectResults` block is 128 bytes of hardware. Solving it for the
    # increment `d` applied before the direction flip gives (rows are the OLD
    # period/direction, columns the NEW):
    #
    #                | new dec, per 0 | new dec, per != 0 | new inc |
    #   old per 0 dec|       0        |        -1         |   +1    |
    #   old per!=0 dec|      0        |         0         |   +2    |
    #   old per 0 inc|       0        |        +1         |   +1    |
    #   old per!=0 inc|      0        |         0         |    0    |
    #
    # i.e. the quoted rule is exactly the `new inc` column; writing a DECREASING
    # envelope suppresses it entirely when the new period is zero, and replaces
    # it with a single step in the OLD direction when the new period is not.
    # channel_1_nrx2_glitch is the independent check: same table, but the second
    # write lands 1024 M-cycles after the trigger and its old periods are 2 and
    # 7 rather than 0 and 1. All 16 of its bytes fall out of the same three
    # columns, and both ROMs' channel_2 twins with them.
    #
    # `vol_env_is_updating` is left in the `new inc` branch where Pan Docs puts
    # it even though neither ROM reaches it with the flag clear: both write soon
    # enough after the trigger that the envelope cannot have saturated.
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
  # The envelope "enable" glitch: taking the period from zero to non-zero costs
  # one extra envelope tick at the next even DIV-APU step, on top of whatever
  # that step would have done. It is the whole difference between
  # channel_1_nrx2_speed_change's tests 1/2/5 (speed change and disable, which
  # this tree already got right) and its tests 3/4/6/7 (enable), every byte of
  # which came out exactly one volume step short without it.
  if ch.enabled and ch.period == 0 and new_period != 0:
    ch.env_extra_tick = true
  elif (value and 0x07) == 0:
    ch.env_extra_tick = false
  ch.starting_volume   = value shr 4
  ch.envelope_add_mode = new_add_mode
  ch.period            = value and 0x07
  ch.dac_enabled       = (value and 0xF8) != 0
  if not ch.dac_enabled: ch.enabled = false
