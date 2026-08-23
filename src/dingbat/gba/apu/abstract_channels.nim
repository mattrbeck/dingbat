# Abstract sound channel base types (included by gba.nim)

const GBA_NO_STEP* = high(CycleCount)
  ## "No pending waveform step" sentinel for next_step: every catch-up guard is
  ## `next_step > scheduler.cycles`, so this parks a channel without a second
  ## flag. Channels start parked; RegisterRamReset's sound phase parks them.

const GBA_OBS_CPU* = high(uint32)
  ## Observer period for a CPU/DMA access (not a scheduler event): bus.catch_up
  ## has already dispatched every event due at this cycle, so a step landing on
  ## it is included (see gba_steps_due).

# -d:psgverify shadows every closed-form catch-up with a per-period loop and
# asserts they agree (O(steps), off by default). CH3's bank-flip-per-wrap is
# exercised only by tools/romfuzz/dingbat_nav's -d:psgdim.

template gba_steps_due*(d, period: CycleCount; arm_delay: uint32;
                        observer_period: uint32): CycleCount =
  ## Waveform steps due, given d = (now - next_step) >= 0, the step period in
  ## scheduler cycles, the delay the PENDING step was armed with (arm_delay),
  ## and the observer's own period.
  ##
  ## A step landing EXACTLY on the observer's cycle reproduces the scheduler's
  ## tie-break for two events due on one cycle: the more recently scheduled
  ## fires first, and a self-rescheduling event is armed its own delay before
  ## it fires — so the step is included when the channel's delay is the shorter
  ## one and deferred when it is the longer. Equal delays include (a period
  ## equal to the sample interval advances one step per sample).
  ##
  ## arm_delay exists because the pending step's delay is not always the current
  ## period: a trigger arms it with the frequency timer at trigger time (+6 on
  ## the wave channel), and a frequency write since does not move an
  ## already-armed step; every later step is one CURRENT period apart.
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
  ## AGB NRx4 order (hardware: gbaedge SWEEPQ/PSGSTAT pages on AGS): the
  ## trigger's reload-if-zero happens FIRST, then a RISING length-enable clocks
  ## length once if the frame sequencer is in the length half, so trigger+enable
  ## with one tick left kills the note at once. The DMG order is the reverse
  ## (the GB core keeps it); this helper is GBA-only.
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
