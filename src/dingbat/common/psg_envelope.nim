# Shared PSG length counter + volume envelope, `include`d by BOTH cores.
#
# The GB and the GBA carry the same four Game Boy sound channels, and the
# length/envelope state machines are identical hardware — this file used to
# exist twice (gb/apu/abstract_channels.nim and gba/apu/abstract_channels.nim)
# as a line-for-line copy that had already drifted in spelling. Fixing an
# envelope bug meant remembering to fix it in two places.
#
# It is `include`d rather than imported because each core is one big shared
# scope (see the include lists in gb.nim / gba.nim). The two cores name their
# channel base types differently, so each defines the SoundChannelBase and
# VolumeEnvChannelBase aliases just before including this file.
#
# What is deliberately NOT here: everything downstream of the envelope. The
# per-channel register decode genuinely differs between the cores — different
# addresses (0xFF16 vs 0x68), different unused-bit read values (GB reads 1s,
# the GBA reads 0s), a 4x frequency-timer scale, two wave-RAM banks on the
# GBA's channel 3 against the GB's one, and integer vs float amplitudes.
# Parameterising all of that would cost more clarity than the duplication does.

proc length_step*(ch: SoundChannelBase) =
  if ch.length_enable and ch.length_counter > 0:
    dec ch.length_counter
    if ch.length_counter == 0:
      ch.enabled = false

proc read_nrx2*(ch: VolumeEnvChannelBase): uint8 =
  (ch.starting_volume shl 4) or
  (if ch.envelope_add_mode: 0x08'u8 else: 0'u8) or ch.envelope_period

proc write_nrx2*(ch: VolumeEnvChannelBase; value: uint8) =
  let new_add_mode = (value and 0x08) != 0
  if ch.enabled:
    if (ch.envelope_period == 0 and ch.envelope_is_updating) or
       (not ch.envelope_add_mode):
      inc ch.current_volume
    if new_add_mode != ch.envelope_add_mode:
      ch.current_volume = 0x10'u8 - ch.current_volume
    ch.current_volume = ch.current_volume and 0x0F
  ch.starting_volume   = value shr 4
  ch.envelope_add_mode = new_add_mode
  ch.envelope_period   = value and 0x07
  ch.dac_enabled       = (value and 0xF8) != 0
  if not ch.dac_enabled: ch.enabled = false

proc init_volume_envelope*(ch: VolumeEnvChannelBase) =
  ch.envelope_timer       = ch.envelope_period
  ch.current_volume       = ch.starting_volume
  ch.envelope_is_updating = true

proc volume_step*(ch: VolumeEnvChannelBase) =
  if ch.envelope_period != 0:
    if ch.envelope_timer > 0:
      dec ch.envelope_timer
    if ch.envelope_timer == 0:
      ch.envelope_timer = ch.envelope_period
      if (ch.current_volume < 0xF and ch.envelope_add_mode) or
         (ch.current_volume > 0 and not ch.envelope_add_mode):
        if ch.envelope_add_mode: inc ch.current_volume
        else:                    dec ch.current_volume
      else:
        ch.envelope_is_updating = false
