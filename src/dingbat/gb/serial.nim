# GB serial port (included by gb.nim)
#
# SB (0xFF01) is the live shift register; SC (0xFF02) bit 7 = transfer
# enable, bit 0 = clock source (1 = internal), bit 1 = CGB fast clock.
#
# The shift clock is a half-rate toggle off the free-running divider: a
# falling edge of DIV bit 7 (CGB-fast: bit 2) flips a master clock, and only
# the flip that takes it LOW shifts. An SC write reseeds the master clock
# low, so the first shift is the SECOND tap edge after the write (gambatte
# serial/*, mooneye boot_sclk_align). DIV writes mid-transfer make or delay
# edges as for TIMA.
#
# GbSerialDriver models the peer, mirroring the GBA SioDriver (gba/serial.nim):
# consulted only on transfer start (SC.7 rising) and completion (the 8th shift
# of a master transfer; outgoing byte in out_latch), byte-duplex, and the
# driver must call serial_finish_transfer on every unit that completes.

proc new_gb_serial*(): GbSerial =
  when SERIAL_CPU_SAMPLE_T < 4:
    # `high`, not 0: cycle 0 is a real M-cycle on a boot-skipped start.
    GbSerial(driver: GbSerialDriver(), edge_cycle: high(CycleCount))
  else:
    GbSerial(driver: GbSerialDriver())

proc serial_clock_mask(serial: GbSerial; gb: GB): uint16 {.inline.} =
  ## Divider bit whose falling edge toggles the shift clock: bit 7 (512 T per
  ## bit), or bit 2 under the CGB fast clock (SC.1), which only exists in
  ## native CGB mode (mooneye misc/bits/unused_hwio-C).
  if gb.cgb_native and (serial.sc and 0x02) != 0: 1'u16 shl 2
  else: 1'u16 shl 7

proc serial_update_shifting(serial: GbSerial) {.inline.} =
  # The one test the timer's per-cycle loop pays for.
  serial.shifting = serial.bits_remaining > 0 and
                    (serial.sc and 0x81) == 0x81

proc serial_finish_transfer*(serial: GbSerial; gb: GB) =
  ## The explicit completion step; drivers fill SB before calling this.
  serial.sc = serial.sc and not 0x80'u8
  serial.bits_remaining = 0
  serial.serial_update_shifting()
  gb.interrupts.serial_interrupt = true

method serial_peer_committed*(drv: GbSerialDriver): bool {.base.} =
  ## Does `serial_complete` publish something outside this core that cannot
  ## be taken back? A driver that talks to a peer MUST return true (link.nim,
  ## printer.nim do), or SERIAL_CPU_SAMPLE_T's rollback rewinds an exchange
  ## the other side already saw (costs the gambatte serial/start_wait_{sc80,stop} rows).
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

# ==================== Bit engine ====================
#
# The shift clock is the selected bit of (divider + tap offset): the tap sits
# a few cycles ahead of what DIV reads return (mooneye boot_div-dmgABCmgb +
# boot_sclk_align-dmgABCmgb, gambatte serial/*).

proc serial_tap(gb: GB): uint16 {.inline.} =
  ## gambatte serial/* puts the tap at [0,3]; mooneye boot_sclk_align-dmgABCmgb
  ## puts the DMG's at [4,7], where it ships (SERIAL_TAP_DMG in gb.nim). The
  ## CGB fast-clock rows (gambatte serial/start83_*) are a whole master-clock
  ## toggle off and no tap phase reaches them.
  if gb.cgb_enabled: uint16(SERIAL_TAP_CGB) else: uint16(SERIAL_TAP_DMG)

proc serial_clock_level(serial: GbSerial; gb: GB): bool {.inline.} =
  ((gb.timer.tdiv + serial_tap(gb)) and serial.serial_clock_mask(gb)) != 0

proc serial_prime_history*(serial: GbSerial; gb: GB) =
  serial.clock_history = if serial.serial_clock_level(gb): 1'u8 else: 0'u8

proc serial_master_edge(serial: GbSerial; gb: GB) =
  ## One falling edge of the divider tap: flips the half-rate master clock,
  ## and only the flip that takes it LOW shifts (gambatte serial/*).
  when SERIAL_CPU_SAMPLE_T < 4:
    # Snapshot the pre-edge state for a CPU access in this M-cycle: the edge is
    # on its last T-cycle and runs at the top. See SERIAL_CPU_SAMPLE_T (gb.nim).
    if serial.edge_cycle != gb.scheduler.cycles:
      serial.edge_cycle = gb.scheduler.cycles
      serial.pre_master = serial.master_clock
      serial.pre_sb     = serial.sb
      serial.pre_sc     = serial.sc
      serial.pre_bits   = serial.bits_remaining
      serial.pre_irq    = gb.interrupts.serial_interrupt
  serial.master_clock = not serial.master_clock
  if serial.master_clock: return
  if (serial.sc and 0x81) != 0x81 or serial.bits_remaining <= 0: return
  serial.sb = (serial.sb shl 1) or 1'u8  # a lone/disconnected line reads 1
  dec serial.bits_remaining
  when defined(gb_serial_trace):
    # Diagnostic (tools only); pair with -d:gb_phase_trace for the phase.
    echo "SHIFT t=", gb.scheduler.cycles, " tdiv=", gb.timer.tdiv,
         " left=", serial.bits_remaining, " sb=", serial.sb.toHex(2)
  if serial.bits_remaining == 0:
    serial.driver.serial_complete(gb)

proc serial_tick*(serial: GbSerial; gb: GB) {.inline.} =
  ## Per-cycle hook from the timer loop (after tdiv increments).
  let current = serial.serial_clock_level(gb)
  let previous = (serial.clock_history and 1) != 0
  serial.clock_history = if current: 1'u8 else: 0'u8
  if previous and not current:  # falling edge of the tap
    serial.serial_master_edge(gb)

const SERIAL_DIV_WRITE_LEAD_T* {.intdefine.} = 4
  ## T-cycles before the end of its own M-cycle at which a `$FF04` store's
  ## divider reset is compared against the serial tap: `mem_write` ticks the
  ## bus before committing, so comparing at the end would turn a tap that rose
  ## inside the M-cycle into a falling edge one M-cycle early. Only the
  ## comparison moves, not the reset. gambatte serial/start_late_div_write_*
  ## pins the M-cycle; the T-cycle within it is assumed, no ROM pins it.

proc serial_div_write_edge*(serial: GbSerial; gb: GB; old_tdiv: uint16) {.inline.} =
  ## The tap's view of a `$FF04` store: `tdiv` is already 0, so the pre-reset
  ## level is rebuilt from `old_tdiv` less SERIAL_DIV_WRITE_LEAD_T.
  when SERIAL_DIV_WRITE_LEAD_T != 0:
    let pre = ((old_tdiv - uint16(SERIAL_DIV_WRITE_LEAD_T) + serial_tap(gb)) and
               serial.serial_clock_mask(gb)) != 0
    serial.clock_history = if pre: 1'u8 else: 0'u8
  serial_tick(serial, gb)

# ==================== Register access ====================

when SERIAL_CPU_SAMPLE_T < 4:
  proc serial_cpu_pre*(serial: GbSerial; gb: GB): bool {.inline.} =
    ## True when this CPU access's M-cycle carries a serial tap edge: the
    ## access is ordered in front of it and reads the pre-edge state.
    serial.edge_cycle == gb.scheduler.cycles

  proc serial_edge_completed(serial: GbSerial): bool {.inline.} =
    ## Did the edge captured this M-cycle finish a transfer?
    serial.pre_master and serial.pre_bits == 1 and
      (serial.pre_sc and 0x81) == 0x81

  proc serial_if_write_fixup*(gb: GB) {.inline.} =
    ## An $FF0F write is ordered in front of this M-cycle's tap edge, so an
    ## edge that completed a transfer raises the request again after the byte
    ## lands (gambatte serial/start_wait_clear_if_read_if_1 and its _ds arm).
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq and
       serial.serial_edge_completed():
      gb.interrupts.serial_interrupt = true

  proc serial_if_latch_fixup*(gb: GB) {.inline.} =
    ## The same rule for an $FF0F read (mem_tick_if_read, after
    ## irq_latch_mcycle); only the edge's own contribution is taken back.
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq:
      gb.interrupts.if_prev = gb.interrupts.if_prev and not 0x08'u8

proc serial_read*(serial: GbSerial; gb: GB; idx: int): uint8 =
  when SERIAL_CPU_SAMPLE_T < 4:
    if serial.serial_cpu_pre(gb):
      when defined(gb_serial_trace):
        echo "PREREAD t=", gb.scheduler.cycles, " idx=", idx.toHex(4),
             " sb=", serial.pre_sb.toHex(2), " sc=", serial.pre_sc.toHex(2)
      case idx
      of 0xFF01: return serial.pre_sb
      of 0xFF02:
        return (if gb.cgb_native: serial.pre_sc or 0x7C'u8
                else: serial.pre_sc or 0x7E'u8)
      else: return 0xFF'u8
  case idx
  of 0xFF01: serial.sb
  of 0xFF02:
    # Unused bits read 1 (bit 1 only exists in native CGB mode)
    if gb.cgb_native: serial.sc or 0x7C'u8
    else: serial.sc or 0x7E'u8
  else: 0xFF'u8

proc serial_write_commit(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF01:
    serial.sb = val
    when defined(test_harness):
      if gb.test_output != nil:
        gb.test_output.serial_buffer.add(char(val))
  of 0xFF02:
    # Any SC write restarts the bit counter and reseeds the master clock LOW;
    # if it was high that is a real edge and a transfer under the OLD SC shifts
    # once more here, but the counter is reset first so it cannot complete
    # (gambatte serial/start_wait_restart_read_if_* and the _sc80/_stop arms).
    let started = (serial.sc and 0x80) == 0 and (val and 0x80) != 0
    let old_sc = serial.sc
    serial.bits_remaining = 8
    if serial.master_clock:
      serial.master_clock = false
      if (old_sc and 0x81) == 0x81:
        serial.sb = (serial.sb shl 1) or 1'u8
        dec serial.bits_remaining
    serial.sc = val and (if gb.cgb_native: 0x83'u8 else: 0x81'u8)
    if (val and 0x80) == 0:
      serial.bits_remaining = 0  # clearing the enable bit aborts a transfer
    elif started:
      serial.out_latch = serial.sb
      serial.driver.serial_start(gb)
    # Resample the tap (the clock-select bit may have moved it): no phantom edge.
    serial.serial_prime_history(gb)
    serial.serial_update_shifting()
  else: discard

proc serial_write*(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  when SERIAL_CPU_SAMPLE_T < 4:
    # The store is ordered in front of this M-cycle's tap edge: rewind to the
    # pre-edge state, commit, and run the edge again (gambatte serial/nopx1_*).
    # A completing edge is rolled back too, as hardware aborts a transfer whose
    # SC write lands in the eighth shift's M-cycle (gambatte
    # serial/start_wait_{sc80,stop}_read_if_1), unless serial_peer_committed.
    if serial.serial_cpu_pre(gb) and
       not (serial.serial_edge_completed() and
            serial.driver.serial_peer_committed()):
      serial.master_clock    = serial.pre_master
      serial.sb              = serial.pre_sb
      serial.sc              = serial.pre_sc
      serial.bits_remaining  = serial.pre_bits
      gb.interrupts.serial_interrupt = serial.pre_irq
      serial.serial_update_shifting()
      serial_write_commit(serial, gb, idx, val)
      # Let the replay capture again: the pre-edge state is now the post-write one.
      serial.edge_cycle = high(CycleCount)
      serial.serial_master_edge(gb)
      return
  serial_write_commit(serial, gb, idx, val)
