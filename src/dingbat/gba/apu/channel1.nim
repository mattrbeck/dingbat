# APU Channel 1 (Square + sweep) (included by gba.nim)

const WAVE_DUTY_CH1*: array[4, array[8, int]] = [
  [-8, -8, -8, -8, -8, -8, -8, +8],  # 12.5%
  [+8, -8, -8, -8, -8, -8, -8, +8],  # 25%
  [+8, -8, -8, -8, -8, +8, +8, +8],  # 50%
  [-8, +8, +8, +8, +8, +8, +8, -8],  # 75%
]

const RANGE_CH1_LOW*  = 0x60'u32
const RANGE_CH1_HIGH* = 0x67'u32

proc ch1_in_range*(address: uint32): bool =
  address >= RANGE_CH1_LOW and address <= RANGE_CH1_HIGH

proc new_channel1*(gba: GBA): Channel1 =
  Channel1(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    starting_volume: 0, envelope_add_mode: false, period_ve: 0,
    volume_envelope_timer: 0, current_volume: 0, volume_envelope_is_updating: false,
    wave_duty_position: 0,
    sweep_period: 0, negate: false, shift_ch1: 0,
    sweep_timer: 0, frequency_shadow: 0, sweep_enabled: false, negate_has_been_used: false,
    duty: 0, length_load: 0, frequency_ch1: 0,
    next_step: GBA_NO_STEP, arm_delay: 0,
    sweep_armed: true, kill_at: GBA_NO_STEP,
  )

proc ch1_frequency_timer*(ch: Channel1): uint32 =
  (0x800'u32 - uint32(ch.frequency_ch1)) * 4 * 4

proc ch1_catchup_slow(ch: Channel1; observer_period: uint32) =
  let now    = ch.gba.scheduler.cycles
  let period = CycleCount(ch.ch1_frequency_timer())
  # next_step is the absolute cycle of the FIRST pending step; every later step
  # is one CURRENT period apart, even across a frequency write (gba_steps_due).
  let steps = gba_steps_due(now - ch.next_step, period, ch.arm_delay,
                            observer_period)
  if steps == 0: return
  when defined(psgverify):
    var want = ch.wave_duty_position
    for _ in 0 ..< steps: want = (want + 1) and 7
  ch.wave_duty_position = (ch.wave_duty_position + int(steps and 7)) and 7
  when defined(psgverify):
    doAssert want == ch.wave_duty_position, "ch1 closed form != naive loop"
  ch.next_step += steps * period
  # The step now pending was armed by the one before it, i.e. one CURRENT
  # period ago.
  ch.arm_delay = uint32(period)

proc ch1_catchup_at*(ch: Channel1; observer_period: uint32) {.inline.} =
  ## Bring wave_duty_position up to scheduler.cycles in closed form (mod-8
  ## counter: (pos + N) and 7). Must run before anything observes the duty
  ## position or changes the period (observation points: apu.nim).
  ## observer_period (GBA_OBS_CPU for MMIO) only matters for a step landing on
  ## this exact cycle.
  if ch.next_step > ch.gba.scheduler.cycles: return   # not due (or parked)
  ch1_catchup_slow(ch, observer_period)

proc ch1_catchup*(ch: Channel1) {.inline.} =
  ch1_catchup_at(ch, GBA_OBS_CPU)

const PSG_SEQ_GRID* = 4
  ## After a master-on the 512 Hz edges fall PSG_SEQ_GRID cycles past the
  ## restarted dividers' 16-cycle grid (s0_anchor). AGB SP s0time.s's
  ## step-synced half (160 cells, each a spread over the poll's 10-cycle
  ## granularity): 127 cells hold dingbat's answer at 4, a single peak
  ## falling to 93 unaligned and 76 at 13.
const PSG_S0_APU_PHASE* = 2'u32
  ## scheduler.cycles mod 4 of the PSG's 4 MHz clock edges: the system clock
  ## divided by four, free-running (the frame is a multiple of 16 cycles, so
  ## it is fixed against the video frame).

proc ch1_s0_kill_at(t: CycleCount; slow: bool; anchor: uint8): CycleCount =
  ## When a trigger written at cycle t that failed the shift-0 check stops
  ## the channel, or GBA_NO_STEP when the check never sees the trigger.
  ## AGB SP (link rig 2026-09-25; SOUNDCNT_X read 3 cycles apart after the
  ## trigger, 16 phases a row, every cell stable):
  ## - slow (s0_slow: no sweep calculation since a master-on, and no 512 Hz
  ##   step while the CPU was halted -- apu.nim tick_frame_sequencer): the
  ##   trigger is taken on the next
  ##   edge of the 2 MHz divider the master-on restarted on 4 MHz edge
  ##   `anchor` (mod 16); a write landing ON that edge is missed and the note
  ##   lives; the stop comes on the next of two edges 4 cycles apart in each
  ##   16 of the 1 MHz divider -- 2 to 12 cycles after the write, one phase
  ##   in 8 escaping. s0trig.s (master-on 40 cycles before), s0time.s (4 ..
  ##   32768 cycles before) and s0long.s (to 262144, and across a halt) all
  ##   agree once the phase is counted from that edge, and s0write.s's
  ##   SOUNDCNT_X / _H / _L writes leave it slow;
  ## - otherwise (s0trig.s bit 14: sound switched on, then a halt spanning a
  ##   step): the first 4 MHz edge at least 3
  ##   cycles after the write -- the channel reads on once, or twice at every
  ##   fourth phase.
  ## Both are fits to those cells, not a derived circuit.
  if not slow:
    result = t + 3
    result += CycleCount((PSG_S0_APU_PHASE + 4 - uint32(result and 3)) and 3)
  else:
    let into = uint32(t + 1 - CycleCount(anchor)) and 7   # 0 = on a 2 MHz edge
    if into == 0: return GBA_NO_STEP
    let taken = t + CycleCount(8 - into)
    result = taken + (if (uint32(taken - CycleCount(anchor)) and 15) == 15: 5 else: 1)

proc ch1_settle*(ch: Channel1) {.inline.} =
  ## Apply a shift-0 kill that has come due (ch1_s0_kill_at); every reader of
  ## the channel's enable runs this first.
  if ch.kill_at <= ch.gba.scheduler.cycles:
    ch.kill_at = GBA_NO_STEP
    ch.enabled = false

proc ch1_frequency_calculation*(ch: Channel1): uint16 =
  let shifted    = ch.frequency_shadow shr ch.shift_ch1
  var calculated = uint32(ch.frequency_shadow) + uint32(if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_has_been_used = true
  if calculated > 0x07FF: ch.enabled = false
  uint16(calculated)

proc sweep_step*(ch: Channel1) =
  # tick_frame_sequencer caught the duty counter up first: this can change
  # frequency_ch1, and elapsed cycles must be priced with the old period.
  if ch.sweep_timer > 0: ch.sweep_timer -= 1
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8
    if ch.sweep_enabled and ch.sweep_period > 0:
      ch.s0_slow = false   # a calculation has run (ch1_s0_kill_at)
      let calculated = ch.ch1_frequency_calculation()
      if calculated <= 0x07FF and ch.shift_ch1 > 0:
        ch.frequency_shadow = calculated
        ch.frequency_ch1    = calculated
        discard ch.ch1_frequency_calculation()

proc ch1_get_amplitude*(ch: Channel1): int16 =
  if ch.enabled and ch.dac_enabled:
    int16(WAVE_DUTY_CH1[ch.duty][ch.wave_duty_position]) * int16(ch.current_volume)
  else:
    0'i16

proc ch1_read*(ch: Channel1; address: uint32): uint8 =
  case address
  of 0x60: (ch.sweep_period shl 4) or (if ch.negate: 0x08'u8 else: 0'u8) or ch.shift_ch1
  of 0x62: ch.duty shl 6
  of 0x63: ch.read_nrx2()
  of 0x65: (if ch.length_enable: 0x40'u8 else: 0'u8)
  else: 0'u8

proc ch1_write*(ch: Channel1; address: uint32; value: uint8) =
  # apu[]= caught the duty counter up to the current cycle before getting here,
  # so a period/duty/trigger change below only affects steps from now on.
  case address
  of 0x60:
    ch.sweep_period = (value and 0x70) shr 4
    ch.negate       = (value and 0x08) > 0
    ch.shift_ch1    = value and 0x07
    if not ch.negate and ch.negate_has_been_used: ch.enabled = false
  of 0x61: discard
  of 0x62:
    ch.duty         = (value and 0xC0) shr 6
    ch.length_load  = value and 0x3F
    ch.length_counter = 0x40 - int(ch.length_load)
  of 0x63: ch.write_nrx2(value)
  of 0x64: ch.frequency_ch1 = (ch.frequency_ch1 and 0x0700'u16) or uint16(value)
  of 0x65:
    ch.frequency_ch1 = (ch.frequency_ch1 and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    let triggered = (value and 0x80) > 0
    if triggered and ch.dac_enabled: ch.enabled = true
    ch.agb_length_on_nrx4(length_enable, triggered, 0x40)
    if triggered:
      # Re-arm a full period from now. The duty POSITION carries across a
      # trigger (Pan Docs: only APU power-off resets it), hence catch-up
      # rather than park.
      let arm1 = ch.ch1_frequency_timer()
      ch.next_step = ch.gba.scheduler.cycles + CycleCount(arm1)
      ch.arm_delay = arm1
      ch.init_volume_envelope()
      let stale = ch.frequency_shadow
      let slow = ch.s0_slow   # (ch1_s0_kill_at) as the trigger finds it
      ch.frequency_shadow     = ch.frequency_ch1
      ch.sweep_timer          = if ch.sweep_period > 0: ch.sweep_period else: 8
      ch.sweep_enabled        = ch.sweep_period > 0 or ch.shift_ch1 > 0
      ch.negate_has_been_used = false
      # A pending shift-0 kill from an earlier trigger does not survive this one
      ch.kill_at = GBA_NO_STEP
      if ch.shift_ch1 > 0:
        # The trigger's overflow check (Pan Docs: with a non-zero shift) runs
        # on the new frequency AND on the one the shadow still held (AGB SP,
        # link rig 2026-09-24, tests/roms/dbsuite/payloads/sweeptrig.s): sweep
        # 0x21 at 1300 lives to its first tick after a master off/on at every
        # 16-cycle phase, but straight after a 1400 note that overflowed it
        # dies at the trigger (hwverified/sweep, cartridge; half the phases
        # over the rig). That is 1400 + 700 still in the shadow, not a second
        # pass over 1300 (1950 + 650), which the lone rows rule out. The
        # hardware's stale view is phase-dependent; this takes it always.
        let offset = int(ch.frequency_shadow shr ch.shift_ch1)
        let stale_offset = int(stale shr ch.shift_ch1)
        if ch.negate: ch.negate_has_been_used = true
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
        let at = ch1_s0_kill_at(ch.gba.scheduler.cycles, slow, ch.s0_anchor)
        if at != GBA_NO_STEP:
          # The check ran (a trigger it missed leaves the unit armed); the
          # stop is not at once: the channel reads as on for a few cycles.
          let offset = int(ch.frequency_shadow)
          if ch.negate: ch.negate_has_been_used = true
          let calc = int(ch.frequency_shadow) + (if ch.negate: -offset else: offset)
          if calc > 0x7FF and ch.enabled: ch.kill_at = at
          ch.sweep_armed = false
          ch.s0_slow = false
  of 0x66, 0x67: discard
  else: echo "Writing to invalid Channel1 register: ", hex_str(uint16(address))
