# GB Timer (included by gb.nim)

proc new_gb_timer*(): GbTimer =
  GbTimer(tdiv: 0, tima: 0, tma: 0, enabled: false, clock_select: 0,
          bit_for_tima: 9, previous_bit: false, countdown: -1)

proc skip_boot*(t: GbTimer; gb: GB) =
  # Internal 16-bit divider at PC=0x100 per boot model. mooneye boot_div-*
  # reads DIV six times at fixed offsets and pins both bytes of the counter;
  # DMG-ABC also pins mooneye boot_sclk_align (serial tap, serial.nim); native
  # CGB is gambatte div/start_inc.
  let native = gb.cgb_flag != cgbNone
  t.tdiv = case gb.boot_model
    of bmDmg0:          0x182C'u16   # boot_div-dmg0
    of bmDmgABC, bmMgb: 0xABC8'u16   # boot_div-dmgABCmgb
    of bmSgb, bmSgb2:
      # SGB boot length depends on the header bytes the DMG transfers to the
      # SNES: mooneye boot_div-S and boot_div2-S differ only in the global
      # checksum bytes (popcount +4) and their DIV windows differ by 16 T, so
      # each set bit costs 4 T. 0xD85C is the boot_div-S seed at header
      # popcount 273. Only the harness selects bmSgb/bmSgb2.
      var bits = 0
      for i in 0x100 .. 0x14F:
        if i < gb.cartridge.rom.len: bits += countSetBits(gb.cartridge.rom[i])
      uint16(0xD85C - 4 * (bits - 273))
    of bmCgb0:          0x2880'u16   # misc/boot_div-cgb0
    of bmAgb:           0x2678'u16   # misc/boot_div-A
    of bmCgbABCDE:
      if native: 0x1E9C'u16 else: 0x2674'u16  # misc/boot_div-cgbABCDE

const TAC_SELECT_LEAD_T* {.intdefine.} = 4
  ## T-cycles before the end of a TAC write's M-cycle at which the newly
  ## selected divider bit is sampled; the bit being left stays the latched
  ## `previous_bit`. A select change can tick TIMA by itself (Pan Docs, "Timer
  ## Obscure Behaviour"); 4 is pinned by gambatte tima/tc00_late_tc01_* and
  ## tima/tc00_tc01_late_tc00_of_*. A $FF05 read DOES see an increment or
  ## reload that landed in its own M-cycle (unlike SB/SC/IF, see
  ## SERIAL_CPU_SAMPLE_T); a pre-edge latch for TIMA loses 18+ tima rows.

const SPEED_SWITCH_IRQ_LEAF_HOLD_T* {.intdefine.} = 8
  ## T-cycles the divider stops counting (`GbTimer.hold_t`) after a speed
  ## switch whose HALT is skipped because an interrupt is already pending (the
  ## oscillator restart the HALT exists to wait out; c-sp
  ## speed-switch/caution/WARNING.md). CGB E owes half
  ## (`GbQuirks.spsw_irq_leaf_hold_short`). 0 compiles it out: the guard sits
  ## on timer_tick's fast path and costs ~0.3% of the GB core. It must be the
  ## divider and not the CPU that stops, because everything the ROMs read is
  ## counted in CPU M-cycles. Pinned by c-sp speed-switch/spsw-interrupts'
  ## IMMEDIATE_INTERRUPT_DIV and _TIMA blocks (CGB B/C and E); spsw-div is
  ## anchored on a divider event and cannot see it.

proc timer_reload_tima(t: GbTimer; gb: GB) =
  when defined(gb_phase_trace):
    echo "TIMIRQ t=", gb_phase, "/", gb_ticklen
  when defined(gb_ss_trace):
    # Diagnostic (tools only): the divider the overflow reload landed on, the
    # anchor of the gambatte speedchange*_tima0N_* rows.
    echo "TIMAIRQ tdiv=", t.tdiv, " tap=", t.bit_for_tima
  gb.interrupts.timer_interrupt = true
  t.tima = t.tma

proc timer_check_edge(t: GbTimer; gb: GB; on_write = false) =
  ## `on_write`: the edge came from a register write (DIV reset, TAC change).
  ## The detector itself (DIV-write and TAC-disable glitch increments) matches
  ## gbedge p02 TIMAGLITCH bytes 00-0F on MGB and AGS. A glitch overflow
  ## reloads through the same one-M-cycle window as a natural one (Pan Docs,
  ## "Timer Obscure Behaviour"); a write commits after its M-cycle's ticks, so
  ## the immediate reload here IS that window. Arming the countdown instead
  ## fails mooneye acceptance/timer/rapid_toggle (DMG); the CGB side of the
  ## reload is Assumed. The window's interior (TIMA reading $00,
  ## TIMA-write-ignore) is not modelled (docs/pandocs-audit.md A6).
  let current_bit = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
  if t.previous_bit and not current_bit:
    t.tima = t.tima + 1
    if t.tima == 0:
      if on_write:
        timer_reload_tima(t, gb)
      else:
        t.countdown = 4
        when TIMER_IRQ_RUN_LEAD != 0:
          # The overflow edge, one M-cycle in front of the reload the countdown
          # arms. Only handle_interrupts reads it. See TIMER_IRQ_RUN_LEAD.
          gb.interrupts.timer_interrupt_early = true
  t.previous_bit = current_bit

proc apu_div_bit(gb: GB): int {.inline.} =
  ## Divider bit that clocks the APU frame sequencer: Pan Docs, a falling edge
  ## of DIV bit 4 (internal bit 12, 512 Hz); bit 5 in double speed keeps the
  ## rate.
  12 + int(gb.memory.current_speed)

proc timer_tick_slow(t: GbTimer; gb: GB; cycles: int) =
  let serial = gb.serial
  var cycles = cycles
  when SPEED_SWITCH_IRQ_LEAF_HOLD_T != 0:
    if t.hold_t > 0:
      # The divider owes time (SPEED_SWITCH_IRQ_LEAF_HOLD_T): the CPU clock is
      # running for the caller but not yet for this unit, so consume the span
      # without counting, serial shifter included.
      let n = min(t.hold_t, cycles)
      t.hold_t -= n
      cycles   -= n
      if cycles == 0: return
  when defined(gb_phase_trace):
    gb_phase = -1
    gb_ticklen = int32(cycles)
  for _ in 0 ..< cycles:
    when defined(gb_phase_trace): inc gb_phase
    if t.countdown > -1: dec t.countdown
    if t.countdown == 0: timer_reload_tima(t, gb)
    t.tdiv = t.tdiv + 1
    timer_check_edge(t, gb)
    if serial.shifting: serial_tick(serial, gb)

proc timer_tick*(t: GbTimer; gb: GB; cycles: int) {.inline.} =
  let serial = gb.serial
  # Fast path: this runs for every 4 T of every memory access. Nothing but the
  # divider can move unless the reload countdown is live, a serial transfer is
  # shifting, or the TIMA tap falls inside the span; the first two are only
  # armed by register writes, between ticks, and the edge count is closed-form
  # below. Bit-identical to timer_tick_slow.
  const no_hold = SPEED_SWITCH_IRQ_LEAF_HOLD_T == 0
  if t.countdown < 0 and (no_hold or t.hold_t == 0) and not serial.shifting:
    let t0 = uint32(t.tdiv)
    let t1 = t0 + uint32(cycles)
    let cur = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
    # `previous_bit == cur` re-establishes the invariant locally, so the fast
    # path stays correct if a caller changes tdiv without an edge check.
    if t.previous_bit == cur:
      if not t.enabled:
        t.tdiv = uint16(t1 and 0xFFFF'u32)
        t.previous_bit = false
        return
      # Falling edges of the tap in (t0, t1] = floor(t1/2^s) - floor(t0/2^s),
      # exact across the 16-bit wrap because 65536 is a multiple of 2^s. An
      # overflow arms the 4-cycle reload countdown, which must land on its own
      # cycle, so that case falls through to the loop.
      let shift = t.bit_for_tima + 1
      let edges = int((t1 shr shift) - (t0 shr shift))
      if int(t.tima) + edges <= 0xFF:
        t.tima = uint8(int(t.tima) + edges)
        t.tdiv = uint16(t1 and 0xFFFF'u32)
        t.previous_bit = (t.tdiv and (1'u16 shl t.bit_for_tima)) != 0
        return
  timer_tick_slow(t, gb, cycles)

proc apu_div_period*(gb: GB): int {.inline.} =
  ## Divider counts between APU-tap falling edges (8192 single / 16384 double
  ## speed — 512 Hz either way). These are raw scheduler cycles, so schedule
  ## them with `schedule`, not `schedule_gb` (which would scale them again).
  2 shl apu_div_bit(gb)

proc apu_div_phase*(t: GbTimer; gb: GB): int =
  ## Raw cycles until the divider's APU tap next falls. Equals the full period
  ## when the divider sits exactly on an edge boundary.
  let period = apu_div_period(gb)
  result = period - (int(t.tdiv) and (period - 1))
  when APU_SPSW_TAP_LAG_T != 0:
    # Double speed only: the lag rides the double-speed tap (bit 13) and a
    # switch back to single speed leaves it behind (gambatte
    # speedchange2_ch2_nr52_{1,2}b).
    if gb.apu.spsw_fs_lag and gb.memory.current_speed == 1:
      result += APU_SPSW_TAP_LAG_T

const SPEED_SWITCH_DIV_RESET_T_SLOW* {.intdefine.} = 4
  ## T-cycles of divider between the STOP fetch and the point the SLOW taps
  ## (TIMA bits >= SPEED_SWITCH_DIV_SLOW_BIT, and the APU's bit 12/13) are
  ## judged for the switch's DIV reset; SPEED_SWITCH_DIV_RESET_T is the same
  ## for the fast taps. Equal values compile the split out. No single point
  ## satisfies both gambatte speedchange_tima00_1a (tap 9) and
  ## speedchange_tima02_2a (tap 5); the split is pinned by gambatte
  ## speedchange*_tima0N_* and *_ch2_nr52_*, and is what a ripple divider
  ## whose high bits lag the count would give.
const SPEED_SWITCH_DIV_SLOW_BIT* {.intdefine.} = 9
  ## Lowest TIMA tap bit judged at the SLOW point; the APU tap is always slow.
  ## Pinned either side by gambatte speedchange*_tima00_* and *_ch2_nr52_*.
const SPEED_SWITCH_DIV_RESET_T* {.intdefine.} = 8
  ## T-cycles of divider between the STOP fetch and the switch's DIV reset.
  ## STOP is a two-byte opcode on this leaf (Pan Docs' STOP chart) and the
  ## reset goes with the second byte, one M-cycle after the fetch dingbat
  ## charges the opcode as. Only the divider moves: the M-cycle is already
  ## inside the stall, and ticking the whole machine breaks the gambatte
  ## speedchange ly44_m3* rows. Pinned to the M-cycle [8, 11]: 7 and 12 each
  ## lose AGE spsw-tima-cgbBC/-cgbE and 12-14 gambatte
  ## speedchange[2]_tima0N_{1a,1b,2a,2b} rows; 8 through 11 score alike. The
  ## value is relative to the TIMER_IRQ_RUN_LEAD anchor and to mem_read's
  ## access phase; re-derive after either moves.

proc timer_read*(t: GbTimer; idx: int): uint8 =
  when defined(gb_div_read_trace):
    # Diagnostic (tools only): the full 16-bit divider behind each DIV/TIMA
    # read, T-cycle resolution where the ROM prints one byte.
    if idx == 0xFF04: echo "DIVREAD tdiv=", t.tdiv
    if idx == 0xFF05: echo "TIMAREAD tima=", t.tima, " tdiv=", t.tdiv
  case idx
  of 0xFF04: uint8(t.tdiv shr 8)
  of 0xFF05: t.tima
  of 0xFF06: t.tma
  of 0xFF07: 0xF8'u8 or (if t.enabled: 0b100'u8 else: 0'u8) or t.clock_select
  else:      0xFF'u8

proc timer_write*(t: GbTimer; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF04:
    # Resetting DIV drops every divider bit: if the APU tap was high the frame
    # sequencer steps early (SameSuite apu/div_*). The sequencer is a scheduled
    # event, so re-aim it now; a lazy re-aim can skip an edge falling before
    # the stale target and loses a SameSuite row.
    let apu_before = (t.tdiv shr apu_div_bit(gb)) and 1
    let old_tdiv = t.tdiv
    t.tdiv = 0
    if apu_before == 1: tick_frame_sequencer(gb.apu, gb)
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
    timer_check_edge(t, gb, on_write = true)
    # The serial tap sees the reset too (gambatte serial/start_late_div_write_*).
    # `old_tdiv`: the level compared against is the one at the top of the
    # store's M-cycle; see SERIAL_DIV_WRITE_LEAD_T.
    if gb.serial.shifting: serial_div_write_edge(gb.serial, gb, old_tdiv)
  of 0xFF05:
    if t.countdown != 0:
      t.tima     = val
      t.countdown = -1
  of 0xFF06:
    t.tma = val
    if t.countdown == 0: t.tima = t.tma
  of 0xFF07:
    let select = val and 0b011
    let bit = case select
      of 0b00: 9
      of 0b01: 3
      of 0b10: 5
      else:    7
    when TAC_SELECT_LEAD_T != 0:
      if bit != t.bit_for_tima:
        # Sample the newly selected tap TAC_SELECT_LEAD_T early by rewinding
        # the divider for the check; the tap being left is the latched
        # previous_bit.
        let now = t.tdiv
        t.tdiv         = now - uint16(TAC_SELECT_LEAD_T)
        t.enabled      = (val and 0b100) != 0
        t.clock_select = select
        t.bit_for_tima = bit
        timer_check_edge(t, gb, on_write = true)
        # Hand the counter back with the new tap latched at the real divider.
        # Only the mux's own edge counts: replaying the rewound cycles under
        # the new tap fails gambatte tima/tc00_late_tc01_4.
        t.tdiv         = now
        t.previous_bit = t.enabled and ((now and (1'u16 shl bit)) != 0)
        return
    t.enabled      = (val and 0b100) != 0
    t.clock_select = select
    t.bit_for_tima = bit
    timer_check_edge(t, gb, on_write = true)
  else: discard


proc timer_speed_switch_div_reset_split(t: GbTimer; gb: GB) =
  ## The switch reset with the slow taps judged at a different point from the
  ## fast ones (SPEED_SWITCH_DIV_RESET_T_SLOW): `timer_write`'s $FF04 body,
  ## opened up so the two domains get different pre-levels.
  timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T_SLOW)
  let apu_slow  = ((t.tdiv shr apu_div_bit(gb)) and 1) == 1
  let tima_slow = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
  # CGB E moves the boundary down to the 65 KHz tap; see
  # `GbQuirks.spsw_div_mid_taps_slow`.
  let slow_bit  = if gb.quirks.spsw_div_mid_taps_slow: 5
                  else: SPEED_SWITCH_DIV_SLOW_BIT
  let slow_tap  = t.bit_for_tima >= slow_bit
  # A slow tap is latched at the slow point: gate it off for the remaining
  # T-cycles so a fall inside the window is not counted twice, once by the
  # tick and again by the reset (c-sp speed-switch/spsw-tima-cgbBC,
  # TEST_INC_EDGE 238).
  let was_enabled = t.enabled
  if slow_tap:
    t.enabled      = false
    t.previous_bit = false
  timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T - SPEED_SWITCH_DIV_RESET_T_SLOW)
  if slow_tap:
    t.enabled      = was_enabled
    t.previous_bit = tima_slow
  let old_tdiv = t.tdiv
  t.tdiv = 0
  if apu_slow: tick_frame_sequencer(gb.apu, gb)
  gb.scheduler.clear(etAPUFrameSeq)
  gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
  timer_check_edge(t, gb, on_write = true)
  if gb.serial.shifting: serial_div_write_edge(gb.serial, gb, old_tdiv)

proc timer_speed_switch_div_reset*(t: GbTimer; gb: GB) =
  ## The DIV reset a KEY1 speed switch performs (memory.nim's stop_instr):
  ## `timer_write($FF04, 0)` SPEED_SWITCH_DIV_RESET_T of divider after the
  ## STOP fetch.
  when APU_SPSW_TAP_LAG_T != 0:
    # Called before memory.nim flips `current_speed`, so "still single" IS
    # "about to enter double". See APU_SPSW_TAP_LAG_T for why this toggles.
    if gb.memory.current_speed == 0: gb.apu.spsw_fs_lag = not gb.apu.spsw_fs_lag
  when SPEED_SWITCH_DIV_RESET_T_SLOW != SPEED_SWITCH_DIV_RESET_T:
    timer_speed_switch_div_reset_split(t, gb)
  else:
    when SPEED_SWITCH_DIV_RESET_T != 0:
      timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T)
    when defined(gb_ss_trace):
      # Diagnostic (tools only): the divider phase each switch's reset is
      # judged against; pair with the TIMAIRQ / IRQDISP lines.
      echo "SSWITCH pc=", toHex(int(gb.cpu.pc), 4),
           " tdiv=", t.tdiv, " (mod64=", int(t.tdiv) mod 64,
           " mod256=", int(t.tdiv) mod 256, " mod1024=", int(t.tdiv) mod 1024,
           ") tima=", toHex(int(t.tima), 2),
           " tap=", t.bit_for_tima, " spd=", gb.memory.current_speed
    timer_write(t, gb, 0xFF04, 0)
