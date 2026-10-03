## The card's save chip on the slot-1 SPI bus (AUXSPICNT 0x40001A0 bit 13,
## AUXSPIDATA 0x40001A2): EEPROM (0.5K with 8+1-bit addresses, 8K-64K with
## 16-bit, 128K with 24-bit), FRAM (16-bit) or FLASH (24-bit, the firmware
## flash's command set). GBATEK "DS Cartridge Backup"; docs/nds/saves.md.
##
## Neither the type nor the size is in the cart header. The chip decides at
## the game's first read or write: the SDK sends the command and address
## bytes from one routine and the data from another, so the number of bytes
## written from the address bytes' program counter is the address width
## (GBATEK, "Detection (in emulators)"). An RDID or a FLASH erase before
## that picks FLASH (EEPROMs answer RDID with FFh). While a detected chip is
## unwritten every access detects again (GBATEK: Over the Hedge first
## addresses an 8K EEPROM, then uses its 0.5K one).
##
## A loaded save of an EEPROM/FRAM size (0.5K, 8K, 32K, 64K, 128K) names
## its chip outright. Any other size (a FLASH size, or a file padded or
## trimmed elsewhere) only hints: the game's accesses pick the address
## width, then the image is fitted to a chip of that width (`fit`). A text
## footer is stripped first (`image_len`).
##
## Infrared carts (game code starting 'I', e.g. the P-letter series) put an
## IR controller between the SPI bus and the save chip (GBATEK "DS Cart
## Infrared Cartridge SPI Commands"): the first byte after chip select picks
## 00h = pass the rest of the transfer to the save chip, 01h = IR receive
## (length, then data), 02h = IR transmit, 08h = version (NEW firmware: AAh).
## No IR peer is modelled: receives return length 0, transmits vanish.

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  BackupKind* = enum
    bkAuto, bkNone, bkEeprom512, bkEeprom, bkEeprom128k, bkFram, bkFlash

  BackupPhase = enum
    bpIdle, bpDetect, bpAddr, bpData, bpStatus, bpWrsr, bpId, bpDone

  IrPhase = enum
    irCommand,            ## next byte is the IR controller's command
    irPass,               ## 00h: bytes go to the save chip
    irVersion,            ## 08h: the version byte follows
    irRecv,               ## 01h: length (0), then nothing
    irIgnore              ## 02h-07h and unknown: swallowed

  Backup* = ref object
    kind*: BackupKind
    data*: seq[uint8]
    dirty*: bool              ## written since the frontend last saved
    status: uint8             ## WEL (bit 1), WP (bits 2-3), SRWD (bit 7)
    phase: BackupPhase
    cmd: uint8
    address: uint32
    addr_left: int
    dummy: int                ## FLASH fast read: one dummy byte
    id_idx: int
    detect: seq[uint8]        ## detecting: address bytes held until decided
    detect_pc: uint32
    ir*: bool                 ## infrared cart: IR controller in front
    ir_phase: IrPhase
    detected*: bool           ## the kind is the game's accesses' (re-detected
                              ## while unwritten; FLASH grows), not a file's size
    loaded: bool              ## `data` started from a save file
    written: bool             ## written or erased since the kind was decided
    flash_cmds: bool          ## a FLASH-only command (RDID, erase, page write) came
    force*: BackupKind        ## a fixed kind for a game detection gets wrong
    dropped*: int             ## bytes of a loaded file past the chip that were
                              ## not padding (reported, not kept)

const
  KB = 1024
  FLASH_SIZES = [256 * KB, 512 * KB, 1024 * KB, 8192 * KB]   ## GBATEK's chip list
  FOOTER_MARK = "|<--Snip above here to create a raw sav by excluding this "

proc new_backup*(): Backup = Backup(kind: bkAuto, detected: true)

proc addr_bytes(k: BackupKind): int =
  case k
  of bkEeprom512: 1
  of bkEeprom, bkFram: 2
  else: 3

proc chip_size(k: BackupKind; have: int): int =
  ## The chip of kind `k` that an image of `have` bytes belongs to. Without
  ## an image, or where the width allows several, the largest common one
  ## (8K and 64K EEPROMs both take 16-bit addresses: 64K holds either;
  ## FLASH: 512K, growing on use, `reach`).
  case k
  of bkEeprom512: 512
  of bkEeprom: (if have in 1 .. 8 * KB: 8 * KB else: 64 * KB)
  of bkFram: 32 * KB
  of bkEeprom128k: 128 * KB
  of bkFlash:
    if have == 0: return 512 * KB
    for s in FLASH_SIZES:
      if s >= have: return s
    FLASH_SIZES[^1]
  else: 0

proc image_len*(save: openArray[uint8]): int =
  ## The save image's length in a save file: all of it, unless it ends in a
  ## text footer that says the raw image is what precedes it ("|<--Snip
  ## above here to create a raw sav by excluding this ... footer", the
  ## .dsv form; searched in the last 1 KB).
  result = save.len
  let m = FOOTER_MARK.len
  for i in max(0, save.len - 1024) .. save.len - m:
    var hit = true
    for k in 0 ..< m:
      if save[i + k] != uint8(FOOTER_MARK[k]):
        hit = false
        break
    if hit: return i

proc is_padding(d: openArray[uint8]; size: int): bool =
  ## Bytes past a chip's `size` that are no save data: all FFh, all 00h, or
  ## whole repeats of the chip (a mirrored dump).
  var ff, zero, mirror = true
  for i in size ..< d.len:
    if d[i] != 0xFF: ff = false
    if d[i] != 0x00: zero = false
    if size == 0 or d[i] != d[i mod size]: mirror = false
  ff or zero or mirror

proc fit(b: Backup; k: BackupKind) =
  ## Make `data` a chip of kind `k`: a loaded image keeps its bytes, padded
  ## with FFh (an erased chip) or cut where the excess is padding. Excess
  ## that is not padding is reported and counted in `dropped`.
  let have = b.data.len
  let size = chip_size(k, have)
  b.kind = k
  if have == size: return
  if have > size and not is_padding(b.data, size):
    b.dropped = have - size
    stderr.writeLine("nds: the save file has " & $b.dropped & " bytes past the " & $size &
                     "-byte chip the game uses that are not padding; they are not kept")
  b.data.setLen(size)
  for i in have ..< size: b.data[i] = 0xFF
  # the fitted image is what the frontend should store from now on (unless
  # bytes were dropped: then only once the game writes it)
  if b.loaded and b.dropped == 0: b.dirty = true

proc set_data*(b: Backup; save: seq[uint8]) =
  ## A save file. 0.5K, 8K/64K, 32K and 128K name EEPROM, EEPROM, FRAM and
  ## 24-bit EEPROM; anything else is held until the game's accesses pick
  ## the chip (`fit`). A stripped footer marks the chip dirty, so the
  ## frontend stores the raw image.
  let n = image_len(save)
  b.data = save[0 ..< n]
  b.dirty = n != save.len
  b.loaded = n > 0
  b.written = false
  b.flash_cmds = false
  b.dropped = 0
  b.detected = false
  b.phase = bpIdle
  if b.force != bkAuto:
    b.fit(b.force)
    return
  case n
  of 512: b.kind = bkEeprom512
  of 8 * KB, 64 * KB: b.kind = bkEeprom
  of 32 * KB: b.kind = bkFram
  of 128 * KB: b.kind = bkEeprom128k
  else:
    b.kind = bkAuto
    b.detected = true

proc force_kind*(b: Backup; k: BackupKind) =
  ## A game GBATEK names as defeating detection: its chip, fixed.
  b.force = k
  b.detected = false
  b.fit(k)

proc flash_id(b: Backup): array[3, uint8] =
  ## By size, from GBATEK's chip list: ST M45PE20 / 45PE40 / 45PE80,
  ## Macronix MX25L6445E (8 MB, Art Academy).
  case b.data.len
  of 8192 * KB: [0xC2'u8, 0x20, 0x17]
  of 1024 * KB: [0x20'u8, 0x40, 0x14]
  of 512 * KB: [0x20'u8, 0x40, 0x13]
  else: [0x20'u8, 0x40, 0x12]

proc page_size(b: Backup): int =
  ## Writes wrap within a page (GBATEK's chip list: M95040 16, M95640 32,
  ## M95512 128 bytes; FLASH 256); FRAM has no limit. 128K EEPROM's page is
  ## not listed: Assumed 256.
  case b.kind
  of bkEeprom512: 16
  of bkEeprom: (if b.data.len <= 8 * KB: 32 else: 128)
  of bkEeprom128k, bkFlash: 256
  else: 0

proc protected(b: Backup; i: int): bool =
  ## EEPROM/FRAM status bits 2-3: 1 = upper quarter, 2 = upper half, 3 = all
  ## read-only (GBATEK "Status Register").
  if b.kind == bkFlash: return false
  case (b.status shr 2) and 3
  of 0: false
  of 1: i >= b.data.len - b.data.len div 4
  of 2: i >= b.data.len div 2
  else: true

proc mask_addr(b: Backup; a: uint32): int {.inline.} =
  if b.data.len == 0: 0 else: int(a mod uint32(b.data.len))

proc reach(b: Backup) =
  ## A detected FLASH holds what the game addresses: past its end it grows
  ## to the next listed size (erased), so 1M and 8M chips work without a
  ## save file. A loaded file of a chip's exact size mirrors as hardware.
  if b.detected and b.kind == bkFlash and int(b.address) >= b.data.len:
    for s in FLASH_SIZES:
      if s > int(b.address):
        let had = b.data.len
        b.data.setLen(s)
        for i in had ..< s: b.data[i] = 0xFF
        return

proc start_access(b: Backup) =
  ## The command's address width is known: collect the address.
  b.address = 0
  b.addr_left = addr_bytes(b.kind)
  b.dummy = if b.kind == bkFlash and b.cmd == 0x0B: 1 else: 0
  b.phase = bpAddr

proc address_done(b: Backup) =
  ## 0.5K EEPROM: RDHI/WRHI (command bit 3) carry address bit 8.
  if b.kind == bkEeprom512 and (b.cmd and 8) != 0: b.address = b.address or 0x100

proc to_eeprom128k(b: Backup; i: int; v: uint8): bool =
  ## A detected 24-bit chip is FLASH or a 128K EEPROM (GBATEK: "FLASH has
  ## same 24bit bus-width as 128Kbyte EEPROM, but isn't compatible on
  ## writing"). A 02h write that sets a bit can only be the EEPROM's
  ## write+erase (FLASH 02h only clears bits, and FLASH code erases first):
  ## then, with nothing past 128K, the chip is the EEPROM.
  if not b.detected or b.flash_cmds or (v and not b.data[i]) == 0: return false
  for k in 128 * KB ..< b.data.len:
    if b.data[k] != 0xFF: return false
  b.kind = bkEeprom128k
  b.data.setLen(128 * KB)
  b.detected = false
  true

proc data_byte(b: Backup; v: uint8): uint8 =
  ## One data byte of a read or write at the current address.
  b.reach()
  var i = b.mask_addr(b.address)
  case b.cmd
  of 0x03, 0x0B:
    if b.dummy > 0:
      dec b.dummy
      return 0xFF
    result = if b.data.len > 0: b.data[i] else: 0xFF
  of 0x02, 0x0A:
    if (b.status and 2) != 0 and b.data.len > 0:
      if b.kind == bkFlash and b.cmd == 0x02 and b.to_eeprom128k(i, v):
        i = b.mask_addr(b.address)
      if b.kind == bkFlash and b.cmd == 0x0A: b.flash_cmds = true
      if not b.protected(i):
        # EEPROM/FRAM: plain write; FLASH: 0A page write replaces, 02 page
        # program can only clear bits
        b.data[i] = if b.kind == bkFlash and b.cmd == 0x02: b.data[i] and v else: v
        b.dirty = true
        b.written = true
    result = 0xFF
  else: result = 0xFF
  let page = if b.cmd in {0x02'u8, 0x0A}: b.page_size() else: 0
  if page > 0:
    let p = uint32(page - 1)
    b.address = (b.address and not p) or ((b.address + 1) and p)   # page wraps
  else:
    inc b.address

proc decide(b: Backup) =
  ## Detecting: the address bytes are all in.
  let n = min(b.detect.len, 3)
  let k = if n <= 1: bkEeprom512 elif n == 2: bkEeprom else: bkFlash
  if b.kind == bkAuto or addr_bytes(b.kind) != n: b.fit(k)
  b.start_access()
  for v in b.detect:
    b.address = (b.address shl 8) or v
    dec b.addr_left
  b.address_done()
  b.detect.setLen(0)
  b.phase = bpData

proc flash_erase(b: Backup; size: uint32) =
  b.flash_cmds = true
  if (b.status and 2) == 0 or b.data.len == 0: return
  b.reach()
  let base = b.mask_addr(b.address and not (size - 1))
  for i in 0 ..< min(int(size), b.data.len - base): b.data[base + i] = 0xFF
  b.dirty = true
  b.written = true

proc chip_transfer(b: Backup; v: uint8; pc: uint32): uint8

proc transfer*(b: Backup; v: uint8; pc: uint32): uint8 =
  ## One byte while the chip is selected; returns the reply.
  if not b.ir: return b.chip_transfer(v, pc)
  case b.ir_phase
  of irPass: return b.chip_transfer(v, pc)
  of irCommand:
    b.ir_phase = case v
      of 0x00: irPass
      of 0x01: irRecv
      of 0x08: irVersion
      else: irIgnore
    # Assumed: the controller drives nothing during its command byte.
    return 0xFF
  of irVersion:
    b.ir_phase = irIgnore
    return 0xAA
  of irRecv, irIgnore:
    return 0x00

proc detecting(b: Backup): bool =
  ## Reads and writes go through detection while the kind is open or was
  ## detected and nothing has been written yet (and no FLASH-only command
  ## settled it).
  b.kind == bkAuto or (b.detected and not b.written and not b.flash_cmds)

proc chip_transfer(b: Backup; v: uint8; pc: uint32): uint8 =
  ## One byte at the save chip itself.
  result = 0xFF
  if b.kind == bkNone: return
  case b.phase
  of bpIdle:
    b.cmd = v
    case v
    of 0x06: b.status = b.status or 2; b.phase = bpDone          # WREN
    of 0x04: b.status = b.status and not 2'u8; b.phase = bpDone  # WRDI
    of 0x05: b.phase = bpStatus                                  # RDSR
    of 0x01:                                                     # WRSR
      # not a FLASH command (GBATEK's firmware-flash list has none)
      b.phase = if b.kind == bkFlash: bpDone else: bpWrsr
    of 0x9F:                                                     # RDID
      if b.kind == bkAuto: b.fit(bkFlash)
      if b.kind == bkFlash: b.flash_cmds = true
      b.id_idx = 0
      b.phase = bpId
    of 0x03, 0x0B, 0x02, 0x0A:
      if b.detecting():
        b.detect.setLen(0)
        b.phase = bpDetect
      elif b.kind != bkFlash and b.kind != bkEeprom512 and v in {0x0B'u8, 0x0A}:
        b.phase = bpDone                                         # not a command here
      else: b.start_access()
    of 0xDB, 0xD8:                                               # FLASH erases
      if b.kind == bkAuto: b.fit(bkFlash)
      if b.kind == bkFlash: b.start_access() else: b.phase = bpDone
    else: b.phase = bpDone
  of bpDetect:
    if b.detect.len == 0:
      b.detect_pc = pc
      b.detect.add v
      return
    if pc == b.detect_pc and b.detect.len < 3:
      b.detect.add v
      return
    b.decide()
    result = b.data_byte(v)
  of bpAddr:
    b.address = (b.address shl 8) or v
    dec b.addr_left
    if b.addr_left == 0:
      b.address_done()
      if b.cmd == 0xDB: b.flash_erase(0x100); b.phase = bpDone
      elif b.cmd == 0xD8: b.flash_erase(0x10000); b.phase = bpDone
      else: b.phase = bpData
  of bpData: result = b.data_byte(v)
  of bpStatus:
    # WIP (bit 0) always 0: writes complete at once
    result = b.status
    if b.kind == bkEeprom512: result = result or 0xF0
  of bpWrsr:
    if (b.status and 2) != 0:
      # only WP (and SRWD, which the 0.5K part lacks) change; WEL drops
      let m = if b.kind == bkEeprom512: 0x0C'u8 else: 0x8C'u8
      b.status = (b.status and 1) or (v and m)
    b.phase = bpDone
  of bpId:
    if b.kind == bkFlash:
      let id = b.flash_id()
      result = if b.id_idx < 3: id[b.id_idx] else: 0xFF
      inc b.id_idx
  of bpDone: discard

proc deselect*(b: Backup) =
  ## Chip select released: a finished write drops the write-enable latch.
  b.ir_phase = irCommand
  if b.phase == bpDetect and b.detect.len > 0: b.decide()
  if b.phase in {bpAddr, bpData, bpDone} and b.cmd in {0x02'u8, 0x0A, 0xDB, 0xD8}:
    b.status = b.status and not 2'u8
  b.phase = bpIdle

{.pop.}
