# GB serial port (included by gb.nim)
#
# SB (0xFF01) is the live shift register; SC (0xFF02) bit 7 = transfer
# enable/in-progress, bit 0 = clock source (1 = internal), bit 1 = CGB fast
# clock.
#
# The shift clock is a HALF-rate toggle, not a direct tap. A falling edge of
# DIV bit 7 (CGB-fast: bit 2) flips a master clock, and only the flip that
# takes it LOW shifts a bit — so the bit period is two edges, 512 T (8192 Hz)
# normal and 16 T (262144 Hz) CGB-fast, both doubling in CGB double speed
# because DIV itself ticks at the CPU clock. The rate is what a single bit-8
# tap would give; the PHASE is not, because the master clock is state and a
# write to SC reseeds it low. That makes the first shift of a transfer the
# SECOND edge after the write — 256..512 T, never less — where a single-tap
# model would sometimes shift within a few cycles of the write. This is
# SameBoy's model (GB_serial_master_edge in Core/timing.c) and it is what
# the gambatte `serial` bucket measures; the reseed is also what
# `start_wait_restart`/`_sc80`/`_stop` see when they rewrite SC mid-transfer.
#
# The clock is still the free-running divider, not a dedicated counter: DIV
# writes mid-transfer produce (or delay) shift edges exactly like the TIMA
# quirk — the behaviors pinned by mooneye boot_sclk_align and the gambatte
# serial tests.
#
# ==================== GbSerialDriver interface ====================
#
# A driver models whatever is plugged into the link port, mirroring the GBA
# SioDriver contract (gba/serial.nim): it is consulted only on transfer
# start and completion (cold path), and completion is an explicit step the
# driver performs. The base methods implement exact no-cable behavior, so
# the default driver instance overrides nothing.
#
# The interface is deliberately byte-duplex — "master clocks 8 bits, then
# the two ends exchange whole bytes" — the same shape as the GBA's
# normal-8 mode. That keeps the door open for a heterogeneous cable (GB/GBC
# core linked to a GBA core running a GB-compat normal-8 transfer): a
# bridge driver only has to pair this completion hook with the GBA side's
# sio_start/sio_complete, converting clocks between the two cores' cycle
# rates (4.19 vs 16.78 MHz).
#
# Contract:
#  - serial_start fires when SC.7 rises. On an internal-clock (master)
#    start the bit engine below runs the transfer off DIV edges either way;
#    the driver only needs this to observe protocol state. On an
#    external-clock (slave) start there is nothing to schedule — the slave
#    waits for a master's completion to deliver a byte.
#  - serial_complete fires on the 8th shift of a master transfer. The
#    driver exchanges bytes with the peer (the master's outgoing byte is
#    out_latch, latched at start) and must call serial_finish_transfer on
#    every unit that gets completion semantics.

proc new_gb_serial*(): GbSerial =
  GbSerial(driver: GbSerialDriver())

proc serial_clock_mask(serial: GbSerial; gb: GB): uint16 {.inline.} =
  ## The DIV counter bit whose falling edge TOGGLES the shift clock. It runs
  ## at twice the bit rate: bit 7 falls every 256 T and a bit is shifted every
  ## other fall, giving the 512 T (8192 Hz) bit period. The CGB fast clock
  ## (SC.1) moves the tap to bit 2 -- 8 T per toggle, 16 T per bit -- and only
  ## exists in native CGB mode; a DMG cart on CGB hardware gets DMG serial
  ## behavior (mooneye misc/bits/unused_hwio-C).
  if gb.cgb_native and (serial.sc and 0x02) != 0: 1'u16 shl 2
  else: 1'u16 shl 7

proc serial_update_shifting(serial: GbSerial) {.inline.} =
  # Cached "an internally-clocked transfer is shifting" flag: the one test
  # the timer's per-cycle loop pays for.
  serial.shifting = serial.bits_remaining > 0 and
                    (serial.sc and 0x81) == 0x81

proc serial_finish_transfer*(serial: GbSerial; gb: GB) =
  ## The explicit completion step: clear the enable bit and raise the
  ## serial interrupt. Drivers fill SB before calling this.
  serial.sc = serial.sc and not 0x80'u8
  serial.bits_remaining = 0
  serial.serial_update_shifting()
  gb.interrupts.serial_interrupt = true

method serial_start*(drv: GbSerialDriver; gb: GB) {.base.} =
  discard

method serial_complete*(drv: GbSerialDriver; gb: GB) {.base.} =
  # No cable: the input line floats high, so the bit engine already shifted
  # in 1s; just complete.
  serial_finish_transfer(gb.serial, gb)

proc set_serial_driver*(gb: GB; drv: GbSerialDriver) =
  ## Bind a link-cable driver (frontend configuration). Drivers are not
  ## serialized; whatever the frontend configured stays bound across
  ## save-state loads.
  gb.serial.driver = drv

# ==================== Bit engine ====================
#
# The shift clock is the selected bit of (divider + tap offset): the serial
# unit's tap sits a few cycles ahead of the value DIV reads return. The
# offset is pinned empirically by mooneye boot_div-dmgABCmgb (which fixes
# the post-boot divider seed via DIV reads) together with
# boot_sclk_align-dmgABCmgb and the gambatte serial tests (which fix the
# shift phase relative to that seed).

proc serial_tap(gb: GB): uint16 {.inline.} =
  ## Both SoCs want the same M-cycle here, and gambatte puts it at [0,3] while
  ## mooneye boot_sclk_align-dmgABCmgb puts the DMG one at [4,7]. The plateau
  ## table and the (measured) reason neither the boot seed nor anything on this
  ## side settles it are at SERIAL_TAP_DMG in gb.nim; the DMG ships at 4, where
  ## the hardware-verified mooneye row is green.
  if gb.cgb_enabled: uint16(SERIAL_TAP_CGB) else: uint16(SERIAL_TAP_DMG)

proc serial_clock_level(serial: GbSerial; gb: GB): bool {.inline.} =
  ((gb.timer.tdiv + serial_tap(gb)) and serial.serial_clock_mask(gb)) != 0

proc serial_prime_history*(serial: GbSerial; gb: GB) =
  serial.clock_history = if serial.serial_clock_level(gb): 1'u8 else: 0'u8

proc serial_master_edge(serial: GbSerial; gb: GB) =
  ## One falling edge of the divider tap. The tap does not shift a bit: it
  ## flips the half-rate master clock, and only the flip that takes that clock
  ## LOW shifts. Two consequences, and both are what the gambatte `serial`
  ## family measures:
  ##
  ##  * The bit period is two tap edges (512 T normal, 16 T CGB-fast), so the
  ##    rate is unchanged from a single bit-8 tap.
  ##  * The phase is now a piece of STATE, and `serial_write` below reseeds it
  ##    low. So the first shift of a transfer is the SECOND tap edge after the
  ##    SC.7 write -- between 256 and 512 T later, not between 0 and 512. When
  ##    the write lands in the tap bit's high half, hardware is a whole bit
  ##    period behind a naive single-tap model.
  serial.master_clock = not serial.master_clock
  if serial.master_clock: return
  if (serial.sc and 0x81) != 0x81 or serial.bits_remaining <= 0: return
  serial.sb = (serial.sb shl 1) or 1'u8  # a lone/disconnected line reads 1
  dec serial.bits_remaining
  if serial.bits_remaining == 0:
    serial.driver.serial_complete(gb)

proc serial_tick*(serial: GbSerial; gb: GB) {.inline.} =
  ## Per-cycle hook from the timer loop (after tdiv increments), gated on
  ## serial.shifting.
  let current = serial.serial_clock_level(gb)
  let previous = (serial.clock_history and 1) != 0
  serial.clock_history = if current: 1'u8 else: 0'u8
  if previous and not current:  # falling edge of the tap
    serial.serial_master_edge(gb)

# ==================== Register access ====================

proc serial_read*(serial: GbSerial; gb: GB; idx: int): uint8 =
  case idx
  of 0xFF01: serial.sb
  of 0xFF02:
    # Unused bits read 1 (bit 1 only exists in native CGB mode)
    if gb.cgb_native: serial.sc or 0x7C'u8
    else: serial.sc or 0x7E'u8
  else: 0xFF'u8

proc serial_write*(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF01:
    serial.sb = val
    when defined(test_harness):
      if gb.test_output != nil:
        gb.test_output.serial_buffer.add(char(val))
  of 0xFF02:
    # Any write to SC restarts the bit counter and reseeds the half-rate
    # master clock LOW. Reseeding is not a plain assignment: if the master
    # clock was high the write drives it through a real edge, so a transfer
    # that was already running under the OLD SC shifts one more bit right
    # there, on the write's own cycle. The counter is reset FIRST, so that
    # forced shift can never be the eighth -- it can't complete a transfer.
    # (This is `start_wait_restart_read_if_*` and the `_sc80`/`_stop` arms.)
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
    # Resample the tap: the clock-select bit may have moved it, and the
    # edge detector must not see a phantom edge on the next cycle.
    serial.serial_prime_history(gb)
    serial.serial_update_shifting()
  else: discard
