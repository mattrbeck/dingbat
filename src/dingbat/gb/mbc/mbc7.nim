# MBC7 cartridge (included by gb.nim)
#
# Cart type $22: Kirby Tilt 'n' Tumble, Command Master. Written from two
# documents and nothing else:
#   * Pan Docs, "MBC7": the register map, the two RAM-enable gates, the
#     accelerometer latch protocol and the EEPROM pin register at Ax8x.
#   * Microchip DS21794F (93AA56/93LC56/93C56, "2K Microwire Compatible
#     Serial EEPROM"): Table 1-3 (instruction set, x16 organisation), 2.1
#     (Start condition), 2.4-2.9 (Erase/ERAL/EWDS/EWEN/Read/Write/WRAL),
#     3.1-3.4 (pin behaviour, Ready/Busy status).
#
# There is no cartridge RAM. $A000-$AFFF is a register file (Pan Docs:
# "Registers are addressed through bits 4-7 of the address. Bits 0-3 and 8-11
# are ignored") in front of a two-axis accelerometer and the four serial pins
# of the EEPROM. The EEPROM is what the battery backs: 128 x 16-bit words
# (Pan Docs: "data is addressed 16 bits at a time, so address 1 corresponds to
# bits 16-31, thus bytes 2-3"), and `ram` holds it as 256 bytes with each word
# little-endian, i.e. word N is ram[2N] (low byte) and ram[2N+1]. That byte
# order is the .sav interchange layout the existing saves already use and is
# kept as-is.
#
# The Mbc7 fields are declared in gb.nim (the save-state code reads them);
# what this file means by each of the EEPROM ones:
#   eeprom_cs/clk/di    the pin levels last written, so edges can be seen.
#   eeprom_do           the output latch driven while a READ streams data.
#   eeprom_command      the instruction shift register. 0 = no Start bit seen.
#                       The Start bit enters as bit 0 and is pushed up one
#                       place per opcode/address bit clocked in beneath it;
#                       when it reaches bit 10 (EE_CMD_DONE) the 10-bit
#                       instruction is complete: bits 9-8 opcode, 7-0 address.
#   read_bits           the chip's 16-bit data register (datasheet block
#                       diagram): data shifts in here for WRITE/WRAL and out of
#                       it, MSB first, for READ.
#   argument_bits_left  bits still to shift for the instruction in progress;
#                       with no instruction (eeprom_command == 0) a nonzero
#                       value is the Ready/Busy countdown of a self-timed
#                       programming cycle.
#   eeprom_write_enabled  the EWEN/EWDS state (datasheet 2.6).

const
  # Pan Docs: "Data is 16-bit and centered at the value 81D0. Earth's gravity
  # affects the value by roughly $70". Before the first latch, and after the
  # $55 erase, both axes read $8000.
  MBC7_ACCEL_CENTRE    = 0x81D0
  MBC7_ACCEL_PER_G     = 0x70
  MBC7_ACCEL_UNLATCHED = 0x8000'u16

  # Pin bits of register Ax8x (Pan Docs, "Ax8x - EEPROM").
  MBC7_EE_DO  = 0x01'u8
  MBC7_EE_DI  = 0x02'u8
  MBC7_EE_CLK = 0x40'u8
  MBC7_EE_CS  = 0x80'u8

  MBC7_EE_WORDS    = 128
  MBC7_EE_CMD_DONE = 1'u16 shl 10   # Start-bit marker after 10 instruction bits

  # 93LC56 opcodes, datasheet Table 1-3 (x16): "SB Opcode Address". The 00
  # opcode covers four instructions told apart by the top two address bits.
  EE_OP_EXT   = 0   # EWDS / WRAL / ERAL / EWEN, see EE_EXT_*
  EE_OP_WRITE = 1
  EE_OP_READ  = 2
  EE_OP_ERASE = 3
  EE_EXT_EWDS = 0
  EE_EXT_WRAL = 1
  EE_EXT_ERAL = 2
  EE_EXT_EWEN = 3

  # A self-timed erase/write cycle takes up to 6 ms (datasheet A12-A15) and
  # software polls DO for Ready. There is no cycle counter among the Mbc7
  # fields, so the cycle is measured in polls instead: this many reads of
  # (or clocks on) the port with CS high report Busy before Ready. Assumed;
  # any value >= 1 satisfies a polling loop and the games only ever poll.
  MBC7_EE_BUSY_POLLS = 4

# --------------------------------------------------------------------------
# EEPROM array
# --------------------------------------------------------------------------

proc ee_load(cart: Mbc7; index: int): uint16 {.inline.} =
  let i = (index and (MBC7_EE_WORDS - 1)) * 2
  uint16(cart.ram[i]) or (uint16(cart.ram[i + 1]) shl 8)

proc ee_store(cart: Mbc7; index: int; val: uint16) {.inline.} =
  let i = (index and (MBC7_EE_WORDS - 1)) * 2
  cart.ram[i] = uint8(val and 0xFF)
  cart.ram[i + 1] = uint8(val shr 8)

proc ee_fill(cart: Mbc7; val: uint16) =
  for w in 0 ..< MBC7_EE_WORDS: cart.ee_store(w, val)

# --------------------------------------------------------------------------
# EEPROM protocol
# --------------------------------------------------------------------------

proc ee_opcode(cart: Mbc7): int {.inline.} = int(cart.eeprom_command shr 8) and 3
proc ee_address(cart: Mbc7): int {.inline.} = int(cart.eeprom_command and 0x7F)
proc ee_extended(cart: Mbc7): int {.inline.} = int(cart.eeprom_command shr 6) and 3
proc ee_instruction_complete(cart: Mbc7): bool {.inline.} =
  (cart.eeprom_command and MBC7_EE_CMD_DONE) != 0
proc ee_busy(cart: Mbc7): bool {.inline.} =
  cart.eeprom_command == 0 and cart.argument_bits_left > 0

proc ee_begin_instruction(cart: Mbc7) =
  ## The tenth bit after the Start bit has just been clocked in.
  case cart.ee_opcode()
  of EE_OP_READ:
    # Datasheet 2.7: "A dummy zero bit precedes the ... 16-bit output string".
    # The dummy appears on this edge; the word follows, MSB first.
    cart.read_bits = cart.ee_load(cart.ee_address())
    cart.argument_bits_left = 16
    cart.eeprom_do = false
  of EE_OP_WRITE:
    # Table 1-3: WRITE is "followed by 16 bits of data" (2.8).
    cart.read_bits = 0
    cart.argument_bits_left = 16
  of EE_OP_ERASE:
    # Address is complete; programming starts when CS falls (2.4).
    cart.argument_bits_left = 0
  else:
    case cart.ee_extended()
    of EE_EXT_EWEN: cart.eeprom_write_enabled = true
    of EE_EXT_EWDS: cart.eeprom_write_enabled = false
    of EE_EXT_WRAL:
      cart.read_bits = 0
      cart.argument_bits_left = 16
    else:  # ERAL: like ERASE, pending until CS falls (2.5)
      cart.argument_bits_left = 0

proc ee_clock(cart: Mbc7; di: bool) =
  ## One rising CLK edge with CS high. Datasheet 2.0: "Instructions, addresses
  ## and write data are clocked into the DI pin on the rising edge of the
  ## clock (CLK)"; 3.2: "Data bits are also clocked out on the positive edge".
  if cart.eeprom_command == 0:
    if cart.argument_bits_left > 0:
      # Busy. 3.2: "CLK cycles are not required during the self-timed write
      # cycle", but a poll that clocks is time passing (see MBC7_EE_BUSY_POLLS).
      dec cart.argument_bits_left
    elif di:
      # 2.1: "The Start bit is detected by the device if CS and DI are both
      # high with respect to the positive edge of the clock for the first time."
      cart.eeprom_command = 1
    return
  if not cart.ee_instruction_complete():
    cart.eeprom_command = (cart.eeprom_command shl 1) or uint16(di)
    if cart.ee_instruction_complete(): cart.ee_begin_instruction()
    return
  case cart.ee_opcode()
  of EE_OP_READ:
    cart.eeprom_do = (cart.read_bits and 0x8000) != 0
    cart.read_bits = cart.read_bits shl 1
    dec cart.argument_bits_left
    if cart.argument_bits_left == 0:
      # 2.7: "Sequential read is possible when CS is held high. The memory
      # data will automatically cycle to the next register and output
      # sequentially" -- no second dummy bit (Figure 2-7).
      let next = (cart.ee_address() + 1) and (MBC7_EE_WORDS - 1)
      cart.eeprom_command = (cart.eeprom_command and not 0x7F'u16) or uint16(next)
      cart.read_bits = cart.ee_load(next)
      cart.argument_bits_left = 16
  of EE_OP_WRITE, EE_OP_EXT:
    # WRITE and WRAL take 16 data bits; the other 00-opcode instructions have
    # argument_bits_left == 0 and ignore further clocks (3.2: "CLK and DI then
    # become 'don't care' inputs waiting for a new Start condition").
    if cart.argument_bits_left > 0:
      cart.read_bits = (cart.read_bits shl 1) or uint16(di)
      dec cart.argument_bits_left
  else:
    discard

proc ee_deselect(cart: Mbc7) =
  ## CS has fallen. 3.1: "If CS is low, the internal control logic is held in
  ## a Reset status." For 93LC devices the falling edge of CS after the last
  ## address/data bit is what "initiates the self-timed auto-erase and
  ## programming cycle" (2.4, 2.5, 2.8, 2.9), so this is where the array
  ## changes. 2.6: every programming mode "must be preceded by an EWEN
  ## instruction"; without it the instruction is dropped here unexecuted.
  var programmed = false
  if cart.ee_instruction_complete() and cart.eeprom_write_enabled and
     cart.argument_bits_left == 0:
    case cart.ee_opcode()
    of EE_OP_WRITE:
      cart.ee_store(cart.ee_address(), cart.read_bits)
      programmed = true
    of EE_OP_ERASE:
      # 2.4: "forces all data bits of the specified address to the logical 1".
      cart.ee_store(cart.ee_address(), 0xFFFF)
      programmed = true
    of EE_OP_EXT:
      case cart.ee_extended()
      of EE_EXT_ERAL:
        cart.ee_fill(0xFFFF)
        programmed = true
      of EE_EXT_WRAL:
        # 2.9: "The WRAL command does include an automatic ERAL cycle".
        cart.ee_fill(cart.read_bits)
        programmed = true
      else: discard
    else: discard
  cart.eeprom_command = 0
  # 3.4: the status "is available on the DO pin if CS is brought high after
  # being low for tCSL and an erase or write operation has been initiated".
  cart.argument_bits_left = if programmed: MBC7_EE_BUSY_POLLS else: 0
  if programmed: cart.ram_dirty = true
  cart.eeprom_do = true

proc ee_do_level(cart: Mbc7): bool =
  ## What DO shows right now. 2.0: "The DO pin is normally held in a High-Z
  ## state except when reading data from the device, or when checking the
  ## Ready/Busy status"; "DO will enter the High-Z state on the falling edge
  ## of CS". High-Z reads as 1 on this cartridge: Assumed (a pull-up), which
  ## also makes an idle port read the same $FF-ish shape as the empty
  ## registers around it.
  if not cart.eeprom_cs: true
  elif cart.ee_busy(): false           # 3.4: "DO low indicates ... in progress"
  elif cart.ee_instruction_complete() and cart.ee_opcode() == EE_OP_READ:
    cart.eeprom_do
  else: true

proc ee_port_read(cart: Mbc7): uint8 =
  ## Ax8x read: bit 0 is DO; DI/CLK/CS read back the levels last written.
  ## Assumed for the latter (the register is a latch and Pan Docs lists the
  ## four pin bits without saying which are readable); the unused bits read 0.
  result = if cart.ee_do_level(): MBC7_EE_DO else: 0'u8
  if cart.eeprom_di:  result = result or MBC7_EE_DI
  if cart.eeprom_clk: result = result or MBC7_EE_CLK
  if cart.eeprom_cs:  result = result or MBC7_EE_CS
  # A status poll is what lets the emulated cycle run down (MBC7_EE_BUSY_POLLS).
  if cart.eeprom_cs and cart.ee_busy(): dec cart.argument_bits_left

proc ee_port_write(cart: Mbc7; val: uint8) =
  ## Ax8x write: bit 7 CS, bit 6 CLK, bit 1 DI. Bit 0 is the chip's output and
  ## a write to it goes nowhere. Only edges matter: CS falling resets the chip
  ## (3.1) and starts a pending programming cycle; CLK rising with CS high
  ## moves one bit.
  let cs  = (val and MBC7_EE_CS) != 0
  let clk = (val and MBC7_EE_CLK) != 0
  let di  = (val and MBC7_EE_DI) != 0
  if cart.eeprom_cs and not cs:
    cart.ee_deselect()
  elif cs and clk and not cart.eeprom_clk:
    cart.ee_clock(di)
  cart.eeprom_cs = cs
  cart.eeprom_clk = clk
  cart.eeprom_di = di

# --------------------------------------------------------------------------
# Accelerometer
# --------------------------------------------------------------------------

proc accel_sample(g: float): uint16 =
  ## Pan Docs: centre $81D0, about $70 per g. `g` is the frontend's tilt on
  ## this axis (set_accelerometer), already signed so that a positive input
  ## raises the reading; the frontends calibrate their own sign to that.
  ## Clamped to the 16-bit register: "Maximum range is unknown" (Assumed).
  var v = float(MBC7_ACCEL_CENTRE) + g * float(MBC7_ACCEL_PER_G)
  if v < 0.0: v = 0.0
  if v > 65535.0: v = 65535.0
  uint16(int(v + 0.5))

proc set_accelerometer*(cart: Mbc; x, y: float) =
  ## Frontend tilt, -1.0 .. 1.0 per axis, 0 = level; ~1 = one g. Only MBC7
  ## has a sensor; a no-op on every other mapper so callers need not check.
  ## A flat cartridge at rest has gravity on neither axis, so (0, 0) samples
  ## as the $81D0 centre on both (Assumed: no sensor noise).
  if cart of Mbc7:
    let c = Mbc7(cart)
    c.accel_x = x
    c.accel_y = y

proc mbc7_reg_read(cart: Mbc7; reg: int): uint8 =
  ## Register select = address bits 4-7 (Pan Docs, "A000-AFFF - RAM Registers").
  case reg
  of 0x2: uint8(cart.x_latch and 0xFF)   # "Ax2x contains the low byte of the X value"
  of 0x3: uint8(cart.x_latch shr 8)      # "Ax3x contains the high byte"
  of 0x4: uint8(cart.y_latch and 0xFF)   # likewise Y
  of 0x5: uint8(cart.y_latch shr 8)
  of 0x6: 0x00'u8                        # "Ax6x always reads $00"
  of 0x8: cart.ee_port_read()
  else: 0xFF'u8   # latch registers ("Reads return $FF"), Ax7x, Ax9x-AxFx

proc mbc7_reg_write(cart: Mbc7; reg: int; val: uint8) =
  case reg
  of 0x0:
    # "Write $55 to Ax0x to erase the latched data (reset back to 8000)".
    if val == 0x55:
      cart.x_latch = MBC7_ACCEL_UNLATCHED
      cart.y_latch = MBC7_ACCEL_UNLATCHED
      cart.latch_ready = true
  of 0x1:
    # "... then $AA to Ax1x to latch the accelerometer and update the
    # addressable registers. Note that you cannot re-latch the accelerometer
    # value without first erasing it; attempts to do so yield no change."
    if val == 0xAA and cart.latch_ready:
      cart.x_latch = accel_sample(cart.accel_x)
      cart.y_latch = accel_sample(cart.accel_y)
      cart.latch_ready = false
  of 0x8: cart.ee_port_write(val)
  else: discard   # "Other writes do not appear to do anything"

# --------------------------------------------------------------------------
# Mapper interface
# --------------------------------------------------------------------------

proc mbc7_registers_enabled(cart: Mbc7): bool {.inline.} =
  ## Pan Docs: the registers "Must be enabled via 0000 and 4000 region
  ## writes ... otherwise reads read $FF and writes do nothing".
  cart.ram_enabled and cart.secondary_enable

method mbc_rom_map*(cart: Mbc7): (int, int) =
  ## Two flat views: bank 0 low, the selected bank high. Nothing written
  ## through $A000-$BFFF moves the ROM window.
  (0, mbc_rom_bank_offset(cart, int(cart.rom_bank_num)))

method mbc_read*(cart: Mbc7; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xAFFF:
    if cart.mbc7_registers_enabled(): cart.mbc7_reg_read((idx shr 4) and 0xF)
    else: 0xFF'u8
  else: 0xFF'u8   # "B000-BFFF ... Only seems to read out $FF"

method mbc_write*(cart: Mbc7; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    # "RAM Enable 1 ... Mostly the same as for MBC1, a value of $0A will
    # enable"; MBC1 decides on the low nibble alone. Dropping the gate is the
    # moment a game has finished with the EEPROM, so flush the save there.
    let enabling = (val and 0x0F) == 0x0A
    if cart.ram_enabled and not enabling: mbc_save(cart)
    cart.ram_enabled = enabling
  of 0x2000..0x3FFF:
    # "ROM Bank 00-7F ... Same as for MBC5": seven bank bits, and bank 0 is
    # bank 0 (Pan Docs marks the latter as needing confirmation).
    cart.rom_bank_num = val and 0x7F
  of 0x4000..0x5FFF:
    # "RAM Enable 2 ... Writing $40 to this region enables access to the RAM
    # registers. Writing any other value appears to disable access".
    cart.secondary_enable = val == 0x40
  of 0xA000..0xAFFF:
    if cart.mbc7_registers_enabled(): cart.mbc7_reg_write((idx shr 4) and 0xF, val)
  else: discard
