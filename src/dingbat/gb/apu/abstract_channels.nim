# Abstract APU channel types (included by gb.nim)

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
