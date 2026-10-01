## The DS card slot: AUXSPICNT 0x40001A0 / AUXSPIDATA 0x40001A2 (backup
## chip), ROMCTRL 0x40001A4, command bytes 0x40001A8-AF, data 0x4100010.
## After a direct boot the card is in KEY2 main-data mode; KEY2 is undone by
## the hardware on both ends, so plaintext is served (docs/nds/gbatek-notes.md
## 11.4).
##
## Transfers are timed: the first word is ready (ROMCTRL.23, DRQ) after the
## 8 command bytes, gap1 and 4 data bytes have gone by at the card clock
## (ROMCTRL.27: 5 or 8 bus cycles per byte), each further word 4 bytes later
## (plus gap2 after each 0x200 bytes when ROMCTRL.28 is set). A word waits
## until 0x4100010 is read (by the CPU, or by slot-1 DMA -- nds.nim triggers
## the owner's DMA on each DRQ), then the next one starts; the last read
## ends the transfer (busy off, IF.19 if AUXSPICNT.14).
##
## The save chip on the slot's SPI side is backup.nim.
##
## TODO(cart): KEY1 (real-BIOS boot), NAND carts.

import irq, backup
when defined(ndsdebug): import std/strutils
import ../sched

export backup

type
  Cart* = ref object
    rom*: seq[uint8]
    chip_id*: uint32
    auxspicnt*: uint16
    romctrl*: uint32
    command*: array[8, uint8]
    buf: seq[uint8]           ## reply bytes of the running transfer
    pos: int
    last_word: uint32
    irq9* {.cursor.}, irq7* {.cursor.}: IrqCtl
    sched* {.cursor.}: NdsScheduler
    owner_arm7*: bool         ## EXMEMCNT bit 11
    backup*: Backup
    spi_out*: uint8
    spilog*: bool             ## -d:ndsdebug: log AUXSPI bytes to stderr
    spi_busy_until: int64     ## AUXSPICNT.7 reads set until this master cycle

proc chip_id_for(size: int): uint32 =
  var mb = max(1, size shr 20)
  var p = 1
  while p < mb: p = p shl 1
  0xC2'u32 or (uint32(p - 1) shl 8)

proc new_cart*(rom: sink seq[uint8]; irq9, irq7: IrqCtl; sched: NdsScheduler): Cart =
  let size = rom.len
  let infrared = size > 0x0C and rom[0x0C] == uint8('I')
  # `rom` is moved in last: a sink parameter used afterwards would be copied
  result = Cart(rom: rom, chip_id: chip_id_for(size), irq9: irq9, irq7: irq7,
                sched: sched, backup: new_backup())
  # Game code 'I...' = cart with an infrared port (GBATEK "NDS Gamecodes")
  result.backup.ir = infrared

proc byte_cycles(c: Cart): int64 {.inline.} =
  ## Master cycles per card byte (bus/5 or bus/8 clock, 2 master per bus).
  if (c.romctrl and (1'u32 shl 27)) != 0: 16 else: 10

proc schedule_word(c: Cart; first: bool) =
  var bytes = 4'i64
  if first:
    bytes += 8 + int64(c.romctrl and 0x1FFF)            # command + gap1
  elif (c.pos and 0x1FF) == 0 and (c.romctrl and (1'u32 shl 28)) != 0:
    bytes += int64((c.romctrl shr 16) and 0x3F)         # gap2 per 0x200 bytes
  c.sched.schedule(c.sched.now + bytes * c.byte_cycles(), evCartDone)

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
    c.schedule_word(true)

proc word_ready*(c: Cart) =
  ## evCartDone: the next word sits in the data register (DRQ).
  if (c.romctrl and 0x8000_0000'u32) != 0 and c.pos < c.buf.len:
    c.romctrl = c.romctrl or 0x0080_0000'u32

proc read_data*(c: Cart): uint32 =
  ## 0x4100010. Without a word ready it returns the last word again.
  if (c.romctrl and 0x0080_0000'u32) == 0: return c.last_word
  for i in 0..3:
    result = result or (uint32(c.buf[c.pos + i]) shl (8 * i))
  c.last_word = result
  c.pos += 4
  c.romctrl = c.romctrl and not 0x0080_0000'u32
  if c.pos >= c.buf.len:
    c.romctrl = c.romctrl and not 0x8000_0000'u32
    c.finish_irq()
  else:
    c.schedule_word(false)

proc data_ready*(c: Cart): bool = (c.romctrl and 0x0080_0000'u32) != 0

proc read_reg*(c: Cart; offset: uint32): uint32 =
  case offset
  of 0x1A0:
    let busy = if c.sched.now < c.spi_busy_until: 0x80'u32 else: 0
    uint32(c.auxspicnt) or busy or (uint32(c.spi_out) shl 16)
  of 0x1A4: c.romctrl
  else: 0

proc spi_byte_cycles*(cnt: uint16): int64 =
  ## Master cycles for one 8-bit SPI transfer at baud rate bits 0-1.
  const hz = [4_000_000'i64, 2_000_000, 1_000_000, 512 * 1024]
  (8 * MASTER_HZ + hz[cnt and 3] - 1) div hz[cnt and 3]

proc spi_selected(c: Cart): bool {.inline.} =
  ## AUXSPICNT: slot enabled (15) in backup-SPI mode (13).
  (c.auxspicnt and 0xA000'u16) == 0xA000

proc write_reg*(c: Cart; offset: uint32; v, mask: uint32; pc = 0'u32) =
  ## `pc` is the writing CPU's program counter (save-chip type detection).
  case offset
  of 0x1A0:
    if (mask and 0xFFFF) != 0:
      let was = c.spi_selected()
      c.auxspicnt = (c.auxspicnt and not uint16(mask)) or (uint16(v) and uint16(mask))
      if was and not c.spi_selected(): c.backup.deselect()
    if (mask and 0x00FF_0000'u32) != 0 and c.spi_selected():
      # AUXSPIDATA: one byte each way; without the hold bit (6) the chip is
      # deselected after it
      c.spi_out = c.backup.transfer(uint8(v shr 16), pc)
      # 8 bits at the AUXSPICNT baud rate (4/2/1 MHz, 512 kHz) keep the busy
      # flag up; the reply is stored at once (GBATEK "AUXSPIDATA")
      c.spi_busy_until = c.sched.now + spi_byte_cycles(c.auxspicnt)
      when defined(ndsdebug):
        if c.spilog:
          stderr.writeLine("spi " & toHex(uint8(v shr 16)) & " -> " & toHex(c.spi_out) &
                           " pc=" & toHex(pc, 8) &
                           (if (c.auxspicnt and 0x40) == 0: " (end)" else: ""))
      if (c.auxspicnt and 0x40) == 0: c.backup.deselect()
  of 0x1A4:
    let was_busy = (c.romctrl and 0x8000_0000'u32) != 0
    let ready = c.romctrl and 0x0080_0000'u32   # read-only
    c.romctrl = (((c.romctrl and not mask) or (v and mask)) and not 0x0080_0000'u32) or ready
    if (c.romctrl and 0x8000_0000'u32) != 0 and not was_busy:
      c.start_transfer()
    elif was_busy and (c.romctrl and 0x8000_0000'u32) == 0:
      c.sched.cancel(evCartDone)       # transfer abandoned
      c.romctrl = c.romctrl and not 0x0080_0000'u32
  of 0x1A8, 0x1AC:
    let base = int(offset - 0x1A8)
    for i in 0..3:
      if ((mask shr (8 * i)) and 0xFF) != 0:
        c.command[base + i] = uint8((v shr (8 * i)) and 0xFF)
  else: discard
