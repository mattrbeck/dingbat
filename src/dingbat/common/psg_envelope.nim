# Shared PSG state machines, `include`d by BOTH cores.
#
# The GBA contains the Game Boy's sound hardware verbatim (GBATEK documents
# 0x4000060-0x4000081 as NR10-NR52), so these state machines — length counter,
# volume envelope, channel 1's frequency sweep, channel 4's noise LFSR, and the
# NRx4 trigger/length-enable sequence — are the SAME silicon on both. They used
# to exist twice as line-for-line copies that had already drifted in spelling,
# so an accuracy fix had to be remembered in two places. It didn't get
# remembered: the GBA's channel-3 trigger delay was a straight copy of the GB's
# `+ 6` even though every period formula around it is scaled x4 for the faster
# clock (see PSG_WAVE_TRIGGER_DELAY below).
#
# It is `include`d rather than imported because each core is one big shared
# scope (see the include lists in gb.nim / gba.nim). Each core defines the
# SoundChannelBase / VolumeEnvChannelBase aliases and PSG_CLOCK_MULT just
# before including this file.
#
# What is deliberately NOT here, because it is genuinely different hardware
# rather than drift:
#   * register addresses and layout — the GB packs NR10-NR52 into 0xFF10-0xFF26,
#     the GBA spreads them over 16-bit-aligned slots with gaps
#   * unused / write-only bit read values — the GB reads them back as 1s
#     (blargg dmg_sound "01-registers" checks this and passes), the GBA reads 0s
#     (the mGBA suite's I/O read tests check this and pass). Both are right for
#     their own hardware.
#   * channel 3's second 32-sample wave RAM bank, the dimension bit and the
#     force-75%-volume bit, which are GBA-only additions
#   * the amplitude representation: the GB models the 4-bit DAC directly
#     (0..15 -> -1.0..+1.0, so a silent-but-enabled channel sits at the rail),
#     the GBA uses a centred +/-8*volume. These differ only in DC offset, which
#     the hardware's output capacitor removes; unifying them would change GBA
#     output for no accuracy gain, so they stay per-core.

proc length_step*(ch: SoundChannelBase) {.inline.} =
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

# ---- NRx4: length-enable edge + trigger ------------------------------------

proc psg_write_nrx4*(ch: SoundChannelBase; value: uint8;
                     first_half_of_length_period: bool;
                     max_length: int): bool {.inline, discardable.} =
  ## Shared handling of NRx4 bits 6-7, the fiddliest corner of the PSG and the
  ## one blargg's dmg_sound 02/03/08 hammer hardest:
  ##
  ##  * enabling the length counter during the FIRST half of a length period
  ##    clocks it one extra time immediately (and can disable the channel)
  ##  * a trigger with a zeroed length counter reloads it to max, and that
  ##    reload is itself clocked once if length is enabled in the first half
  ##
  ## `max_length` is 64 for the square/noise channels and 256 for the wave
  ## channel. Returns true when bit 7 was set, i.e. this write was a TRIGGER,
  ## so the caller can do its channel-specific trigger work (reschedule the
  ## frequency timer, init the envelope, seed the sweep / LFSR / wave position).
  let length_enable = (value and 0x40) != 0
  if first_half_of_length_period and not ch.length_enable and
     length_enable and ch.length_counter > 0:
    dec ch.length_counter
    if ch.length_counter == 0: ch.enabled = false
  ch.length_enable = length_enable
  result = (value and 0x80) != 0
  if result:
    if ch.dac_enabled: ch.enabled = true
    if ch.length_counter == 0:
      ch.length_counter = max_length
      if ch.length_enable and first_half_of_length_period:
        dec ch.length_counter

# ---- Channel 1: frequency sweep --------------------------------------------

proc psg_sweep_calc*(ch: SweepChannelBase): uint16 =
  ## One sweep frequency calculation: shadow +/- (shadow >> shift), with the
  ## overflow check that disables the channel. Note the subtraction can never
  ## underflow — (shadow >> shift) <= shadow for any shift — so only the
  ## addition can trip the > 0x7FF check.
  let shifted = ch.frequency_shadow shr ch.shift
  let calc = int(ch.frequency_shadow) +
             (if ch.negate: -int(shifted) else: int(shifted))
  if ch.negate: ch.negate_used = true
  if calc > 0x07FF: ch.enabled = false
  uint16(calc and 0x7FFF)

proc psg_sweep_step*(ch: SweepChannelBase) =
  ## Frame-sequencer sweep tick (steps 2 and 6). A period of 0 reloads as 8.
  if ch.sweep_timer > 0: dec ch.sweep_timer
  if ch.sweep_timer == 0:
    ch.sweep_timer = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
    if ch.sweep_enabled and ch.sweep_period > 0:
      let calc = psg_sweep_calc(ch)
      if calc <= 0x07FF and ch.shift > 0:
        ch.frequency_shadow = calc
        ch.frequency        = calc
        # Hardware runs a second calculation purely for its overflow check
        discard psg_sweep_calc(ch)

proc psg_sweep_trigger*(ch: SweepChannelBase) =
  ## Sweep state seeded on a channel-1 trigger.
  ch.frequency_shadow = ch.frequency
  ch.sweep_timer      = if ch.sweep_period > 0: ch.sweep_period else: 8'u8
  ch.sweep_enabled    = ch.sweep_period > 0 or ch.shift > 0
  ch.negate_used      = false
  if ch.shift > 0: discard psg_sweep_calc(ch)

# ---- Channel 4: noise LFSR -------------------------------------------------

proc psg_lfsr_step*(ch: NoiseChannelBase) {.inline.} =
  ## 15-bit LFSR, XOR of the low two bits fed back into bit 14 (and bit 6 as
  ## well in 7-bit width mode, shortening the period).
  let new_bit = (ch.lfsr and 0b01'u16) xor ((ch.lfsr and 0b10'u16) shr 1)
  ch.lfsr = (ch.lfsr shr 1) or (new_bit shl 14)
  if ch.width_mode != 0:
    ch.lfsr = (ch.lfsr and not (1'u16 shl 6)) or (new_bit shl 6)

# ---- Channel 3: wave trigger delay ------------------------------------------

const PSG_WAVE_TRIGGER_DELAY* = 6 * PSG_CLOCK_MULT
  ## Triggering the wave channel restarts its frequency timer 6 CPU cycles late
  ## (a documented DMG/CGB quirk). PSG_CLOCK_MULT scales it to the host core's
  ## clock: 1 on the GB (4.19 MHz), 4 on the GBA (16.78 MHz), which runs the
  ## same sound hardware from a 4x clock. The GBA previously used a bare 6 —
  ## a copy of the GB constant that never got the x4 that every surrounding
  ## period formula has — making its wave-trigger delay a quarter of the
  ## hardware's.
