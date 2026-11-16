# GB serial port (included by gb.nim)
#
# SB (0xFF01) is the live shift register; SC (0xFF02) bit 7 = transfer
# enable, bit 0 = clock source (1 = internal), bit 1 = CGB fast clock.
#
# Bit rate (Pan Docs): 8192 Hz, or 262144 Hz under CGB SC bit 1; double
# speed doubles either. System-counter bit 7 cycles at twice 8192 Hz and bit 2
# at twice 262144 Hz, so one transfer bit is TWO tap periods: falling edges
# alternately open and close a bit slot, and SB moves at the close. An SC
# write restarts the slot sequence (first bit on the second tap edge after
# it) and closes an open slot on the spot. A DIV write can make or lose an
# edge exactly as for TIMA. Pinned by mooneye boot_sclk_align, gambatte
# serial/*, and gbedge p06 SERIAL (identical on MGB and AGS).
#
# GbSerialDriver models the peer, like the GBA SioDriver (gba/serial.nim):
# consulted only on transfer start (SC.7 rising) and completion (8th shift of
# a master transfer; outgoing byte in out_latch). The driver must call
# serial_finish_transfer on every unit that completes.

proc new_gb_serial*(): GbSerial =
  when SERIAL_CPU_SAMPLE_T < 4:
    # `high`, not 0: cycle 0 is a real M-cycle on a boot-skipped start.
    GbSerial(driver: GbSerialDriver(), edge_cycle: high(CycleCount))
  else:
    GbSerial(driver: GbSerialDriver())

# Whether a bit slot is open: GbSerial.master_clock (savestate.nim packs it
# as bit 1 of the clock byte), pre-edge copy in pre_master.
template slot_open(serial: GbSerial): bool = serial.master_clock
template `slot_open=`(serial: GbSerial; v: bool) = serial.master_clock = v
template pre_slot_open(serial: GbSerial): bool = serial.pre_master
template `pre_slot_open=`(serial: GbSerial; v: bool) = serial.pre_master = v

proc serial_is_master(serial: GbSerial): bool {.inline.} =
  ## Transfer enabled on the internal clock (SC.7 and SC.0 both set).
  (serial.sc and 0x81) == 0x81

proc serial_tap_bit(serial: GbSerial; gb: GB): uint16 {.inline.} =
  ## Tap bit: 7 (256 T period, 512 T per bit), or 2 under SC.1, the CGB fast
  ## clock, wired only in native CGB mode (mooneye misc/bits/unused_hwio-C).
  if gb.cgb_native and (serial.sc and 0x02) != 0: 1'u16 shl 2
  else: 1'u16 shl 7

proc serial_update_shifting(serial: GbSerial) {.inline.} =
  # The one test the timer's per-cycle loop pays for.
  serial.shifting = serial.bits_remaining > 0 and serial.serial_is_master()

proc serial_finish_transfer*(serial: GbSerial; gb: GB) =
  ## The explicit completion step; drivers fill SB before calling this.
  serial.sc = serial.sc and not 0x80'u8
  serial.bits_remaining = 0
  serial.serial_update_shifting()
  when IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD != 0:
    # A CGB dispatch that took the serial line is still holding it clear.
    if not irq_clear_holds(gb.interrupts, INT_SERIAL, gb.scheduler.cycles):
      gb.interrupts.serial_interrupt = true
  else:
    gb.interrupts.serial_interrupt = true
  when defined(gb_io_trace):
    echo "SERIALIF ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter, " sched=", gb.scheduler.cycles

method serial_peer_committed*(drv: GbSerialDriver): bool {.base.} =
  ## Does `serial_complete` publish something that cannot be taken back? A
  ## driver with a peer MUST return true (link.nim, printer.nim), or
  ## SERIAL_CPU_SAMPLE_T's rollback rewinds an exchange the peer already saw.
  false

method serial_start*(drv: GbSerialDriver; gb: GB) {.base.} =
  discard

method serial_complete*(drv: GbSerialDriver; gb: GB) {.base.} =
  # No cable: the input line floats high and the bit engine shifted in 1s.
  serial_finish_transfer(gb.serial, gb)

proc set_serial_driver*(gb: GB; drv: GbSerialDriver) =
  ## Bind a link-cable driver. Drivers are not serialized and stay bound
  ## across save-state loads.
  gb.serial.driver = drv

# ==================== Bit-slot clock ====================
#
# The tap is read from (divider + phase): the serial unit's counter runs a
# few T-cycles ahead of a DIV read (mooneye boot_sclk_align, gambatte serial/*).

proc serial_phase(gb: GB): uint16 {.inline.} =
  ## T-cycles: CGB in [0,3] (gambatte serial/*), DMG in [4,7] (mooneye
  ## boot_sclk_align-dmgABCmgb). See SERIAL_TAP_DMG in gb.nim.
  if gb.cgb_enabled: uint16(SERIAL_TAP_CGB) else: uint16(SERIAL_TAP_DMG)

proc serial_tap_high(serial: GbSerial; gb: GB): bool {.inline.} =
  ((gb.timer.tdiv + serial_phase(gb)) and serial.serial_tap_bit(gb)) != 0

proc serial_prime_history*(serial: GbSerial; gb: GB) =
  ## Resample the tap so the next tick compares against its present level.
  serial.clock_history = if serial.serial_tap_high(gb): 1'u8 else: 0'u8

proc serial_move_bit(serial: GbSerial; gb: GB) =
  ## A slot closing on a master transfer: SB shifts in a 1 (no cable) and the
  ## eighth close hands the byte to the driver.
  serial.sb = (serial.sb shl 1) or 1'u8
  dec serial.bits_remaining
  when defined(gb_serial_trace):
    # Diagnostic, off by default; pair with -d:gb_phase_trace.
    echo "SHIFT t=", gb.scheduler.cycles, " tdiv=", gb.timer.tdiv,
         " left=", serial.bits_remaining, " sb=", serial.sb.toHex(2)
  if serial.bits_remaining == 0:
    serial.driver.serial_complete(gb)

when SERIAL_CPU_SAMPLE_T < 4:
  proc serial_keep_pre_edge(serial: GbSerial; gb: GB) {.inline.} =
    ## Keep the pre-edge shifter for a CPU access in this M-cycle: the edge is
    ## on its last T-cycle and runs at the top. See SERIAL_CPU_SAMPLE_T (gb.nim).
    if serial.edge_cycle != gb.scheduler.cycles:
      serial.edge_cycle = gb.scheduler.cycles
      serial.pre_slot_open = serial.slot_open
      serial.pre_sb        = serial.sb
      serial.pre_sc        = serial.sc
      serial.pre_bits      = serial.bits_remaining
      serial.pre_irq       = gb.interrupts.serial_interrupt

proc serial_tap_fell(serial: GbSerial; gb: GB) =
  ## One falling tap edge: opens a slot, or closes one (and moves a bit).
  when SERIAL_CPU_SAMPLE_T < 4:
    serial.serial_keep_pre_edge(gb)
  if not serial.slot_open:
    serial.slot_open = true
    return
  serial.slot_open = false
  if serial.serial_is_master() and serial.bits_remaining > 0:
    serial.serial_move_bit(gb)

proc serial_tick*(serial: GbSerial; gb: GB) {.inline.} =
  ## Per-cycle hook from the timer loop (after tdiv increments).
  let now = serial.serial_tap_high(gb)
  let before = (serial.clock_history and 1) != 0
  serial.clock_history = if now: 1'u8 else: 0'u8
  if before and not now:
    serial.serial_tap_fell(gb)

const SERIAL_DIV_WRITE_LEAD_T* {.intdefine.} = 4
  ## T-cycles before the end of its M-cycle at which a `$FF04` store's reset
  ## is compared against the tap: `mem_write` ticks the bus first, so comparing
  ## at the end turns a tap that rose inside the M-cycle into a falling edge
  ## one M-cycle early. Only the comparison moves, not the reset. gambatte
  ## serial/start_late_div_write_* pins the M-cycle; the T-cycle is assumed.

proc serial_div_write_edge*(serial: GbSerial; gb: GB; old_tdiv: uint16) {.inline.} =
  ## The tap's view of a `$FF04` store: `tdiv` is already 0, so the pre-reset
  ## level is rebuilt from `old_tdiv` less SERIAL_DIV_WRITE_LEAD_T. A tap that
  ## already fell on its own in the store's M-cycle gets no second edge from
  ## the reset (DocBoy serial_timing_reset_div_during_transfer_stall_alt_*).
  when SERIAL_DIV_WRITE_LEAD_T != 0:
    let was_high = (serial.clock_history and 1) != 0 and
                   ((old_tdiv - uint16(SERIAL_DIV_WRITE_LEAD_T) + serial_phase(gb)) and
                    serial.serial_tap_bit(gb)) != 0
    serial.clock_history = if was_high: 1'u8 else: 0'u8
  serial_tick(serial, gb)

# ==================== Register access ====================

when SERIAL_CPU_SAMPLE_T < 4:
  proc serial_cpu_pre*(serial: GbSerial; gb: GB): bool {.inline.} =
    ## This access's M-cycle carries a tap edge: the access goes first and sees
    ## the pre-edge state.
    serial.edge_cycle == gb.scheduler.cycles

  proc serial_edge_finished_byte(serial: GbSerial): bool {.inline.} =
    ## Did this M-cycle's edge finish a master transfer's byte?
    serial.pre_slot_open and serial.pre_bits == 1 and
      (serial.pre_sc and 0x81) == 0x81

  proc serial_if_write_fixup*(gb: GB) {.inline.} =
    ## An $FF0F write goes before this M-cycle's tap edge, so an edge that
    ## completed a transfer raises the request again (gambatte
    ## serial/start_wait_clear_if_read_if_1).
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq and
       serial.serial_edge_finished_byte():
      gb.interrupts.serial_interrupt = true
      when defined(gb_io_trace):
        echo "SERIALIF2 ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter, " sched=", gb.scheduler.cycles

  proc serial_if_latch_fixup*(gb: GB) {.inline.} =
    ## The same rule for an $FF0F read (mem_tick_if_read, after
    ## irq_latch_mcycle); only the edge's own contribution is taken back.
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq:
      gb.interrupts.if_prev = gb.interrupts.if_prev and not 0x08'u8

const SERIAL_HALT_TAIL_BLIND* {.intdefine.} = 1
  ## 1: a HALTED CPU misses a serial request raised by the tap edge of the
  ## M-cycle it is latching and wakes one M-cycle later. The edge is on the
  ## last T-cycle (SERIAL_CPU_SAMPLE_T, gb.nim); the halted latch is earlier
  ## (HALT_IF_SAMPLE_T, cpu.nim). The running CPU's check is unchanged.
  ## Pinned by DocBoy `serial_interrupt{,_timing}_halted_round2` and
  ## `*_interrupt_serial_halted_*`.

when SERIAL_CPU_SAMPLE_T < 4 and SERIAL_HALT_TAIL_BLIND != 0:
  proc halt_serial_tail_blind*(gb: GB): bool {.noinline.} =
    ## Is the interrupt line up ONLY because this M-cycle's tap edge finished
    ## a transfer? Reached only with the line up, from a halted latch.
    let irq = gb.interrupts
    if not (irq.serial_interrupt and irq.serial_enabled): return false
    if (irq.vblank_interrupt   and irq.vblank_enabled)   or
       (irq.lcd_stat_interrupt and irq.lcd_stat_enabled) or
       (irq.timer_interrupt    and irq.timer_enabled)    or
       (irq.joypad_interrupt   and irq.joypad_enabled): return false
    let serial = gb.serial
    serial.serial_cpu_pre(gb) and not serial.pre_irq

proc serial_sc_unused_bits(gb: GB): uint8 {.inline.} =
  # Unused SC bits read 1; bit 1 only exists in native CGB mode.
  if gb.cgb_native: 0x7C'u8 else: 0x7E'u8

proc serial_read*(serial: GbSerial; gb: GB; idx: int): uint8 =
  when SERIAL_CPU_SAMPLE_T < 4:
    if serial.serial_cpu_pre(gb):
      when defined(gb_serial_trace):
        echo "PREREAD t=", gb.scheduler.cycles, " idx=", idx.toHex(4),
             " sb=", serial.pre_sb.toHex(2), " sc=", serial.pre_sc.toHex(2)
      case idx
      of 0xFF01: return serial.pre_sb
      of 0xFF02: return serial.pre_sc or serial_sc_unused_bits(gb)
      else: return 0xFF'u8
  case idx
  of 0xFF01: serial.sb
  of 0xFF02: serial.sc or serial_sc_unused_bits(gb)
  else: 0xFF'u8

const SERIAL_SC_WRITE_LEAD_T* {.intdefine.} = 4
  ## T-cycles before the divider's present count at which an SC store samples
  ## the tap it restarts from (0 = the present count, serial_prime_history).
  ## Default 4: the bus half has already run when the byte commits, so 4 back
  ## is the top of the M-cycle, where a CPU write lands (as
  ## SERIAL_DIV_WRITE_LEAD_T for DIV). 1..4 are equivalent (edges sit on the
  ## M-cycle grid); 0 and 5+ fail DocBoy `serial_timing_*` and gambatte
  ## `serial/nopx*` tests. Clean-room: derived from test ROM sources/outputs and
  ## dingbat's own trace runs; no emulator source consulted.

proc serial_write_commit(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF01:
    serial.sb = val
    when defined(test_harness):
      if gb.test_output != nil:
        gb.test_output.serial_buffer.add(char(val))
  of 0xFF02:
    # Any SC write restarts the bit count and slot sequence. An open slot is
    # closed by it, shifting one bit into SB under the OLD SC; the count
    # restarts after that, so the new byte still takes eight closes (DocBoy
    # serial_abort_to_81_sc_round{1,2}).
    let started = (serial.sc and 0x80) == 0 and (val and 0x80) != 0
    let was_master = serial.serial_is_master()
    if serial.slot_open:
      serial.slot_open = false
      if was_master:
        serial.sb = (serial.sb shl 1) or 1'u8
    serial.bits_remaining = 8
    serial.sc = val and (if gb.cgb_native: 0x83'u8 else: 0x81'u8)
    if (val and 0x80) == 0:
      serial.bits_remaining = 0  # clearing the enable bit aborts a transfer
    elif started:
      serial.out_latch = serial.sb
      serial.driver.serial_start(gb)
    # The clock-select bit may have moved the tap: resample it, no phantom edge.
    when SERIAL_SC_WRITE_LEAD_T != 0:
      serial.clock_history =
        if ((gb.timer.tdiv - uint16(SERIAL_SC_WRITE_LEAD_T) + serial_phase(gb)) and
            serial.serial_tap_bit(gb)) != 0: 1'u8 else: 0'u8
    else:
      serial.serial_prime_history(gb)
    serial.serial_update_shifting()
  else: discard

proc serial_write*(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  when SERIAL_CPU_SAMPLE_T < 4:
    # The store goes before this M-cycle's tap edge: rewind to the pre-edge
    # state, commit, and run the edge again (gambatte serial/nopx1_*). A
    # completing edge is rolled back too: an SC write in the eighth shift's
    # M-cycle aborts the transfer (gambatte serial/start_wait_{sc80,stop}_*),
    # unless serial_peer_committed.
    if serial.serial_cpu_pre(gb) and
       not (serial.serial_edge_finished_byte() and
            serial.driver.serial_peer_committed()):
      serial.slot_open       = serial.pre_slot_open
      serial.sb              = serial.pre_sb
      serial.sc              = serial.pre_sc
      serial.bits_remaining  = serial.pre_bits
      gb.interrupts.serial_interrupt = serial.pre_irq
      serial.serial_update_shifting()
      serial_write_commit(serial, gb, idx, val)
      # Let the replay keep again: the pre-edge state is now the post-write one.
      serial.edge_cycle = high(CycleCount)
      serial.serial_tap_fell(gb)
      # The replayed edge is spent; SERIAL_SC_WRITE_LEAD_T's sample must not
      # see it again.
      serial.serial_prime_history(gb)
      return
  serial_write_commit(serial, gb, idx, val)
