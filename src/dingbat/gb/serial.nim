# GB serial port (included by gb.nim)
#
# SB (0xFF01) is the live shift register; SC (0xFF02) bit 7 = transfer
# enable, bit 0 = clock source (1 = internal), bit 1 = CGB fast clock.
#
# Bit rate. Pan Docs (Serial Data Transfer): "In Non-CGB Mode the Game Boy
# supplies an internal clock of 8192Hz only"; in CGB mode SC bit 1 set gives
# "262144 Hz ... Normal speed" and double speed doubles either rate. Pan Docs
# (Timer and Divider Registers): DIV "is incremented at a rate of 16384Hz" and
# "will increment at 32768Hz in double speed" -- DIV being the high byte of
# the system counter, its bit 7 completes a cycle at exactly twice the 8192 Hz
# bit rate, and bit 2 at twice 262144 Hz. So one bit of a transfer is TWO
# periods of that tap bit: its falling edges alternately open a bit slot and
# close it, and SB moves at the close. An SC write starts the slot sequence
# over, so the first bit lands on the second tap edge after the write, and a
# write that finds a slot open closes it on the spot (mooneye boot_sclk_align,
# gambatte serial/*, gbedge p06 SERIAL: no-cable duration, SC=$83 on both
# clocks, DIV reset mid-transfer, mid-shift SB/SC -- all eight scored bytes
# identical on MGB and AGS). A DIV write mid-transfer is a tap-bit change like
# any other, so it can make or lose an edge exactly as it does for TIMA.
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

# The bit-slot state lives in GbSerial.master_clock (gb.nim; savestate.nim
# packs it as bit 1 of the clock byte), and its pre-edge copy in pre_master.
# Named here for what they hold: whether a bit slot is currently open.
template slot_open(serial: GbSerial): bool = serial.master_clock
template `slot_open=`(serial: GbSerial; v: bool) = serial.master_clock = v
template pre_slot_open(serial: GbSerial): bool = serial.pre_master
template `pre_slot_open=`(serial: GbSerial; v: bool) = serial.pre_master = v

proc serial_is_master(serial: GbSerial): bool {.inline.} =
  ## Transfer enabled on the internal clock (SC.7 and SC.0 both set).
  (serial.sc and 0x81) == 0x81

proc serial_tap_bit(serial: GbSerial; gb: GB): uint16 {.inline.} =
  ## The system-counter bit the bit-slot clock is taken from: bit 7 (a 256 T
  ## period, 512 T per bit), or bit 2 under SC.1, the CGB fast clock, which is
  ## only wired up in native CGB mode (mooneye misc/bits/unused_hwio-C).
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

# ==================== Bit-slot clock ====================
#
# The tap is read from (divider + phase): the serial unit's copy of the
# counter runs a few T-cycles ahead of what a DIV read returns (mooneye
# boot_div-dmgABCmgb + boot_sclk_align-dmgABCmgb, gambatte serial/*).

proc serial_phase(gb: GB): uint16 {.inline.} =
  ## gambatte serial/* puts the phase at [0,3]; mooneye boot_sclk_align-dmgABCmgb
  ## puts the DMG's at [4,7], where it ships (SERIAL_TAP_DMG in gb.nim). The
  ## CGB fast-clock rows (gambatte serial/start83_*) are a whole bit slot off
  ## and no phase reaches them.
  if gb.cgb_enabled: uint16(SERIAL_TAP_CGB) else: uint16(SERIAL_TAP_DMG)

proc serial_tap_high(serial: GbSerial; gb: GB): bool {.inline.} =
  ((gb.timer.tdiv + serial_phase(gb)) and serial.serial_tap_bit(gb)) != 0

proc serial_prime_history*(serial: GbSerial; gb: GB) =
  ## Resample the tap so the next tick compares against its present level.
  serial.clock_history = if serial.serial_tap_high(gb): 1'u8 else: 0'u8

proc serial_move_bit(serial: GbSerial; gb: GB) =
  ## A bit slot closing on a master transfer: SB takes one bit in from the
  ## line (a lone/disconnected line reads 1) and the count goes down; the
  ## eighth close hands the byte to the driver.
  serial.sb = (serial.sb shl 1) or 1'u8
  dec serial.bits_remaining
  when defined(gb_serial_trace):
    # Diagnostic (tools only); pair with -d:gb_phase_trace for the phase.
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
  ## One falling edge of the tap. With no slot open it opens one; with a slot
  ## open it closes it, and that close is where a master transfer moves a bit.
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
    let was_high = ((old_tdiv - uint16(SERIAL_DIV_WRITE_LEAD_T) + serial_phase(gb)) and
                    serial.serial_tap_bit(gb)) != 0
    serial.clock_history = if was_high: 1'u8 else: 0'u8
  serial_tick(serial, gb)

# ==================== Register access ====================

when SERIAL_CPU_SAMPLE_T < 4:
  proc serial_cpu_pre*(serial: GbSerial; gb: GB): bool {.inline.} =
    ## True when this CPU access's M-cycle carries a serial tap edge: the
    ## access is ordered in front of it and reads the pre-edge state.
    serial.edge_cycle == gb.scheduler.cycles

  proc serial_edge_finished_byte(serial: GbSerial): bool {.inline.} =
    ## Did the edge kept this M-cycle close the last slot of a master
    ## transfer, i.e. finish the byte?
    serial.pre_slot_open and serial.pre_bits == 1 and
      (serial.pre_sc and 0x81) == 0x81

  proc serial_if_write_fixup*(gb: GB) {.inline.} =
    ## An $FF0F write is ordered in front of this M-cycle's tap edge, so an
    ## edge that completed a transfer raises the request again after the byte
    ## lands (gambatte serial/start_wait_clear_if_read_if_1 and its _ds arm).
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq and
       serial.serial_edge_finished_byte():
      gb.interrupts.serial_interrupt = true

  proc serial_if_latch_fixup*(gb: GB) {.inline.} =
    ## The same rule for an $FF0F read (mem_tick_if_read, after
    ## irq_latch_mcycle); only the edge's own contribution is taken back.
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq:
      gb.interrupts.if_prev = gb.interrupts.if_prev and not 0x08'u8

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

proc serial_write_commit(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF01:
    serial.sb = val
    when defined(test_harness):
      if gb.test_output != nil:
        gb.test_output.serial_buffer.add(char(val))
  of 0xFF02:
    # Any SC write restarts the bit count and the slot sequence. A slot that
    # is open when the write lands is closed by it, which moves one bit of a
    # transfer still running under the OLD SC -- but the count was already
    # restarted, so that bit can never be the completing one (gambatte
    # serial/start_wait_restart_read_if_* and the _sc80/_stop arms).
    let started = (serial.sc and 0x80) == 0 and (val and 0x80) != 0
    let was_master = serial.serial_is_master()
    serial.bits_remaining = 8
    if serial.slot_open:
      serial.slot_open = false
      if was_master:
        serial.serial_move_bit(gb)
    serial.sc = val and (if gb.cgb_native: 0x83'u8 else: 0x81'u8)
    if (val and 0x80) == 0:
      serial.bits_remaining = 0  # clearing the enable bit aborts a transfer
    elif started:
      serial.out_latch = serial.sb
      serial.driver.serial_start(gb)
    # The clock-select bit may have moved the tap: resample it, no phantom edge.
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
      return
  serial_write_commit(serial, gb, idx, val)
