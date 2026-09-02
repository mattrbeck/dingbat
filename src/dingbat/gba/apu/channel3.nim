# APU Channel 3 (Wave) (included by gba.nim)

const RANGE_CH3_LOW*      = 0x70'u32
const RANGE_CH3_HIGH*     = 0x77'u32
const WAVE_RAM_LOW*       = 0x90'u32
const WAVE_RAM_HIGH*      = 0x9F'u32
const WAVE_RAM_SIZE*      = 16  # 0x90..0x9F = 16 bytes

proc ch3_in_range*(address: uint32): bool =
  (address >= RANGE_CH3_LOW and address <= RANGE_CH3_HIGH) or
  (address >= WAVE_RAM_LOW  and address <= WAVE_RAM_HIGH)

proc new_channel3*(gba: GBA): Channel3 =
  result = Channel3(
    gba: gba,
    enabled: false, dac_enabled: false,
    length_counter: 0, length_enable: false,
    wave_ram_position: 0,
    wave_ram_sample_buffer: 0,
    wave_ram_dimension: false,
    wave_ram_bank: 0,
    length_load_ch3: 0,
    volume_code: 0, volume_force: false,
    frequency_ch3: 0,
    next_step: GBA_NO_STEP, arm_delay: 0,
  )
  for bank in 0..1:
    result.wave_ram[bank] = newSeq[byte](WAVE_RAM_SIZE)
    for idx in 0 ..< WAVE_RAM_SIZE:
      result.wave_ram[bank][idx] = if (idx and 1) == 0: 0x00'u8 else: 0xFF'u8

proc ch3_frequency_timer*(ch: Channel3): uint32 =
  (0x800'u32 - uint32(ch.frequency_ch3)) * 2 * 4

proc ch3_catchup_slow(ch: Channel3; observer_period: uint32) =
  let now    = ch.gba.scheduler.cycles
  let period = CycleCount(ch.ch3_frequency_timer())
  let steps = gba_steps_due(now - ch.next_step, period, ch.arm_delay,
                            observer_period)
  if steps == 0: return
  # The GBA wave channel is the CGB one with a second 32-nibble bank: the
  # pointer is a free-running mod-32 counter and, in 64-step mode (dimension),
  # the bank flips every time it wraps to 0 (GBATEK SOUND3CNT_L bit 5). So N
  # steps land at (pos + N) mod 32 with the bank toggled once per wrap —
  # wraps = (pos + N) div 32, and only its parity matters.
  when defined(psgverify):
    # Per-period loop the closed form must agree with.
    var wpos  = ch.wave_ram_position
    var wbank = ch.wave_ram_bank
    var wbuf  = ch.wave_ram_sample_buffer
    for _ in 0 ..< steps:
      wpos = uint8(int(wpos + 1) mod (WAVE_RAM_SIZE * 2))
      if wpos == 0 and ch.wave_ram_dimension: wbank = wbank xor 1
      let fs = ch.wave_ram[wbank][wpos div 2]
      wbuf = (fs shr (if (wpos and 1) == 0: 4 else: 0)) and 0xF
  let total = CycleCount(ch.wave_ram_position) + steps
  ch.wave_ram_position = uint8(total and 31)
  if ch.wave_ram_dimension and ((total shr 5) and 1) != 0:
    ch.wave_ram_bank = ch.wave_ram_bank xor 1
  # Only the LAST read matters: wave RAM and the dimension/bank bits cannot
  # change between catch-ups (every 0x90-0x9F access and SOUND3CNT write
  # catches this channel up first).
  let full_sample = ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2]
  ch.wave_ram_sample_buffer =
    (full_sample shr (if (ch.wave_ram_position and 1) == 0: 4 else: 0)) and 0xF
  when defined(psgverify):
    doAssert wpos  == ch.wave_ram_position, "ch3 pointer closed form != naive loop"
    doAssert wbank == ch.wave_ram_bank, "ch3 bank closed form != naive loop"
    doAssert wbuf  == ch.wave_ram_sample_buffer, "ch3 sample buffer != naive loop"
  ch.next_step += steps * period
  # The step now pending was armed by the one before it, i.e. one CURRENT
  # period ago.
  ch.arm_delay = uint32(period)

proc ch3_catchup_at*(ch: Channel3; observer_period: uint32) {.inline.} =
  ## See ch1_catchup_at.
  if ch.next_step > ch.gba.scheduler.cycles: return
  ch3_catchup_slow(ch, observer_period)

proc ch3_catchup*(ch: Channel3) {.inline.} =
  ch3_catchup_at(ch, GBA_OBS_CPU)

proc ch3_get_amplitude*(ch: Channel3): int16 =
  ## The current nibble, centred, at the SOUND3CNT_H output level: bits 13-14
  ## select mute / 100% / 50% / 25%, and bit 15 overrides them with 75%
  ## (GBATEK). Full scale is +-128 (a multiple of 16), so the quarters below
  ## divide exactly.
  if not (ch.enabled and ch.dac_enabled): return 0'i16
  let full = (int(ch.wave_ram_sample_buffer) - 8) * 16
  let quarter = full div 4
  if ch.volume_force: return int16(full - quarter)
  case ch.volume_code
  of 0'u8: 0'i16
  of 1'u8: int16(full)
  of 2'u8: int16(quarter * 2)
  else:    int16(quarter)

proc ch3_read*(ch: Channel3; address: uint32): uint8 =
  # 0x90-0x9F while enabled returns the byte CH3 is currently playing, so apu[]
  # catches the wave pointer up before calling this.
  case address
  of 0x70:
    (if ch.dac_enabled: 0x80'u8 else: 0'u8) or
    (ch.wave_ram_bank shl 6) or
    (if ch.wave_ram_dimension: 0x20'u8 else: 0'u8)
  of 0x73:
    (if ch.volume_force: 0x80'u8 else: 0'u8) or (ch.volume_code shl 5)
  of 0x75: (if ch.length_enable: 0x40'u8 else: 0'u8)
  of WAVE_RAM_LOW..WAVE_RAM_HIGH:
    if ch.enabled:
      ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2]
    else:
      ch.wave_ram[ch.wave_ram_bank][address - WAVE_RAM_LOW]
  else: 0'u8

proc ch3_write*(ch: Channel3; address: uint32; value: uint8) =
  # apu[]= caught the wave pointer up first, so a period/dimension/bank/trigger
  # change below only affects steps from now on, and a wave-RAM write lands at
  # the position CH3 is actually playing.
  case address
  of 0x70:
    ch.dac_enabled      = (value and 0x80) > 0
    if not ch.dac_enabled: ch.enabled = false
    ch.wave_ram_dimension = bit(value, 5)
    ch.wave_ram_bank    = bits_range(value, 6, 6)
  of 0x71: discard
  of 0x72:
    ch.length_load_ch3  = value
    ch.length_counter   = 0x100 - int(value)
  of 0x73:
    ch.volume_code  = (value and 0x60) shr 5
    ch.volume_force = bit(value, 7)
  of 0x74: ch.frequency_ch3 = (ch.frequency_ch3 and 0x0700'u16) or uint16(value)
  of 0x75:
    ch.frequency_ch3 = (ch.frequency_ch3 and 0x00FF'u16) or ((uint16(value) and 0x07'u16) shl 8)
    let length_enable = (value and 0x40) > 0
    let triggered = (value and 0x80) > 0
    if triggered and ch.dac_enabled: ch.enabled = true
    ch.agb_length_on_nrx4(length_enable, triggered, 0x100)  # AGB order; see abstract_channels
    if triggered:
      # Re-arm period + 6 from now (the +6 is outside ch3_frequency_timer's *4).
      let arm3 = ch.ch3_frequency_timer() + 6
      ch.next_step = ch.gba.scheduler.cycles + CycleCount(arm3)
      ch.arm_delay = arm3
      # The index resets but wave_ram_sample_buffer does NOT: the last nibble
      # read keeps being output until CH3 next reads one (Pan Docs).
      ch.wave_ram_position = 0
  of 0x76, 0x77: discard
  of WAVE_RAM_LOW..WAVE_RAM_HIGH:
    if ch.enabled:
      ch.wave_ram[ch.wave_ram_bank][ch.wave_ram_position div 2] = value
    else:
      ch.wave_ram[ch.wave_ram_bank][address - WAVE_RAM_LOW] = value
  else: echo "Writing to invalid Channel3 register: ", hex_str(uint16(address))
