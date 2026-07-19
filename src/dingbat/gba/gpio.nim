# GPIO implementation (included by gba.nim)

proc new_gpio*(gba: GBA): GPIO =
  result = GPIO(
    gba: gba,
    data: 0,
    direction: 0,
    allow_reads: false,
    rtc: new_rtc(gba),
  )

proc address_in_gpio*(address: uint32): bool =
  address >= 0x080000C4'u32 and address <= 0x080000C9'u32

proc gpio_rumble*(gpio: GPIO): bool =
  ## Cart rumble motor state. Rumble carts (Drill Dozer, WarioWare: Twisted!)
  ## wire the motor to GPIO bit 3: on while the game drives it high as an
  ## output. RTC uses bits 0-2 and the Boktai solar sensor reads bit 3 as an
  ## INPUT, so an output-high bit 3 uniquely means a rumble motor running.
  (gpio.direction and 0x8'u8) != 0 and (gpio.data and 0x8'u8) != 0

proc `[]`*(gpio: GPIO; io_addr: uint32): uint8 =
  case io_addr and 0xFF'u32
  of 0xC4:  # IO Port Data
    if gpio.allow_reads:
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
    rtc_write(gpio.rtc, masked)
  of 0xC6:  # IO Port Direction
    gpio.direction = value and 0x0F'u8
  of 0xC8:  # IO Port Control
    gpio.allow_reads = bit(value, 0)
  else: discard
