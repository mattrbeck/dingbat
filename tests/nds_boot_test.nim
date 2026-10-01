## DS boot and card encryption (src/dingbat/nds/io/cartcrypt.nim, cart.nim,
## boot.nim): KEY2 against GBATEK's documented stream, KEY1 round trips,
## the secure-area forms, the card's whole boot handshake driven through its
## registers as the BIOS drives it (both protocol variants), and direct
## boot's secure-area handling.
##
## dingbat has no copy of the BIOS7 KEY1 table, so the KEY1 checks run on a
## made-up table (any 0x1048 bytes make a valid key schedule). With the
## user's dumps ($DINGBAT_NDS_BIOS, and SoulSilver at $DINGBAT_NDS_GAME) the
## real table is also checked against a game header's secure-area CRC.
##
## Run with: nimble test_ndsboot

import std/[os, strutils]
import dingbat/nds/[sched, nds]
import dingbat/nds/io/[irq, cart, cartcrypt]

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

const ALL = 0xFFFF_FFFF'u32

proc fake_table(): seq[uint8] =
  ## A stand-in KEY1 table: xorshift bytes.
  result = newSeq[uint8](KEY1_TABLE_SIZE)
  var x = 0x2545F491'u32
  for i in 0 ..< result.len:
    x = x xor (x shl 13); x = x xor (x shr 17); x = x xor (x shl 5)
    result[i] = uint8(x shr 24)

proc crc16(data: openArray[uint8]): uint16 =
  var crc = 0xFFFF'u16
  for b in data:
    crc = crc xor uint16(b)
    for _ in 0..7:
      crc = if (crc and 1) != 0: (crc shr 1) xor 0xA001'u16 else: crc shr 1
  crc

proc w32(s: var seq[uint8]; i: int; v: uint32) =
  for k in 0..3: s[i + k] = uint8(v shr (8 * k))

proc fake_rom(size: int; form: SecureAreaForm; table: seq[uint8]): seq[uint8] =
  ## A ROM with an ARM9 binary at 0x4000 (-> 0x02000000, entry 0x02000800)
  ## and an ARM7 one at 0x8000, its secure area in `form`.
  result = newSeq[uint8](size)
  for i in 0 ..< size: result[i] = uint8((i * 7 + (i shr 8)) and 0xFF)
  for i in 0 ..< 0x200: result[i] = 0
  for i, ch in "DINGBATTEST": result[i] = uint8(ch)
  for i, ch in "ADBE": result[0x0C + i] = uint8(ch)
  result.w32(0x20, 0x4000); result.w32(0x24, 0x02000800)
  result.w32(0x28, 0x02000000); result.w32(0x2C, 0x4000)
  result.w32(0x30, 0x8000); result.w32(0x34, 0x02380000)
  result.w32(0x38, 0x02380000); result.w32(0x3C, 0x1000)
  result[0x13] = 2
  case form
  of saDecrypted, saEncrypted:
    for i, ch in SECURE_AREA_ID: result[0x4000 + i] = uint8(ch)
    if form == saEncrypted:
      var area = result[0x4000 ..< 0x8000]
      encrypt_secure_area(table, result.gamecode, area)
      for i in 0 ..< 0x4000: result[0x4000 + i] = area[i]
  of saDestroyed:
    result.w32(0x4000, SECURE_DESTROYED); result.w32(0x4004, SECURE_DESTROYED)
  else:
    for i in 0 ..< 0x800: result[0x4000 + i] = 0
  result.w32(0x15C, 0)   # CRCs unused here

# ---------------------------------------------------------------------------

block key2_unit:
  echo "KEY2"
  # GBATEK "Activate KEY2": before initialisation the 910h dummy bytes read
  # HIGH-Z, C5h, 3Ah, 81h, ... -- the card's pre-init stream XOR 00 (the
  # first byte is driven HIGH-Z but still advances the stream).
  var k = init_key2(KEY2_PRE_SEED0, KEY2_SEED1)
  discard k.next()
  let b = [k.next(), k.next(), k.next()]
  check b == [0xC5'u8, 0x3A, 0x81], "pre-init stream after the HIGH-Z byte: C5 3A 81",
        toHex(b[0]) & " " & toHex(b[1]) & " " & toHex(b[2])
  check card_seed0(0x123456, 2) == (0x123456'u64 shl 15) + 0x6000 + 0x5A,
        "seed0 = mmmnnn<<15 + 6000h + seedbyte[hdr.13]"
  var a1 = init_key2(card_seed0(0xABCDEF, 5), KEY2_SEED1)
  var a2 = a1
  var plain = newSeq[uint8](64)
  for i in 0 ..< 64: plain[i] = uint8(i * 3)
  var wire = plain
  for i in 0 ..< 64: wire[i] = wire[i] xor a1.next()
  var back = wire
  for i in 0 ..< 64: back[i] = back[i] xor a2.next()
  check back == plain and wire != plain, "the same seed on both ends cancels"
  check (a1.x shr 39) == 0 and (a1.y shr 39) == 0, "registers stay 39-bit"

block key1_unit:
  echo "KEY1 (made-up table)"
  let t = fake_table()
  let k2 = init_key1(t, 0x45424441'u32, 2, 8)
  var ok = true
  for i in 0'u32 ..< 200:
    var lo = i * 0x9E3779B9'u32
    var hi = not (i * 0x85EBCA6B'u32)
    let (l0, h0) = (lo, hi)
    k2.encrypt64(lo, hi)
    if lo == l0 and hi == h0: ok = false
    k2.decrypt64(lo, hi)
    if lo != l0 or hi != h0: ok = false
  check ok, "decrypt64(encrypt64(v)) = v, and encryption changes v"
  let k1 = init_key1(t, 0x45424441'u32, 1, 8)
  let k3 = init_key1(t, 0x45424441'u32, 3, 8)
  check k1.buf != k2.buf and k2.buf != k3.buf, "each level reschedules the key"
  let m12 = init_key1(t, 0x5043414D'u32, 2, 12)
  let m8 = init_key1(t, 0x5043414D'u32, 2, 8)
  check m12.buf != m8.buf, "modulo 12 (firmware) and 8 (cards) differ"
  check key1_table_from_bios7(newSeq[uint8](0x4000)).len == 0,
        "a BIOS7 image with a zero-filled table has no KEY1 table"

block secure_area_unit:
  echo "secure area forms"
  let t = fake_table()
  let dec = fake_rom(0x20000, saDecrypted, t)
  let enc = fake_rom(0x20000, saEncrypted, t)
  let des = fake_rom(0x20000, saDestroyed, t)
  let hb = fake_rom(0x20000, saUnknown, t)
  check dec.secure_area_form(t) == saDecrypted, "\"encryObj\" = decrypted"
  check enc.secure_area_form(t) == saEncrypted, "decrypts to \"encryObj\" = encrypted"
  check des.secure_area_form(t) == saDestroyed, "E7FFDEFF x2 = decrypted, ID overwritten"
  check hb.secure_area_form(t) == saUnknown, "zero fill (homebrew) = unknown"
  check enc.secure_area_form(@[]) == saUnknown, "encrypted without the table = unknown"
  check card_secure_area(dec, t) == enc[0x4000 ..< 0x8000] and
        card_secure_area(des, t) == enc[0x4000 ..< 0x8000],
        "decrypted dumps re-encrypt to the card's form"
  check card_secure_area(enc, t) == enc[0x4000 ..< 0x8000], "encrypted dumps serve as dumped"
  var area = enc[0x4000 ..< 0x4800]
  check boot_secure_area(enc, t, area) and area[0 ..< 8] ==
        @[0xFF'u8, 0xDE, 0xFF, 0xE7, 0xFF, 0xDE, 0xFF, 0xE7] and
        area[8 ..< 0x800] == dec[0x4008 ..< 0x4800],
        "boot form of an encrypted dump: decrypted, ID -> E7FFDEFF"
  area = dec[0x4000 ..< 0x4800]
  check boot_secure_area(dec, t, area) and area == des[0x4000 ..< 0x4800],
        "boot form of a decrypted dump: ID -> E7FFDEFF"
  area = enc[0x4000 ..< 0x4800]
  check not boot_secure_area(enc, @[], area) and area == enc[0x4000 ..< 0x4800],
        "no table: an encrypted dump stays as dumped"

# ---------------------------------------------------------------------------
# The card handshake, driven as the BIOS does (GBATEK "DS Cartridge
# Protocol"): raw 9F/00/90/3C, KEY1 4/1/2/A, then KEY2 B7/B8.

proc xfer(c: Cart; s: NdsScheduler; cmd: array[8, uint8]; romctrl: uint32): seq[uint8] =
  ## One transfer: command, ROMCTRL with start, then every word as it
  ## arrives.
  var lo, hi: uint32
  for i in 0..3:
    lo = lo or (uint32(cmd[i]) shl (8 * i))
    hi = hi or (uint32(cmd[4 + i]) shl (8 * i))
  c.write_reg(0x1A8, lo, ALL)
  c.write_reg(0x1AC, hi, ALL)
  c.write_reg(0x1A4, romctrl or 0x8000_0000'u32 or 0x2000_0000'u32, ALL)
  var ev: NdsEvent
  var at: int64
  while (c.read_reg(0x1A4) and 0x8000_0000'u32) != 0:
    s.now = s.next_at()
    discard s.pop_due(ev, at)
    c.word_ready()
    let w = c.read_data()
    for k in 0..3: result.add uint8(w shr (8 * k))

proc key1_cmd(k: Key1; v: uint64): array[8, uint8] =
  ## A KEY1 command as the BIOS sends it: encrypt_64bit with the first
  ## command byte as the MSB, sent MSB first.
  var lo = uint32(v and 0xFFFF_FFFF'u64)
  var hi = uint32(v shr 32)
  k.encrypt64(lo, hi)
  for i in 0..3:
    result[i] = uint8(hi shr (24 - 8 * i))
    result[4 + i] = uint8(lo shr (24 - 8 * i))

proc handshake(variant_new: bool) =
  let t = fake_table()
  let rom = fake_rom(0x20000, saDecrypted, t)
  let s = new_nds_scheduler()
  let c = new_cart(rom, IrqCtl(), IrqCtl(), s)
  c.set_key1_table(t)
  if variant_new: c.chip_id = c.chip_id or 0x8000_0000'u32
  c.power_on()
  c.write_reg(0x1A0, 0x8000, 0xFFFF)
  const BS4 = 7'u32 shl 24
  const BS200 = 1'u32 shl 24
  const BS1000 = 4'u32 shl 24
  var z: array[8, uint8]
  check c.xfer(s, z, BS200) == rom[0 ..< 0x200], "raw 00: the header"
  z[0] = 0x90
  let id = c.xfer(s, z, BS4)
  check id == @[uint8(c.chip_id), uint8(c.chip_id shr 8), uint8(c.chip_id shr 16),
                uint8(c.chip_id shr 24)], "raw 90: the chip ID"
  z[0] = 0x3C
  discard c.xfer(s, z, 0)
  check c.mode == cmKey1, "3C enters KEY1 mode"
  let k = init_key1(t, rom.gamecode, 2, 8)
  # KEY1 timing: the old protocol clocks its gaps (ROMCTRL.28), the new one
  # does not and sends each command twice, the first time with no data
  let gaps = if variant_new: 0x001808F8'u32 else: 0x101808F8'u32
  proc send(v: uint64; ctl: uint32; parts = 1): seq[uint8] =
    let cmd = key1_cmd(k, v)
    if variant_new:
      discard c.xfer(s, cmd, gaps)
      for p in 0 ..< parts: result.add c.xfer(s, cmd, ctl)
    else:
      result = c.xfer(s, cmd, ctl)
  let mmmnnn = 0x5A5A5A'u64
  var kk = 0x10000'u64
  discard send((0x4'u64 shl 60) or (0x1234'u64 shl 44) or (mmmnnn shl 20) or kk, gaps)
  inc kk
  # the console's KEY2: same seed via the SEED registers, ROMCTRL.15
  let s0 = card_seed0(uint32(mmmnnn), rom[0x13])
  c.write_reg(0x1B0, uint32(s0 and 0xFFFF_FFFF'u64), ALL)
  c.write_reg(0x1B4, uint32(KEY2_SEED1 and 0xFFFF_FFFF'u64), ALL)
  c.write_reg(0x1B8, uint32(s0 shr 32) or (uint32(KEY2_SEED1 shr 32) shl 16), ALL)
  c.write_reg(0x1A4, 0x2000_8000'u32, ALL)
  check (c.read_reg(0x1A4) and 0x8000'u32) == 0, "ROMCTRL.15 reads back zero"
  let data = gaps or 0x6000'u32   # KEY2 data decryption on
  let id2 = send((0x1'u64 shl 60) or (0x1234'u64 shl 44) or kk, data or BS4)
  inc kk
  check id2 == id, "KEY1 1: the chip ID through both KEY2 streams"
  var secure: seq[uint8]
  for blk in [5'u64, 4, 7, 6]:
    let part = if variant_new: send((0x2'u64 shl 60) or (blk shl 44) or kk, data or BS200, 8)
               else: send((0x2'u64 shl 60) or (blk shl 44) or kk, data or BS1000)
    inc kk
    if part.len != 0x1000: check false, "4 KB secure block", $part.len
    secure.setLen(0x4000)
    for i in 0 ..< 0x1000: secure[int(blk - 4) * 0x1000 + i] = part[i]
  check secure == card_secure_area(rom, t), "KEY1 2: secure blocks 4..7 in card form"
  var area = secure
  decrypt_secure_area(t, rom.gamecode, area)
  check area[0 ..< 8] == @[uint8('e'), uint8('n'), uint8('c'), uint8('r'), uint8('y'),
                           uint8('O'), uint8('b'), uint8('j')] and
        area[8 ..< 0x4000] == rom[0x4008 ..< 0x8000],
        "the BIOS's decryption gives back \"encryObj\" and the dump"
  discard send((0xA'u64 shl 60) or (0x1234'u64 shl 44) or kk, data)
  check c.mode == cmMain, "KEY1 A: main data mode"
  let main = 0x00406000'u32 or 0x18_0000'u32   # KEY2 commands and data
  var b7: array[8, uint8] = [0xB7'u8, 0, 0, 0x90, 0x10, 0, 0, 0]
  check c.xfer(s, b7, main or BS200) == rom[0x9010 ..< 0x9210], "B7 0x9010: plaintext"
  b7[3] = 0x10; b7[4] = 0
  check c.xfer(s, b7, main or BS200) == rom[0x8000 ..< 0x8200],
        "B7 below 0x8000 reads 0x8000 + (addr and 0x1FF)"
  var b8: array[8, uint8] = [0xB8'u8, 0, 0, 0, 0, 0, 0, 0]
  check c.xfer(s, b8, main or BS4) == id, "B8: the chip ID"
  b7[3] = 0x90; b7[4] = 0
  let raw = c.xfer(s, b7, 0x00400000'u32 or BS200)
  check raw != rom[0x9000 ..< 0x9200], "without ROMCTRL.13 the CPU reads ciphertext"

block handshake_old:
  echo "card handshake, older protocol (chip ID bit 31 clear)"
  handshake(false)

block handshake_new:
  echo "card handshake, newer protocol (chip ID bit 31 set)"
  handshake(true)

block chip_id_unit:
  echo "chip ID"
  check new_cart(newSeq[uint8](16 shl 20), IrqCtl(), IrqCtl(), new_nds_scheduler()).chip_id ==
        0x00000FC2'u32, "16 MB: C2 0F 00 00"
  check chip_id_for(128 shl 20, true) == 0x80017FC2'u32,
        "128 MB IR card: C2 7F 01 80 (bit 31 = newer protocol)"
  check chip_id_for(256 shl 20, false) == 0x8000FFC2'u32 and
        chip_id_for(512 shl 20, false) == 0x8000FEC2'u32, "256 / 512 MB: size bytes FF / FE"
  check new_cart(@[], IrqCtl(), IrqCtl(), new_nds_scheduler()).chip_id == 0xFFFFFFFF'u32,
        "no card: FF FF FF FF"

# ---------------------------------------------------------------------------
# Direct boot: the ARM9 binary's first 2 KB as the BIOS would leave them

block direct_boot_unit:
  echo "direct boot secure area"
  let t = fake_table()
  var bios7 = newSeq[uint8](0x4000)
  for i in 0 ..< KEY1_TABLE_SIZE: bios7[KEY1_TABLE_OFFSET + i] = t[i]
  let want = fake_rom(0x20000, saDestroyed, t)
  for form in [saEncrypted, saDecrypted, saDestroyed]:
    let rom = fake_rom(0x20000, form, t)
    let n = new_nds(rom, @[], bios7, @[])
    var got = newSeq[uint8](0x800)
    for i in 0 ..< 0x800: got[i] = n.main_ram[i]
    check got == want[0x4000 ..< 0x4800], "ARM9 binary from a " & $form & " dump"
    check n.arm9.next_pc == 0x02000800'u32, "ARM9 at the header's entry (" & $form & ")"
  let hb = fake_rom(0x20000, saUnknown, t)
  let n = new_nds(hb, @[], bios7, @[])
  check n.main_ram[0 ..< 0x800] == hb[0x4000 ..< 0x4800], "homebrew zero fill kept as is"
  let fb = new_nds(hb, @[], @[], @[], boot = nbFirmware)
  check fb.arm9.next_pc == 0x02000800'u32 and fb.cart.mode == cmMain,
        "firmware boot without dumps falls back to direct boot"

# ---------------------------------------------------------------------------
# The real KEY1 table (local only: needs the user's dumps)

block real_table:
  let dir = getEnv("DINGBAT_NDS_BIOS")
  let game = getEnv("DINGBAT_NDS_GAME")
  if dir.len == 0 or not fileExists(dir / "bios7.bin") or game.len == 0 or not fileExists(game):
    echo "real KEY1 table: skipped (set DINGBAT_NDS_BIOS and DINGBAT_NDS_GAME)"
  else:
    echo "real KEY1 table"
    proc rf(p: string): seq[uint8] =
      let s = readFile(p)
      result = newSeq[uint8](s.len)
      if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)
    let t = key1_table_from_bios7(rf(dir / "bios7.bin"))
    let rom = rf(game)
    check t.len == KEY1_TABLE_SIZE, "the table reads from bios7.bin"
    if rom.has_secure_area():
      let card = card_secure_area(rom, t)
      let hdr = uint16(rom[0x6C]) or (uint16(rom[0x6D]) shl 8)
      check crc16(card) == hdr, "the card-form secure area matches header CRC 06Ch",
            toHex(crc16(card)) & " vs " & toHex(hdr)

if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
