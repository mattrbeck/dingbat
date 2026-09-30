# The GB side of the shared PSG (included by gb.nim, before
# ../../common/psg_channels): the clock the channels run on -- the 1 MHz tick
# grid, the DIV-APU phase, CGB double speed -- and the GB-only output stage
# (the DAC and PCM12/PCM34). The channels themselves are common/psg*.nim.

type PsgHost = GB
const PSG_AGB = false

template psg_now(h: GB): CycleCount = h.scheduler.cycles
template psg_shl(h: GB): untyped = h.scheduler.speed
template psg_length_half(h: GB): bool = h.apu.first_half_of_length_period
template psg_cgb(h: GB): bool = h.cgb_enabled
template psg_q_length_any(h: GB): bool = h.quirks.length_clock_any_nrx4
template psg_q_length_defer(h: GB): bool = h.revision == grCgbAB
template psg_q_backstep(h: GB): bool = h.quirks.square_freq_backstep_halftick

const GB_NO_STEP* = PSG_NO_STEP
const GB_OBS_CPU* = PSG_OBS_CPU

template gb_apu_tick*(gb: GB): CycleCount =
  ## One APU tick in scheduler cycles: the frequency timers run at 1 MHz
  ## (SameSuite channel_1_align), one tick per 4 T-cycles; at CGB double speed
  ## the CPU cycle halves but the tick does not.
  CycleCount(4) shl gb.scheduler.speed

template psg_tick(h: GB): CycleCount = gb_apu_tick(h)

proc gb_apu_edge*(gb: GB): CycleCount =
  ## The first edge of the APU's 1 MHz tick grid at or after the current cycle.
  ## A register write between two edges is not picked up until the next one.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  let past = (now + tick - (gb.apu.tick_phase mod tick)) mod tick
  if past == 0: now else: now + (tick - past)

template psg_edge(h: GB): CycleCount = gb_apu_edge(h)

const APU_TRIGGER_EDGE_BEFORE* {.intdefine.} = 0
  ## 1: a square trigger counts its startup from the 1 MHz edge at or BEFORE
  ## the write; 0: from the edge at or after it. Only distinguishable at double
  ## speed, where a CPU write can land half a tick off the grid. The two
  ## claims contradict on CPU CGB C: gambatte sound/ch1_duty0_pos6_to_pos7_
  ## timing_ds_{5,6} want 1 (a first trigger one NOP later lands on the same
  ## edge), SameSuite channel_{1,2}_align{,_cpu} and channel_1_freq_change_
  ## timing-* (7 rows) want 0 and lose with 1. Ships 0; the two gambatte rows
  ## are the residual (docs/gb-failure-triage.md H1).

proc gb_apu_edge_before*(gb: GB): CycleCount =
  ## The last edge of the APU's 1 MHz tick grid at or before the current cycle.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  now - ((now + tick - (gb.apu.tick_phase mod tick)) mod tick)

const APU_CLOCK_CARRY* {.intdefine.} = 0
  ## Ships 0. 1: on CPU CGB C and older (GbQuirks.apu_clock_carry) the square
  ## channels count their start-up from the 1 MHz edge at or BEFORE the write
  ## on a 2 MHz APU clock whose phase is carried through APU power-on, DIV
  ## resets and speed switches (the apu_sh_* shadow below, the rules
  ## gambatte-core's PSG uses), and a switch carries every APU deadline across
  ## by its distance in 2 MHz cycles (apu_rescale_speed), with
  ## APU_SPSW_EXTRA_DOTS_CARRY{,_SINGLE} = 5 / 1 for the stall. It takes the
  ## thirteen red gambatte speed-switch audio rows (speedchange{2..5}*_ch1_
  ## duty0_pos6_to_pos7_timing_*, speedchange_ch1_nr4init_*_2; peak bracketed
  ## on both extras) and loses SameSuite channel_1_freq_change_timing-cgb0BC,
  ## whose single-speed triggers after an APU power-on want the grid anchored
  ## at the write (gambatte's clock puts the edge 3 cycles earlier there).
  ## docs/gb-failure-triage.md H2.

when APU_CLOCK_CARRY != 0:
  template sh_now(gb: GB): int64 = int64(gb.scheduler.cycles)
  template sh_ds(gb: GB): int64 = int64(gb.memory.current_speed)
  proc apu_sh_advance*(gb: GB; t: int64; ds: int64) =
    ## Whole 2 MHz cycles up to `t` (2 scheduler cycles each at single speed,
    ## 4 at double); the remainder stays carried in `sh_last`.
    let step = 2'i64 shl ds
    if t > gb.sh_last:
      let n = (t - gb.sh_last) div step
      gb.sh_last += n * step
      gb.sh_cc += n
  proc apu_sh_boot*(gb: GB) =
    let t = sh_now(gb)
    gb.sh_last = t - 1
    gb.sh_cc = t shr 1
  proc apu_sh_power_on*(gb: GB) =
    ## Power-on keeps the counter's low bits and re-aligns the clock to a
    ## multiple of four cycles.
    let t = sh_now(gb)
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let off = gb.sh_last and ds
    let c = gb.sh_cc + off
    gb.sh_cc = (c and 0xFFF) + 2 * ((not (c + 1 + (1 - ds))) and 0x800)
    gb.sh_last = ((gb.sh_last + 3) and not 3'i64) - (1 - ds)
  proc apu_sh_div_reset*(gb: GB; t: int64) =
    ## A DIV reset re-aligns the counter to a 4096-cycle boundary.
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let off = gb.sh_last and ds
    let c = gb.sh_cc + off
    gb.sh_cc = (c and not 0xFFF'i64) + 2 * (c and 0x800) - off
  proc apu_sh_speed_change*(gb: GB; t: int64; old_ds: int64) =
    ## The carried remainder is re-read at the new speed (one cycle less going
    ## down); going up the counter also drops half its cycles since the reset.
    apu_sh_advance(gb, t, old_ds)
    gb.sh_l0 = gb.sh_last
    gb.sh_last -= old_ds
    gb.sh_l1 = gb.sh_last
    if old_ds == 0:
      gb.sh_cc = gb.sh_cc - (gb.sh_cc and 0xFFF) div 2 - (gb.sh_last and 1)
  proc apu_sh_edge*(gb: GB): CycleCount =
    ## The 1 MHz edge at or before the write, on the carried clock.
    let t = sh_now(gb)
    let ds = sh_ds(gb)
    apu_sh_advance(gb, t, ds)
    let refv = if ds != 0 and (gb.sh_last and 1) != 0: 0'i64 else: 1'i64
    let k = gb.sh_cc - ((gb.sh_cc - refv) and 1)
    CycleCount(max(0'i64, gb.sh_last + (k - gb.sh_cc) * (2'i64 shl ds)))

const APU_DS_TRIGGER_SNAP* {.intdefine.} = 1
  ## CPU CGB C and older (GbQuirks.apu_clock_carry), double speed: a square
  ## trigger counts its start-up from the nearest point of a 2 us grid that
  ## starts 8 CPU cycles after the APU's power-on write (a write 4 cycles off
  ## it rounds toward it either way). gambatte `sound/ch1_duty0_pos6_to_
  ## pos7_timing_ds_{1..6}` [cgb]: `_5`, whose first trigger is 124 cycles
  ## past power-on, counts from the same edge as `_1` at 120 (rounding down),
  ## while SameSuite `channel_1_freq_change_timing-cgb0BC`'s triggers 100
  ## cycles past power-on round up. The 1 MHz edge-after rule alone cannot
  ## give both. CGB D/E keep the 1 MHz rule: SameSuite `channel_{1,2}_align`
  ## on E lose with the snap. 0 = the 1 MHz grid on every revision.

proc gb_trigger_deadline*(gb: GB; period: CycleCount;
                          extra_ticks: int): CycleCount =
  ## Absolute cycle of a channel's first waveform step after a trigger: the
  ## write is picked up on the next edge of the 1 MHz grid (SameSuite
  ## channel_1_align / channel_1_align_cpu), then one full period plus
  ## extra_ticks of startup delay -- 2 for a square that was off
  ## (channel_1_delay), 1 for a restart (channel_1_restart). The waveform
  ## position is untouched. Channel 4 has its own rule: gb_noise_deadline.
  var edge = if APU_TRIGGER_EDGE_BEFORE != 0: gb_apu_edge_before(gb)
             else: gb_apu_edge(gb)
  when APU_DS_TRIGGER_SNAP != 0:
    if gb.memory.current_speed != 0 and gb.quirks.apu_clock_carry:
      let w = int64(gb.scheduler.cycles)
      let d = ((w - gb.apu_power_on_at - 8) mod 16 + 16) mod 16
      edge = CycleCount(if d < 8: w - d else: w + (16 - d))
  when APU_CLOCK_CARRY != 0:
    if gb.quirks.apu_clock_carry: edge = apu_sh_edge(gb)
  edge + period + CycleCount(extra_ticks) * gb_apu_tick(gb)

template psg_trigger_deadline(h: GB; period: CycleCount;
                              extra_ticks: int): CycleCount =
  gb_trigger_deadline(h, period, extra_ticks)

template psg_noise_phase(h: GB): CycleCount = h.apu.noise_phase
  ## The 512 kHz grid channel 4's divisor stage counts on (GbApu.noise_phase).

# Forward declaration: timer.nim is included after the APU (gb.nim, which
# already forward-declares apu_div_phase).
proc apu_div_period*(gb: GB): int {.inline.}

proc fs_next_edge_in*(gb: GB): int =
  ## Raw scheduler cycles until the frame sequencer's next step runs
  ## (stage `gb.apu.frame_sequencer_stage`), including a pending skipped edge.
  result = apu_div_phase(gb.timer, gb)
  if gb.apu.div_skip: result += apu_div_period(gb)

template psg_fs_next_edge_in(h: GB): int = fs_next_edge_in(h)
template psg_fs_next_stage(h: GB): int = h.apu.frame_sequencer_stage


# ---- The output stage: DAC and PCM12/PCM34 ----

# DAC transfer function, digital 0-15 to analog +1..-1. Pan Docs, Audio
# Details: the slope is negative, digital 0 is analog +1. A channel that is
# switched off still feeds digital 0 to its enabled DAC (analog +1); only a
# disabled DAC sits at analog 0, which is why a DAC toggle pops and a channel
# toggle does not. A table: exact endpoints, one load per channel per sample.
const GB_DAC_LUT* = block:
  var t: array[16, float32]
  for i in 0 .. 15: t[i] = float32(1.0 - float64(i) / 7.5)
  t

proc sq_dac_input(ch: PsgSquare): uint8 =
  ## 4-bit digital output (CGB PCM12); 0 while off. Masked to four bits: a
  ## hand-edited save state can hold a volume above 15 and this indexes
  ## GB_DAC_LUT.
  if ch.enabled and ch.dac_enabled:
    uint8(int(ch.sample_bit) * int(ch.current_volume)) and 0x0F
  else: 0'u8

proc sq_pcm_edge_zero(ch: PsgSquare; gb: GB): bool {.inline.} =
  ## Whether a PCM12 read on this cycle answers 0 for a square channel (CGB
  ## 0/A/B/C read glitch, GbQuirks.pcm_read_edge_zero; the caller checks the
  ## quirk): the read sits on a duty step whose previous output was 0. The
  ## position is post-step, so the previous duty entry is the replaced
  ## output; the volume cannot move across a step without an envelope tick (an
  ## observation point). Measured on channel 1; channel 2 is the same duty
  ## hardware and no channel_2 build of the ROM measures it -- assumed.
  ch.enabled and ch.dac_enabled and ch.last_step_at == gb.scheduler.cycles and
    int(PSG_DUTY[ch.duty][(ch.wave_duty_position + 7) and 7]) *
      int(ch.current_volume) == 0

proc ch3_dac_input(ch: PsgWave): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC -- see sq_dac_input.
  if ch.enabled and ch.dac_enabled:
    let nibble = if (ch.wave_ram_position and 1) == 0:
                   (ch.wave_ram_sample_buffer shr 4) and 0x0F
                 else:
                   ch.wave_ram_sample_buffer and 0x0F
    nibble shr ch.volume_code_shift
  else: 0'u8

proc ch4_dac_input(ch: PsgNoise): uint8 =
  ## Current 4-bit digital output (0-15), pre-DAC -- see sq_dac_input.
  if ch.enabled and ch.dac_enabled:
    uint8(int(not ch.lfsr and 1'u16) * int(ch.current_volume)) and 0x0F
  else: 0'u8

template psg_amplitude(ch: PsgChannel; input: uint8): float32 =
  ## DAC-gated, not `enabled`-gated: a switched-off channel feeds digital 0
  ## (analog +1) to a powered DAC. See GB_DAC_LUT.
  if ch.dac_enabled: GB_DAC_LUT[input] else: 0.0'f32

const GB_PSG_READ_OR: array[0x14, uint8] = [
  ## Bits of NR10..NR44 that read back as 1 (unused, or write-only); NR20 and
  ## NR40 do not exist. blargg dmg_sound 01-registers.
  0x80'u8, 0x3F, 0x00, 0xFF, 0xBF,   # NR10-NR14
  0xFF,    0x3F, 0x00, 0xFF, 0xBF,   # NR20-NR24
  0x7F,    0xFF, 0x9F, 0xFF, 0xBF,   # NR30-NR34
  0xFF,    0xFF, 0x00, 0x00, 0xBF]   # NR40-NR44
