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

when defined(linkTrace):
  # Trade-repro harness hook: fires on a full SIOCNT write with old/new value.
  var onSiocntWrite*: proc(gba: GBA; oldv, newv: uint16) = nil

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
# A driver models whatever is plugged into the link port; it is consulted
# only on SIO register access and transfer completion.
#
#  - sio_start: SIOCNT start-bit rising edge. The driver decides when and
#    with what data the transfer completes: schedule it
#    (schedule_sio_completion -> etSerial -> sio_complete) or, for
#    out-of-process transports, leave busy set and call finish_sio_transfer
#    when the peer responds. Doing nothing models a transfer that never
#    completes.
#  - sio_complete: the etSerial event fired; fill the receive registers,
#    then call finish_sio_transfer.
#  - sio_pin_state: SC/SD/SI/SO levels (RCNT bits 0-3); games probe these in
#    general-purpose mode as a "cable present?" check.
#  - sio_siocnt_status: mode-dependent read-only SIOCNT bits; read_siocnt
#    masks the result to the bits the mode exposes.
#  - sio_mode_changed / sio_attached / sio_detached: cable attach/detach.
#
# The base methods implement the no-cable behaviour (mGBA suite SIO register
# R/W tests). In-flight transfer state lives in Serial; drivers are never
# serialized.

type
  NullSioDriver* = ref object of SioDriver
    ## No cable; all behaviour comes from the base methods.

  LoopbackSioDriver* = ref object of SioDriver
    ## Loopback plug, SO -> SI. Normal mode receives the data registers
    ## unchanged; multi mode sees a 1-unit bus (SIOMLT_SEND -> SIOMULTI0,
    ## other slots 0xFFFF).

# --- Helpers for drivers ---

proc normal_transfer_cycles*(serial: Serial): int =
  ## Cycles from the start write to completion of an internally-clocked
  ## normal-mode transfer.
  let is_32bit = bit(serial.siocnt, 12)
  let fast = bit(serial.siocnt, 1)
  let bits = if is_32bit: 32 else: 8
  let cycles_per_bit = if fast: 8 else: 64
  # Start-up overhead before the first shifted bit; pinned by the mGBA suite
  # SIO timing tests (which shift uniformly when CPU cycle accounting changes).
  const SIO_TRANSFER_OVERHEAD = 8
  bits * cycles_per_bit + SIO_TRANSFER_OVERHEAD

proc multi_transfer_cycles*(serial: Serial): int =
  ## Duration of a multi-mode round: 16 bits at the SIOCNT baud selection.
  let cycles_per_bit = case serial.siocnt and 3
    of 0: 1748  # 16.78 MHz / 9600
    of 1: 437   # / 38400
    of 2: 291   # / 57600
    else: 146   # / 115200
  16 * cycles_per_bit

proc schedule_sio_completion*(serial: Serial; cycles: int) =
  ## etSerial `cycles` from now dispatches to the driver's sio_complete.
  serial.gba.scheduler.schedule(cycles, etSerial)

proc finish_sio_transfer*(serial: Serial) =
  ## Clear Start/Busy and raise the serial IRQ if enabled. Drivers fill the
  ## receive registers before calling this.
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
  ## SC/SD/SI/SO pin levels (RCNT bits 0-3) with no cable connected.
  case mode
  of smNormal8, smNormal32:
    let so = if bit(serial.siocnt, 3): 1'u16 else: 0'u16
    0x05'u16 or (so shl 3)  # SC=1, SD=0, SI=1 (pull-up), SO=SIOCNT.3
  of smMulti, smUart:
    0x0F'u16  # All high during idle
  of smGeneralPurpose:
    # Input pins read high (pull-up); output pins reflect their data bits.
    let dir = (serial.rcnt shr 4) and 0x0F'u16
    let data = serial.rcnt and 0x0F'u16
    (not dir and 0x0F'u16) or (dir and data)
  of smJoyBus:
    0x0C'u16  # SC=0, SD=0, SI=1, SO=1

method sio_siocnt_status*(drv: SioDriver; serial: Serial; mode: SioMode): uint16 {.base.} =
  ## Mode-dependent read-only SIOCNT bits, in position.
  case mode
  of smNormal8, smNormal32:
    if bit(drv.sio_pin_state(serial, mode), 2): 0x0004'u16 else: 0'u16  # SI
  of smMulti:
    # No connection: SI=1 (child), SD=1 (pulled high), ID=0, Error=0
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
    # External clock: nothing drives it, the transfer never starts
  of smMulti:
    discard  # no other unit: stays busy forever (games time out via a timer)
  else:
    discard

method sio_complete*(drv: SioDriver; serial: Serial; mode: SioMode) {.base.} =
  # SI floats high with no cable, so every received bit is 1
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
    let so = if bit(serial.siocnt, 3): 1'u16 else: 0'u16
    0x01'u16 or (so shl 2) or (so shl 3)  # SC=1, SD=0, SI=SO, SO
  of smGeneralPurpose:
    let dir = (serial.rcnt shr 4) and 0x0F'u16
    let data = serial.rcnt and 0x0F'u16
    var pins = (not dir and 0x0F'u16) or (dir and data)
    if bit(dir, 3) and not bit(dir, 2):  # SO driven, SI is an input
      pins = (pins and not 0x4'u16) or ((pins shr 1) and 0x4'u16)  # SI = SO
    pins
  else:
    procCall sio_pin_state(SioDriver(drv), serial, mode)

method sio_siocnt_status*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode): uint16 =
  case mode
  of smMulti:
    0x0008'u16  # SD=1 (1-unit bus all ready), SI=0 (parent), ID=0, Error=0
  else:
    procCall sio_siocnt_status(SioDriver(drv), serial, mode)

method sio_start*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32:
    let internal_clock = bit(serial.siocnt, 0)
    if internal_clock:
      serial.schedule_sio_completion(serial.normal_transfer_cycles())
  of smMulti:
    serial.schedule_sio_completion(serial.multi_transfer_cycles())  # we are parent
  else:
    discard

method sio_complete*(drv: LoopbackSioDriver; serial: Serial; mode: SioMode) =
  case mode
  of smNormal8, smNormal32:
    discard  # own bits clocked back in: data registers unchanged
  of smMulti:
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
  ## Bind a link-cable driver. Drivers are not serialized, so the frontend's
  ## choice survives a save-state load.
  if gba.serial.driver != nil:
    gba.serial.driver.sio_detached(gba.serial)
  gba.serial.driver = drv
  drv.sio_attached(gba.serial)

# --- SIOCNT read masking: per-mode read-only bits come from the driver ---

proc read_siocnt(serial: Serial): uint16 =
  let mode = serial.sio_mode()
  let status = serial.driver.sio_siocnt_status(serial, mode)
  var v = serial.siocnt
  case mode
  of smNormal8, smNormal32:
    v = (v and 0x7F8B'u16) or (status and 0x0004'u16)  # bit 2 SI; 4-6, 15 zero
  of smMulti:
    v = (v and 0x7F83'u16) or (status and 0x007C'u16)  # bits 2-6 SI/SD/ID/err
  of smUart:
    v = (v and 0x7FAF'u16) or (status and 0x0050'u16)  # bits 4, 6 flags
  of smGeneralPurpose, smJoyBus:
    # GBATEK: read/written "same manner as for Normal, Multiplay, or UART
    # mode"; normal-mode masking is used.
    v = (v and 0x7F8B'u16) or (status and 0x0004'u16)
  v

# --- RCNT read masking ---

proc read_rcnt(serial: Serial): uint16 =
  var v = serial.rcnt
  v = v and not 0x3E00'u16  # bits 9-13 always 0
  let mode = serial.sio_mode()
  let pins = serial.driver.sio_pin_state(serial, mode)
  case mode
  of smNormal8, smNormal32, smMulti, smUart:
    v = v and 0x41F0'u16  # keep bits 14, 8-4; bits 0-3 are the pins
    v = v or pins
  of smGeneralPurpose:
    v = (v and not 0x000F'u16) or pins
  of smJoyBus:
    v = (v and not 0x000F'u16) or pins
  v

# --- Transfer logic ---

proc serial_transfer_complete*(serial: Serial) =
  serial.driver.sio_complete(serial, serial.sio_mode())

proc write_siocnt(serial: Serial; old_val: uint16) =
  let mode = serial.sio_mode()

  let start_rising = not bit(old_val, 7) and bit(serial.siocnt, 7)
  if start_rising:
    serial.driver.sio_start(serial, mode)

proc notify_mode_change(serial: Serial; old_mode: SioMode) =
  let new_mode = serial.sio_mode()
  if new_mode != old_mode:
    serial.driver.sio_mode_changed(serial, old_mode, new_mode)

# --- JOYCNT: bits 0-2 write-1-to-acknowledge, bit 6 IRQ enable, rest 0 ---

proc write_joycnt(serial: Serial; value: uint8; byte_num: uint32) =
  if byte_num == 0:
    let ack_bits = value and 0x07'u8
    serial.joycnt = serial.joycnt and not uint16(ack_bits)
    serial.joycnt = (serial.joycnt and not 0x0040'u16) or (uint16(value) and 0x0040'u16)

# --- Read operator ---

proc `[]`*(serial: Serial; io_addr: uint32): uint8 =
  case io_addr
  of 0x120..0x123:
    # SIODATA32 in normal 32-bit mode, SIOMULTI0-1 receive latches in multi
    let mode = serial.sio_mode()
    if mode == smNormal32:
      let shift = 8 * (io_addr - 0x120)
      uint8(serial.siodata32 shr shift)
    elif mode == smMulti:
      read(serial.multi_recv[(io_addr - 0x120) div 2], io_addr and 1)
    else:
      0'u8
  of 0x124..0x125:
    if serial.sio_mode() == smMulti: read(serial.multi_recv[2], io_addr and 1)
    else: 0'u8
  of 0x126..0x127:
    if serial.sio_mode() == smMulti: read(serial.multi_recv[3], io_addr and 1)
    else: 0'u8
  of 0x128..0x129: read(serial.read_siocnt(), io_addr and 1)
  of 0x12A..0x12B:
    # SIODATA8 / SIOMLT_SEND: not readable in UART mode
    let mode = serial.sio_mode()
    if mode == smUart:
      0'u8
    else:
      read(serial.siodata8, io_addr and 1)
  of 0x134..0x135: read(serial.read_rcnt(), io_addr and 1)
  of 0x136..0x139: 0'u8
  of 0x140..0x141: read(serial.joycnt, io_addr and 1)
  of 0x142..0x14F: 0'u8
  of 0x150..0x153: 0'u8  # JOY_RECV: not CPU-readable
  of 0x154..0x157: 0'u8  # JOY_TRANS: write-only from the CPU side
  of 0x158..0x159: read(serial.joystat, io_addr and 1)
  of 0x15A..0x15B: 0'u8
  else: 0'u8

# --- Write operator ---

proc `[]=`*(serial: Serial; io_addr: uint32; value: uint8) =
  case io_addr
  of 0x120..0x123:
    # SIODATA32 / SIOMULTI0-1: stored regardless of mode
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
    when defined(linkTrace):
      if onSiocntWrite != nil and (io_addr and 1) == 1:  # high byte = full write
        onSiocntWrite(serial.gba, old_val, serial.siocnt)
  of 0x12A..0x12B:
    write(serial.siodata8, value, io_addr and 1)
  of 0x134..0x135:
    let old_mode = serial.sio_mode()
    write(serial.rcnt, value, io_addr and 1)
    serial.notify_mode_change(old_mode)
  of 0x136..0x139: discard
  of 0x140..0x141: write_joycnt(serial, value, io_addr and 1)
  of 0x142..0x14F: discard
  of 0x150..0x153: discard  # JOY_RECV: not CPU-writable
  of 0x154..0x157:
    let shift = 8 * (io_addr - 0x154)
    let mask = not(0xFF'u32 shl shift)
    serial.joy_trans = (serial.joy_trans and mask) or (uint32(value) shl shift)
  of 0x158..0x159:
    # JOYSTAT: only bits 4-5 (general purpose) are CPU-writable
    if (io_addr and 1) == 0:
      serial.joystat = (serial.joystat and not 0x0030'u16) or (uint16(value) and 0x0030'u16)
  of 0x15A..0x15B: discard
  else: discard
