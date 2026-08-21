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
  when SERIAL_CPU_SAMPLE_T < 4:
    # `high` and not 0: cycle 0 is a real M-cycle on a boot-skipped start, and
    # a zero sentinel would serve that M-cycle's accesses a pre-edge state that
    # was never captured.
    GbSerial(driver: GbSerialDriver(), edge_cycle: high(CycleCount))
  else:
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

method serial_peer_committed*(drv: GbSerialDriver): bool {.base.} =
  ## Does this driver's `serial_complete` publish anything OUTSIDE this core --
  ## a byte handed to a peer, a printer command accepted -- that cannot be
  ## taken back?
  ##
  ## False for the base (no-cable) driver: its completion only clears SC.7,
  ## zeroes the counter and raises IF, all of which SERIAL_CPU_SAMPLE_T's
  ## rollback restores exactly. **Any driver that talks to something else MUST
  ## override this to true**, or a CPU store landing in the same M-cycle as the
  ## eighth shift will rewind this side of an exchange the other side already
  ## saw. `LockstepGbSerialDriver` (link.nim) and `GbPrinterDriver`
  ## (printer.nim) both do; overriding costs those drivers the two
  ## `start_wait_{sc80,stop}` rows, which is the price of not desyncing a cable.
  false

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
  ##
  ## ---- REFUTED 2026-08-21: the CGB FAST clock's residue is not a phase -----
  ##
  ## `start83_*` runs the CGB fast clock (SC.1, tap bit 2, 8 T per toggle,
  ## 16 T per bit) and dingbat is a uniform TWO M-cycles late on it. Measured
  ## two-sidedly against SameBoy on `start83_late_div_write_wait_read_if_1a`,
  ## sliding both islands through their sleds: dingbat's E0->E8 flip is at +2
  ## where SameBoy's is at 0, at all thirteen DIV-write positions, with the
  ## 2-M-cycle alternation of the tap's own period on top. Eight T-cycles is
  ## one whole master-clock toggle, which no tap value can express -- the fast
  ## mask is bit 2, so a tap only reaches phases 0..7.
  ##
  ## The complete phase space was then swept, 24 builds, over all 82 `serial`
  ## rows: a fast-clock-specific tap 0..7 crossed with what the SC write does
  ## to the half-rate master clock (reseed LOW = shipping, reseed HIGH, or
  ## leave it free-running). Everything scores 75 except (seed HIGH, tap 4..7)
  ## which scores 77 -- a four-cell plateau, one M-cycle wide, and the global
  ## maximum of the whole space.
  ##
  ## It is not shipped, and the reason is not the total. At that maximum three
  ## rows go green (`nopx1_start83_wait_read_if_2`,
  ## `start83_late_div_write_wait_read_if_{1b,2b}`) and
  ## `nopx2_start83_wait_read_if_1` goes red -- a row SameBoy passes -- so the
  ## maximum still does not reconcile with the oracle, "the master clock is
  ## reseeded HIGH on a fast start" has no support outside this score, it is
  ## worth zero RUNNER rows (`gambatte/serial` fails either way), and it would
  ## change what a real CGB link cable does. **What the sweep does establish is
  ## that the residue is not reachable by any phase of this model at all**, so
  ## the next attempt needs a different one -- most likely that SC.1 does not
  ## use the same half-rate master divider as SC.0 in the first place.
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
  when SERIAL_CPU_SAMPLE_T < 4:
    # The state a CPU access in THIS M-cycle is entitled to: the edge is on the
    # M-cycle's last T-cycle and dingbat runs it at the top, so everything the
    # edge touches is snapshotted here and served to serial_read /
    # serial_write below. Only the first edge of an M-cycle captures (a second
    # cannot happen -- the fastest tap is 8 T per toggle -- but the guard costs
    # nothing and keeps the invariant local).
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
    # Diagnostic (tools only). The T-cycle a shift landed on inside its own
    # M-cycle is the whole of SERIAL_CPU_SAMPLE_T's evidence, and no suite
    # reports it. Pair with -d:gb_phase_trace for the `phase=` field.
    echo "SHIFT t=", gb.scheduler.cycles, " tdiv=", gb.timer.tdiv,
         " left=", serial.bits_remaining, " sb=", serial.sb.toHex(2)
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

const SERIAL_DIV_WRITE_LEAD_T* {.intdefine.} = 4
  ## How many T-cycles BEFORE the end of its own M-cycle a `$FF04` store's
  ## divider reset is compared against the serial tap.
  ##
  ## Same rule as SERIAL_CPU_SAMPLE_T, one register further out. `mem_write`
  ## runs the whole bus half (`mem_tick_bus(4)`) at the TOP of the M-cycle and
  ## only then commits the byte, so by the time `timer_write` zeroes `tdiv` the
  ## divider has already been advanced through all four of this M-cycle's
  ## T-cycles. The tap level the reset is then compared against is therefore
  ## the one at the END of the M-cycle, and a tap bit that ROSE inside that
  ## M-cycle is seen as high -- so the reset manufactures a falling edge one
  ## M-cycle before hardware does. Subtracting the M-cycle back off puts the
  ## comparison where the store is, without moving the reset itself.
  ##
  ## Measured two-sidedly against SameBoy on `serial/start_late_div_write_*`
  ## by sliding BOTH islands of the ROM (the `ldh ($ff04),a` and the
  ## `ldh a,($ff0f)`) through their NOP sleds -- 17 x 79 patched ROMs, DMG.
  ## The number reported per DIV-write position is the first IF-read offset
  ## that reads $E8, i.e. the M-cycle the transfer's 8th shift lands on:
  ##
  ##   div    -10  -9  -8  -7  -6  -5  -4  -3  -2  -1  +0  +1  +2  +3  +4
  ##   SameBoy  -9  -8  -7  -6  -5  -4  -3  -2  -1   0  +1 -62 -61 -60 -59
  ##   dingbat  -9  -8  -7  -6  -5  -4  -3  -2  -1   0 -63 -62 -61 -60 -59
  ##
  ## Both emulators ramp +1 per M-cycle of DIV-write delay (the reset restarts
  ## the divider, so the next tap edge moves with it) and both take the same
  ## 64-M-cycle step DOWN when the reset starts cancelling a tap period -- the
  ## step is one master-clock toggle, 256 T. The ONLY disagreement in 1343
  ## cells is WHERE that step falls: hardware at div+1, dingbat at div+0.
  ## Exactly one M-cycle, exactly one lead of 4 T. The reset itself must NOT
  ## move with it: every other row in the table is already exact, and shifting
  ## the reset would carry all of them off by one.

proc serial_div_write_edge*(serial: GbSerial; gb: GB; old_tdiv: uint16) {.inline.} =
  ## The tap's view of a `$FF04` store: `tdiv` is already 0 here, so the
  ## PRE-reset level has to be reconstructed from the value the divider held,
  ## less this M-cycle's own four T-cycles. See SERIAL_DIV_WRITE_LEAD_T.
  when SERIAL_DIV_WRITE_LEAD_T != 0:
    let pre = ((old_tdiv - uint16(SERIAL_DIV_WRITE_LEAD_T) + serial_tap(gb)) and
               serial.serial_clock_mask(gb)) != 0
    serial.clock_history = if pre: 1'u8 else: 0'u8
  serial_tick(serial, gb)

# ==================== Register access ====================

when SERIAL_CPU_SAMPLE_T < 4:
  proc serial_cpu_pre*(serial: GbSerial; gb: GB): bool {.inline.} =
    ## True when the M-cycle this CPU access is being served in carries a
    ## serial tap edge -- so the access is ordered in front of it and reads the
    ## shifter's pre-edge state. See SERIAL_CPU_SAMPLE_T in gb.nim.
    serial.edge_cycle == gb.scheduler.cycles

  proc serial_edge_completed(serial: GbSerial): bool {.inline.} =
    ## Did the edge captured this M-cycle finish a transfer? Only an edge that
    ## takes the master clock LOW shifts, and only the eighth shift completes.
    serial.pre_master and serial.pre_bits == 1 and
      (serial.pre_sc and 0x81) == 0x81

  proc serial_if_write_fixup*(gb: GB) {.inline.} =
    ## An $FF0F WRITE is ordered in front of this M-cycle's tap edge for the
    ## same reason a read is, so an edge that completed a transfer raises the
    ## serial request AGAIN once the written byte has landed -- the CPU cleared
    ## a bit that had not been set yet. `start_wait_clear_if_read_if_1` and its
    ## `_ds` arm (three rows) clear IF in exactly that M-cycle and then read it
    ## back expecting $E8; without this they read $E0.
    let serial = gb.serial
    if serial.serial_cpu_pre(gb) and not serial.pre_irq and
       serial.serial_edge_completed():
      gb.interrupts.serial_interrupt = true

  proc serial_if_latch_fixup*(gb: GB) {.inline.} =
    ## The serial IF bit half of the same rule, for the one register whose read
    ## does not come through serial_read: $FF0F. Called from mem_tick_if_read
    ## after irq_latch_mcycle, which is the point the $FF0F read's byte is
    ## fixed. `pre_irq` keeps a bit that was ALREADY pending before this
    ## M-cycle's edge -- only the edge's own contribution is taken back.
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

proc serial_write*(serial: GbSerial; gb: GB; idx: int; val: uint8) =
  when SERIAL_CPU_SAMPLE_T < 4:
    # A completing edge is rolled back too -- gambatte's `start_wait_sc80_read_if_1`
    # and `start_wait_stop_read_if_1` (four rows) put the SC write in exactly
    # the M-cycle of the eighth shift and hardware ABORTS the transfer there,
    # so the completion has to be undone. That is exact for the no-cable
    # driver, whose completion is entirely local; a driver that has already
    # published the byte to a peer declines it (serial_peer_committed above),
    # keeping the four rows red on a linked core rather than desyncing it.
    if serial.serial_cpu_pre(gb) and
       not (serial.serial_edge_completed() and
            serial.driver.serial_peer_committed()):
      # The store is ordered in front of this M-cycle's tap edge: rewind the
      # shifter to the state captured in serial_master_edge, commit, and run
      # the edge again on top of it. This is what inverts `nopx1_*` -- the SC
      # write reseeds the master clock from the PRE-edge level, so the edge it
      # shares an M-cycle with counts toward the transfer instead of being
      # swallowed by the reseed, and the first shift comes 256 T sooner. See
      # SERIAL_CPU_SAMPLE_T in gb.nim.
      serial.master_clock    = serial.pre_master
      serial.sb              = serial.pre_sb
      serial.sc              = serial.pre_sc
      serial.bits_remaining  = serial.pre_bits
      gb.interrupts.serial_interrupt = serial.pre_irq
      serial.serial_update_shifting()
      serial_write_commit(serial, gb, idx, val)
      # Let the replay capture again: the pre-edge state a later observer is
      # entitled to is now the post-write one.
      serial.edge_cycle = high(CycleCount)
      serial.serial_master_edge(gb)
      return
  serial_write_commit(serial, gb, idx, val)
