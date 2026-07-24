# Abstract sound channel base types (included by gba.nim)

proc new_sound_channel*(gba: GBA): SoundChannel =
  SoundChannel(gba: gba, enabled: false, dac_enabled: false, length_counter: 0, length_enable: false)

proc length_step*(ch: SoundChannel) =
  if ch.length_enable and ch.length_counter > 0:
    ch.length_counter -= 1
    if ch.length_counter == 0:
      ch.enabled = false

proc read_nrx2*(ch: VolumeEnvelopeChannel): uint8 =
  (ch.starting_volume shl 4) or (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.envelope_period

proc write_nrx2*(ch: VolumeEnvelopeChannel; value: uint8) =
  let new_envelope_add_mode = (value and 0x08) > 0
  if ch.enabled:
    if (ch.envelope_period == 0 and ch.envelope_is_updating) or not ch.envelope_add_mode:
      ch.current_volume += 1
    if new_envelope_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  ch.starting_volume    = value shr 4
  ch.envelope_add_mode  = new_envelope_add_mode
  ch.envelope_period    = value and 0x07
  ch.dac_enabled        = (value and 0xF8) > 0
  if not ch.dac_enabled: ch.enabled = false

proc init_volume_envelope*(ch: VolumeEnvelopeChannel) =
  ch.envelope_timer       = ch.envelope_period
  ch.current_volume       = ch.starting_volume
  ch.envelope_is_updating = true

proc volume_step*(ch: VolumeEnvelopeChannel) =
  if ch.envelope_period != 0:
    if ch.envelope_timer > 0:
      ch.envelope_timer -= 1
    if ch.envelope_timer == 0:
      ch.envelope_timer = ch.envelope_period
      if (ch.current_volume < 0xF and ch.envelope_add_mode) or
         (ch.current_volume > 0 and not ch.envelope_add_mode):
        if ch.envelope_add_mode: ch.current_volume += 1
        else: ch.current_volume -= 1
      else:
        ch.envelope_is_updating = false
