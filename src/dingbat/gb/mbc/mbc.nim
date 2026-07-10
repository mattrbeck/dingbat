# MBC base + factory (included by gb.nim)

method mbc_read*(cart: Mbc; idx: int): uint8 {.base.} = 0xFF'u8
method mbc_write*(cart: Mbc; idx: int; val: uint8) {.base.} = discard

proc load_cartridge*(rom_path: string): Mbc =
  let raw = readFile(rom_path)
  var rom = newSeq[uint8](raw.len)
  for i in 0 ..< raw.len: rom[i] = uint8(raw[i])

  let cart_type = rom[0x0147]
  let has_ram     = (cart_type in [0x02'u8, 0x03, 0x08, 0x09,
                                    0x0C, 0x0D, 0x10, 0x12, 0x13,
                                    0x1A, 0x1B, 0x1D, 0x1E])
  let has_battery = (cart_type in [0x03'u8, 0x06, 0x09, 0x0D, 0x0F,
                                    0x10, 0x13, 0x1B, 0x1E])

  let ram_sz = case rom[0x0149]
    of 0x01: 0x0800
    of 0x02: 0x2000
    of 0x03: 0x2000 * 4
    of 0x04: 0x2000 * 16
    of 0x05: 0x2000 * 8
    else:    0

  let sav_path = rom_path[0 ..< rom_path.rfind('.')] & ".sav"

  var cart: Mbc
  case cart_type
  of 0x00, 0x08, 0x09:
    let c = MbcRom(rom: rom, ram: newSeq[uint8](ram_sz),
                   sav_path: sav_path, has_battery: has_battery)
    cart = c
  of 0x01, 0x02, 0x03:
    let actual_ram = if ram_sz == 0 and has_ram: 0x2000 else: ram_sz
    let c = Mbc1(rom: rom, ram: newSeq[uint8](actual_ram),
                 sav_path: sav_path, has_battery: has_battery,
                 reg1: 1)
    cart = c
  of 0x05, 0x06:
    let c = Mbc2(rom: rom, ram: newSeq[uint8](0x0200),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank: 1)
    cart = c
  of 0x0F, 0x10, 0x11, 0x12, 0x13:
    let c = Mbc3(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1,
                 has_rtc: cart_type in [0x0F'u8, 0x10])
    cart = c
  of 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E:
    let c = Mbc5(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1)
    cart = c
  else:
    echo "Warning: unimplemented cartridge type 0x", toHex(cart_type, 2), ", treating as ROM"
    let c = MbcRom(rom: rom, ram: newSeq[uint8](ram_sz),
                   sav_path: sav_path, has_battery: has_battery)
    cart = c

  mbc_load(cart)
  result = cart
