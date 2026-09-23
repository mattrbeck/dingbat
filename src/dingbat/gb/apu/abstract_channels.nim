# Abstract APU channel types (included by gb.nim)

const GB_OBS_CPU* = high(uint32)
  ## Observer period meaning "a CPU access": tick_slow has already dispatched
  ## every event due at or before scheduler.cycles, so a step landing on this
  ## exact cycle has happened (see gb_steps_due).

template gb_steps_due*(d, period: CycleCount; defer_tie: bool): CycleCount =
  ## Waveform steps due, given d = (now - next_step) >= 0 and the step period.
  ## A step landing exactly on the observer's cycle is included when the
  ## channel's period is shorter than the observer's and deferred when longer,
  ## reproducing the scheduler's tie order for same-cycle events (the more
  ## recently armed, i.e. shorter-period, event fires first). Equal periods
  ## resolve as "include".
  block:
    var s = d div period + 1
    if defer_tie and (d mod period) == 0: dec s
    s

template gb_apu_tick*(gb: GB): CycleCount =
  ## One APU tick in scheduler cycles: the frequency timers run at 1 MHz
  ## (SameSuite channel_1_align), one tick per 4 T-cycles; at CGB double speed
  ## the CPU cycle halves but the tick does not.
  CycleCount(4) shl gb.scheduler.speed

proc gb_apu_edge*(gb: GB): CycleCount =
  ## The first edge of the APU's 1 MHz tick grid at or after the current cycle.
  ## A register write between two edges is not picked up until the next one.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  let past = (now + tick - (gb.apu.tick_phase mod tick)) mod tick
  if past == 0: now else: now + (tick - past)

const APU_TRIGGER_EDGE_BEFORE* {.intdefine.} = 0
  ## 1: a square trigger counts its startup from the 1 MHz edge at or BEFORE
  ## the write; 0: from the edge at or after it. Only distinguishable at double
  ## speed, where a CPU write can land half a tick off the grid. The two
  ## claims contradict on CPU CGB C: gambatte sound/ch1_duty0_pos6_to_pos7_
  ## timing_ds_{5,6} want 1 (a first trigger one NOP later lands on the same
  ## edge), SameSuite channel_{1,2}_align{,_cpu} and channel_1_freq_change_
  ## timing-* (7 rows) want 0 and lose with 1. Ships 0; the two gambatte rows
  ## are the residual (docs/gb-failure-triage.md H1).

proc gb_apu_edge_before*(gb: GB): CycleCount =
  ## The last edge of the APU's 1 MHz tick grid at or before the current cycle.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  now - ((now + tick - (gb.apu.tick_phase mod tick)) mod tick)

const APU_CLOCK_CARRY* {.intdefine.} = 0
  ## Ships 0. 1: on CPU CGB C and older (GbQuirks.apu_clock_carry) the square
  ## channels count their start-up from the 1 MHz edge at or BEFORE the write
  ## on a 2 MHz APU clock whose phase is carried through APU power-on, DIV
  ## resets and speed switches (the apu_sh_* shadow below, the rules
  ## gambatte-core's PSG uses), and a switch carries every APU deadline across
  ## by its distance in 2 MHz cycles (apu_rescale_speed), with
  ## APU_SPSW_EXTRA_DOTS_CARRY{,_SINGLE} = 5 / 1 for the stall. It takes all
  ## fourteen red gambatte audio rows (sound/ch1_duty0_pos6_to_pos7_timing_ds_6,
  ## speedchange{2..5}*_ch1_duty0_pos6_to_pos7_timing_*, speedchange_ch1_
  ## nr4init_*_2; peak bracketed on both extras) and loses SameSuite
  ## channel_1_freq_change_timing-cgb0BC, whose triggers want the 1 MHz grid
  ## anchored at the power-on write (the shipping rule). Both are CGB C
  ## hardware records; applied to D/E too it loses nine more SameSuite rows.
  ## docs/gb-failure-triage.md H1/H2.

when APU_CLOCK_CARRY != 0:
  template sh_now(gb: GB): int64 = int64(gb.scheduler.cycles)
  template sh_ds(gb: GB): int64 = int64(gb.memory.current_speed)
  proc apu_sh_advance*(gb: GB; t: int64; ds: int64) =
    ## Whole 2 MHz cycles up to `t` (2 scheduler cycles each at single speed,
    ## 4 at double); the remainder stays carried in `sh_last`.
    let step = 2'i64 shl ds
    if t > gb.sh_last:
      let n = (t - gb.sh_last) div step
      gb.sh_last += n * step
      gb.sh_cc += n
  proc apu_sh_boot*(gb: GB) =
    let t = sh_now(gb)
    gb.sh_last = t - 1
    gb.sh_cc = t shr 1
  proc apu_sh_power_on*(gb: GB) =
    ## Power-on keeps the counter's low bits and re-aligns the clock to a
    ## multiple of four cycles.
    let t = sh_now(gb)
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let off = gb.sh_last and ds
    let c = gb.sh_cc + off
    gb.sh_cc = (c and 0xFFF) + 2 * ((not (c + 1 + (1 - ds))) and 0x800)
    gb.sh_last = ((gb.sh_last + 3) and not 3'i64) - (1 - ds)
  proc apu_sh_div_reset*(gb: GB; t: int64) =
    ## A DIV reset re-aligns the counter to a 4096-cycle boundary.
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let off = gb.sh_last and ds
    let c = gb.sh_cc + off
    gb.sh_cc = (c and not 0xFFF'i64) + 2 * (c and 0x800) - off
  proc apu_sh_speed_change*(gb: GB; t: int64; old_ds: int64) =
    ## The carried remainder is re-read at the new speed (one cycle less going
    ## down); going up the counter also drops half its cycles since the reset.
    apu_sh_advance(gb, t, old_ds)
    gb.sh_l0 = gb.sh_last
    gb.sh_last -= old_ds
    gb.sh_l1 = gb.sh_last
    if old_ds == 0:
      gb.sh_cc = gb.sh_cc - (gb.sh_cc and 0xFFF) div 2 - (gb.sh_last and 1)
  proc apu_sh_edge*(gb: GB): CycleCount =
    ## The 1 MHz edge at or before the write, on the carried clock.
    let t = sh_now(gb)
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let refv = if ds != 0 and (gb.sh_last and 1) != 0: 0'i64 else: 1'i64
    let k = gb.sh_cc - ((gb.sh_cc - refv) and 1)
    CycleCount(max(0'i64, gb.sh_last + (k - gb.sh_cc) * (2'i64 shl ds)))

proc gb_trigger_deadline*(gb: GB; period: CycleCount;
                          extra_ticks: int): CycleCount =
  ## Absolute cycle of a channel's first waveform step after a trigger: the
  ## write is picked up on the next edge of the 1 MHz grid (SameSuite
  ## channel_1_align / channel_1_align_cpu), then one full period plus
  ## extra_ticks of startup delay -- 2 for a square that was off
  ## (channel_1_delay), 1 for a restart (channel_1_restart). The waveform
  ## position is untouched. Channel 4 has its own rule: gb_noise_deadline.
  var edge = if APU_TRIGGER_EDGE_BEFORE != 0: gb_apu_edge_before(gb)
             else: gb_apu_edge(gb)
  when APU_CLOCK_CARRY != 0:
    if gb.quirks.apu_clock_carry: edge = apu_sh_edge(gb)
  edge + period + CycleCount(extra_ticks) * gb_apu_tick(gb)

proc gb_noise_deadline*(gb: GB; period: CycleCount; divisor_code: uint8;
                        restarting: bool): CycleCount =
  ## Absolute cycle of channel 4's first LFSR shift after a trigger. Two parts:
  ## the first period is half-length (a trigger clears the divide-by-two on the
  ## divisor stage's output; a restart of a running channel leaves it alone and
  ## waits a full period) -- SameSuite channel_4_delay's rows are
  ## `period/2 + 2` M-cycles, channel_4_lfsr_restart pins the restart -- and
  ## the divisor stage is clocked by a 512 kHz grid a trigger cannot reset
  ## (GbApu.noise_phase): divisor code 0 starts on the 1 MHz tick, code 1
  ## rounds it up to the grid, codes >= 2 round it down
  ## (channel_4_frequency_alignment; cross-checked by
  ## channel_4_equivalent_frequencies and channel_4_align). Codes 5-7 are not
  ## exercised by any test and follow the >= 2 case.
  let tick = gb_apu_tick(gb)
  let edge = gb_apu_edge(gb)
  var extra = 2 * tick
  if divisor_code != 0:
    let half = 2 * tick
    if ((edge + half - gb.apu.noise_phase) mod half) != tick:
      # Off the 512 kHz grid. Adjusting `extra` rather than `edge` keeps the
      # sum from underflowing in the down-rounding case.
      extra = (if divisor_code == 1: extra + tick else: extra - tick)
  edge + (if restarting: period else: period div 2) + extra

const GB_NO_STEP* = high(CycleCount)
  ## "no pending waveform step" sentinel: every catch-up guard is
  ## `next_step > scheduler.cycles`, so this parks a channel without a flag.

# DAC transfer function, digital 0-15 to analog +1..-1. Pan Docs, Audio
# Details: the slope is negative, digital 0 is analog +1. A channel that is
# switched off still feeds digital 0 to its enabled DAC (analog +1); only a
# disabled DAC sits at analog 0, which is why a DAC toggle pops and a channel
# toggle does not. A table: exact endpoints, one load per channel per sample.
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

proc init_volume_envelope*(ch: GbVolumeEnvChannel; extra = 0) =
  ## `extra`: envelope clocks added to the first period (env_trigger_extra).
  ch.volume_envelope_timer = (if ch.period != 0: ch.period + uint8(extra)
                              else: ch.period)
  ch.current_volume        = ch.starting_volume
  ch.vol_env_is_updating   = true

# Forward declaration: timer.nim is included after the APU (gb.nim, which
# already forward-declares apu_div_phase).
proc apu_div_period*(gb: GB): int {.inline.}

const ENV_TRIGGER_PRECLOCK_SKIP* {.intdefine.} = 1
  ## 1: a trigger landing in the frame-sequencer step before the envelope
  ## clock (step 6), taken 4 T-cycles early, does not get that clock: its
  ## first envelope period is one clock longer. gambatte
  ## sound/ch2_init_{,reset_}env_counter_timing_* (40 rows, both devices):
  ## 0 loses `reset_` 11, 13, 14 [dmg] and 15 [cgb], which trigger inside
  ## step 6 and expect the envelope still at volume 0 after the clock.
const SWEEP_TRIGGER_LEAD_T_DMG* {.intdefine.} = 4
const SWEEP_TRIGGER_LEAD_T_CGB* {.intdefine.} = 8
  ## A trigger within this many T-cycles before a sweep clock (steps 2 and 6)
  ## misses that clock: the sweep timer starts one clock later. gambatte
  ## sound/ch1_init_reset_sweep_counter_timing_* (22 rows): 0 loses
  ## timing_4 [dmg] and timing_10 [cgb], whose triggers sit one NOP before a
  ## sweep clock and expect the channel still running (no overflow yet) when
  ## the ROM turns the sweep off.

proc fs_next_edge_in*(gb: GB): int =
  ## Raw scheduler cycles until the frame sequencer's next step runs
  ## (stage `gb.apu.frame_sequencer_stage`), including a pending skipped edge.
  result = apu_div_phase(gb.timer, gb)
  if gb.apu.div_skip: result += apu_div_period(gb)

proc env_trigger_extra*(gb: GB): int =
  ## Extra envelope clocks for a trigger now (ENV_TRIGGER_PRECLOCK_SKIP).
  when ENV_TRIGGER_PRECLOCK_SKIP == 0:
    0
  else:
    let d = fs_next_edge_in(gb)
    let lead = 4 shl gb.scheduler.speed
    let stage = gb.apu.frame_sequencer_stage
    if (stage == 7 and d > lead) or (stage == 6 and d <= lead): 1 else: 0

proc sweep_trigger_extra*(gb: GB): uint8 =
  ## Extra sweep clocks for a trigger now (SWEEP_TRIGGER_LEAD_T_*).
  let lead_t = (if gb.cgb_enabled: SWEEP_TRIGGER_LEAD_T_CGB
                else: SWEEP_TRIGGER_LEAD_T_DMG)
  if lead_t == 0: return 0
  let d = fs_next_edge_in(gb)
  let stage = gb.apu.frame_sequencer_stage
  if (stage == 2 or stage == 6) and d <= (lead_t shl gb.scheduler.speed): 1
  else: 0

proc read_NRx2*(ch: GbVolumeEnvChannel): uint8 =
  (ch.starting_volume shl 4) or (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.period

proc write_NRx2*(ch: GbVolumeEnvChannel; value: uint8) =
  # Can clear ch.enabled (DAC off); apu_write catches the channel up first.
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
  # extra envelope tick at the next odd frame-sequencer stage
  # (tick_frame_sequencer; SameSuite channel_1_nrx2_speed_change tests 3/4/6/7).
  if ch.enabled and ch.period == 0 and new_period != 0:
    ch.env_extra_tick = true
  elif (value and 0x07) == 0:
    ch.env_extra_tick = false
  ch.starting_volume   = value shr 4
  ch.envelope_add_mode = new_add_mode
  ch.period            = value and 0x07
  ch.dac_enabled       = (value and 0xF8) != 0
  if not ch.dac_enabled: ch.enabled = false
