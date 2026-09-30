# The GBA side of the shared PSG (included by gba.nim, before
# ../../common/psg_channels): the register layout, the 16 MHz clock the
# channels are scaled to, the AGB-measured master-on and shift-0 laws, and
# the GBA's centred output. The channels themselves are common/psg*.nim.

type PsgHost = GBA
const PSG_AGB = true

template psg_now(h: GBA): CycleCount = h.scheduler.cycles
template psg_shl(h: GBA): untyped = 2
  ## The PSG keeps the GB's absolute rates on a 4x faster system clock:
  ## GBATEK gives channel 3 as 2097152/(2048-n) Hz on both machines.
template psg_cgb(h: GBA): bool = true
template psg_q_length_any(h: GBA): bool = false
template psg_q_length_defer(h: GBA): bool = false

const GBA_NO_STEP* = PSG_NO_STEP
const GBA_OBS_CPU* = PSG_OBS_CPU

# -d:psgverify shadows every closed-form catch-up with a per-period loop and
# asserts they agree (O(steps), off by default). CH3's bank-flip-per-wrap is
# exercised only by tools/romfuzz/dingbat_nav's -d:psgdim.

const PSG_POWER_ON_WINDOW* {.intdefine.} = 8
  ## Cycles after a SOUNDCNT_X master-on write during which an NRx4 length
  ## enable is clocked as in the first half of a length period whatever the
  ## sequencer says. AGB SP (link rig 2026-09-25): payloads/fsfirst.s triggers
  ## ch2 with counter 1 four cycles after master-on, and in all 31 cells
  ## (six sessions' runs), at every 512 Hz phase, the extra clock takes it to
  ## 0 and the trigger reloads it to 63 (the note outlives the 0x20000-poll
  ## cap); payloads/fsgap.s triggers 8..39 cycles after, and every cell is
  ## two-valued with the 512 Hz tap -- the cap, or no extra clock and death
  ## at the first step 16.6k..32.6k cycles on. So 4 < window <= 8.

proc length_half*(apu: APU): bool {.inline.} =
  ## Whether an NRx4 length enable now gets the extra length clock
  ## (PSG_POWER_ON_WINDOW; first_half_of_length_period otherwise).
  apu.first_half_of_length_period or
    (apu.power_on_at != GBA_NO_STEP and
     apu.gba.scheduler.cycles - apu.power_on_at < CycleCount(PSG_POWER_ON_WINDOW))

template psg_length_half(h: GBA): bool = h.apu.length_half()

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

proc ch1_settle*(ch: Channel1; gba: GBA) {.inline.} =
  ## Apply a shift-0 kill that has come due (ch1_s0_kill_at); every reader of
  ## the channel's enable runs this first.
  if ch.kill_at <= gba.scheduler.cycles:
    ch.kill_at = GBA_NO_STEP
    ch.enabled = false

# ---- The register block ----

const RANGE_CH1_LOW*  = 0x60'u32
const RANGE_CH1_HIGH* = 0x67'u32
const RANGE_CH2_LOW*  = 0x68'u32
const RANGE_CH2_HIGH* = 0x6F'u32
const RANGE_CH3_LOW*  = 0x70'u32
const RANGE_CH3_HIGH* = 0x77'u32
const RANGE_CH4_LOW*  = 0x78'u32
const RANGE_CH4_HIGH* = 0x7F'u32
const WAVE_RAM_LOW*   = 0x90'u32
const WAVE_RAM_HIGH*  = 0x9F'u32

const GBA_PSG_NR: array[0x60 .. 0x7F, int8] = block:
  ## SOUND1CNT_L .. SOUND4CNT_H byte addresses (offsets from 0x4000000) to
  ## NR numbers (GBATEK "Sound Channel 1..4"); -1 = unused byte.
  var t: array[0x60 .. 0x7F, int8]
  for i in 0x60 .. 0x7F: t[i] = -1
  t[0x60] = NR10; t[0x62] = NR11; t[0x63] = NR12; t[0x64] = NR13; t[0x65] = NR14
  t[0x68] = NR21; t[0x69] = NR22; t[0x6C] = NR23; t[0x6D] = NR24
  t[0x70] = NR30; t[0x72] = NR31; t[0x73] = NR32; t[0x74] = NR33; t[0x75] = NR34
  t[0x78] = NR41; t[0x79] = NR42; t[0x7C] = NR43; t[0x7D] = NR44
  t

proc psg_in_range*(address: uint32): bool {.inline.} =
  address >= RANGE_CH1_LOW and address <= RANGE_CH4_HIGH
proc ch1_in_range*(address: uint32): bool {.inline.} =
  address >= RANGE_CH1_LOW and address <= RANGE_CH1_HIGH
proc ch2_in_range*(address: uint32): bool {.inline.} =
  address >= RANGE_CH2_LOW and address <= RANGE_CH2_HIGH
proc ch3_in_range*(address: uint32): bool {.inline.} =
  (address >= RANGE_CH3_LOW and address <= RANGE_CH3_HIGH) or
  (address >= WAVE_RAM_LOW  and address <= WAVE_RAM_HIGH)
proc ch4_in_range*(address: uint32): bool {.inline.} =
  address >= RANGE_CH4_LOW and address <= RANGE_CH4_HIGH

# ---- The output stage ----

proc sq_get_amplitude(ch: PsgSquare): int16 =
  ## The latched duty output (PsgSquare.sample_bit), centred: -8 / +8 x
  ## volume.
  if ch.enabled and ch.dac_enabled:
    (int16(ch.sample_bit) * 16 - 8) * int16(ch.current_volume)
  else:
    0'i16

proc ch3_get_amplitude(ch: PsgWave): int16 =
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

proc ch4_get_amplitude(ch: PsgNoise): int16 =
  if ch.enabled and ch.dac_enabled:
    (int16(not ch.lfsr and 1) * 16 - 8) * int16(ch.current_volume)
  else:
    0'i16
