## DS card encryption (GBATEK "DS Encryption by Gamecode/Idcode (KEY1)" and
## "DS Encryption by Random Seed (KEY2)").
##
## KEY1 is a Blowfish variant keyed by the gamecode (or the firmware's
## idcode). Its 0x1048-byte initial table lives in the ARM7 BIOS at
## 0x30..0x1077 and is read from the user's dump at run time: dingbat has no
## copy, so without a BIOS7 dump nothing here can run (key1_table_from_bios7
## returns an empty table and callers fall back).
##
## KEY2 is a pair of 39-bit LFSRs whose low bytes XOR the card bus stream on
## both ends (the card encrypts, the console's card interface decrypts).

type
  Key1* = object
    ## P-array (18 words) + 4 S-boxes (256 words each), as GBATEK's keybuf.
    buf*: array[0x412, uint32]
    code*: array[3, uint32]   ## GBATEK's keycode[0..2]

  Key2* = object
    x*, y*: uint64            ## 39-bit registers

const
  KEY1_TABLE_OFFSET* = 0x30   ## in the ARM7 BIOS (GBATEK "KEY1")
  KEY1_TABLE_SIZE* = 0x1048
  KEY2_MASK = (1'u64 shl 39) - 1
  KEY2_SEED1* = 0x5C879B9B05'u64          ## seed 1, before and after init
  KEY2_PRE_SEED0* = 0x58C56DE0E8'u64      ## card seed 0 after reset
  KEY2_SEED_BYTES* = [0xE8'u8, 0x4D, 0x5A, 0xB1, 0x17, 0x8F, 0x99, 0xD5]
    ## header[0x13] bits 0-2 pick one (GBATEK "KEY2 39bit Seed Values")
  SECURE_AREA_ID* = "encryObj"
  SECURE_DESTROYED* = 0xE7FFDEFF'u32      ## what the BIOS writes over the ID

# ---------------------------------------------------------------------------
# KEY1

proc key1_table_from_bios7*(bios7: openArray[uint8]): seq[uint8] =
  ## The KEY1 initial table from an ARM7 BIOS dump, or @[] when the image
  ## is too short to be one (the HLE BIOS has no table either).
  if bios7.len < KEY1_TABLE_OFFSET + KEY1_TABLE_SIZE: return @[]
  result = @(bios7.toOpenArray(KEY1_TABLE_OFFSET, KEY1_TABLE_OFFSET + KEY1_TABLE_SIZE - 1))
  # A dump with the first 4 KB zero-filled (GBATEK "BIOSes": incomplete
  # NDS7 dumps exist) has no table.
  var any = false
  for b in result:
    if b != 0: any = true; break
  if not any: result = @[]

proc f(k: Key1; z: uint32): uint32 {.inline.} =
  var x = k.buf[0x012 + int((z shr 24) and 0xFF)]
  x = k.buf[0x112 + int((z shr 16) and 0xFF)] + x
  x = k.buf[0x212 + int((z shr 8) and 0xFF)] xor x
  k.buf[0x312 + int(z and 0xFF)] + x

proc encrypt64*(k: Key1; lo, hi: var uint32) =
  ## GBATEK encrypt_64bit: lo = [ptr+0] (Y), hi = [ptr+4] (X).
  var y = lo
  var x = hi
  for i in 0 .. 0x0F:
    let z = k.buf[i] xor x
    x = y xor k.f(z)
    y = z
  lo = x xor k.buf[0x10]
  hi = y xor k.buf[0x11]

proc decrypt64*(k: Key1; lo, hi: var uint32) =
  ## GBATEK decrypt_64bit.
  var y = lo
  var x = hi
  for i in countdown(0x11, 0x02):
    let z = k.buf[i] xor x
    x = y xor k.f(z)
    y = z
  lo = x xor k.buf[0x01]
  hi = y xor k.buf[0x00]

proc bswap32(v: uint32): uint32 {.inline.} =
  (v shr 24) or ((v shr 8) and 0xFF00) or ((v shl 8) and 0xFF0000) or (v shl 24)

proc apply_keycode(k: var Key1; modulo: int) =
  k.encrypt64(k.code[1], k.code[2])
  k.encrypt64(k.code[0], k.code[1])
  for i in countup(0, 0x44, 4):
    k.buf[i div 4] = k.buf[i div 4] xor bswap32(k.code[(i mod modulo) div 4])
  var s0, s1: uint32
  for i in countup(0, 0x1040, 8):
    k.encrypt64(s0, s1)
    k.buf[i div 4] = s1
    k.buf[i div 4 + 1] = s0

proc init_key1*(table: openArray[uint8]; idcode: uint32; level, modulo: int): Key1 =
  ## GBATEK init_keycode(idcode, level, modulo, nds). `table` is the
  ## 0x1048-byte BIOS7 table (key1_table_from_bios7).
  doAssert table.len == KEY1_TABLE_SIZE
  for i in 0 ..< result.buf.len:
    result.buf[i] = uint32(table[i * 4]) or (uint32(table[i * 4 + 1]) shl 8) or
                    (uint32(table[i * 4 + 2]) shl 16) or (uint32(table[i * 4 + 3]) shl 24)
  result.code[0] = idcode
  result.code[1] = idcode shr 1
  result.code[2] = idcode shl 1
  if level >= 1: result.apply_keycode(modulo)
  if level >= 2: result.apply_keycode(modulo)
  result.code[1] = result.code[1] shl 1
  result.code[2] = result.code[2] shr 1
  if level >= 3: result.apply_keycode(modulo)

proc rd32le(s: openArray[uint8]; i: int): uint32 {.inline.} =
  uint32(s[i]) or (uint32(s[i + 1]) shl 8) or (uint32(s[i + 2]) shl 16) or
    (uint32(s[i + 3]) shl 24)

proc wr32le(s: var openArray[uint8]; i: int; v: uint32) {.inline.} =
  s[i] = uint8(v); s[i + 1] = uint8(v shr 8); s[i + 2] = uint8(v shr 16)
  s[i + 3] = uint8(v shr 24)

proc gamecode*(rom: openArray[uint8]): uint32 =
  if rom.len < 0x10: 0'u32 else: rd32le(rom, 0x0C)

proc crypt_block(k: Key1; s: var openArray[uint8]; at: int; encrypt: bool) =
  var lo = rd32le(s, at)
  var hi = rd32le(s, at + 4)
  if encrypt: k.encrypt64(lo, hi) else: k.decrypt64(lo, hi)
  wr32le(s, at, lo)
  wr32le(s, at + 4, hi)

proc decrypt_secure_area*(table: openArray[uint8]; gamecode: uint32;
                          area: var openArray[uint8]) =
  ## GBATEK gamecart_decryption, the secure-area half: the first 8 bytes
  ## with the level-2 key, then every 8 bytes of the first 2 KB with the
  ## level-3 key. `area` starts at ROM 0x4000 (at least 0x800 bytes).
  let k2 = init_key1(table, gamecode, 2, 8)
  k2.crypt_block(area, 0, false)
  let k3 = init_key1(table, gamecode, 3, 8)
  for i in countup(0, 0x7F8, 8): k3.crypt_block(area, i, false)

proc encrypt_secure_area*(table: openArray[uint8]; gamecode: uint32;
                          area: var openArray[uint8]) =
  ## The inverse of decrypt_secure_area: what a card holds.
  let k3 = init_key1(table, gamecode, 3, 8)
  for i in countup(0, 0x7F8, 8): k3.crypt_block(area, i, true)
  let k2 = init_key1(table, gamecode, 2, 8)
  k2.crypt_block(area, 0, true)

type SecureAreaForm* = enum
  saNone        ## no secure area (ARM9 ROM offset outside 0x4000..0x7FFF)
  saEncrypted   ## as on the card: decrypts to "encryObj"
  saDecrypted   ## decrypted, ID still "encryObj"
  saDestroyed   ## decrypted, ID already overwritten by E7FFDEFF E7FFDEFF
  saUnknown     ## anything else (homebrew zero fill; or encrypted, no key)

proc has_secure_area*(rom: openArray[uint8]): bool =
  ## GBATEK "Secure Area Size": present when the ARM9 ROM offset is in
  ## 0x4000..0x7FFF.
  if rom.len < 0x8000: return false
  let off = rd32le(rom, 0x20)
  off >= 0x4000'u32 and off < 0x8000'u32

proc id_is(area: openArray[uint8]): bool =
  for i in 0..7:
    if area[i] != uint8(SECURE_AREA_ID[i]): return false
  true

proc secure_area_form*(rom: openArray[uint8]; table: openArray[uint8]): SecureAreaForm =
  ## Which form a dump's secure area (ROM 0x4000..) is in. Recognising the
  ## encrypted form needs the KEY1 table.
  if not rom.has_secure_area(): return saNone
  if id_is(rom.toOpenArray(0x4000, 0x4007)): return saDecrypted
  if rd32le(rom, 0x4000) == SECURE_DESTROYED and rd32le(rom, 0x4004) == SECURE_DESTROYED:
    return saDestroyed
  if table.len == KEY1_TABLE_SIZE:
    var first = @(rom.toOpenArray(0x4000, 0x4007))
    let k2 = init_key1(table, rom.gamecode, 2, 8)
    k2.crypt_block(first, 0, false)
    let k3 = init_key1(table, rom.gamecode, 3, 8)
    k3.crypt_block(first, 0, false)
    if id_is(first): return saEncrypted
  saUnknown

proc card_secure_area*(rom: openArray[uint8]; table: openArray[uint8]): seq[uint8] =
  ## ROM 0x4000..0x7FFF as a card would hold it (first 2 KB KEY1-encrypted),
  ## for the KEY1 "Get Secure Area Block" command: decrypted dumps are
  ## re-encrypted with the ID put back; other forms are served as dumped.
  ## Without the KEY1 table there are no KEY1 commands: @[].
  if table.len != KEY1_TABLE_SIZE: return @[]
  result = newSeq[uint8](0x4000)
  for i in 0 ..< 0x4000:
    result[i] = if 0x4000 + i < rom.len: rom[0x4000 + i] else: 0xFF'u8
  case rom.secure_area_form(table)
  of saDecrypted, saDestroyed:
    for i in 0..7: result[i] = uint8(SECURE_AREA_ID[i])
    encrypt_secure_area(table, rom.gamecode, result)
  else: discard

proc boot_secure_area*(rom: openArray[uint8]; table: openArray[uint8];
                       area: var openArray[uint8]): bool =
  ## What the BIOS leaves of the first 2 KB of the ARM9 binary when the
  ## ROM offset is 0x4000 (`area` = those bytes as copied from the dump):
  ## decrypted, ID checked, then the ID (or, if it does not match, the whole
  ## 2 KB) overwritten with E7FFDEFF (GBATEK "Secure Area ID"). Returns
  ## false when an encrypted dump cannot be decrypted (no KEY1 table) or the
  ## form is not recognised; `area` is then left as dumped.
  case rom.secure_area_form(table)
  of saEncrypted:
    decrypt_secure_area(table, rom.gamecode, area)
    wr32le(area, 0, SECURE_DESTROYED); wr32le(area, 4, SECURE_DESTROYED)
    true
  of saDecrypted:
    wr32le(area, 0, SECURE_DESTROYED); wr32le(area, 4, SECURE_DESTROYED)
    true
  of saDestroyed: true
  else: false

# ---------------------------------------------------------------------------
# KEY2

proc reverse39(v: uint64): uint64 =
  for i in 0 .. 38:
    if (v and (1'u64 shl i)) != 0: result = result or (1'u64 shl (38 - i))

proc seed*(k: var Key2; seed0, seed1: uint64) =
  ## Registers start as the seeds with their 39 bits reversed.
  k.x = reverse39(seed0 and KEY2_MASK)
  k.y = reverse39(seed1 and KEY2_MASK)

proc init_key2*(seed0, seed1: uint64): Key2 = result.seed(seed0, seed1)

proc next*(k: var Key2): uint8 {.inline.} =
  ## Advance both registers by one byte; the byte to XOR onto the stream.
  ## Step-then-XOR is what yields GBATEK's pre-init dummy stream
  ## (HIGH-Z, C5, 3A, 81, ...), checked in tests/nds_boot_test.nim.
  let x = k.x
  let y = k.y
  k.x = ((((x shr 5) xor (x shr 17) xor (x shr 18) xor (x shr 31)) and 0xFF) +
         (x shl 8)) and KEY2_MASK
  k.y = ((((y shr 5) xor (y shr 23) xor (y shr 18) xor (y shr 31)) and 0xFF) +
         (y shl 8)) and KEY2_MASK
  uint8((k.x xor k.y) and 0xFF)

proc skip*(k: var Key2; n: int) =
  for _ in 0 ..< n: discard k.next()

proc card_seed0*(mmmnnn: uint32; seed_select: uint8): uint64 =
  ## Card seed 0 after "Activate KEY2" (GBATEK): (mmmnnn shl 15) + 0x6000 +
  ## seed byte.
  (uint64(mmmnnn and 0xFFFFFF) shl 15) + 0x6000'u64 +
    uint64(KEY2_SEED_BYTES[seed_select and 7])
