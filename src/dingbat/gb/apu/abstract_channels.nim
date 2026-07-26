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

const GB_NO_STEP* = high(CycleCount)
  ## "no pending waveform step" sentinel for the channels' next_step deadline.
  ## Every catch-up guard is `next_step > scheduler.cycles`, so this parks a
  ## channel without a second flag -- it matches the old behaviour of simply
  ## not having an etAPUChannel* event queued (which is the state every channel
  ## starts in: the old code only armed the chain on the first trigger).

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
  if ch.enabled:
    if (ch.period == 0 and ch.vol_env_is_updating) or (not ch.envelope_add_mode):
      inc ch.current_volume
    if new_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  ch.starting_volume   = value shr 4
  ch.envelope_add_mode = new_add_mode
  ch.period            = value and 0x07
  ch.dac_enabled       = (value and 0xF8) != 0
  if not ch.dac_enabled: ch.enabled = false
