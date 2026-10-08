## The DS card slot: AUXSPICNT 0x40001A0 / AUXSPIDATA 0x40001A2 (backup
## chip), ROMCTRL 0x40001A4, command bytes 0x40001A8-AF, KEY2 seeds
## 0x40001B0-BB, data 0x4100010.
##
## The card side follows GBATEK "DS Cartridge Protocol": after reset it takes
## raw commands (9F dummy, 00 header, 90 chip ID, 3C enter KEY1), then
## KEY1-encrypted ones (4 KEY2 on, 1 chip ID, 2 secure-area block, 6 KEY2
## off, A enter main mode), then KEY2-encrypted main-data commands (B7 read,
## B8 chip ID). KEY1 needs the BIOS7 dump's table (cartcrypt.nim); the
## secure area is served as a card holds it (first 2 KB KEY1-encrypted, a
## decrypted dump re-encrypted). Direct boot leaves the card in main mode.
##
## KEY2 runs on both ends: the card XORs its stream onto replies (and takes
## commands through it in main mode); the console's interface XORs its own
## stream onto commands (ROMCTRL.22) and data (ROMCTRL.13), seeded from the
## SEED registers by ROMCTRL.15. Both advance on every byte clocked over the
## bus -- command bytes, gap clocks (ROMCTRL.28) and data -- so with the
## same seeds they cancel and the CPU reads plaintext. Assumed (GBATEK does
## not say): a side only advances while it is encrypting; a transfer's bytes
## are all clocked when it starts (an abandoned block still advances both).
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
## TODO(cart): NAND carts, DSi carts (command 3D), the HIGH-Z byte leading
## a KEY1 reply's dummy period.

import irq, backup, cartcrypt
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}
when defined(ndsdebug): import std/strutils
import ../sched

export backup, cartcrypt

type
  CardMode* = enum
    cmRaw     ## after reset: unencrypted commands
    cmKey1    ## after 3C: KEY1-encrypted commands, KEY2-encrypted replies
    cmMain    ## after A: KEY2 commands and data (where direct boot leaves it)

  Cart* = ref object
    rom*: seq[uint8]
    chip_id*: uint32
    mode*: CardMode
    in_reset*: bool           ## card held in reset until ROMCTRL.29 is set
    key1_table*: seq[uint8]   ## from the BIOS7 dump; @[] = no KEY1
    key1: Key1                ## gamecode, level 2: the KEY1 command key
    secure*: seq[uint8]       ## ROM 0x4000..0x7FFF as the card holds it
    card_k2*, con_k2*: Key2   ## card-side and console-side KEY2 streams
    card_k2_on*: bool         ## the card encrypts (until KEY1 command 6)
    seed_lo*, seed_hi*: array[2, array[2, uint32]]
      ## SEED registers per CPU (0 = ARM9, 1 = ARM7): [cpu][seed0/1]
    last_cmd: array[8, uint8] ## previous KEY1 command (plain)
    key1_repeat: bool         ## the running KEY1 command repeats the last one
    sec_pos: int              ## bytes of the current secure block sent
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
    cartlog*: bool            ## -d:ndsdebug: log ROM transfers to stderr
    spi_busy_until: int64     ## AUXSPICNT.7 reads set until this master cycle

proc chip_id_for*(size: int; ir: bool): uint32 =
  ## GBATEK "1st Get ROM Chip ID": byte 0 maker (C2 = Macronix), byte 1
  ## size (MB - 1 up to 128 MB, then 100h - N for N x 256 MB), byte 2 bit 0
  ## infrared, byte 3 bit 7 the
  ## newer protocol variant. GBATEK's table has bit 31 set on every NDS
  ## card of 128 MB and up and on few smaller ones, so: bit 31 from 128 MB.
  ## The IR bit follows the gamecode's 'I' (GBATEK "NDS Gamecodes").
  var mb = max(1, size shr 20)
  var p = 1
  while p < mb: p = p shl 1
  let size = if p <= 128: p - 1 else: 0x100 - p div 256
  result = 0xC2'u32 or (uint32(size) shl 8)
  if p >= 128: result = result or 0x8000_0000'u32
  if ir: result = result or 0x0001_0000'u32

proc sync_key2*(c: Cart; seed0: uint64) =
  ## Both KEY2 streams (and both CPUs' seed registers) at the same seed, as
  ## after a boot: replies decrypt to plaintext.
  c.card_k2 = init_key2(seed0, KEY2_SEED1)
  c.con_k2 = c.card_k2
  c.card_k2_on = true
  for cpu in 0..1:
    c.seed_lo[cpu] = [uint32(seed0 and 0xFFFF_FFFF'u64), uint32(KEY2_SEED1 and 0xFFFF_FFFF'u64)]
    c.seed_hi[cpu] = [uint32(seed0 shr 32), uint32(KEY2_SEED1 shr 32)]

proc set_key1_table*(c: Cart; table: seq[uint8]) =
  ## Hand the card the BIOS7 KEY1 table: it can then take KEY1 commands and
  ## serve its secure area in card (encrypted) form.
  c.key1_table = table
  if table.len == KEY1_TABLE_SIZE and c.rom.len >= 0x10:
    c.key1 = init_key1(table, c.rom.gamecode, 2, 8)
  c.secure = card_secure_area(c.rom, table)

proc new_cart*(rom: sink seq[uint8]; irq9, irq7: IrqCtl; sched: NdsScheduler): Cart =
  ## A card as direct boot leaves it: reset released, main-data mode.
  let size = rom.len
  let ir = size > 0x0C and rom[0x0C] == uint8('I')
  let sel = if size > 0x13: rom[0x13] else: 0'u8
  # `rom` is moved in last: a sink parameter used afterwards would be copied
  result = Cart(rom: rom, chip_id: chip_id_for(size, ir), irq9: irq9, irq7: irq7,
                sched: sched, backup: new_backup(), mode: cmMain)
  if size == 0: result.chip_id = 0xFFFF_FFFF'u32   # no card (GBATEK)
  # Game code 'I...' = cart with an infrared port (GBATEK "NDS Gamecodes")
  result.backup.ir = ir
  # GBATEK "DS Cartridge Backup": Rune Factory (ARFx) defeats detection,
  # "force 64Kbyte EEPROM"
  if size > 0x0E and rom[0x0C] == uint8('A') and rom[0x0D] == uint8('R') and
     rom[0x0E] == uint8('F'):
    result.backup.force_kind(bkEeprom)
  result.set_key1_table(@[])
  result.sync_key2(card_seed0(0, sel))   # Assumed: any shared seed will do

proc power_on*(c: Cart) =
  ## The card at power-on (firmware boot): held in reset, ROMCTRL 0; the
  ## BIOS releases it (ROMCTRL.29) and starts with raw commands.
  c.in_reset = true
  c.mode = cmRaw
  c.romctrl = 0

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

proc fill_chip_id(c: Cart; len: int) =
  for i in 0 ..< len: c.buf[i] = uint8((c.chip_id shr (8 * (i and 3))) and 0xFF)

proc reply_raw(c: Cart; cmd: array[8, uint8]; len: int) =
  case cmd[0]
  of 0x00:
    # header, repeated every 0x1000 bytes (GBATEK "Get Header")
    for i in 0 ..< len: c.buf[i] = c.rom_byte(i and 0xFFF)
  of 0x90: c.fill_chip_id(len)
  of 0x3C:
    # enter KEY1 mode; replies HIGH-Z
    for i in 0 ..< len: c.buf[i] = 0xFF
    if c.key1_table.len > 0: c.mode = cmKey1
  else:
    for i in 0 ..< len: c.buf[i] = 0xFF   # 9F dummy and anything else: HIGH-Z

proc reply_key1(c: Cart; wire: array[8, uint8]; len: int): array[8, uint8] =
  ## A KEY1 command: decrypted with the gamecode's level-2 key (the first
  ## command byte is the MSB of the 64-bit value). Returns it decrypted.
  var lo = (uint32(wire[4]) shl 24) or (uint32(wire[5]) shl 16) or
           (uint32(wire[6]) shl 8) or uint32(wire[7])
  var hi = (uint32(wire[0]) shl 24) or (uint32(wire[1]) shl 16) or
           (uint32(wire[2]) shl 8) or uint32(wire[3])
  c.key1.decrypt64(lo, hi)
  var cmd: array[8, uint8]
  for i in 0..3:
    cmd[i] = uint8(hi shr (24 - 8 * i))
    cmd[4 + i] = uint8(lo shr (24 - 8 * i))
  # The newer protocol sends each command twice or nine times; the repeats
  # carry the same bytes (GBATEK "Cart Protocol Variants"), and a secure
  # block's 0x200-byte portions follow one another.
  c.key1_repeat = cmd == c.last_cmd
  if not c.key1_repeat: c.sec_pos = 0
  c.last_cmd = cmd
  result = cmd
  for i in 0 ..< len: c.buf[i] = 0
  case cmd[0] shr 4
  of 0x1: c.fill_chip_id(len)
  of 0x2:
    # 2bbbbiiijjjkkkkk: secure-area block bbbb (4..7 = ROM 0x4000..0x7FFF)
    let blk = ((int(cmd[0]) and 0xF) shl 12) or (int(cmd[1]) shl 4) or (int(cmd[2]) shr 4)
    let base = blk * 0x1000
    for i in 0 ..< len:
      let a = base + ((c.sec_pos + i) and 0xFFF)
      c.buf[i] = if a >= 0x4000 and a < 0x8000 and c.secure.len == 0x4000: c.secure[a - 0x4000]
                 else: c.rom_byte(a)
    c.sec_pos += len
  else: discard   # 4, 6, A: 00 bytes; others: the KEY2 stream XOR 00

proc after_key1(c: Cart) =
  ## Mode changes take effect once the command's reply is out -- on the
  ## newer protocol (chip ID bit 31) once the command's second send is: the
  ## first one only announces it (GBATEK "Cart Protocol Variants": the
  ## BIOS sends 4/1/2/A twice, with the secure-area delay between).
  if (c.chip_id and 0x8000_0000'u32) != 0 and not c.key1_repeat: return
  case c.last_cmd[0] shr 4
  of 0x4:
    # 4llllmmmnnnkkkkk: mmmnnn seeds the card's KEY2 (GBATEK "KEY2 39bit
    # Seed Values")
    let mmmnnn = ((uint32(c.last_cmd[2]) and 0xF) shl 20) or (uint32(c.last_cmd[3]) shl 12) or
                 (uint32(c.last_cmd[4]) shl 4) or (uint32(c.last_cmd[5]) shr 4)
    let sel = if c.rom.len > 0x13: c.rom[0x13] else: 0'u8
    c.card_k2.seed(card_seed0(mmmnnn, sel), KEY2_SEED1)
  of 0x6: c.card_k2_on = false
  of 0xA: c.mode = cmMain
  else: discard

proc reply_main(c: Cart; cmd: array[8, uint8]; len: int) =
  case cmd[0]
  of 0xB7:
    var a = (int(cmd[1]) shl 24) or (int(cmd[2]) shl 16) or
            (int(cmd[3]) shl 8) or int(cmd[4])
    if a < 0x8000: a = 0x8000 + (a and 0x1FF)
    for i in 0 ..< len:
      # wraps within its 4 KB block
      c.buf[i] = c.rom_byte((a and not 0xFFF) + ((a + i) and 0xFFF))
  of 0xB8: c.fill_chip_id(len)
  else:
    for i in 0 ..< len: c.buf[i] = 0   # invalid: the KEY2 stream XOR 00

proc crypt_stream(c: Cart; s: var openArray[uint8]; card_on, con_on: bool) =
  ## XOR each side's KEY2 stream onto `s` (bytes on the wire), advancing it.
  ## Equal states on both sides cancel: advance one and copy it.
  if card_on and con_on and c.card_k2 == c.con_k2:
    c.card_k2.skip(s.len)
    c.con_k2 = c.card_k2
    return
  for i in 0 ..< s.len:
    if card_on: s[i] = s[i] xor c.card_k2.next()
    if con_on: s[i] = s[i] xor c.con_k2.next()

proc start_transfer(c: Cart) =
  let bs = (c.romctrl shr 24) and 7
  let len = if bs == 0: 0 elif bs == 7: 4 else: 0x100 shl bs
  c.buf.setLen(len)
  c.pos = 0
  if c.rom.len == 0 or c.in_reset:
    # no card / card in reset: HIGH-Z
    for i in 0 ..< len: c.buf[i] = 0xFF
  else:
    let con_cmd = (c.romctrl and (1'u32 shl 22)) != 0
    let con_data = (c.romctrl and (1'u32 shl 13)) != 0
    let gaps = (c.romctrl and (1'u32 shl 28)) != 0
    let mode = c.mode
    let card_on = c.card_k2_on and mode != cmRaw
    # command bytes: console KEY2 (ROMCTRL.22), then the card's own in main
    # mode
    var cmd = c.command
    c.crypt_stream(cmd, card_on and mode == cmMain, con_cmd)
    case mode
    of cmRaw: c.reply_raw(cmd, len)
    of cmKey1: cmd = c.reply_key1(cmd, len)
    of cmMain: c.reply_main(cmd, len)
    # reply: gap1 clocks, then data with gap2 clocks after each 0x200 bytes
    var gap = newSeq[uint8](if gaps: int(c.romctrl and 0x1FFF) else: 0)
    c.crypt_stream(gap, card_on, con_data)
    let gap2 = int((c.romctrl shr 16) and 0x3F)
    var i = 0
    while i < len:
      let n = min(0x200, len - i)
      c.crypt_stream(c.buf.toOpenArray(i, i + n - 1), card_on, con_data)
      i += n
      if gaps and i < len and gap2 > 0:
        gap.setLen(gap2)
        c.crypt_stream(gap, card_on, con_data)
    when defined(ndsdebug):
      if c.cartlog:
        var line = "card " & (if c.owner_arm7: "7 " else: "9 ") & $mode &
                   " romctrl=" & toHex(c.romctrl, 8) & " cmd="
        for b in cmd: line.add toHex(b)
        line.add " len=" & $len
        if len > 0:
          line.add " -> "
          for k in 0 ..< min(len, 8): line.add toHex(c.buf[k])
        stderr.writeLine(line)
    if mode == cmKey1: c.after_key1()
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

proc write_reg*(c: Cart; offset: uint32; v, mask: uint32; pc = 0'u32; from7 = false) =
  ## `pc` is the writing CPU's program counter (save-chip type detection);
  ## `from7`: the ARM7 wrote (each CPU has its own SEED registers).
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
    let reset_released = (c.romctrl and 0x2000_0000'u32) != 0
    c.romctrl = (((c.romctrl and not mask) or (v and mask)) and not 0x0080_8000'u32) or ready
    # bit 29 cannot be cleared once set; bit 15 (apply seed) is write-only
    if reset_released: c.romctrl = c.romctrl or 0x2000_0000'u32
    if (v and mask and 0x8000'u32) != 0:
      let cpu = if from7: 1 else: 0
      c.con_k2.seed(uint64(c.seed_lo[cpu][0]) or (uint64(c.seed_hi[cpu][0] and 0x7F) shl 32),
                    uint64(c.seed_lo[cpu][1]) or (uint64(c.seed_hi[cpu][1] and 0x7F) shl 32))
    if c.in_reset and (c.romctrl and 0x2000_0000'u32) != 0:
      # reset released: raw mode, KEY2 at its pre-init seeds (GBATEK)
      c.in_reset = false
      c.mode = cmRaw
      c.card_k2 = init_key2(KEY2_PRE_SEED0, KEY2_SEED1)
      c.card_k2_on = true
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
  of 0x1B0, 0x1B4:
    # SEED0/SEED1 low 32 bits (write-only; applied by ROMCTRL.15)
    let cpu = if from7: 1 else: 0
    let k = int(offset - 0x1B0) div 4
    c.seed_lo[cpu][k] = (c.seed_lo[cpu][k] and not mask) or (v and mask)
  of 0x1B8:
    # SEED0 high 7 bits (0x1B8), SEED1 high 7 bits (0x1BA)
    let cpu = if from7: 1 else: 0
    if (mask and 0x7F) != 0: c.seed_hi[cpu][0] = v and 0x7F
    if (mask and 0x7F_0000) != 0: c.seed_hi[cpu][1] = (v shr 16) and 0x7F
  else: discard

{.pop.}
