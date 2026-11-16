# HuC3 cartridge (included by gb.nim)
#
# Sources: Pan Docs "HuC-3" and the hardware thread it cites
# (https://gbdev.gg8.se/forums/viewtopic.php?id=744).
#
# MBC5-shaped banking (7-bit, bank 0 mappable at 0x4000). The low nibble
# written to 0x0000-0x1FFF picks what 0xA000-0xBFFF decodes to:
#
#   0x0  cart RAM, read-only
#   0xA  cart RAM, read/write
#   0xB  command/argument mailbox      (write)
#   0xC  command/response mailbox      (read)
#   0xD  semaphore                     (read/write)
#   0xE  infrared transceiver
#   any other value: open bus on read, writes dropped
#
# Behind 0xB/0xC/0xD is a 4-bit MCU with a 256-nibble memory: the host writes
# command + argument to 0xB, clears the semaphore, waits for it, and reads the
# answer from 0xC. D7 is not wired, so bit 7 of every read floats high.
#
# Commands run as soon as the semaphore clears and report ready at once (busy
# time not modelled; games poll). The piezo tone generator is not modelled
# (extended command 0xE is dropped). Register map and clock: gb.nim.

proc huc3_exec_extended(cart: Huc3; arg: uint8) =
  ## Command 0x6's argument selects one of the MCU's higher-level operations.
  case arg
  of 0x0:  # copy the running clock into the snapshot registers
    for i in 0 ..< HUC3_CLOCK_LEN:
      cart.regs[HUC3_SNAPSHOT + i] = cart.regs[HUC3_CLOCK + i]
  of 0x1:  # copy the snapshot back onto the running clock
    # The MCU shifts the event deadline by the amount the clock moved, so
    # setting the clock cannot skip a wait.
    let before = cart.huc3_now_minutes()
    for i in 0 ..< HUC3_CLOCK_LEN:
      cart.regs[HUC3_CLOCK + i] = cart.regs[HUC3_SNAPSHOT + i]
    let delta = cart.huc3_now_minutes() - before
    if delta != 0:
      let shifted = cart.nyb3(HUC3_EVENT + 3) * MINUTES_PER_DAY +
                    cart.nyb3(HUC3_EVENT) + delta
      if shifted >= 0:
        cart.set_nyb3(HUC3_EVENT, shifted mod MINUTES_PER_DAY)
        cart.set_nyb3(HUC3_EVENT + 3, (shifted div MINUTES_PER_DAY) mod HUC3_DAY_WRAP)
    cart.ram_dirty = true
  of 0x2:
    # Robot Poncots spins on 0x62 until the response nibble is 1.
    cart.response = 1
  else: discard  # 0xE is the tone generator; the rest are unobserved

proc huc3_execute(cart: Huc3) =
  ## Run whatever is sitting in the mailbox. Command in bits 6-4, argument in
  ## bits 3-0.
  let arg = cart.mailbox and 0x0F
  case (cart.mailbox shr 4) and 0x07
  of 1:  # read the addressed nibble, then step the address on
    cart.response = cart.regs[cart.access_addr]
    cart.access_addr = cart.access_addr + 1   # 8 bits wide: 0xFF wraps to 0
  of 3:  # write the addressed nibble, then step the address on
    cart.regs[cart.access_addr] = arg
    cart.access_addr = cart.access_addr + 1
    cart.ram_dirty = true
  of 4: cart.access_addr = (cart.access_addr and 0xF0) or arg
  of 5: cart.access_addr = (cart.access_addr and 0x0F) or (arg shl 4)
  of 6: cart.huc3_exec_extended(arg)
  else: discard  # 0 and 7 have never been seen; 2 is used by Pocket Family GB2
                 # with argument 0 and nobody has worked out what it does

proc huc3_window_read(cart: Huc3; idx: int): uint8 =
  # A12-A0 do not reach the chip: the window aliases one register.
  case cart.mode
  of 0x0C:
    # Bit 7 floats high, bits 6-4 read back the command still in the mailbox,
    # bits 3-0 are the answer the last executed command left.
    0x80'u8 or (cart.mailbox and 0x70) or (cart.response and 0x0F)
  of 0x0D:
    # Bit 0 is the semaphore (set = MCU ready); bits 6-2 are the mailbox
    # showing through (endrift, on hardware).
    0x80'u8 or (cart.mailbox and 0x7C) or 1'u8
  of 0x0E: 0xC0'u8  # IR, as HuC1: no light seen, and nothing here to see it from
  of 0x00, 0x0A:
    if cart.ram.len > 0:
      cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)]
    else: 0xFF'u8
  else: 0xFF'u8   # 0xB is write-only, and every other mode reads back open bus

proc huc3_window_write(cart: Huc3; val: uint8): bool =
  ## True when the write went to the MCU interface rather than to cart RAM.
  case cart.mode
  of 0x0B:
    cart.mailbox = val and 0x7F  # D7 is not connected
    true
  of 0x0C: true   # response mailbox: read-only
  of 0x0D:
    # Clearing the semaphore requests execution; setting it is the MCU's job.
    if (val and 1) == 0: cart.huc3_execute()
    true
  of 0x0E:
    cart.cart_ir = (val and 1) != 0
    true
  else: false     # 0xA falls through to RAM; 0 and the rest drop the write

method mbc_rom_map*(cart: Huc3): (int, int) =
  (0, mbc_rom_bank_offset(cart, int(cart.rom_bank_num)))

method mbc_read*(cart: Huc3; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    # Bank 0 is mappable here, as on MBC5
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF: huc3_window_read(cart, idx)
  else: 0xFF'u8

method mbc_write*(cart: Huc3; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    let m = val and 0x0F
    # Steering the window off RAM is this mapper's RAM disable: flush here.
    if cart.mode == 0x0A and m != 0x0A: mbc_save(cart)
    cart.mode = m
  of 0x2000..0x3FFF: cart.rom_bank_num = val and 0x7F
  of 0x4000..0x5FFF: cart.ram_bank_num = val  # width undocumented; the shared
                                              # helper wraps it to the RAM size
  of 0x6000..0x7FFF: discard  # games write 0x01 here at boot; it does nothing
  of 0xA000..0xBFFF:
    if huc3_window_write(cart, val): return
    if cart.mode == 0x0A and cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)] = val
  else: discard
