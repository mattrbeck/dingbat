# Abstract sound channel base types (included by gba.nim)

const GBA_NO_STEP* = high(CycleCount)
  ## "no pending waveform step" sentinel for a channel's next_step deadline.
  ## Every catch-up guard is `next_step > scheduler.cycles`, so this parks a
  ## channel without a second flag — it matches the old behaviour of simply not
  ## having an etAPUChannel* event queued, which is the state every channel
  ## starts in (the old code only armed the chain on the first trigger) and the
  ## state RegisterRamReset's sound phase put them back into.

const GBA_OBS_CPU* = high(uint32)
  ## Observer period meaning "a CPU/DMA access, not a scheduler event". See
  ## gba_steps_due: by the time an MMIO access reaches the APU, bus.catch_up has
  ## already advanced the scheduler to this exact cycle and dispatched every
  ## event due at or before it, so a step landing on this cycle has definitely
  ## happened and must be included.

# Build with -d:psgverify to shadow every closed-form catch-up with the
# per-period loop the scheduler events used to run and assert they land on the
# same state. It costs O(steps) so it is off by default, but it is what proves
# the closed forms — in particular CH3's bank-flip-per-wrap, which no title in
# the sweep set exercises (tools/romfuzz/dingbat_nav's -d:psgdim forces it).

template gba_steps_due*(d, period: CycleCount; arm_delay: uint32;
                        observer_period: uint32): CycleCount =
  ## How many waveform steps are due, given d = (now - next_step) >= 0, the step
  ## period in scheduler cycles, the delay the PENDING step was armed with
  ## (arm_delay), and the observer's own period.
  ##
  ## The subtlety is a step landing on EXACTLY the cycle the observer runs on.
  ## The old per-period channel event and the observing event were then both due
  ## at that cycle, and Scheduler.schedule breaks the tie in favour of the more
  ## recently scheduled event: equal-cycle inserts land at the higher index, and
  ## the highest index pops first. Each self-rescheduling event is armed exactly
  ## its own delay before it fires, so "more recently scheduled" is "shorter
  ## delay" — include the step when the channel's delay is the shorter one,
  ## defer it to the next observation when it is the longer one.
  ##
  ## The delay is NOT always the current period, which is why arm_delay exists:
  ##   - the step at d == 0 was armed either by a trigger (delay = the frequency
  ##     timer at trigger time, +6 on the wave channel) or by the previous step
  ##     (delay = the period in force THEN) — and a frequency write since would
  ##     have changed the period without moving that already-armed step;
  ##   - every step after it is one CURRENT period apart.
  ## Modelling this is the difference between "phase-exact" and bit-identical
  ## output, and only a PCM byte-diff against the pre-catch-up build catches it:
  ## the framebuffer cannot, and neither can the mGBA suite.
  ##
  ## Equal delays are a genuine knife edge — both events were armed on the same
  ## cycle, so in the old code the winner depended on which was inserted first,
  ## and for two self-rescheduling events of the same period it alternated. They
  ## resolve uniformly as "include" here, which is also the more defensible
  ## answer (a period equal to the sample interval should advance one step per
  ## sample). Against the 512-cycle sample event that is frequency 0x7E0 on a
  ## square, 0x7C0 on the wave channel and NR43 = 0x40/0x30/0x21 on the noise
  ## channel.
  block:
    let m = d div period
    var s = m + 1
    if (d mod period) == 0:
      let arm = if m == 0: arm_delay else: uint32(period)
      if arm > observer_period: dec s
    s

proc new_sound_channel*(gba: GBA): SoundChannel =
  SoundChannel(gba: gba, enabled: false, dac_enabled: false, length_counter: 0, length_enable: false)

proc agb_length_on_nrx4*(ch: SoundChannel; length_enable, triggered: bool;
                         max_len: int) =
  ## AGB NRx4 length semantics (hardware-verified, gbaedge SWEEPQ/PSGSTAT
  ## pages, AGB SP sessions 2/3): the trigger's reload-if-zero happens
  ## FIRST, then a RISING length-enable clocks length once if the frame
  ## sequencer is in the length half. A trigger+enable write with one
  ## length tick remaining therefore kills the note immediately (the
  ## SWEEPQ length-63 control dies at poll 0), where the DMG order - the
  ## rising-edge clock before the trigger - lets the trigger reload it to
  ## a full note. The GB core keeps the DMG order; this helper is
  ## GBA-only.
  let rising = length_enable and not ch.length_enable
  ch.length_enable = length_enable
  if triggered and ch.length_counter == 0:
    ch.length_counter = max_len
    if length_enable and not rising and ch.gba.apu.first_half_of_length_period:
      ch.length_counter -= 1
  if rising and ch.gba.apu.first_half_of_length_period and ch.length_counter > 0:
    ch.length_counter -= 1
    if ch.length_counter == 0: ch.enabled = false

proc length_step*(ch: SoundChannel) =
  if ch.length_enable and ch.length_counter > 0:
    ch.length_counter -= 1
    if ch.length_counter == 0:
      ch.enabled = false

proc read_nrx2*(ch: VolumeEnvelopeChannel): uint8 =
  (ch.starting_volume shl 4) or (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.period_ve

proc write_nrx2*(ch: VolumeEnvelopeChannel; value: uint8) =
  let new_envelope_add_mode = (value and 0x08) > 0
  if ch.enabled:
    if (ch.period_ve == 0 and ch.volume_envelope_is_updating) or not ch.envelope_add_mode:
      ch.current_volume += 1
    if new_envelope_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  ch.starting_volume    = value shr 4
  ch.envelope_add_mode  = new_envelope_add_mode
  ch.period_ve          = value and 0x07
  ch.dac_enabled        = (value and 0xF8) > 0
  if not ch.dac_enabled: ch.enabled = false

proc init_volume_envelope*(ch: VolumeEnvelopeChannel) =
  ch.volume_envelope_timer    = ch.period_ve
  ch.current_volume           = ch.starting_volume
  ch.volume_envelope_is_updating = true

proc volume_step*(ch: VolumeEnvelopeChannel) =
  if ch.period_ve != 0:
    if ch.volume_envelope_timer > 0:
      ch.volume_envelope_timer -= 1
    if ch.volume_envelope_timer == 0:
      ch.volume_envelope_timer = ch.period_ve
      if (ch.current_volume < 0xF and ch.envelope_add_mode) or
         (ch.current_volume > 0 and not ch.envelope_add_mode):
        if ch.envelope_add_mode: ch.current_volume += 1
        else: ch.current_volume -= 1
      else:
        ch.volume_envelope_is_updating = false
