# GB serial port (included by gb.nim)
#
# SB (0xFF01) is the live shift register; SC (0xFF02) bit 7 = transfer
# enable/in-progress, bit 0 = clock source (1 = internal), bit 1 = CGB fast
# clock. An internally-clocked transfer shifts one bit on each falling edge
# of the selected DIV counter bit (bit 8 -> 8192 Hz, CGB-fast bit 3 ->
# 262144 Hz; both double in CGB double speed because DIV itself ticks at the
# CPU clock). The serial clock is the free-running divider, not a dedicated
# counter started by SC: starting mid-phase shortens the first bit period,
# and DIV writes mid-transfer produce (or delay) shift edges exactly like
# the TIMA quirk — the behaviors pinned by mooneye boot_sclk_align and the
# gambatte serial tests.
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
  ## The DIV counter bit whose falling edge drives the shift clock. The CGB
  ## fast clock (SC.1) only exists in native CGB mode; a DMG cart on CGB
  ## hardware gets DMG serial behavior (mooneye misc/bits/unused_hwio-C).
  if gb.cgb_native and (serial.sc and 0x02) != 0: 1'u16 shl 3
  else: 1'u16 shl 8

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
  ## Both SoCs want the same M-cycle here: the DMG's old 4 was one M-cycle
  ## high and cost three `serial` rows. Swept and bracketed on both sides at
  ## SERIAL_TAP_DMG in gb.nim, where the plateau table lives; mooneye
  ## boot_div-dmgABCmgb and boot_sclk_align-dmgABCmgb still pin the DMG seed
  ## and shift phase jointly, and both stay green at 0.
  if gb.cgb_enabled: uint16(SERIAL_TAP_CGB) else: uint16(SERIAL_TAP_DMG)

proc serial_clock_level(serial: GbSerial; gb: GB): bool {.inline.} =
  ((gb.timer.tdiv + serial_tap(gb)) and serial.serial_clock_mask(gb)) != 0

proc serial_prime_history*(serial: GbSerial; gb: GB) =
  serial.clock_history = if serial.serial_clock_level(gb): 1'u8 else: 0'u8

proc serial_tick*(serial: GbSerial; gb: GB) {.inline.} =
  ## Per-cycle hook from the timer loop (after tdiv increments), gated on
  ## serial.shifting.
  let current = serial.serial_clock_level(gb)
  let previous = (serial.clock_history and 1) != 0
  when SERIAL_START_ARM != 0:
    serial.clock_history = (serial.clock_history and 2'u8) or
                           (if current: 1'u8 else: 0'u8)
  else:
    serial.clock_history = if current: 1'u8 else: 0'u8
  if previous and not current and serial.bits_remaining > 0:  # falling edge
    when SERIAL_START_ARM != 0:
      # Experiment: the first falling edge after SC.7 rises does not shift, it
      # only arms the shifter (clock_history bit 1 is the arm flag).
      if (serial.clock_history and 2) != 0:
        serial.clock_history = serial.clock_history and not 2'u8
        return
    serial.sb = (serial.sb shl 1) or 1'u8  # a lone/disconnected line reads 1
    dec serial.bits_remaining
    if serial.bits_remaining == 0:
      serial.driver.serial_complete(gb)

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
    let started = (serial.sc and 0x80) == 0 and (val and 0x80) != 0
    serial.sc = val and (if gb.cgb_native: 0x83'u8 else: 0x81'u8)
    if (val and 0x80) == 0:
      serial.bits_remaining = 0  # clearing the enable bit aborts a transfer
    elif started:
      serial.out_latch = serial.sb
      serial.bits_remaining = 8
      # Watch the free-running serial clock for its next falling edge
      serial.serial_prime_history(gb)
      when SERIAL_START_ARM != 0:
        serial.clock_history = serial.clock_history or 2'u8
      serial.driver.serial_start(gb)
    else:
      # Rewrite while enabled (e.g. clock-select change mid-transfer):
      # resample so the edge detector tracks the newly selected bit
      serial.serial_prime_history(gb)
    serial.serial_update_shifting()
  else: discard
