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
template psg_q_reload_halftick(h: GB): bool = h.quirks.square_reload_halftick
template psg_env_late(h: GB): bool =
  ## Step 7's envelope work waits for ENV_CLOCK_DS_LATE_T past the divider's
  ## tap edge (GbQuirks.env_clock_ds_late, apu.nim), unless the KEY1 tap lag
  ## already put the step that far behind it (GbApu.spsw_fs_lag: the same 2 T
  ## at double speed, asserted in apu.nim).
  h.quirks.env_clock_ds_late and h.scheduler.speed == 1 and not h.apu.spsw_fs_lag
template psg_cpu_bus_addr(h: GB): int =
  ## The address the CPU drives in the M-cycle after a register write: the
  ## next opcode fetch, PC (every store to an I/O register ends its
  ## instruction). Wave RAM sees it when CH3 lets go of the port (ch3_write).
  int(h.cpu.pc)

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

proc gb_apu_edge_at*(gb: GB; t: CycleCount): CycleCount =
  ## gb_apu_edge for an arbitrary cycle `t`: the first 1 MHz edge at or after it.
  let tick = gb_apu_tick(gb)
  let past = (t + tick - (gb.apu.tick_phase mod tick)) mod tick
  if past == 0: t else: t + (tick - past)

template psg_edge_at(h: GB; t: CycleCount): CycleCount = gb_apu_edge_at(h, t)

proc gb_apu_edge_before*(gb: GB): CycleCount =
  ## The last edge of the APU's 1 MHz tick grid at or before the current cycle.
  let tick = gb_apu_tick(gb)
  let now  = gb.scheduler.cycles
  now - ((now + tick - (gb.apu.tick_phase mod tick)) mod tick)

const SQ_START_HALF_RATE_LEAD_T* {.intdefine.} = 4
  ## CPU CGB C and older, double speed: a square channel triggered from off
  ## starts counting its period on the first 1 MHz edge at least this many
  ## T-cycles after the NRx4 write that is an odd tick of the grid's half
  ## rate, the 512 kHz clock the APU power-on starts with it (GbApu.
  ## noise_phase; gb_trigger_deadline). 0 compiles the CGB <= C placement out
  ## (every revision then takes gb_apu_edge's).
  ##
  ## Four write phases are measured, in 2 MHz M-cycles after the NR52
  ## power-on write (two to a tick, so even ticks are 0, 4, 8, ...):
  ##   25 -> 30  SameSuite channel_1_freq_change_timing-cgb0BC, cells 8..15
  ##             (the sixth step falls 53 M-cycles after the trigger: cell
  ##             9's NR14 write there wins the reload, cell 10's a M-cycle
  ##             later does not), and the five gambatte speedchange{,2}*_ch1_
  ##             duty0_pos6_to_pos7_timing_{,nop_}ds_{1,2} pairs
  ##   30 -> 34  gambatte sound/ch1_duty0_pos6_to_pos7_timing_ds_{1,2,3,4}
  ##   31 -> 34  the same family's `_ds_{5,6}`
  ## and, powered on at single speed and triggered after a KEY1 switch (which
  ## re-anchors both grids, apu_rescale_speed), speedchange_ch1_nr4init_
  ## duty0_pos6_to_pos7_timing_{1,2}: 5 M-cycles after the write.
  ## A plain two ticks after the next edge, CPU CGB D/E's rule, gives 36 for
  ## 31 and loses `_ds_6` and `nr4init_..._2`; the other half-rate phase loses
  ## nine tests and SameSuite's. The lead: 4 passes; 2 loses the five `ds_1`
  ## speedchange tests and SameSuite's; 6 loses `nr4init_..._2`; 8 that and
  ## `_ds_6`. Single speed is left on the two-tick rule (every write is on
  ## the grid there, and the gambatte tests that pin it trigger on even ticks
  ## only). A restart keeps gb_apu_edge's placement: no CGB <= C test sees a
  ## restarted note's next step at double speed.

template gb_trigger_async(gb: GB): bool =
  ## CPU CGB C and older at double speed: SQ_START_HALF_RATE_LEAD_T's
  ## placement, and a trigger that acts in the write's own M-cycle
  ## (gb_trigger_pickup).
  SQ_START_HALF_RATE_LEAD_T != 0 and gb.quirks.cgb_c_or_older and
    gb.scheduler.speed != 0

proc gb_trigger_deadline*(gb: GB; period: CycleCount;
                          extra_ticks: int): CycleCount =
  ## Absolute cycle of a channel's first waveform step after a trigger: the
  ## write is picked up on the next edge of the 1 MHz grid (SameSuite
  ## channel_1_align / channel_1_align_cpu), then one full period plus
  ## extra_ticks of startup delay -- 2 for a square that was off
  ## (channel_1_delay), 1 for a restart (channel_1_restart). The waveform
  ## position is untouched. Channel 4 has its own rule: psg_noise_first_inc.
  let tick = gb_apu_tick(gb)
  if extra_ticks == 2 and gb_trigger_async(gb):
    # From off on CPU CGB C and older at double speed: the first odd tick of
    # the 512 kHz grid at least the lead after the write.
    let lead = CycleCount(SQ_START_HALF_RATE_LEAD_T) shl gb.scheduler.speed
    var e = gb_apu_edge_at(gb, gb.scheduler.cycles + lead)
    let half = 2 * tick
    if (e + half - (gb.apu.noise_phase mod half)) mod half < tick: e += tick
    return e + period
  gb_apu_edge(gb) + period + CycleCount(extra_ticks) * tick

template psg_trigger_deadline(h: GB; period: CycleCount;
                              extra_ticks: int): CycleCount =
  gb_trigger_deadline(h, period, extra_ticks)

proc gb_trigger_pickup*(gb: GB): CycleCount =
  ## The 1 MHz edge a square trigger written now takes effect on: the edge at
  ## or after the write (gb_trigger_deadline's rule): the pickup rules in
  ## sq_trigger are stated on this edge. PSG_NO_STEP on CPU CGB C and older
  ## at double speed, where the trigger acts in the write's own M-cycle: a
  ## duty step due on the next edge, half a tick or less ahead, is lost with
  ## the restart. gambatte sound/ch1_duty0_pos6_to_pos7_timing_ds_{1,3}
  ## (the retrigger half a tick before the seventh step: silent) against
  ## `_ds_{2,4}` (on it: audible), and speedchange{,3_nop}_ch1_duty0_pos6_to_
  ## pos7_timing_{,nop_}1 with the step 1 T ahead; with CPU CGB D/E's pickup
  ## those and four more tests of the two ladders are lost (nine in all).
  if gb_trigger_async(gb): PSG_NO_STEP else: gb_apu_edge(gb)

template psg_trigger_pickup(h: GB): CycleCount = gb_trigger_pickup(h)

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

const PCM12_CH2_EDGE_ZERO* {.booldefine.} = true
  ## GbQuirks.pcm_read_edge_zero covers channel 2 as it does channel 1
  ## (gb/memory.nim, $FF76). Not measured on channel 2: SameSuite's
  ## apu/README.md states the glitch for channels 1, 2 and 4 on CPU CGB C
  ## and older ("report a glitched PCM amplitude ... if they're read in the
  ## same M-cycle they change"), and the two squares are one circuit bar the
  ## sweep unit. No scored test reads PCM12 on a channel 2 step on those
  ## revisions (SameSuite's channel_2 tests run on CPU CGB E), so either
  ## setting passes everything.

proc sq_pcm_edge_zero(ch: PsgSquare; gb: GB): bool {.inline.} =
  ## Whether a PCM12 read on this cycle answers 0 for a square channel (CGB
  ## 0/A/B/C read glitch, GbQuirks.pcm_read_edge_zero; the caller checks the
  ## quirk): the read sits on a duty step whose previous output was 0. The
  ## position is post-step, so the previous duty entry is the replaced
  ## output; the volume cannot move across a step without an envelope tick (an
  ## observation point). Measured on channel 1.
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
