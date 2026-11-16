# MBC7 cartridge (included by gb.nim)
#
# Cart type $22: Kirby Tilt 'n' Tumble, Command Master. Sources: Pan Docs
# "MBC7", and Microchip DS21794F (93LC56 Microwire EEPROM; section numbers
# below refer to it).
#
# No cartridge RAM: $A000-$AFFF is a register file (address bits 4-7 select)
# in front of a two-axis accelerometer and the EEPROM's four pins. The
# battery-backed EEPROM is 128 x 16-bit words; `ram` holds them as 256 bytes,
# word N little-endian at ram[2N]. That is the .sav layout; keep it.
#
# Mbc7 EEPROM fields (declared in gb.nim):
#   pin_cs/clk/di  pin levels last written, for edge detection.
#   pin_do         output latch while a READ streams data.
#   instr_shift    0 = no Start bit seen. The Start bit enters as bit 0 and
#                  moves up per bit clocked in; at bit 10 (MBC7_EE_CMD_DONE)
#                  the instruction is complete: bits 9-8 opcode, 7-0 address.
#   data_reg       the chip's 16-bit data register, MSB first.
#   bits_to_shift  bits left for the instruction; with instr_shift == 0, a
#                  nonzero value is the Ready/Busy countdown.
#   write_enabled  EWEN/EWDS state (2.6).

const
  # Pan Docs: centred at $81D0, gravity moves it by roughly $70. Unlatched
  # (before the first latch, after the $55 erase) both axes read $8000.
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

  # The self-timed program cycle (up to 6 ms) is counted in polls, not time:
  # this many reads of (or clocks on) the port with CS high report Busy.
  # Assumed; any value >= 1 satisfies the games' polling loops.
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

proc ee_opcode(cart: Mbc7): int {.inline.} = int(cart.instr_shift shr 8) and 3
proc ee_address(cart: Mbc7): int {.inline.} = int(cart.instr_shift and 0x7F)
proc ee_extended(cart: Mbc7): int {.inline.} = int(cart.instr_shift shr 6) and 3
proc ee_instruction_complete(cart: Mbc7): bool {.inline.} =
  (cart.instr_shift and MBC7_EE_CMD_DONE) != 0
proc ee_busy(cart: Mbc7): bool {.inline.} =
  cart.instr_shift == 0 and cart.bits_to_shift > 0

proc ee_begin_instruction(cart: Mbc7) =
  ## The tenth bit after the Start bit has just been clocked in.
  case cart.ee_opcode()
  of EE_OP_READ:
    # 2.7: a dummy zero bit (this edge) precedes the word, MSB first.
    cart.data_reg = cart.ee_load(cart.ee_address())
    cart.bits_to_shift = 16
    cart.pin_do = false
  of EE_OP_WRITE:
    # 16 data bits follow (2.8).
    cart.data_reg = 0
    cart.bits_to_shift = 16
  of EE_OP_ERASE:
    # Address is complete; programming starts when CS falls (2.4).
    cart.bits_to_shift = 0
  else:
    case cart.ee_extended()
    of EE_EXT_EWEN: cart.write_enabled = true
    of EE_EXT_EWDS: cart.write_enabled = false
    of EE_EXT_WRAL:
      cart.data_reg = 0
      cart.bits_to_shift = 16
    else:  # ERAL: like ERASE, pending until CS falls (2.5)
      cart.bits_to_shift = 0

proc ee_clock(cart: Mbc7; di: bool) =
  ## One rising CLK edge with CS high: bits clock in and out on it (2.0, 3.2).
  if cart.instr_shift == 0:
    if cart.bits_to_shift > 0:
      # Busy: a clocking poll counts down (MBC7_EE_BUSY_POLLS).
      dec cart.bits_to_shift
    elif di:
      # 2.1: Start bit = first rising edge with CS and DI both high.
      cart.instr_shift = 1
    return
  if not cart.ee_instruction_complete():
    cart.instr_shift = (cart.instr_shift shl 1) or uint16(di)
    if cart.ee_instruction_complete(): cart.ee_begin_instruction()
    return
  case cart.ee_opcode()
  of EE_OP_READ:
    cart.pin_do = (cart.data_reg and 0x8000) != 0
    cart.data_reg = cart.data_reg shl 1
    dec cart.bits_to_shift
    if cart.bits_to_shift == 0:
      # 2.7: with CS held high the read continues at the next word, with no
      # second dummy bit (Figure 2-7).
      let next = (cart.ee_address() + 1) and (MBC7_EE_WORDS - 1)
      cart.instr_shift = (cart.instr_shift and not 0x7F'u16) or uint16(next)
      cart.data_reg = cart.ee_load(next)
      cart.bits_to_shift = 16
  of EE_OP_WRITE, EE_OP_EXT:
    # WRITE/WRAL take 16 data bits; the other 00-opcode instructions have
    # bits_to_shift == 0 and ignore clocks until a new Start (3.2).
    if cart.bits_to_shift > 0:
      cart.data_reg = (cart.data_reg shl 1) or uint16(di)
      dec cart.bits_to_shift
  else:
    discard

proc ee_deselect(cart: Mbc7) =
  ## CS has fallen: the chip resets (3.1), and a completed program instruction
  ## starts its self-timed cycle here (2.4, 2.5, 2.8, 2.9), so this is where
  ## the array changes. Without a prior EWEN (2.6) it is dropped.
  var programmed = false
  if cart.ee_instruction_complete() and cart.write_enabled and
     cart.bits_to_shift == 0:
    case cart.ee_opcode()
    of EE_OP_WRITE:
      cart.ee_store(cart.ee_address(), cart.data_reg)
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
        cart.ee_fill(cart.data_reg)
        programmed = true
      else: discard
    else: discard
  cart.instr_shift = 0
  # 3.4: Ready/Busy shows on DO once CS rises again after a program start.
  cart.bits_to_shift = if programmed: MBC7_EE_BUSY_POLLS else: 0
  if programmed: cart.ram_dirty = true
  cart.pin_do = true

proc ee_do_level(cart: Mbc7): bool =
  ## DO is High-Z except during a READ or a Ready/Busy check, and with CS low
  ## (2.0). High-Z reads 1: Assumed (pull-up).
  if not cart.pin_cs: true
  elif cart.ee_busy(): false           # 3.4: "DO low indicates ... in progress"
  elif cart.ee_instruction_complete() and cart.ee_opcode() == EE_OP_READ:
    cart.pin_do
  else: true

proc ee_port_read(cart: Mbc7): uint8 =
  ## Ax8x read: bit 0 is DO; DI/CLK/CS read back the levels last written
  ## (Assumed: Pan Docs does not say which bits are readable); unused bits 0.
  result = if cart.ee_do_level(): MBC7_EE_DO else: 0'u8
  if cart.pin_di:  result = result or MBC7_EE_DI
  if cart.pin_clk: result = result or MBC7_EE_CLK
  if cart.pin_cs:  result = result or MBC7_EE_CS
  # A status poll is what lets the emulated cycle run down (MBC7_EE_BUSY_POLLS).
  if cart.pin_cs and cart.ee_busy(): dec cart.bits_to_shift

proc ee_port_write(cart: Mbc7; val: uint8) =
  ## Ax8x write: bit 7 CS, bit 6 CLK, bit 1 DI (bit 0 is output-only). Only
  ## edges matter: CS falling ends the instruction, CLK rising moves a bit.
  let cs  = (val and MBC7_EE_CS) != 0
  let clk = (val and MBC7_EE_CLK) != 0
  let di  = (val and MBC7_EE_DI) != 0
  if cart.pin_cs and not cs:
    cart.ee_deselect()
  elif cs and clk and not cart.pin_clk:
    cart.ee_clock(di)
  cart.pin_cs = cs
  cart.pin_clk = clk
  cart.pin_di = di

# --------------------------------------------------------------------------
# Accelerometer
# --------------------------------------------------------------------------

proc accel_sample(g: float): uint16 =
  ## `g` is the frontend's tilt on this axis; positive raises the reading.
  ## Clamped to 16 bits (Pan Docs: "Maximum range is unknown").
  var v = float(MBC7_ACCEL_CENTRE) + g * float(MBC7_ACCEL_PER_G)
  if v < 0.0: v = 0.0
  if v > 65535.0: v = 65535.0
  uint16(int(v + 0.5))

proc set_accelerometer*(cart: Mbc; x, y: float) =
  ## Frontend tilt, -1.0 .. 1.0 per axis, 0 = level, ~1 = one g. A no-op on
  ## mappers other than MBC7. (0, 0) samples as the centre (Assumed: no noise).
  if cart of Mbc7:
    let c = Mbc7(cart)
    c.accel_x = x
    c.accel_y = y

proc mbc7_reg_read(cart: Mbc7; reg: int): uint8 =
  ## Register select = address bits 4-7 (Pan Docs, "A000-AFFF - RAM Registers").
  case reg
  of 0x2: uint8(cart.x_sample and 0xFF)   # "Ax2x contains the low byte of the X value"
  of 0x3: uint8(cart.x_sample shr 8)      # "Ax3x contains the high byte"
  of 0x4: uint8(cart.y_sample and 0xFF)   # likewise Y
  of 0x5: uint8(cart.y_sample shr 8)
  of 0x6: 0x00'u8                        # "Ax6x always reads $00"
  of 0x8: cart.ee_port_read()
  else: 0xFF'u8   # latch registers ("Reads return $FF"), Ax7x, Ax9x-AxFx

proc mbc7_reg_write(cart: Mbc7; reg: int; val: uint8) =
  case reg
  of 0x0:
    # "Write $55 to Ax0x to erase the latched data (reset back to 8000)".
    if val == 0x55:
      cart.x_sample = MBC7_ACCEL_UNLATCHED
      cart.y_sample = MBC7_ACCEL_UNLATCHED
      cart.latch_armed = true
  of 0x1:
    # "$AA to Ax1x to latch"; re-latching without an erase first does
    # nothing (Pan Docs).
    if val == 0xAA and cart.latch_armed:
      cart.x_sample = accel_sample(cart.accel_x)
      cart.y_sample = accel_sample(cart.accel_y)
      cart.latch_armed = false
  of 0x8: cart.ee_port_write(val)
  else: discard   # "Other writes do not appear to do anything"

# --------------------------------------------------------------------------
# Mapper interface
# --------------------------------------------------------------------------

proc mbc7_registers_enabled(cart: Mbc7): bool {.inline.} =
  ## Pan Docs: the registers "Must be enabled via 0000 and 4000 region
  ## writes ... otherwise reads read $FF and writes do nothing".
  cart.ram_enabled and cart.ram_enable2

method mbc_rom_map*(cart: Mbc7): (int, int) =
  ## Bank 0 low, the selected bank high.
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
    # RAM Enable 1: $0A in the low nibble, as MBC1. Dropping the gate means
    # the game is done with the EEPROM, so flush the save there.
    let enabling = (val and 0x0F) == 0x0A
    if cart.ram_enabled and not enabling: mbc_save(cart)
    cart.ram_enabled = enabling
  of 0x2000..0x3FFF:
    # Seven bank bits, as MBC5; bank 0 is bank 0 (unconfirmed in Pan Docs).
    cart.rom_bank_num = val and 0x7F
  of 0x4000..0x5FFF:
    # RAM Enable 2: $40 enables, anything else disables (Pan Docs).
    cart.ram_enable2 = val == 0x40
  of 0xA000..0xAFFF:
    if cart.mbc7_registers_enabled(): cart.mbc7_reg_write((idx shr 4) and 0xF, val)
  else: discard
