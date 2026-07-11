# Serial/SIO implementation (included by gba.nim)
#
# Register map:
#   0x120-0x121  SIODATA32_L / SIOMULTI0
#   0x122-0x123  SIODATA32_H / SIOMULTI1
#   0x124-0x125  SIOMULTI2
#   0x126-0x127  SIOMULTI3
#   0x128-0x129  SIOCNT
#   0x12A-0x12B  SIODATA8 / SIOMLT_SEND
#   0x134-0x135  RCNT
#   0x140-0x141  JOYCNT
#   0x150-0x153  JOY_RECV
#   0x154-0x157  JOY_TRANS
#   0x158-0x159  JOYSTAT

type
  SioMode* = enum
    smNormal8, smNormal32, smMulti, smUart, smGeneralPurpose, smJoyBus

proc sio_mode*(serial: Serial): SioMode =
  if bit(serial.rcnt, 15):
    if bit(serial.rcnt, 14): smJoyBus
    else: smGeneralPurpose
  else:
    case (serial.siocnt shr 12) and 3
    of 0: smNormal8
    of 1: smNormal32
    of 2: smMulti
    of 3: smUart
    else: smNormal8

# ==================== SioDriver interface ====================
#
# A driver models whatever is plugged into the link port. It is consulted
# only on SIO register access and transfer completion (cold path).
#
# Contract:
#  - sio_start fires on the SIOCNT start-bit rising edge. The driver decides
#    when — in emulated cycles — and with what data the transfer completes.
#    Completion is an explicit step the driver performs, never a return
#    value: either schedule it (serial.schedule_sio_completion -> etSerial ->
#    sio_complete) or, for out-of-process transports, leave the busy bit set
#    indefinitely and later fill the data registers and call
#    serial.finish_sio_transfer directly when the peer responds. Doing
#    nothing models a transfer that never completes (the game polls busy or
#    times out via a timer).
#  - sio_complete runs when the scheduled etSerial event fires: fill the
#    receive registers, then call serial.finish_sio_transfer.
#  - sio_pin_state answers the SC/SD/SI/SO pin levels (RCNT bits 0-3); games
#    probe these in general-purpose mode as a "cable present?" check.
#  - sio_siocnt_status answers the mode-dependent read-only SIOCNT bits
#    (normal: SI; multi: SI/SD/ID/error; UART: flags). read_siocnt masks the
#    result to the bits the mode actually exposes.
#  - sio_mode_changed fires on every RCNT/SIOCNT mode transition
#    (attach/detach semantics for the emulated cable).
#  - sio_attached/sio_detached fire when the frontend (re)binds a driver.
#
# The base methods below implement the exact no-cable behavior (pinned by
# the mGBA suite's SIO register R/W tests), so NullSioDriver overrides
# nothing. In-flight transfer state lives in Serial (busy bit + etSerial
# event) and serializes through the existing mechanisms; drivers themselves
# are never serialized (see the type declaration in gba.nim).

type
  NullSioDriver* = ref object of SioDriver
    ## No cable plugged in. All behavior comes from the SioDriver base
    ## methods; this subtype exists only to give the default a name.

  LoopbackSioDriver* = ref object of SioDriver
    ## Link cable wired back to itself (factory loopback plug): SO -> SI.
    ## Normal mode: the unit clocks its own bits back in, so the data
    ## registers are received unchanged and SI follows SO. Multi mode: the
    ## unit sees itself as parent of a 1-unit bus; its SIOMLT_SEND arrives
    ## in SIOMULTI0 and the other slots read absent (0xFFFF).

# --- Helpers for drivers ---

proc normal_transfer_cycles*(serial: Serial): int =
  ## Duration of an internally-clocked normal-mode transfer, from the start
  ## write to completion.
  let is_32bit = bit(serial.siocnt, 12)
  let fast = bit(serial.siocnt, 1)
  let bits = if is_32bit: 32 else: 8
  let cycles_per_bit = if fast: 8 else: 64
  # Start-up overhead between the SIOCNT start write and the first shifted
  # bit, calibrated against the mGBA suite's SIO timing tests. The same
  # value works under the HLE and the official BIOS: both execute (or
  # charge) the identical Halt wake -> BIOS return -> caller path. Retune
  # when CPU cycle accounting changes (the four tests shift by a uniform
  # delta; they print "Got OURS vs EXPECTED").
  const SIO_TRANSFER_OVERHEAD = 8
  bits * cycles_per_bit + SIO_TRANSFER_OVERHEAD

proc multi_transfer_cycles*(serial: Serial): int =
  ## Duration of a multi-mode round: each connected unit shifts 16 bits at
  ## the SIOCNT baud selection (9600/38400/57600/115200 bps).
  let cycles_per_bit = case serial.siocnt and 3
    of 0: 1748  # 16.78 MHz / 9600
    of 1: 437   # / 38400
    of 2: 291   # / 57600
    else: 146   # / 115200
  16 * cycles_per_bit

proc schedule_sio_completion*(serial: Serial; cycles: int) =
  ## Schedule the etSerial event `cycles` from now; it dispatches back to
  ## the driver's sio_complete.
  serial.gba.scheduler.schedule(cycles, etSerial)

proc finish_sio_transfer*(serial: Serial) =
  ## The explicit completion step: clear Start/Busy and raise the serial
  ## IRQ if enabled. Drivers fill the receive registers before calling this.
  serial.siocnt = serial.siocnt and not 0x0080'u16
  if bit(serial.siocnt, 14):
    serial.gba.interrupts.reg_if.serial = true
    serial.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

# --- Base methods: exact no-cable behavior ---

method sio_attached*(drv: SioDriver; serial: Serial) {.base.} =
  discard

method sio_detached*(drv: SioDriver; serial: Serial) {.base.} =
  discard

method sio_mode_changed*(drv: SioDriver; serial: Serial;
                         old_mode, new_mode: SioMode) {.base.} =
  discard

method sio_pin_state*(drv: SioDriver; serial: Serial; mode: SioMode): uint16 {.base.} =
  ## SC/SD/SI/SO pin levels (RCNT bits 0-3). With no cable connected, pins
  ## float to their default states per mode.
  case mode
  of smNormal8, smNormal32:
    # SC=1 (idle high), SD=0, SI=1 (pull-up, no connection), SO=SIOCNT.bit3
    let so = if bit(serial.siocnt, 3): 1'u16 else: 0'u16
    0x05'u16 or (so shl 3)  # SC=1, SD=0, SI=1, SO=variable
  of smMulti, smUart:
    0x0F'u16  # All high during idle
  of smGeneralPurpose:
    # In GPIO mode, pins reflect data/direction.
    # Input pins with pull-ups read high; output pins reflect data bits.
    let dir = (serial.rcnt shr 4) and 0x0F'u16
    let data = serial.rcnt and 0x0F'u16
    # For input pins (dir=0): read high (pull-up). For output pins: read data.
    (not dir and 0x0F'u16) or (dir and data)
  of smJoyBus:
    0x0C'u16  # SC=0, SD=0, SI=1, SO=1

method sio_siocnt_status*(drv: SioDriver; serial: Serial; mode: SioMode): uint16 {.base.} =
  ## Mode-dependent read-only SIOCNT bits, in position. read_siocnt masks
  ## this to the bits the mode exposes.
  case mode
  of smNormal8, smNormal32:
    # Bit 2: SI input state
    if bit(drv.sio_pin_state(serial, mode), 2): 0x0004'u16 else: 0'u16
  of smMulti:
    # With no connection: SI=1 (child), SD=1 (line pulled high), ID=0, Error=0
    0x000C'u16
  of smUart:
    0'u16  # send-full/receive-empty/error flags read 0 when idle
  of smGeneralPurpose, smJoyBus:
    0x0004'u16  # SI high

method sio_start*(drv: SioDriver; serial: Serial; mode: SioMode) {.base.} =
  case mode
  of smNormal8, smNormal32:
    let internal_clock = bit(serial.siocnt, 0)
    if internal_clock:
      serial.schedule_sio_completion(serial.normal_transfer_cycles())
    # External clock: no other GBA to drive it, transfer never starts
  of smMulti:
    # No other GBA connected — transfer never completes, stays busy.
    # The test suite expects this to timeout via Timer1.
    discard
  else:
    discard

method sio_complete*(drv: SioDriver; serial: Serial; mode: SioMode) {.base.} =
  # With no cable connected, SI is high, so all received bits are 1
  case mode
  of smNormal8:
    serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or 0x00FF'u16
  of smNormal32:
    serial.siodata32 = 0xFFFFFFFF'u32
  else:
    discard
  serial.finish_sio_transfer()

# --- Loopback driver: SO wired back to SI ---

method sio_pin_state*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode): uint16 =
  case mode
  of smNormal8, smNormal32:
    # SI is wired to SO, so it reads back SIOCNT.bit3; SC idles high.
    let so = if bit(serial.siocnt, 3): 1'u16 else: 0'u16
    0x01'u16 or (so shl 2) or (so shl 3)  # SC=1, SD=0, SI=SO, SO
  of smGeneralPurpose:
    # SI input follows the SO output; other inputs float high as usual.
    let dir = (serial.rcnt shr 4) and 0x0F'u16
    let data = serial.rcnt and 0x0F'u16
    var pins = (not dir and 0x0F'u16) or (dir and data)
    if bit(dir, 3) and not bit(dir, 2):  # SO driven, SI is an input
      pins = (pins and not 0x4'u16) or ((pins shr 1) and 0x4'u16)  # SI = SO
    pins
  else:
    # Multi/UART/JoyBus: same idle levels as no-cable
    procCall sio_pin_state(SioDriver(drv), serial, mode)

method sio_siocnt_status*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode): uint16 =
  case mode
  of smMulti:
    # A cable is present and every unit on the (1-unit) bus is ready:
    # SD=1 (all ready), SI=0 (this unit is parent), ID=0, Error=0
    0x0008'u16
  else:
    procCall sio_siocnt_status(SioDriver(drv), serial, mode)

method sio_start*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32:
    let internal_clock = bit(serial.siocnt, 0)
    if internal_clock:
      serial.schedule_sio_completion(serial.normal_transfer_cycles())
    # External clock: a loopback plug provides no clock source either
  of smMulti:
    # This unit is the parent, so its start bit drives the round.
    serial.schedule_sio_completion(serial.multi_transfer_cycles())
  else:
    discard

method sio_complete*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32:
    # The unit clocks its own bits back in: data registers are unchanged.
    discard
  of smMulti:
    # Parent's SIOMLT_SEND lands in SIOMULTI0; absent units read 0xFFFF.
    serial.multi_recv[0] = serial.siodata8
    serial.multi_recv[1] = 0xFFFF'u16
    serial.multi_recv[2] = 0xFFFF'u16
    serial.multi_recv[3] = 0xFFFF'u16
  else:
    discard
  serial.finish_sio_transfer()

# ==================== Serial implementation ====================

proc new_serial*(gba: GBA): Serial =
  result = Serial(gba: gba, driver: NullSioDriver())

proc set_sio_driver*(gba: GBA; drv: SioDriver) =
  ## Bind a link-cable driver (frontend configuration). Also the rebind
  ## point after a save-state load: drivers are not serialized, so whatever
  ## the frontend configured stays bound.
  if gba.serial.driver != nil:
    gba.serial.driver.sio_detached(gba.serial)
  gba.serial.driver = drv
  drv.sio_attached(gba.serial)

# --- SIOCNT read masking ---
# Certain bits are read-only depending on mode. Hardware forces them to 0 or
# their driver-provided hardware value on read.

proc read_siocnt(serial: Serial): uint16 =
  let mode = serial.sio_mode()
  let status = serial.driver.sio_siocnt_status(serial, mode)
  var v = serial.siocnt
  case mode
  of smNormal8, smNormal32:
    # Bit 15: always 0. Bits 4-6: always 0. Bit 2: SI state (read-only).
    v = (v and 0x7F8B'u16) or (status and 0x0004'u16)
  of smMulti:
    # Bit 15: always 0. Bits 4-6: read-only (ID, error). Bits 2-3: read-only (SI/SD).
    v = (v and 0x7F83'u16) or (status and 0x007C'u16)
  of smUart:
    # Bit 15: always 0. Bits 4,6: read-only flags (send/error).
    v = (v and 0x7FAF'u16) or (status and 0x0050'u16)
  of smGeneralPurpose, smJoyBus:
    # SIOCNT not used in these modes but bits are still read/writable
    # per gbatek: "same manner as for Normal, Multiplay, or UART mode"
    # Use Normal mode masking as default
    v = (v and 0x7F8B'u16) or (status and 0x0004'u16)
  v

# --- RCNT read masking ---

proc read_rcnt(serial: Serial): uint16 =
  var v = serial.rcnt
  # Bits 9-13 are always 0 (read-only)
  v = v and not 0x3E00'u16
  let mode = serial.sio_mode()
  let pins = serial.driver.sio_pin_state(serial, mode)
  case mode
  of smNormal8, smNormal32, smMulti, smUart:
    # Bit 15 must be 0, bits 0-3 reflect pin state (read-only)
    v = v and 0x41F0'u16  # keep bits 14, 8-4; clear 15, 13-9, 3-0
    v = v or pins
  of smGeneralPurpose:
    # Bits 0-3 reflect pin state, rest writable
    v = (v and not 0x000F'u16) or pins
  of smJoyBus:
    # Bits 0-3 reflect pin state
    v = (v and not 0x000F'u16) or pins
  v

# --- Transfer logic ---

proc serial_transfer_complete*(serial: Serial) =
  # etSerial fired: the driver fills the receive registers and finishes.
  serial.driver.sio_complete(serial, serial.sio_mode())

proc write_siocnt(serial: Serial; old_val: uint16) =
  let mode = serial.sio_mode()

  # Check if Start bit (bit 7) was just set
  let start_rising = not bit(old_val, 7) and bit(serial.siocnt, 7)
  if start_rising:
    serial.driver.sio_start(serial, mode)

proc notify_mode_change(serial: Serial; old_mode: SioMode) =
  let new_mode = serial.sio_mode()
  if new_mode != old_mode:
    serial.driver.sio_mode_changed(serial, old_mode, new_mode)

# --- JOYCNT write behavior ---
# Bits 0-2: write-1-to-acknowledge (writing 1 clears the flag)
# Bit 6: IRQ enable (normal R/W)
# All other bits: unused, read as 0

proc write_joycnt(serial: Serial; value: uint8; byte_num: uint32) =
  if byte_num == 0:
    # Bits 0-2: acknowledge on write-1 (clear those bits)
    let ack_bits = value and 0x07'u8
    serial.joycnt = serial.joycnt and not uint16(ack_bits)
    # Bit 6: writable
    serial.joycnt = (serial.joycnt and not 0x0040'u16) or (uint16(value) and 0x0040'u16)
  # High byte: ignored (no writable bits)

# --- Read operator ---

proc `[]`*(serial: Serial; io_addr: uint32): uint8 =
  case io_addr
  of 0x120..0x123:
    # SIODATA32 / SIOMULTI0-1: readable in Normal 32-bit mode (transfer
    # data) and Multi mode (receive latches, driver-filled)
    let mode = serial.sio_mode()
    if mode == smNormal32:
      let shift = 8 * (io_addr - 0x120)
      uint8(serial.siodata32 shr shift)
    elif mode == smMulti:
      read(serial.multi_recv[(io_addr - 0x120) div 2], io_addr and 1)
    else:
      0'u8
  of 0x124..0x125:
    # SIOMULTI2: receive-only; latch readable in Multi mode
    if serial.sio_mode() == smMulti: read(serial.multi_recv[2], io_addr and 1)
    else: 0'u8
  of 0x126..0x127:
    # SIOMULTI3: receive-only; latch readable in Multi mode
    if serial.sio_mode() == smMulti: read(serial.multi_recv[3], io_addr and 1)
    else: 0'u8
  of 0x128..0x129: read(serial.read_siocnt(), io_addr and 1)
  of 0x12A..0x12B:
    # SIODATA8 / SIOMLT_SEND: readable in all modes except UART
    let mode = serial.sio_mode()
    if mode == smUart:
      0'u8
    else:
      read(serial.siodata8, io_addr and 1)
  of 0x134..0x135: read(serial.read_rcnt(), io_addr and 1)
  of 0x136..0x139: 0'u8
  of 0x140..0x141: read(serial.joycnt, io_addr and 1)
  of 0x142..0x14F: 0'u8
  of 0x150..0x153: 0'u8  # JOY_RECV: not CPU-readable (protocol-filled)
  of 0x154..0x157: 0'u8  # JOY_TRANS: reads 0 (written by CPU, read by external)
  of 0x158..0x159: read(serial.joystat, io_addr and 1)
  of 0x15A..0x15B: 0'u8
  else: 0'u8

# --- Write operator ---

proc `[]=`*(serial: Serial; io_addr: uint32; value: uint8) =
  case io_addr
  of 0x120..0x123:
    # SIODATA32 / SIOMULTI0-1: writable (stored regardless of mode)
    let shift = 8 * (io_addr - 0x120)
    let mask = not(0xFF'u32 shl shift)
    serial.siodata32 = (serial.siodata32 and mask) or (uint32(value) shl shift)
  of 0x124..0x125: write(serial.siomulti2, value, io_addr and 1)
  of 0x126..0x127: write(serial.siomulti3, value, io_addr and 1)
  of 0x128..0x129:
    let old_val = serial.siocnt
    let old_mode = serial.sio_mode()
    write(serial.siocnt, value, io_addr and 1)
    serial.notify_mode_change(old_mode)
    write_siocnt(serial, old_val)
  of 0x12A..0x12B: write(serial.siodata8, value, io_addr and 1)
  of 0x134..0x135:
    let old_mode = serial.sio_mode()
    write(serial.rcnt, value, io_addr and 1)
    serial.notify_mode_change(old_mode)
  of 0x136..0x139: discard
  of 0x140..0x141: write_joycnt(serial, value, io_addr and 1)
  of 0x142..0x14F: discard
  of 0x150..0x153: discard  # JOY_RECV: written by protocol, not CPU
  of 0x154..0x157:
    # JOY_TRANS: CPU-writable (data to send to external device)
    let shift = 8 * (io_addr - 0x154)
    let mask = not(0xFF'u32 shl shift)
    serial.joy_trans = (serial.joy_trans and mask) or (uint32(value) shl shift)
  of 0x158..0x159:
    # JOYSTAT: only bits 4-5 (general purpose) are CPU-writable
    if (io_addr and 1) == 0:
      serial.joystat = (serial.joystat and not 0x0030'u16) or (uint16(value) and 0x0030'u16)
    # High byte: no writable bits
  of 0x15A..0x15B: discard
  else: discard
