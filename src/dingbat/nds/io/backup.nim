## The card's save chip on the slot-1 SPI bus (AUXSPICNT 0x40001A0 bit 13,
## AUXSPIDATA 0x40001A2): EEPROM (0.5K with 8+1-bit addresses, 8K-64K with
## 16-bit, 128K with 24-bit), FRAM (16-bit) or FLASH (24-bit, the firmware
## flash's command set). GBATEK "DS Cartridge Backup".
##
## Neither the type nor the size is in the cart header. With `bkAuto` the
## chip decides at the first read or write: the SDK sends the command and
## address bytes from one routine and the data from another, so the number
## of bytes written from the address bytes' program counter is the address
## width (GBATEK, "Detection (in emulators)"). An RDID before that picks
## FLASH (EEPROMs answer it with FFh). A loaded save picks the type by its
## size instead (`set_data`).

type
  BackupKind* = enum
    bkAuto, bkNone, bkEeprom512, bkEeprom, bkEeprom128k, bkFram, bkFlash

  BackupPhase = enum
    bpIdle, bpDetect, bpAddr, bpData, bpStatus, bpWrsr, bpId, bpDone

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
    detect: seq[uint8]        ## bkAuto: address bytes held until decided
    detect_pc: uint32

const
  DEFAULT_SIZE: array[BackupKind, int] =
    [0, 0, 512, 64 * 1024, 128 * 1024, 32 * 1024, 512 * 1024]

proc new_backup*(): Backup = Backup(kind: bkAuto)

proc set_kind(b: Backup; k: BackupKind; size = 0) =
  b.kind = k
  let n = if size > 0: size else: DEFAULT_SIZE[k]
  if b.data.len != n:
    b.data.setLen(n)
    for i in 0 ..< n: b.data[i] = 0xFF

proc set_data*(b: Backup; save: seq[uint8]) =
  ## A save file: its size names the chip (512 B: 0.5K EEPROM; 8K or 64K:
  ## EEPROM; 32K: FRAM; 128K: 24-bit EEPROM; 256K and up: FLASH).
  let k = case save.len
    of 512: bkEeprom512
    of 8 * 1024, 64 * 1024: bkEeprom
    of 32 * 1024: bkFram
    of 128 * 1024: bkEeprom128k
    of 0: bkAuto
    else: bkFlash
  b.set_kind(k, save.len)
  for i in 0 ..< save.len: b.data[i] = save[i]
  b.dirty = false

proc addr_bytes(k: BackupKind): int =
  case k
  of bkEeprom512: 1
  of bkEeprom, bkFram: 2
  else: 3

proc flash_id(b: Backup): array[3, uint8] =
  ## ST parts by size (GBATEK's chip list): M45PE20/40/80.
  case b.data.len
  of 1024 * 1024: [0x20'u8, 0x40, 0x14]
  of 512 * 1024: [0x20'u8, 0x40, 0x13]
  else: [0x20'u8, 0x40, 0x12]

proc mask_addr(b: Backup; a: uint32): int {.inline.} =
  if b.data.len == 0: 0 else: int(a mod uint32(b.data.len))

proc start_access(b: Backup) =
  ## The command's address width is known: collect the address.
  b.address = 0
  b.addr_left = addr_bytes(b.kind)
  b.dummy = if b.kind == bkFlash and b.cmd == 0x0B: 1 else: 0
  if b.kind == bkEeprom512 and (b.cmd and 8) != 0: b.address = 0x100  # RDHI/WRHI
  b.phase = bpAddr

proc data_byte(b: Backup; v: uint8): uint8 =
  ## One data byte of a read or write at the current address.
  let i = b.mask_addr(b.address)
  case b.cmd
  of 0x03, 0x0B:
    if b.dummy > 0:
      dec b.dummy
      return 0xFF
    result = if b.data.len > 0: b.data[i] else: 0xFF
  of 0x02, 0x0A:
    if (b.status and 2) != 0 and b.data.len > 0:
      # EEPROM/FRAM: plain write; FLASH: 0A page write replaces, 02 page
      # program can only clear bits
      b.data[i] = if b.kind == bkFlash and b.cmd == 0x02: b.data[i] and v else: v
      b.dirty = true
    result = 0xFF
  else: result = 0xFF
  if b.kind == bkFlash and b.cmd in {0x02'u8, 0x0A}:
    b.address = (b.address and not 0xFF'u32) or ((b.address + 1) and 0xFF)  # page wraps
  else:
    inc b.address

proc decide(b: Backup) =
  ## bkAuto: the address bytes are all in.
  let n = b.detect.len
  # 3 address bytes: FLASH, or the rare 128K EEPROM (indistinguishable
  # until it writes; FLASH is the common one)
  let k = if n <= 1: bkEeprom512 elif n == 2: bkEeprom else: bkFlash
  b.set_kind(k)
  b.start_access()
  for v in b.detect:
    b.address = (b.address shl 8) or v
    dec b.addr_left
  if k == bkEeprom512 and (b.cmd and 8) != 0: b.address = b.address or 0x100
  b.detect.setLen(0)
  b.phase = bpData

proc flash_erase(b: Backup; size: uint32) =
  if (b.status and 2) == 0 or b.data.len == 0: return
  let base = b.mask_addr(b.address and not (size - 1))
  for i in 0 ..< min(int(size), b.data.len - base): b.data[base + i] = 0xFF
  b.dirty = true

proc transfer*(b: Backup; v: uint8; pc: uint32): uint8 =
  ## One byte while the chip is selected; returns the chip's reply.
  result = 0xFF
  if b.kind == bkNone: return
  case b.phase
  of bpIdle:
    b.cmd = v
    case v
    of 0x06: b.status = b.status or 2; b.phase = bpDone          # WREN
    of 0x04: b.status = b.status and not 2'u8; b.phase = bpDone  # WRDI
    of 0x05: b.phase = bpStatus                                  # RDSR
    of 0x01: b.phase = bpWrsr                                    # WRSR
    of 0x9F:                                                     # RDID
      if b.kind == bkAuto: b.set_kind(bkFlash)
      b.id_idx = 0
      b.phase = bpId
    of 0x03, 0x0B, 0x02, 0x0A:
      if b.kind == bkAuto:
        b.detect.setLen(0)
        b.phase = bpDetect
      elif b.kind != bkFlash and b.kind != bkEeprom512 and v in {0x0B'u8, 0x0A}:
        b.phase = bpDone                                         # not a command here
      else: b.start_access()
    of 0xDB, 0xD8:                                               # FLASH erases
      if b.kind == bkAuto: b.set_kind(bkFlash)
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
      if b.cmd == 0xDB: b.flash_erase(0x100); b.phase = bpDone
      elif b.cmd == 0xD8: b.flash_erase(0x10000); b.phase = bpDone
      else: b.phase = bpData
  of bpData: result = b.data_byte(v)
  of bpStatus:
    result = b.status
    if b.kind == bkEeprom512: result = result or 0xF0
  of bpWrsr:
    if (b.status and 2) != 0:
      b.status = (b.status and 3) or (v and 0x8C)
      b.status = b.status and not 2'u8
    b.phase = bpDone
  of bpId:
    if b.kind == bkFlash:
      let id = b.flash_id()
      result = if b.id_idx < 3: id[b.id_idx] else: 0xFF
      inc b.id_idx
  of bpDone: discard

proc deselect*(b: Backup) =
  ## Chip select released: a finished write drops the write-enable latch.
  if b.phase == bpDetect and b.detect.len > 0: b.decide()
  if b.phase in {bpAddr, bpData, bpDone} and b.cmd in {0x02'u8, 0x0A, 0xDB, 0xD8}:
    b.status = b.status and not 2'u8
  b.phase = bpIdle
