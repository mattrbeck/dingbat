## ARM7 SPI hub: SPICNT 0x40001C0, SPIDATA 0x40001C2. Three devices behind
## one chip select: power manager (0), firmware flash (1), touchscreen
## controller (2). A byte's reply is stored at once; the busy flag (bit 7)
## reads set for the 8 bits' time at the baud rate (bits 0-1), and an IRQ
## (IF.23) is raised if enabled.

import irq, input
import ../sched

type
  FlashState = enum fsIdle, fsAddr, fsRead, fsWrite, fsStatus, fsId, fsOther

  Spi* = ref object
    cnt*: uint16
    data_out*: uint8
    firmware*: seq[uint8]     ## 256 KB image (real dump or synthesized)
    # flash
    fstate: FlashState
    faddr: uint32
    faddr_bytes: int
    fid_idx: int
    fcmd: uint8               ## command whose address is being received
    write_enable: bool
    # touchscreen
    tsc_value: uint16        ## 12-bit result being shifted out
    tsc_byte: int
    tsc_8bit: bool
    # power manager
    pm_regs*: array[8, uint8]
    pm_index: int            ## -1 = expecting index byte
    irq* {.cursor.}: IrqCtl
    input* {.cursor.}: Input
    selected: int            ## device held by chip select, -1 = none
    sched* {.cursor.}: NdsScheduler  ## for the busy time (nil: never busy)
    busy_until: int64

proc new_spi*(firmware: seq[uint8]; irq: IrqCtl; input: Input): Spi =
  result = Spi(firmware: firmware, irq: irq, input: input, selected: -1, pm_index: -1)
  result.pm_regs[0] = 0x0D  # sound amp, both backlights
  if result.firmware.len < 256 * 1024: result.firmware.setLen(256 * 1024)

proc user_settings_offset*(s: Spi): int =
  let o = (int(s.firmware[0x20]) or (int(s.firmware[0x21]) shl 8)) * 8
  if o <= 0 or o + 0x200 > s.firmware.len: 0x3FE00 else: o

proc settings_crc_ok(s: Spi; a: int): bool =
  ## CRC16 (initial FFFFh) of entries 00h..6Fh against entry 72h.
  var crc = 0xFFFF'u16
  for i in a ..< a + 0x70:
    crc = crc xor uint16(s.firmware[i])
    for _ in 0..7:
      crc = if (crc and 1) != 0: (crc shr 1) xor 0xA001'u16 else: crc shr 1
  crc == (uint16(s.firmware[a + 0x72]) or (uint16(s.firmware[a + 0x73]) shl 8))

proc user_settings*(s: Spi): int =
  ## The current user-settings copy (GBATEK "DS Firmware User Settings"):
  ## of two with valid CRCs the one whose update counter (70h) is one more
  ## than the other's; else the one with a valid CRC; neither valid: the
  ## first (Assumed; the firmware would ask for the settings again).
  let a = s.user_settings_offset()
  let b = a + 0x100
  let oka = s.settings_crc_ok(a)
  let okb = s.settings_crc_ok(b)
  if oka != okb: return (if okb: b else: a)
  let ca = int(s.firmware[a + 0x70]) and 0x7F
  let cb = int(s.firmware[b + 0x70]) and 0x7F
  if ((ca + 1) and 0x7F) == cb: b else: a

proc touch_adc(s: Spi; channel: int): uint16 =
  ## Screen position -> ADC via the firmware's two calibration points.
  if not s.input.touching:
    return if channel == 1: 0xFFF'u16 else: 0
  let u = s.user_settings()
  template rd16(o: int): int = int(s.firmware[u + o]) or (int(s.firmware[u + o + 1]) shl 8)
  let adc_x1 = rd16(0x58) and 0xFFF
  let adc_y1 = rd16(0x5A) and 0xFFF
  let scr_x1 = int(s.firmware[u + 0x5C])
  let scr_y1 = int(s.firmware[u + 0x5D])
  let adc_x2 = rd16(0x5E) and 0xFFF
  let adc_y2 = rd16(0x60) and 0xFFF
  let scr_x2 = int(s.firmware[u + 0x62])
  let scr_y2 = int(s.firmware[u + 0x63])
  proc lerp(p, s1, s2, a1, a2: int): int =
    # The centre of pixel p's ADC span, so both the truncating (GBATEK) and
    # the rounding conversions back to pixels land on p.
    if s2 == s1: return a1
    a1 + ((2 * (p - s1) + 1) * (a2 - a1)) div (2 * (s2 - s1))
  let v = if channel == 5: lerp(s.input.touch_x, scr_x1, scr_x2, adc_x1, adc_x2)
          else: lerp(s.input.touch_y, scr_y1, scr_y2, adc_y1, adc_y2)
  uint16(clamp(v, 0, 0xFFF))

proc flash_erase(s: Spi; a: uint32; size: uint32) =
  let base = int(a and not (size - 1) and 0x3FFFF)
  for i in 0 ..< int(size): s.firmware[base + i] = 0xFF

proc flash_byte(s: Spi; v: uint8): uint8 =
  ## ST M45PE20 (GBATEK "DS Firmware Serial Flash Memory"): commands MSB
  ## first, 3 address bytes, data streams while chip select is held. Writes
  ## change the in-memory image only. TODO(spi): write/erase busy time (WIP).
  case s.fstate
  of fsIdle:
    case v
    of 0x03, 0x0B, 0x0A, 0x02, 0xDB, 0xD8:
      s.fstate = fsAddr; s.faddr = 0; s.faddr_bytes = 0; s.fcmd = v
      s.fid_idx = if v == 0x0B: 1 else: 0   # fast read: one dummy byte
    of 0x05: s.fstate = fsStatus
    of 0x9F: s.fstate = fsId; s.fid_idx = 0
    of 0x06: s.write_enable = true
    of 0x04: s.write_enable = false
    else: s.fstate = fsOther  # deep power-down/release: no reply
  of fsAddr:
    s.faddr = (s.faddr shl 8) or v
    inc s.faddr_bytes
    if s.faddr_bytes == 3:
      case s.fcmd
      of 0x03, 0x0B: s.fstate = fsRead
      of 0x0A, 0x02: s.fstate = (if s.write_enable: fsWrite else: fsOther)
      of 0xDB, 0xD8:
        # page / sector erase, on the third address byte
        if s.write_enable:
          s.flash_erase(s.faddr, if s.fcmd == 0xDB: 0x100'u32 else: 0x10000'u32)
          s.write_enable = false
        s.fstate = fsOther
      else: s.fstate = fsOther
  of fsRead:
    if s.fid_idx > 0:
      dec s.fid_idx
      return 0
    result = s.firmware[int(s.faddr and 0x3FFFF)]
    inc s.faddr
  of fsWrite:
    # page write (0A) replaces, page program (02) can only clear bits; both
    # wrap inside the 256-byte page
    let i = int(s.faddr and 0x3FFFF)
    s.firmware[i] = if s.fcmd == 0x02: s.firmware[i] and v else: v
    s.faddr = (s.faddr and not 0xFF'u32) or ((s.faddr + 1) and 0xFF)
  of fsStatus: result = if s.write_enable: 2'u8 else: 0'u8
  of fsId:
    const id = [0x20'u8, 0x40, 0x12]
    result = if s.fid_idx < 3: id[s.fid_idx] else: 0
    inc s.fid_idx
  of fsOther: discard

proc tsc_byte_in(s: Spi; v: uint8): uint8 =
  # Reply: the result of the last control byte, MSB first after one dummy
  # bit, spread over the next two bytes -- 12 bits, or 8 in 8-bit mode
  # (control bit 3).
  let bits = if s.tsc_8bit: 8 else: 12
  result = case s.tsc_byte
    of 1: uint8((s.tsc_value shr (bits - 7)) and 0xFF)
    of 2: uint8((s.tsc_value shl (15 - bits)) and 0xFF)
    else: 0'u8
  inc s.tsc_byte
  if (v and 0x80) != 0:
    let channel = int((v shr 4) and 7)
    var r = case channel
      of 1, 5: s.touch_adc(channel)
      of 6: 0x800'u16   # microphone: silence
      else: 0'u16
    s.tsc_8bit = (v and 8) != 0
    if s.tsc_8bit: r = r shr 4
    s.tsc_value = r
    s.tsc_byte = 1

proc pm_byte(s: Spi; v: uint8): uint8 =
  if s.pm_index < 0:
    s.pm_index = int(v)
    return 0
  let reg = s.pm_index and 7
  let read = (s.pm_index and 0x80) != 0
  if read: result = s.pm_regs[reg and 3]
  else: s.pm_regs[reg and 3] = v
  s.pm_index = -1

proc write_cnt*(s: Spi; v, mask: uint32) =
  let m = uint16(mask and 0xFFFF)
  s.cnt = (s.cnt and not m) or (uint16(v) and m and 0xCF03)
  if (s.cnt and 0x8000) == 0: s.selected = -1

proc write_data*(s: Spi; v: uint8) =
  if (s.cnt and 0x8000) == 0: return
  let dev = int((s.cnt shr 8) and 3)
  if s.selected != dev:
    # chip select edge: reset the device's command state
    s.selected = dev
    s.fstate = fsIdle
    s.pm_index = -1
    s.tsc_byte = 0
  s.data_out = case dev
    of 0: s.pm_byte(v)
    of 1: s.flash_byte(v)
    of 2: s.tsc_byte_in(v)
    else: 0
  if (s.cnt and 0x800) == 0:
    # no hold: deselect; a finished page write/program drops write enable
    if dev == 1 and s.fstate == fsWrite: s.write_enable = false
    s.selected = -1
  if s.sched != nil:
    const hz = [4_000_000'i64, 2_000_000, 1_000_000, 512 * 1024]
    s.busy_until = s.sched.now + (8 * MASTER_HZ + hz[s.cnt and 3] - 1) div hz[s.cnt and 3]
  if (s.cnt and 0x4000) != 0: s.irq.raise_irq(irqSpi)

proc read_reg*(s: Spi; offset: uint32): uint32 =
  let busy = if s.sched != nil and s.sched.now < s.busy_until: 0x80'u32 else: 0
  uint32(s.cnt) or busy or (uint32(s.data_out) shl 16)
