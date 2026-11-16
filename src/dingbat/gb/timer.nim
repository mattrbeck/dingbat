# GB Timer (included by gb.nim)

proc new_gb_timer*(): GbTimer =
  GbTimer(tdiv: 0, tima: 0, tma: 0, enabled: false, clock_select: 0,
          bit_for_tima: 9, previous_bit: false, countdown: -1)

const CGB_BOOT_LICENSED_T* = 4360
  ## T-cycles a Nintendo-licensed cart (old licensee $01, or $33 with new
  ## licensee "01") adds to the CGB boot ROM's run when its title checksum
  ## matches no compatibility-palette entry (177 of 256 checksums, measured by
  ## running the boot ROM). A matching title's time depends on its place in
  ## Nintendo's table, which dingbat does not carry (as for the palette, I3).
  ## Pinned by DocBoy cgb/boot `boot_div_title_*`.

proc cgb_boot_header_t(rom: seq[uint8]): int =
  ## T-cycles the CGB boot ROM's licensee checks add to its run, relative to
  ## an old licensee other than $01/$33 (Pan Docs, "Power Up Sequence": DIV
  ## at hand-off depends on the header). Measured by running the boot ROM
  ## (docs/gb-failure-triage.md I9); pinned by DocBoy cgb/boot
  ## `boot_div_title_00_*`. mooneye's header ($33, "ZZ") is the -4 path.
  if rom.len < 0x150: return 0
  case rom[0x14B]
  of 0x01: CGB_BOOT_LICENSED_T
  of 0x33:
    if rom[0x144] != uint8('0'): -4
    elif rom[0x145] != uint8('1'): 32
    else: 32 + CGB_BOOT_LICENSED_T
  else: 0

proc skip_boot*(t: GbTimer; gb: GB) =
  # Internal 16-bit divider at PC=0x100 per boot model, pinned by mooneye
  # boot_div-* (both bytes); DMG-ABC also by boot_sclk_align (serial.nim).
  let native = gb.cgb_flag != cgbNone
  t.tdiv = case gb.boot_model
    of bmDmg0:          0x182C'u16   # boot_div-dmg0
    of bmDmgABC, bmMgb: 0xABC8'u16   # boot_div-dmgABCmgb
    of bmSgb, bmSgb2:
      # SGB boot length depends on the header bytes sent to the SNES: each
      # set bit costs 4 T (mooneye boot_div-S vs boot_div2-S). 0xD85C is the
      # seed at header popcount 273. Only the harness selects bmSgb/bmSgb2.
      var bits = 0
      for i in 0x100 .. 0x14F:
        if i < gb.cartridge.rom.len: bits += countSetBits(gb.cartridge.rom[i])
      uint16(0xD85C - 4 * (bits - 273))
    of bmCgb0:          0x2880'u16   # misc/boot_div-cgb0
    of bmAgb:           0x2678'u16   # misc/boot_div-A
    of bmCgbABCDE:
      # Plus the header path's length (cgb_boot_header_t). Pinned by gambatte
      # div/start_inc (CGB cart) and mooneye boot_div-cgbABCDE (compatibility).
      # AGB and CGB0 keep the one value their mooneye test measures.
      uint16((if native: 0x1E9C else: 0x2678) + cgb_boot_header_t(gb.cartridge.rom))
  if gb.boot_model == bmCgbABCDE:
    # The boot ROM powers the APU on early, so a header path that runs past
    # another 8192 T boundary hands off one sequencer step on.
    # BOOT_FS_STAGE_CGB is the stage at the CGB-cart base (0x1E9C).
    gb.apu.frame_sequencer_stage =
      (gb.apu.frame_sequencer_stage + int(t.tdiv) div 8192) and 7
    # The length gate goes with the step, as memory.skip_boot sets it.
    gb.apu.first_half_of_length_period = (gb.apu.frame_sequencer_stage and 1) == 1

const TAC_SELECT_LEAD_T* {.intdefine.} = 0
  ## T-cycles before the end of a TAC write's M-cycle at which the newly
  ## selected divider bit is sampled; the old bit stays the latched
  ## `previous_bit` (Pan Docs "Timer Obscure Behaviour"). Default 0, compiled
  ## out: both taps judged at the end of the M-cycle; 1..4 fail gambatte
  ## `tima/tc00_late_tc01_*` (docs/gb-derivations.md). A $FF05 read DOES see
  ## an increment or reload in its own M-cycle (unlike SB/SC/IF, see
  ## SERIAL_CPU_SAMPLE_T); a pre-edge TIMA latch fails 18+ tima tests.
  ## Clean-room: derived from test ROM sources/outputs
  ## and dingbat's own trace runs; no emulator source consulted.

const SPEED_SWITCH_IRQ_LEAF_HOLD_T* {.intdefine.} = 8
  ## T-cycles the divider stops counting (`GbTimer.hold_t`) after a speed
  ## switch whose HALT is skipped because an interrupt is pending (the
  ## oscillator restart the HALT waits out; c-sp
  ## speed-switch/caution/WARNING.md). CGB E owes half
  ## (`GbQuirks.spsw_irq_leaf_hold_short`). 0 compiles it out (the guard on
  ## timer_tick's fast path costs ~0.3% of the GB core). The divider stops,
  ## not the CPU. Pinned by c-sp spsw-interrupts IMMEDIATE_INTERRUPT_DIV/_TIMA.

const SPEED_SWITCH_LEAF_PPU* {.intdefine.} = 1
  ## A KEY1 switch on the leaf Pan Docs' STOP chart gives as "1 byte, mode
  ## doesn't change, DIV is reset, CPU speed changes" (a request pending, so
  ## no HALT) still restarts the oscillator: the PPU takes the switch's
  ## extra dots (SPEED_SWITCH_PPU_EXTRA_DOTS 8 / _SINGLE 3), then sits out
  ## the divider's hold (SPEED_SWITCH_IME0_LEAF_HOLD_T, two M-cycles of the
  ## new speed) via GbMemory.ppu_mdot_shift = PPU_SIT_OUT, released by
  ## timer_tick_slow at the M-cycle after the hold ends. Net +4 dots into
  ## double speed, -5 into single. Pinned two-sided by DocBoy
  ## `*stop_key1_joypad0_interrupt1_ime0_*` (docs/gb-failure-triage.md I7).
  ## 0 = the PPU runs straight through.
const PPU_SIT_OUT* = 24
  ## GbMemory.ppu_mdot_shift while the PPU sits out: no tick reaches 2^24.
const SPEED_SWITCH_LEAF_PPU_IME1* {.intdefine.} = 1
  ## The same for the IME-set leaf (Pan Docs: "The CPU glitches
  ## non-deterministically"), with its own divider hold (SPEED_SWITCH_IRQ_
  ## LEAF_HOLD_T, half on CGB E). No test reads the PPU after it.

proc timer_reload_tima(t: GbTimer; gb: GB) =
  when defined(gb_phase_trace):
    echo "TIMIRQ t=", gb_phase, "/", gb_ticklen
  when defined(gb_ss_trace):
    # Diagnostic (tools only): the divider the overflow reload landed on.
    echo "TIMAIRQ tdiv=", t.tdiv, " tap=", t.bit_for_tima
  when IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD != 0:
    # A CGB dispatch that took the timer line is still holding it clear.
    if not irq_clear_holds(gb.interrupts, INT_TIMER, gb.scheduler.cycles):
      gb.interrupts.timer_interrupt = true
  else:
    gb.interrupts.timer_interrupt = true
  when defined(gb_io_trace):
    echo "TIMERIF ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter, " sched=", gb.scheduler.cycles
  t.tima = t.tma

proc timer_check_edge(t: GbTimer; gb: GB; on_write = false) =
  ## `on_write`: the edge came from a register write (DIV reset, TAC change).
  ## The glitch increments match gbedge p02 TIMAGLITCH on MGB and AGS. A
  ## write commits after its M-cycle's ticks, so the immediate reload here IS
  ## the one-M-cycle reload window (Pan Docs, "Timer Obscure Behaviour");
  ## arming the countdown fails mooneye timer/rapid_toggle (DMG; CGB
  ## assumed). The window's interior (TIMA reading $00, TIMA-write-ignore) is
  ## not modelled (docs/pandocs-audit.md A6).
  let current_bit = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
  if t.previous_bit and not current_bit:
    t.tima = t.tima + 1
    if t.tima == 0:
      if on_write:
        timer_reload_tima(t, gb)
      else:
        t.countdown = 4
        when TIMER_IRQ_RUN_LEAD != 0:
          # The overflow edge, one M-cycle before the reload. Only
          # handle_interrupts reads it; see TIMER_IRQ_RUN_LEAD.
          gb.interrupts.timer_interrupt_early = true
  t.previous_bit = current_bit

proc apu_div_bit(gb: GB): int {.inline.} =
  ## Divider bit that clocks the APU frame sequencer: Pan Docs, a falling edge
  ## of DIV bit 4 (internal bit 12, 512 Hz); bit 5 in double speed keeps the
  ## rate.
  12 + int(gb.memory.current_speed)

proc timer_tick_slow(t: GbTimer; gb: GB; cycles: int) =
  gb.wl_mark = gb.scheduler.cycles
  let serial = gb.serial
  var cycles = cycles
  when SPEED_SWITCH_IRQ_LEAF_HOLD_T != 0:
    if t.hold_t > 0:
      # The divider owes time (SPEED_SWITCH_IRQ_LEAF_HOLD_T): consume the
      # span without counting, serial shifter included.
      let n = min(t.hold_t, cycles)
      t.hold_t -= n
      cycles   -= n
      when SPEED_SWITCH_LEAF_PPU != 0:
        # The PPU sits the same span out; it resumes from the next M-cycle
        # (this one's PPU half is still to come): -1 brings that M-cycle here.
        if t.hold_t == 0 and gb.memory.ppu_mdot_shift == PPU_SIT_OUT:
          t.hold_t = -1
      if cycles == 0: return
    elif t.hold_t < 0:
      gb.memory.ppu_mdot_shift = int(gb.memory.current_speed)
      t.hold_t = 0
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
  # Fast path, run for every 4 T of every memory access. Nothing but the
  # divider moves unless the reload countdown is live, serial is shifting
  # (both armed only by register writes) or the TIMA tap falls in the span
  # (closed-form below). Must stay bit-identical to timer_tick_slow.
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
  ## speed, 512 Hz either way). Raw scheduler cycles: use `schedule`, not
  ## `schedule_gb` (which would scale them again).
  2 shl apu_div_bit(gb)

proc apu_div_phase*(t: GbTimer; gb: GB): int =
  ## Raw cycles until the divider's APU tap next falls. Equals the full period
  ## when the divider sits exactly on an edge boundary.
  let period = apu_div_period(gb)
  result = period - (int(t.tdiv) and (period - 1))
  when APU_SPSW_TAP_LAG_T != 0:
    # The lag rides the double-speed tap (bit 13) only; a switch back to
    # single speed leaves it behind.
    if gb.apu.spsw_fs_lag and gb.memory.current_speed == 1:
      result += APU_SPSW_TAP_LAG_T

const SPEED_SWITCH_DIV_RESET_T_SLOW* {.intdefine.} = 4
  ## T-cycles of divider between the STOP fetch and the point the SLOW taps
  ## (TIMA bits >= SPEED_SWITCH_DIV_SLOW_BIT, and the APU's bit 12/13) are
  ## judged for the switch's DIV reset; SPEED_SWITCH_DIV_RESET_T is the same
  ## for the fast taps. Equal values compile the split out. No single point
  ## passes both the tap 9 and tap 5 tests, as a ripple divider whose high
  ## bits lag would give; pinned by gambatte speedchange*_tima0N_*, *_ch2_nr52_*.
const SPEED_SWITCH_DIV_SLOW_BIT* {.intdefine.} = 9
  ## Lowest TIMA tap bit judged at the SLOW point; the APU tap is always slow.
const SPEED_SWITCH_DIV_RESET_T* {.intdefine.} = 8
  ## T-cycles of divider between the STOP fetch and the switch's DIV reset.
  ## STOP is a two-byte opcode on this leaf (Pan Docs' STOP chart) and the
  ## reset goes with the second byte, one M-cycle after the fetch dingbat
  ## charges the opcode as. Only the divider moves: the M-cycle is already
  ## inside the stall; ticking the whole machine breaks gambatte speedchange
  ## ly44_m3*. Any of 8..11 passes (AGE spsw-tima-*, gambatte
  ## speedchange*_tima0N_*). Relative to the TIMER_IRQ_RUN_LEAD anchor and
  ## mem_read's access phase; re-derive after either moves.

proc timer_read*(t: GbTimer; idx: int): uint8 =
  when defined(gb_div_read_trace):
    # Diagnostic (tools only): the full 16-bit divider behind each DIV/TIMA read.
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
    # sequencer steps early (SameSuite apu/div_*). Re-aim the sequencer now:
    # a lazy re-aim can skip an edge before the stale target.
    let apu_before = (t.tdiv shr apu_div_bit(gb)) and 1
    let old_tdiv = t.tdiv
    # A deferred step 7 is dated from the divider about to reset: land it
    # now, at most ENV_CLOCK_DS_LATE_T early.
    if gb.apu.env_late_pending: apu_env_late_run(gb.apu)
    t.tdiv = 0
    if apu_before == 1: tick_frame_sequencer(gb.apu, gb)
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
    timer_check_edge(t, gb, on_write = true)
    # The serial tap sees the reset too; `old_tdiv` is the level at the top
    # of the store's M-cycle (see SERIAL_DIV_WRITE_LEAD_T).
    if gb.serial.shifting: serial_div_write_edge(gb.serial, gb, old_tdiv)
  of 0xFF05:
    if t.countdown != 0:
      t.tima     = val
      when TIMER_IRQ_RUN_LEAD != 0:
        # A write in the M-cycle after an overflow (Pan Docs, "Timer Obscure
        # Behaviour", cycle A) stops IF being set, so the early request goes
        # too. A request already in IF stays, as irq_write does.
        if t.countdown > 0:
          gb.interrupts.timer_interrupt_early = gb.interrupts.timer_interrupt
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
        # Sample the new tap TAC_SELECT_LEAD_T early by rewinding the divider
        # for the check.
        let now = t.tdiv
        t.tdiv         = now - uint16(TAC_SELECT_LEAD_T)
        t.enabled      = (val and 0b100) != 0
        t.clock_select = select
        t.bit_for_tima = bit
        timer_check_edge(t, gb, on_write = true)
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


const SPSW_DIV_RESET_RELOAD_LATE* {.intdefine.} = 1
  ## Whether a TIMA overflow ticked by the speed switch's own DIV reset
  ## reloads through the ordinary one-M-cycle window (the countdown, Pan
  ## Docs "Timer Obscure Behaviour") rather than at once. A CPU store to
  ## $FF04 commits at its M-cycle's end, where the immediate reload IS that
  ## window; this reset is inside STOP, ahead of the stall, so the request
  ## rises one M-cycle into the stall, unseen by its entry check
  ## (SPEED_SWITCH_ENTRY_IRQ_CHECK, memory.nim). Pinned by DocBoy
  ## `speed_switch_to_single_interrupt_timers_b_round2` (CGB E).
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
  # T-cycles so a fall inside the window is not counted by both the tick and
  # the reset (c-sp spsw-tima-cgbBC).
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
  timer_check_edge(t, gb, on_write = SPSW_DIV_RESET_RELOAD_LATE == 0)
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
      # judged against.
      echo "SSWITCH pc=", toHex(int(gb.cpu.pc), 4),
           " tdiv=", t.tdiv, " (mod64=", int(t.tdiv) mod 64,
           " mod256=", int(t.tdiv) mod 256, " mod1024=", int(t.tdiv) mod 1024,
           ") tima=", toHex(int(t.tima), 2),
           " tap=", t.bit_for_tima, " spd=", gb.memory.current_speed
    timer_write(t, gb, 0xFF04, 0)
