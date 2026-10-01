## ARM7 SPI hub: SPICNT 0x40001C0, SPIDATA 0x40001C2 (GBATEK "DS Serial
## Peripheral Interface Bus (SPI)"). Three devices behind one chip select:
## power manager (0), firmware flash (1), touchscreen controller (2).
##
## Writing SPIDATA starts a transfer: the busy flag (bit 7) reads set for the
## 8 bits' time (16 in the "bugged" 16-bit mode, bit 10) at the baud rate
## (bits 0-1); at the end the reply appears in SPIDATA, the chip select drops
## unless bit 11 holds it, and IF.23 is raised if bit 14 is set. The device
## answers the byte at its start; only what the CPU sees waits for the end.

import irq, input, mic
import ../sched

type
  FlashState = enum fsIdle, fsAddr, fsRead, fsWrite, fsErase, fsStatus, fsId, fsOther

  Spi* = ref object
    cnt*: uint16
    data_out*: uint8
    firmware*: seq[uint8]     ## 256 KB image (real dump or synthesized)
    # transfer
    pending: uint8            ## reply shown in SPIDATA when the transfer ends
    busy_until: int64
    hold_at_start: bool       ## SPICNT.11 when the transfer started
    in_flight: bool           ## a transfer has not delivered its end yet
    sched* {.cursor.}: NdsScheduler  ## for the busy time (nil: no time passes)
    # flash
    fstate: FlashState
    faddr: uint32
    faddr_bytes: int
    fid_idx: int
    fcmd: uint8               ## command whose address is being received
    fwrote: bool              ## a page write/program received data bytes
    write_enable: bool
    wip_until: int64          ## write/erase in progress until this cycle
    deep_power_down: bool
    # touchscreen
    tsc_value: uint16        ## 12-bit result being shifted out
    tsc_byte: int
    tsc_8bit: bool
    mic*: Mic
    # power manager
    pm_ctrl*: uint8          ## register 0: amp, mute, backlights, LED, power
    pm_lite*: bool           ## DS-Lite device: register 4 exists, no mute bit
    battery_low*: bool       ## register 1 bit 0 (the frontend sets it)
    ext_power*: bool         ## register 4 bit 3, DS-Lite (the frontend sets it)
    mic_amp*, mic_gain*: uint8   ## registers 2 and 3
    bl_level*: uint8         ## register 4 bits 0-1
    bl_force_max: bool       ## register 4 bit 2
    power_off*: bool         ## register 0 bit 6 was written: the DS is off
    pm_index: int            ## -1 = expecting index byte
    irq* {.cursor.}: IrqCtl
    input* {.cursor.}: Input
    selected: int            ## device held by chip select, -1 = none

const
  # Firmware flash busy times, GBATEK "DS Firmware Serial Flash Memory"
  # (typical figures): page write 11 ms, page program 1.2 ms, page erase
  # 10 ms, sector erase 1 s.
  FLASH_PW_CYCLES = MASTER_HZ * 11 div 1000
  FLASH_PP_CYCLES = MASTER_HZ * 12 div 10000
  FLASH_PE_CYCLES = MASTER_HZ * 10 div 1000
  FLASH_SE_CYCLES = MASTER_HZ
  # TSC2046 temperature diodes (TI datasheet SBAS265G, "Temperature
  # Measurement"): TEMP0 typically 600 mV at 25 C; TEMP1 - TEMP0 = T / 2.573
  # mV with T in kelvin. With the DS's 3.33 V reference (GBATEK) that is
  # 738 and 881 in 12 bits at 25 C (Assumed room temperature).
  TSC_TEMP0 = 738'u16
  TSC_TEMP1 = 881'u16
  # Touch pressure: plate and contact resistances in ohms, Assumed (GBATEK
  # gives the formulas, not the DS panel's values).
  PLATE_X = 400
  PLATE_Y = 400
  R_TOUCH = 1000

proc new_spi*(firmware: seq[uint8]; irq: IrqCtl; input: Input): Spi =
  result = Spi(firmware: firmware, irq: irq, input: input, selected: -1, pm_index: -1)
  result.pm_ctrl = 0x0D  # sound amp, both backlights
  if result.firmware.len < 256 * 1024: result.firmware.setLen(256 * 1024)
  # Firmware header 0x1D, console type (GBATEK "DS Firmware Header"):
  # 20h DS-Lite, 63h iQue DS-Lite, 57h DSi -- the power managers with
  # register 4 (GBATEK "DS Power Management Device").
  result.pm_lite = result.firmware[0x1D] in [0x20'u8, 0x63, 0x57]
  result.mic = new_mic(nil)

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

proc set_sched*(s: Spi; sched: NdsScheduler) =
  s.sched = sched
  s.mic = new_mic(sched)
  # DS-Lite backlight level as the firmware leaves it: user settings 0x64
  # bits 4-5 (GBATEK "DS Firmware User Settings"); that the boot applies it
  # is Assumed.
  s.bl_level = (s.firmware[s.user_settings() + 0x64] shr 4) and 3

proc now(s: Spi): int64 {.inline.} = (if s.sched != nil: s.sched.now else: 0)

# --- touchscreen controller -------------------------------------------------

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
    # The centre of pixel p's ADC span, the calibration points' screen
    # values taken as pixel numbers: libnds/calico's conversion lands on p
    # (touch_test reads 128,96 for a touch at 128,96). GBATEK's formula,
    # with its (scr1 - 1) term, lands half a pixel lower: p - 1 truncated.
    if s2 == s1: return a1
    a1 + ((2 * (p - s1) + 1) * (a2 - a1)) div (2 * (s2 - s1))
  let v = if channel == 5: lerp(s.input.touch_x, scr_x1, scr_x2, adc_x1, adc_x2)
          else: lerp(s.input.touch_y, scr_y1, scr_y2, adc_y1, adc_y2)
  uint16(clamp(v, 0, 0xFFF))

proc touch_z(s: Spi; channel: int): uint16 =
  ## Z1 (3) / Z2 (4), GBATEK "Touchscreen Pressure": Y+ at VREF, X- at
  ## ground; Z1 reads the X plate at the contact, Z2 the Y plate. Released,
  ## the X plate sits at ground and the Y plate floats up to VREF.
  if not s.input.touching:
    return if channel == 3: 0'u16 else: 0xFFF'u16
  let rx = int64(PLATE_X) * int64(s.touch_adc(5))            # x 4096
  let ry = int64(PLATE_Y) * int64(4096 - int(s.touch_adc(1)))
  let rt = int64(R_TOUCH) * 4096
  let total = rx + ry + rt
  let v = if channel == 3: 4096 * rx div total else: 4096 * (rx + rt) div total
  uint16(clamp(v, 0, 0xFFF))

proc mic_adc(s: Spi): uint16 =
  ## AUX = microphone amplifier output: mid-scale is silence. Full-scale
  ## input reaches full scale at gain 160 and half as far per step down
  ## (Assumed); with the amplifier off it reads mid-scale (Assumed).
  if (s.mic_amp and 1) == 0: return 0x800
  let v = 0x800 + (s.mic.sample() shl int(s.mic_gain and 3)) div 128
  uint16(clamp(v, 0, 0xFFF))

proc tsc_convert(s: Spi; control: uint8): uint16 =
  ## GBATEK "DS Touch Screen Controller (TSC)" channels. In differential
  ## mode (bit 2 = 0) only X, Y, Z1, Z2 exist; the others read 0 (Assumed).
  let channel = int((control shr 4) and 7)
  let single = (control and 4) != 0
  case channel
  of 1, 5: s.touch_adc(channel)
  of 3, 4: s.touch_z(channel)
  of 0: (if single: TSC_TEMP0 else: 0'u16)
  of 7: (if single: TSC_TEMP1 else: 0'u16)
  of 6: (if single: s.mic_adc() else: 0'u16)
  else: 0'u16   # 2: battery input, grounded on the DS

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
    var r = s.tsc_convert(v)
    s.tsc_8bit = (v and 8) != 0
    if s.tsc_8bit: r = r shr 4
    s.tsc_value = r
    s.tsc_byte = 1
    # power-down bits 0-1: /PENIRQ is enabled in modes 0 and 2 (GBATEK
    # "Power Down Mode"); EXTKEYIN bit 6 is that pin
    s.input.penirq_enabled = (v and 1) == 0

# --- firmware flash -----------------------------------------------------------

proc flash_erase(s: Spi; a: uint32; size: uint32) =
  let base = int(a and not (size - 1) and 0x3FFFF)
  for i in 0 ..< int(size): s.firmware[base + i] = 0xFF

proc flash_busy(s: Spi): bool {.inline.} = s.now() < s.wip_until

proc flash_byte(s: Spi; v: uint8): uint8 =
  ## ST M45PE20 (GBATEK "DS Firmware Serial Flash Memory"): commands MSB
  ## first, 3 address bytes, data streams while chip select is held. A page
  ## write/program or erase runs when chip select drops; while it runs
  ## (status bit 0, WIP) every command but RDSR is ignored. Deep power-down
  ## ignores everything but its release.
  case s.fstate
  of fsIdle:
    if s.deep_power_down:
      if v == 0xAB: s.deep_power_down = false
      s.fstate = fsOther
      return 0
    if s.flash_busy() and v != 0x05:
      s.fstate = fsOther
      return 0
    case v
    of 0x03, 0x0B, 0x0A, 0x02, 0xDB, 0xD8:
      s.fstate = fsAddr; s.faddr = 0; s.faddr_bytes = 0; s.fcmd = v
      s.fid_idx = if v == 0x0B: 1 else: 0   # fast read: one dummy byte
      s.fwrote = false
    of 0x05: s.fstate = fsStatus
    of 0x9F: s.fstate = fsId; s.fid_idx = 0
    of 0x06: s.write_enable = true
    of 0x04: s.write_enable = false
    of 0xB9: s.deep_power_down = true; s.fstate = fsOther
    else: s.fstate = fsOther  # release from deep power-down: no reply
  of fsAddr:
    s.faddr = (s.faddr shl 8) or v
    inc s.faddr_bytes
    if s.faddr_bytes == 3:
      case s.fcmd
      of 0x03, 0x0B: s.fstate = fsRead
      of 0x0A, 0x02: s.fstate = (if s.write_enable: fsWrite else: fsOther)
      of 0xDB, 0xD8: s.fstate = (if s.write_enable: fsErase else: fsOther)
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
    s.fwrote = true
  of fsErase: s.fstate = fsOther   # a byte past the address: not an erase
  of fsStatus:
    # WEL (bit 1) stays set until the write/erase it allowed has finished
    let busy = s.flash_busy()
    result = (if s.write_enable or busy: 2'u8 else: 0'u8) or (if busy: 1'u8 else: 0'u8)
  of fsId:
    const id = [0x20'u8, 0x40, 0x12]
    result = if s.fid_idx < 3: id[s.fid_idx] else: 0
    inc s.fid_idx
  of fsOther: discard

proc flash_deselect(s: Spi) =
  ## Chip select rising: a page write/program or an erase starts.
  case s.fstate
  of fsWrite:
    if s.fwrote:
      s.wip_until = s.now() + (if s.fcmd == 0x0A: FLASH_PW_CYCLES else: FLASH_PP_CYCLES)
    s.write_enable = false
  of fsErase:
    let sector = s.fcmd == 0xD8
    s.flash_erase(s.faddr, if sector: 0x10000'u32 else: 0x100'u32)
    s.wip_until = s.now() + (if sector: FLASH_SE_CYCLES else: FLASH_PE_CYCLES)
    s.write_enable = false
  else: discard
  s.fstate = fsIdle

# --- power manager ------------------------------------------------------------

proc pm_reg(s: Spi; index: int): int =
  ## Old DS: registers 0-3, mirrored through 7Fh. DS-Lite: 0-4, 5-7 mirror
  ## 4, 8-7Fh mirror 0-7 (GBATEK "DS Power Management Device").
  if s.pm_lite: min(index and 7, 4) else: index and 3

proc pm_read(s: Spi; reg: int): uint8 =
  case reg
  of 0: s.pm_ctrl and (if s.pm_lite: 0x7D'u8 else: 0x7F'u8)   # Lite: no mute bit
  of 1: (if s.battery_low: 1'u8 else: 0'u8)
  of 2: s.mic_amp and 1
  of 3: s.mic_gain and 3
  else:
    # register 4: bits 4-7 read 4; forced maximum on external power reads 3
    let level = if s.bl_force_max and s.ext_power: 3'u8 else: s.bl_level
    0x40'u8 or level or (if s.bl_force_max: 4'u8 else: 0'u8) or
      (if s.ext_power: 8'u8 else: 0'u8)

proc pm_write(s: Spi; reg: int; v: uint8) =
  case reg
  of 0:
    s.pm_ctrl = v and 0x7F
    if (v and 0x40) != 0: s.power_off = true
  of 1: discard   # battery status is read-only
  of 2: s.mic_amp = v and 1
  of 3: s.mic_gain = v and 3
  else:
    s.bl_level = v and 3
    s.bl_force_max = (v and 4) != 0

proc pm_byte(s: Spi; v: uint8): uint8 =
  if s.pm_index < 0:
    s.pm_index = int(v)
    return 0
  let reg = s.pm_reg(s.pm_index and 0x7F)
  if (s.pm_index and 0x80) != 0: result = s.pm_read(reg)
  else: s.pm_write(reg, v)
  s.pm_index = -1

proc backlight*(s: Spi; top: bool): bool =
  ## Register 0 bit 3 (upper) / bit 2 (lower) -- the frontend's screens.
  (s.pm_ctrl and (if top: 8'u8 else: 4'u8)) != 0

# --- the bus --------------------------------------------------------------------

proc deselect(s: Spi) =
  if s.selected == 1: s.flash_deselect()
  s.selected = -1

proc device_byte(s: Spi; dev: int; v: uint8): uint8 =
  case dev
  of 0: s.pm_byte(v)
  of 1: s.flash_byte(v)
  of 2: s.tsc_byte_in(v)
  else: 0

proc transfer_end*(s: Spi) =
  ## evSpi: the last bit has moved.
  if not s.in_flight: return
  s.in_flight = false
  s.data_out = s.pending
  if not s.hold_at_start: s.deselect()
  if (s.cnt and 0x4000) != 0: s.irq.raise_irq(irqSpi)

proc busy*(s: Spi): bool =
  ## Busy until the transfer's time is up; an end not yet dispatched as an
  ## event is delivered here, so a read never sees idle with the old reply.
  if s.sched != nil and s.sched.now < s.busy_until: return true
  if s.in_flight: s.transfer_end()

proc write_cnt*(s: Spi; v, mask: uint32) =
  discard s.busy()   # deliver a finished transfer first
  let m = uint16(mask and 0xFFFF)
  s.cnt = (s.cnt and not m) or (uint16(v) and m and 0xCF03)
  if (s.cnt and 0x8000) == 0: s.deselect()

proc write_data*(s: Spi; v: uint8) =
  ## A write while a transfer is running is ignored (Assumed).
  if (s.cnt and 0x8000) == 0 or s.busy(): return
  let dev = int((s.cnt shr 8) and 3)
  if s.selected != dev:
    # chip select edge: reset the device's command state
    if s.selected == 1: s.flash_deselect()
    s.selected = dev
    s.fstate = fsIdle
    s.pm_index = -1
    s.tsc_byte = 0
  s.pending = s.device_byte(dev, v)
  let wide = (s.cnt and 0x400) != 0
  if wide:
    # bugged 16-bit mode: two bytes move (the second sends 0, Assumed) and
    # only the second reply reaches SPIDATA (GBATEK "Notes/Glitches")
    s.pending = s.device_byte(dev, 0)
  s.hold_at_start = (s.cnt and 0x800) != 0
  s.in_flight = true
  if s.sched == nil:
    s.transfer_end()
    return
  const hz = [4_000_000'i64, 2_000_000, 1_000_000, 512 * 1024]
  let bits = if wide: 16'i64 else: 8'i64
  s.busy_until = s.sched.now + (bits * MASTER_HZ + hz[s.cnt and 3] - 1) div hz[s.cnt and 3]
  s.sched.schedule(s.busy_until, evSpi)

proc read_reg*(s: Spi; offset: uint32): uint32 =
  let busy = if s.busy(): 0x80'u32 else: 0
  uint32(s.cnt) or busy or (uint32(s.data_out) shl 16)
