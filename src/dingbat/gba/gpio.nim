# GPIO implementation (included by gba.nim)

const SOLAR_DARK* = 0xE8'u8  # sensor light level with no sunlight

proc new_gpio*(gba: GBA): GPIO =
  result = GPIO(
    gba: gba,
    data: 0,
    direction: 0,
    allow_reads: false,
    rtc: new_rtc(gba),
  )
  # Gyro carts (WarioWare: Twisted!, game codes from its ROM headers) have
  # no RTC; letting gyro clock edges walk the RTC state machine on the
  # shared pins would fabricate phantom RTC commands.
  result.gyro_present = gba.cartridge != nil and
    gba.cartridge.game_code() in ["RZWE", "RZWJ", "RZWP"]
  result.solar_present = gba.cartridge != nil and
    gba.cartridge.game_code()[0 .. 2] in ["U3I", "U32", "U33"]
  result.solar_level = SOLAR_DARK
  # An RTC cart's clock persists in its battery file (rtc_calendar.nim): the
  # trailer read with the save resumes it, and every save write refreshes it.
  let st = gba.storage
  if st != nil and st.rtc_cart and not result.gyro_present:
    st.rtc = result.rtc
    if st.has_trailer:
      discard result.rtc.rtc_apply_trailer(st.trailer)

proc solar_update(gpio: GPIO; pins: uint8) =
  ## Reset (bit 1) clears the counter; each rising clock (bit 0) counts up,
  ## saturating. The chip-select bit is not modelled: the game resets the
  ## counter before every measurement, so RTC traffic on the shared clock
  ## line cannot reach a reading.
  if (pins and 2'u8) != 0:
    gpio.solar_counter = 0
  let clock = (pins and 1'u8) != 0
  if clock and not gpio.solar_clock and gpio.solar_counter < 0xFF'u8:
    inc gpio.solar_counter
  gpio.solar_clock = clock

proc solar_flag(gpio: GPIO): uint8 =
  if gpio.solar_counter >= gpio.solar_level: 0x8'u8 else: 0'u8

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
      elif gpio.solar_present and (gpio.direction and 0x8'u8) == 0:
        (rtc_read(gpio.rtc) and 0x7'u8) or gpio.solar_flag()
      else:
        rtc_read(gpio.rtc) and 0xF'u8
    else:
      0'u8
  of 0xC6:  # IO Port Direction
    gpio.direction and 0xF'u8
  of 0xC8:  # IO Port Control
    if gpio.allow_reads: 1'u8 else: 0'u8
  else: 0'u8

proc drive_pins(gpio: GPIO; prev: uint8) =
  ## Hand the port's output levels to the device on the pins. An input bit
  ## is not driven by the port; the device sees it low (Assumed; SIO, the
  ## only input the RTC protocol uses, is ignored while the chip drives it).
  let pins = gpio.data and gpio.direction
  if gpio.gyro_present:
    gyro_update(gpio, pins)
  else:
    rtc_write(gpio.rtc, pins, prev)
    if gpio.solar_present:
      solar_update(gpio, pins)

proc `[]=`*(gpio: GPIO; io_addr: uint32; value: uint8) =
  case io_addr and 0xFF'u32
  of 0xC4:  # IO Port Data
    # The data register latches every bit written, and a bit drives its pin
    # while its direction is Out. Assumed from Nintendo's RTC library, which
    # on every transaction writes SCK high, then SCK|CS, and only THEN sets
    # the direction to output; the first transaction after power-on (the
    # direction resets to all-In) is its status probe. Masking the write by
    # the direction loses that probe: Sennen Kazoku's copy of the library
    # then reads status 00h and resets the clock at every boot, which a
    # clock game on a real cart cannot be doing.
    let prev = gpio.data and gpio.direction
    gpio.data = value and 0xF'u8
    gpio.drive_pins(prev)
  of 0xC6:  # IO Port Direction
    let prev = gpio.data and gpio.direction
    gpio.direction = value and 0x0F'u8
    if (gpio.data and gpio.direction) != prev:
      gpio.drive_pins(prev)
  of 0xC8:  # IO Port Control
    gpio.allow_reads = bit(value, 0)
  else: discard
