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

proc gb_trigger_deadline*(gb: GB; period: CycleCount;
                          extra_ticks: int): CycleCount =
  ## Absolute cycle of a channel's first waveform step after a trigger: the
  ## write is picked up on the next edge of the 1 MHz grid (SameSuite
  ## channel_1_align / channel_1_align_cpu), then one full period plus
  ## extra_ticks of startup delay -- 2 for a square that was off
  ## (channel_1_delay), 1 for a restart (channel_1_restart). The waveform
  ## position is untouched. Channel 4 has its own rule: gb_noise_deadline.
  gb_apu_edge(gb) + period + CycleCount(extra_ticks) * gb_apu_tick(gb)

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

proc init_volume_envelope*(ch: GbVolumeEnvChannel) =
  ch.volume_envelope_timer = ch.period
  ch.current_volume        = ch.starting_volume
  ch.vol_env_is_updating   = true

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
