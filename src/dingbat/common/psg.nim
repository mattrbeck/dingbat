# The PSG: the four Game Boy sound channels, one model for both cores.
#
# The GBA carries the CGB's sound hardware (GBATEK maps 0x4000060-0x4000081
# onto NR10-NR52), so both cores run the same channels. This module holds what
# needs no host: the channel state and the state machines that only read it.
# Everything that reads a clock, a register block or a revision lives in
# psg_channels.nim, which each core `include`s after defining its hooks, so
# each core compiles its own copy with its own constants folded in.
#
# The channel objects carry the union of both cores' fields. A field only one
# core uses today says so at its declaration.

import scheduler

const PSG_NO_STEP* = high(CycleCount)
  ## "No pending waveform step" sentinel for a deadline: every catch-up guard
  ## is `next_step > now`, so this parks a channel without a second flag.

const PSG_OBS_CPU* = high(uint32)
  ## Observer period meaning "a CPU access": the host has already dispatched
  ## every event due at or before this cycle, so a step landing on it has
  ## happened (psg_steps_due).

const PSG_DUTY*: array[4, array[8, uint8]] = [
  [0'u8, 0, 0, 0, 0, 0, 0, 1],  # 12.5%
  [1'u8, 0, 0, 0, 0, 0, 0, 1],  # 25%
  [1'u8, 0, 0, 0, 0, 1, 1, 1],  # 50%
  [0'u8, 1, 1, 1, 1, 1, 1, 0],  # 75%
]

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

const PSG_WAVE_BANK* = 16
  ## Bytes in one wave RAM bank. The GB has one; the GBA two (SOUND3CNT_L).

type
  PsgChannel* = ref object of RootObj
    enabled*:        bool
    dac_enabled*:    bool
    length_counter*: int
    length_enable*:  bool
    # Absolute scheduler cycle of the next waveform step, or PSG_NO_STEP.
    # Replaces a per-period scheduler event: the waveform is advanced in
    # closed form when something observes it (psg_channels.nim). NOT
    # serialized as a field -- each savestate.nim converts it to/from an
    # etAPUChannel<N> event so the state format is unchanged.
    next_step*:      CycleCount
    # GBA: the delay the pending step was armed with, for the scheduler
    # tie-break a step landing on an observer's own cycle reproduces
    # (psg_steps_due). In the GBA state's in-flight section (rev 9).
    arm_delay*:      uint32

  PsgEnvChannel* = ref object of PsgChannel
    starting_volume*:        uint8
    envelope_add_mode*:      bool
    period*:                 uint8
    volume_envelope_timer*:  uint8
    current_volume*:         uint8
    vol_env_is_updating*:    bool
    # GB: an NRx2 write taking the envelope period from zero to non-zero makes
    # the next EVEN DIV-APU tick clock that channel's envelope (SameSuite
    # channel_1_nrx2_speed_change); see write_nrx2 and psg_seq_step.
    # Serialized from GB payload rev 6: a 512 Hz step can span a frame edge.
    env_extra_tick*:         bool

  PsgSquare* = ref object of PsgEnvChannel
    ## Channel 2, and channel 1 without its sweep unit.
    wave_duty_position*: int
    # GB: the latched duty output, sampled once per duty step and held, so a
    # mid-sample NR11 duty change is not audible until the next step
    # (SameSuite channel_1_duty_delay) and a trigger keeps emitting the
    # previous sample through the startup delay (channel_1_duty, _align).
    # Refreshed only by sq_catchup_slow. Serialized from GB payload rev 6.
    sample_bit*:         uint8
    # GB: absolute scheduler cycle of the most recent duty step (PSG_NO_STEP
    # if none since the trigger); only sq_reload_is_now reads it, to tell a
    # reload on this very cycle from a start delay one period away. Not
    # serialized: rewritten by the next duty step.
    last_step_at*:       CycleCount
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  PsgSweepSquare* = ref object of PsgSquare
    ## Channel 1.
    sweep_period*:       uint8
    negate*:             bool
    shift*:              uint8
    sweep_timer*:        uint8
    frequency_shadow*:   uint16
    sweep_enabled*:      bool
    negate_used*:        bool
    # GB: absolute scheduler cycle of the sweep's second overflow check, or
    # PSG_NO_STEP: it trails the frequency writeback by 7 M-cycles and re-reads
    # NR10 (PSG_SWEEP_CHECK_DELAY). Serialized from GB payload rev 6, with the
    # two sweep deadlines below and sweep_load_value, as distances from the
    # payload's scheduler clock.
    sweep_check_at*:     CycleCount
    # GB: absolute scheduler cycle at which a sweep overflow STOP reaches NR52,
    # or PSG_NO_STEP when none is in flight. Every sweep calculation's stop is
    # one APU tick behind the calculation itself; see PSG_SWEEP_STOP_DELAY.
    sweep_stop_at*:      CycleCount
    # GB: a trigger's frequency-shadow load in flight: the value NR13/NR14
    # held when the channel was triggered, and the absolute scheduler cycle it
    # reaches the sweep unit's shadow register (PSG_NO_STEP when none is
    # pending). The load does NOT happen on the write; PSG_SWEEP_SHADOW_DELAY.
    sweep_load_at*:      CycleCount
    sweep_load_value*:   uint16
    # GBA: the AGB's shift-0 trigger check is armed (ch1_write). Saved in
    # bit 15 of frequency_shadow's field; the format has no bit of its own.
    sweep_armed*:        bool
    # GBA: scheduler.cycles mod 32 of the 4 MHz edge a master-on restarted the
    # PSG's dividers on (ch1_s0_kill_at, psg_edge, psg_noise_phase). In the
    # rev-10 PSG section; revs <= 9 kept it mod 16 in the high nibble of
    # sweep_timer's byte.
    s0_anchor*:          uint8
    # GBA: the shift-0 check's slow timing (ch1_s0_kill_at). Saved in bit 7
    # of sweep_period's byte.
    s0_slow*:            bool
    # GBA: cycle a failed shift-0 trigger check stops the channel, or
    # PSG_NO_STEP (at most 13 cycles ahead). Saved as a distance in bits
    # 11..14 of frequency_shadow's field.
    kill_at*:            CycleCount

  PsgWave* = ref object of PsgChannel
    ## Channel 3. Bank 0 is wave_ram[0 ..< 16], bank 1 (GBA) [16 ..< 32].
    wave_ram*:               array[2 * PSG_WAVE_BANK, uint8]
    wave_ram_position*:      uint8
    # GB: whether CH3 has fetched a byte since its last trigger: a trigger
    # reloads the timer with period + 6 (Pan Docs), so until then there is no
    # "byte CH3 is on" for a DMG wave RAM access to land on (ch3_wave_open).
    # Serialized from GB payload rev 6.
    wave_fetched*:           bool
    # The byte last fetched; the DAC plays the nibble the position selects.
    # (GBA revs <= 9 held the nibble.)
    wave_ram_sample_buffer*: uint8
    length_load*:            uint8
    volume_code*:            uint8
    volume_code_shift*:      uint8   # GB: 4/0/1/2 by volume_code
    frequency*:              uint16
    wave_ram_dimension*:     bool    # GBA: SOUND3CNT_L bit 5, 64-step mode
    wave_ram_bank*:          uint8   # GBA: SOUND3CNT_L bit 6, bank played
    volume_force*:           bool    # GBA: SOUND3CNT_H bit 15, force 75%

  PsgNoise* = ref object of PsgEnvChannel
    ## Channel 4.
    lfsr*:         uint16
    length_load*:  uint8
    clock_shift*:  uint8
    width_mode*:   uint8
    divisor_code*: uint8
    # The noise timer is two counters: `div_counter` free-runs off the
    # divisor stage and `clock_shift` picks which bit clocks the LFSR;
    # `div_next` is the divisor stage's next increment (ch4_steps_to_rise).
    # NR43 selects a new view of both without restarting either. Serialized
    # from GB payload rev 6 and GBA rev 10; an older state re-derives them
    # from `next_step` (ch4_resync_divisor).
    div_counter*:  uint16
    div_next*:     CycleCount

proc new_psg_square_sweep*(): PsgSweepSquare =
  PsgSweepSquare(next_step: PSG_NO_STEP, last_step_at: PSG_NO_STEP,
                 sweep_check_at: PSG_NO_STEP, sweep_stop_at: PSG_NO_STEP,
                 sweep_load_at: PSG_NO_STEP, sweep_armed: true,
                 kill_at: PSG_NO_STEP)

proc new_psg_square*(): PsgSquare =
  PsgSquare(next_step: PSG_NO_STEP, last_step_at: PSG_NO_STEP)

proc new_psg_wave*(banks: int): PsgWave =
  ## Wave RAM starts in the GB's power-on pattern, 00 FF 00 FF ..., in every
  ## bank the host has.
  result = PsgWave(next_step: PSG_NO_STEP)
  for i in 0 ..< banks * PSG_WAVE_BANK:
    result.wave_ram[i] = if (i and 1) == 0: 0x00'u8 else: 0xFF'u8

proc new_psg_noise*(): PsgNoise =
  PsgNoise(next_step: PSG_NO_STEP, div_next: PSG_NO_STEP)

# ---- Host-free state machines ----

proc length_step*(ch: PsgChannel) =
  if ch.length_enable and ch.length_counter > 0:
    dec ch.length_counter
    if ch.length_counter == 0:
      ch.enabled = false

proc volume_step*(ch: PsgEnvChannel) =
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

proc init_volume_envelope*(ch: PsgEnvChannel; extra = 0) =
  ## `extra`: envelope clocks added to the first period (psg_env_trigger_extra).
  ch.volume_envelope_timer = (if ch.period != 0: ch.period + uint8(extra)
                              else: ch.period)
  ch.current_volume        = ch.starting_volume
  ch.vol_env_is_updating   = true

proc read_nrx2*(ch: PsgEnvChannel): uint8 =
  (ch.starting_volume shl 4) or (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.period

proc psg_lfsr_shift*(ch: PsgNoise) {.inline.} =
  ## 15-bit LFSR: the XOR of the low two bits feeds bit 14, and bit 6 as well
  ## in 7-bit width mode.
  let new_bit = (ch.lfsr and 0b01'u16) xor ((ch.lfsr and 0b10'u16) shr 1)
  ch.lfsr = ch.lfsr shr 1
  ch.lfsr = ch.lfsr or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = ch.lfsr and not (1'u16 shl 6)
    ch.lfsr = ch.lfsr or (new_bit shl 6)

proc ch4_steps_to_rise*(counter: uint16; shift: uint8): uint32 =
  ## Increments until bit `shift` of `counter` rises; 1 .. 2^(shift+1), so a
  ## counter sitting on the edge waits a full period.
  let m = 1'u32 shl (int(shift) + 1)
  let t = 1'u32 shl int(shift)
  let c = uint32(counter) and (m - 1)
  ((t + m - c - 1) and (m - 1)) + 1

proc ch4_resync_divisor*(ch: PsgNoise) =
  ## Rebuild the two stages from `next_step` alone after loading a state that
  ## did not carry them (GB payload rev < 6, GBA rev < 10): counter one
  ## increment short of the rising edge, that increment due on the deadline.
  ## Only an NR43 write inside the first period after the load could tell. An
  ## assignment, not a subtraction, so it cannot underflow.
  if ch.next_step == PSG_NO_STEP:
    ch.div_next = PSG_NO_STEP
    ch.div_counter = 0
    return
  ch.div_counter = (1'u16 shl int(ch.clock_shift)) - 1
  ch.div_next = ch.next_step

# ---- Register numbering ----
#
# The channel registers by NR offset from NR10 (GB: address - 0xFF10), so
# the GB's packed block and the GBA's spread one share one write path.

const
  NR10* = 0x00
  NR11* = 0x01
  NR12* = 0x02
  NR13* = 0x03
  NR14* = 0x04
  NR21* = 0x06
  NR22* = 0x07
  NR23* = 0x08
  NR24* = 0x09
  NR30* = 0x0A
  NR31* = 0x0B
  NR32* = 0x0C
  NR33* = 0x0D
  NR34* = 0x0E
  NR41* = 0x10
  NR42* = 0x11
  NR43* = 0x12
  NR44* = 0x13
