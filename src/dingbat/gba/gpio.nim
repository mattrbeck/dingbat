# GPIO implementation (included by gba.nim)

proc new_gpio*(gba: GBA): GPIO =
  result = GPIO(
    gba: gba,
    data: 0,
    direction: 0,
    allow_reads: false,
    rtc: new_rtc(gba),
  )
  # Gyro carts have no RTC; letting gyro clock edges walk the RTC state
  # machine on the shared pins would fabricate phantom RTC commands.
  result.gyro_present = gba.cartridge != nil and
    gba.cartridge.game_code() in ["RZWE", "RZWJ", "RZWP"]

proc address_in_gpio*(address: uint32): bool =
  address >= 0x080000C4'u32 and address <= 0x080000C9'u32

proc gpio_rumble*(gpio: GPIO): bool =
  ## Cart rumble motor state. Rumble carts (Drill Dozer, WarioWare: Twisted!)
  ## wire the motor to GPIO bit 3: on while the game drives it high as an
  ## output. RTC uses bits 0-2 and the Boktai solar sensor reads bit 3 as an
  ## INPUT, so an output-high bit 3 uniquely means a rumble motor running.
  (gpio.direction and 0x8'u8) != 0 and (gpio.data and 0x8'u8) != 0

proc gyro_update(gpio: GPIO; pins: uint8) =
  ## GBATEK "GBA Cart Gyro Sensor": bit 0 = start conversion, bit 1 = serial
  ## clock, bit 2 = serial data; "4 dummy bits ... followed by 12 data bits".
  ## Its read loop samples data, drops the clock, then raises it, so it does
  ## not fix the edge: shifting on the FALLING edge is Assumed (WarioWare
  ## Twisted plays; rising-edge shifting halves every reading). Neutral 0x6C0,
  ## ±0x323 ≈ the hard-rotation extremes; 0x000/0xFFF mean "no sensor", hence
  ## the clamp to [1, 0xFFE].
  if (pins and 1'u8) != 0:
    let v = max(1, min(0xFFE, 0x6C0 + int(gpio.gyro_z * float(0x323))))
    gpio.gyro_sample = uint16(v)
  let clock = (pins and 2'u8) != 0
  if gpio.gyro_clock and not clock:
    gpio.gyro_out = uint8((gpio.gyro_sample shr 15) and 1'u16)
    gpio.gyro_sample = gpio.gyro_sample shl 1
  gpio.gyro_clock = clock

proc `[]`*(gpio: GPIO; io_addr: uint32): uint8 =
  case io_addr and 0xFF'u32
  of 0xC4:  # IO Port Data
    if gpio.allow_reads:
      if gpio.gyro_present:
        ((gpio.data and gpio.direction) or (gpio.gyro_out shl 2)) and 0xF'u8
      else:
        rtc_read(gpio.rtc) and 0xF'u8
    else:
      0'u8
  of 0xC6:  # IO Port Direction
    gpio.direction and 0xF'u8
  of 0xC8:  # IO Port Control
    if gpio.allow_reads: 1'u8 else: 0'u8
  else: 0'u8

proc `[]=`*(gpio: GPIO; io_addr: uint32; value: uint8) =
  case io_addr and 0xFF'u32
  of 0xC4:  # IO Port Data
    let masked = (value and gpio.direction and 0xF'u8) or (gpio.data and (not gpio.direction) and 0xF'u8)
    gpio.data = masked
    if gpio.gyro_present:
      gyro_update(gpio, masked)
    else:
      rtc_write(gpio.rtc, masked)
  of 0xC6:  # IO Port Direction
    gpio.direction = value and 0x0F'u8
  of 0xC8:  # IO Port Control
    gpio.allow_reads = bit(value, 0)
  else: discard
