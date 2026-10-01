## The DS card slot: AUXSPICNT 0x40001A0 / AUXSPIDATA 0x40001A2 (backup
## chip), ROMCTRL 0x40001A4, command bytes 0x40001A8-AF, data 0x4100010.
## After a direct boot the card is in KEY2 main-data mode; KEY2 is undone by
## the hardware on both ends, so plaintext is served (docs/nds/gbatek-notes.md
## 11.4). KEY1 (real-BIOS boot), backup EEPROM/flash and transfer timing are
## TODO(cart).

import irq

type
  Cart* = ref object
    rom*: seq[uint8]
    chip_id*: uint32
    auxspicnt*: uint16
    romctrl*: uint32
    command*: array[8, uint8]
    buf: seq[uint8]           ## reply bytes of the running transfer
    pos: int
    irq9* {.cursor.}, irq7* {.cursor.}: IrqCtl
    owner_arm7*: bool         ## EXMEMCNT bit 11
    backup*: seq[uint8]
    spi_out*: uint8

proc chip_id_for(size: int): uint32 =
  var mb = max(1, size shr 20)
  var p = 1
  while p < mb: p = p shl 1
  0xC2'u32 or (uint32(p - 1) shl 8)

proc new_cart*(rom: seq[uint8]; irq9, irq7: IrqCtl): Cart =
  Cart(rom: rom, chip_id: chip_id_for(rom.len), irq9: irq9, irq7: irq7)

proc rom_byte(c: Cart; a: int): uint8 =
  if c.rom.len == 0: return 0xFF
  c.rom[a mod c.rom.len]

proc finish_irq(c: Cart) =
  if (c.auxspicnt and 0x4000) != 0:
    (if c.owner_arm7: c.irq7 else: c.irq9).raise_irq(irqCartDone)

proc start_transfer(c: Cart) =
  let bs = (c.romctrl shr 24) and 7
  let len = if bs == 0: 0 elif bs == 7: 4 else: 0x100 shl bs
  c.buf.setLen(len)
  c.pos = 0
  case c.command[0]
  of 0xB7:
    var a = (int(c.command[1]) shl 24) or (int(c.command[2]) shl 16) or
            (int(c.command[3]) shl 8) or int(c.command[4])
    if a < 0x8000: a = 0x8000 + (a and 0x1FF)
    for i in 0 ..< len:
      # wraps within its 4 KB block
      c.buf[i] = c.rom_byte((a and not 0xFFF) + ((a + i) and 0xFFF))
  of 0x00:
    for i in 0 ..< len: c.buf[i] = c.rom_byte(i and 0x1FF)
  of 0x90, 0xB8:
    for i in 0 ..< len: c.buf[i] = uint8((c.chip_id shr (8 * (i and 3))) and 0xFF)
  else:
    for i in 0 ..< len: c.buf[i] = 0xFF
  if len == 0:
    c.romctrl = c.romctrl and not 0x8080_0000'u32
    c.finish_irq()
  else:
    c.romctrl = c.romctrl or 0x0080_0000'u32   # word ready at once (TODO timing)

proc read_data*(c: Cart): uint32 =
  if (c.romctrl and 0x0080_0000'u32) == 0: return 0xFFFF_FFFF'u32
  for i in 0..3:
    result = result or (uint32(c.buf[c.pos + i]) shl (8 * i))
  c.pos += 4
  if c.pos >= c.buf.len:
    c.romctrl = c.romctrl and not 0x8080_0000'u32
    c.finish_irq()

proc data_ready*(c: Cart): bool = (c.romctrl and 0x0080_0000'u32) != 0

proc read_reg*(c: Cart; offset: uint32): uint32 =
  case offset
  of 0x1A0: uint32(c.auxspicnt) or (uint32(c.spi_out) shl 16)
  of 0x1A4: c.romctrl
  else: 0

proc write_reg*(c: Cart; offset: uint32; v, mask: uint32) =
  case offset
  of 0x1A0:
    if (mask and 0xFFFF) != 0:
      c.auxspicnt = (c.auxspicnt and not uint16(mask)) or (uint16(v) and uint16(mask))
    if (mask and 0x00FF_0000'u32) != 0:
      c.spi_out = 0xFF   # TODO(cart): backup EEPROM/flash/FRAM protocol
  of 0x1A4:
    let was_busy = (c.romctrl and 0x8000_0000'u32) != 0
    let ready = c.romctrl and 0x0080_0000'u32   # read-only
    c.romctrl = (((c.romctrl and not mask) or (v and mask)) and not 0x0080_0000'u32) or ready
    if (c.romctrl and 0x8000_0000'u32) != 0 and not was_busy:
      c.start_transfer()
  of 0x1A8, 0x1AC:
    let base = int(offset - 0x1A8)
    for i in 0..3:
      if ((mask shr (8 * i)) and 0xFF) != 0:
        c.command[base + i] = uint8((v shr (8 * i)) and 0xFF)
  else: discard
