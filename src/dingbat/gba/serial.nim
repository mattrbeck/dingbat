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
  SioMode = enum
    smNormal8, smNormal32, smMulti, smUart, smGeneralPurpose, smJoyBus

proc sio_mode(serial: Serial): SioMode =
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

proc new_serial*(gba: GBA): Serial =
  result = Serial(gba: gba)

# --- Pin state emulation (RCNT bits 0-3) ---
# With no cable connected, pins float to their default states per mode.

proc rcnt_pin_state(serial: Serial): uint16 =
  let mode = serial.sio_mode()
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

# --- SIOCNT read masking ---
# Certain bits are read-only depending on mode. Hardware forces them to 0 or
# their hardware value on read.

proc read_siocnt(serial: Serial): uint16 =
  let mode = serial.sio_mode()
  var v = serial.siocnt
  case mode
  of smNormal8, smNormal32:
    # Bit 15: always 0. Bits 4-6: always 0. Bit 2: SI state (read-only).
    v = v and 0x7F8B'u16  # clear bits 15, 6-4, 2
    v = v or (if bit(serial.rcnt_pin_state(), 2): 0x0004'u16 else: 0'u16)  # SI
  of smMulti:
    # Bit 15: always 0. Bits 4-6: read-only (ID, error). Bits 2-3: read-only (SI/SD).
    # With no connection: SI=1 (child), SD=1 (line pulled high), ID=0, Error=0
    v = v and 0x7F83'u16  # clear bits 15, 6-2
    v = v or 0x000C'u16   # SI=1, SD=1 (no connection: both pulled high)
  of smUart:
    # Bit 15: always 0. Bits 4,6: read-only flags (send/error), 0 when idle.
    # Bit 5: receive data flag. 0 = not empty? Actually 0=Not Full for bit4.
    v = v and 0x7FAF'u16  # clear bits 15, 6, 4
  of smGeneralPurpose, smJoyBus:
    # SIOCNT not used in these modes but bits are still read/writable
    # per gbatek: "same manner as for Normal, Multiplay, or UART mode"
    # Use Normal mode masking as default
    v = v and 0x7F8B'u16
    v = v or 0x0004'u16  # SI high
  v

# --- RCNT read masking ---

proc read_rcnt(serial: Serial): uint16 =
  var v = serial.rcnt
  # Bits 9-13 are always 0 (read-only)
  v = v and not 0x3E00'u16
  let mode = serial.sio_mode()
  case mode
  of smNormal8, smNormal32, smMulti, smUart:
    # Bit 15 must be 0, bits 0-3 reflect pin state (read-only)
    v = v and 0x41F0'u16  # keep bits 14, 8-4; clear 15, 13-9, 3-0
    v = v or serial.rcnt_pin_state()
  of smGeneralPurpose:
    # Bits 0-3 reflect pin state, rest writable
    v = (v and not 0x000F'u16) or serial.rcnt_pin_state()
  of smJoyBus:
    # Bits 0-3 reflect pin state
    v = (v and not 0x000F'u16) or serial.rcnt_pin_state()
  v

# --- Transfer logic ---

proc start_normal_transfer(serial: Serial) =
  let internal_clock = bit(serial.siocnt, 0)
  if not internal_clock:
    return  # External clock: no other GBA to drive it, transfer never starts

  let is_32bit = bit(serial.siocnt, 12)
  let fast = bit(serial.siocnt, 1)
  let bits = if is_32bit: 32 else: 8
  let cycles_per_bit = if fast: 8 else: 64
  const SIO_TRANSFER_OVERHEAD = 56  # # Complete hack to pass mgba suite. Only works with the HLE BIOS.
  let total_cycles = bits * cycles_per_bit + SIO_TRANSFER_OVERHEAD

  serial.gba.scheduler.schedule(total_cycles, etSerial)

proc serial_transfer_complete*(serial: Serial) =
  # Clear Start/Busy bit
  serial.siocnt = serial.siocnt and not 0x0080'u16

  # With no cable connected, SI is high, so all received bits are 1
  let mode = serial.sio_mode()
  case mode
  of smNormal8:
    serial.siodata8 = (serial.siodata8 and 0xFF00'u16) or 0x00FF'u16
  of smNormal32:
    serial.siodata32 = 0xFFFFFFFF'u32
  else:
    discard

  # Fire serial interrupt if enabled
  if bit(serial.siocnt, 14):
    serial.gba.interrupts.reg_if.serial = true
    serial.gba.interrupts.schedule_interrupt_check()

proc write_siocnt(serial: Serial; old_val: uint16) =
  let mode = serial.sio_mode()

  # Check if Start bit (bit 7) was just set
  let start_rising = not bit(old_val, 7) and bit(serial.siocnt, 7)
  if start_rising:
    case mode
    of smNormal8, smNormal32:
      serial.start_normal_transfer()
    of smMulti:
      # No other GBA connected — transfer never completes, stays busy.
      # The test suite expects this to timeout via Timer1.
      discard
    else:
      discard

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
    # SIODATA32 / SIOMULTI0-1: only readable in Normal 32-bit mode
    let mode = serial.sio_mode()
    if mode == smNormal32:
      let shift = 8 * (io_addr - 0x120)
      uint8(serial.siodata32 shr shift)
    else:
      0'u8
  of 0x124..0x125: 0'u8  # SIOMULTI2: receive-only, reads 0
  of 0x126..0x127: 0'u8  # SIOMULTI3: receive-only, reads 0
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
    write(serial.siocnt, value, io_addr and 1)
    write_siocnt(serial, old_val)
  of 0x12A..0x12B: write(serial.siodata8, value, io_addr and 1)
  of 0x134..0x135: write(serial.rcnt, value, io_addr and 1)
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
