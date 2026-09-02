## Unit tests for the MBC7 mapper (src/dingbat/gb/mbc/mbc7.nim): the 93LC56
## EEPROM instruction set bit-banged through the Ax8x pin register exactly as
## a game does it (Pan Docs, "MBC7"; Microchip DS21794F Table 1-3), the
## Ready/Busy status after a programming cycle, the EWEN/EWDS gate, the
## little-endian word layout of the 256-byte save image, the two RAM-enable
## gates and the $55/$AA accelerometer latch protocol.
##
## Build: nim c -r -d:test_harness -d:release --hints:off --path:src \
##          tests/mbc7_test.nim

import dingbat/gb/gb

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

proc make_cart(): Mbc7 =
  ## Mirrors the power-on state load_cartridge gives a type-$22 cart: erased
  ## EEPROM (all ones), unlatched accelerometer, idle port.
  result = Mbc7(rom: newSeq[uint8](0x8000), ram: newSeq[uint8](0x100),
                x_latch: 0x8000, y_latch: 0x8000, latch_ready: true,
                read_bits: 0xFFFF, eeprom_do: true)
  for i in 0 ..< result.ram.len: result.ram[i] = 0xFF
  mbc_write(result, 0x0000, 0x0A)   # RAM enable 1
  mbc_write(result, 0x4000, 0x40)   # RAM enable 2

const
  PORT = 0xA080
  CS = 0x80'u8
  CLK = 0x40'u8
  DI = 0x02'u8
  OP_EXT = 0
  OP_WRITE = 1
  OP_READ = 2
  OP_ERASE = 3
  EXT_EWDS = 0x00
  EXT_WRAL = 0x40
  EXT_ERAL = 0x80
  EXT_EWEN = 0xC0

proc port(c: Mbc7; v: uint8) = mbc_write(c, PORT, v)
proc do_pin(c: Mbc7): bool = (mbc_read(c, PORT) and 1) != 0

proc clock_bit(c: Mbc7; b: bool) =
  ## CS high: present DI with CLK low, then raise CLK.
  let di = if b: DI else: 0'u8
  c.port(CS or di)
  c.port(CS or CLK or di)

proc send(c: Mbc7; bits: uint32; n: int) =
  for i in countdown(n - 1, 0): c.clock_bit(((bits shr i) and 1) != 0)

proc start(c: Mbc7) =
  ## The Pan Docs preamble: $00, $80, $C0 (a 0 bit), $82, $C2 (the Start bit).
  c.port(0x00); c.port(0x80); c.port(0xC0); c.port(0x82); c.port(0xC2)

proc instruction(c: Mbc7; op, address: int) =
  c.start()
  c.send(uint32((op shl 8) or address), 10)

proc finish(c: Mbc7) = c.port(0x00)   # CS low: reset, or begin programming

proc poll_ready(c: Mbc7; limit = 64): int =
  ## Raise CS and count the reads until DO reports Ready (1); -1 if never.
  c.port(CS)
  for n in 0 ..< limit:
    if c.do_pin(): return n
  -1

var dummy_bit_missing = false   # any READ whose dummy 0 bit did not appear

proc read_words(c: Mbc7; address, count: int): seq[uint16] =
  ## READ, then stream `count` sequential words while CS stays high.
  c.instruction(OP_READ, address)
  if c.do_pin(): dummy_bit_missing = true
  for w in 0 ..< count:
    var v = 0'u16
    for i in 0 ..< 16:
      c.clock_bit(false)
      v = (v shl 1) or (if c.do_pin(): 1'u16 else: 0'u16)
    result.add(v)
  c.finish()

proc write_word(c: Mbc7; address: int; val: uint16): int =
  ## WRITE and return the number of busy polls before Ready.
  c.instruction(OP_WRITE, address)
  c.send(uint32(val), 16)
  c.finish()
  result = c.poll_ready()
  c.finish()

proc simple(c: Mbc7; op, address: int): int =
  c.instruction(op, address)
  c.finish()
  result = c.poll_ready()
  c.finish()

echo "=== 93LC56 EEPROM ==="

block:
  let c = make_cart()
  check(c.read_words(5, 1) == @[0xFFFF'u16], "erased EEPROM reads all ones")
  check(c.do_pin(), "idle port reads DO high")

  # Power-up is EWDS (datasheet 2.6): a WRITE must be refused.
  let polls = c.write_word(5, 0x1234)
  check(polls == 0, "WRITE while disabled: no programming cycle, DO ready at once")
  check(c.read_words(5, 1) == @[0xFFFF'u16], "WRITE while disabled leaves the word erased")
  check(not c.ram_dirty, "refused WRITE does not dirty the save")

  discard c.simple(OP_EXT, EXT_EWEN)
  check(c.eeprom_write_enabled, "EWEN enables programming")
  let busy = c.write_word(5, 0x1234)
  check(busy > 0, "WRITE: DO reads Busy (0) before Ready, polls = " & $busy)
  check(c.read_words(5, 1) == @[0x1234'u16], "WRITE then READ returns the word")
  check(c.ram[10] == 0x34 and c.ram[11] == 0x12, "word 5 is little-endian at ram[10..11]")
  check(c.ram_dirty, "programming dirties the save")

  discard c.write_word(6, 0xBEEF)
  check(c.read_words(5, 2) == @[0x1234'u16, 0xBEEF'u16], "sequential READ streams the next word")
  discard c.write_word(0, 0x0001)
  check(c.read_words(127, 2) == @[0xFFFF'u16, 0x0001'u16],
        "sequential READ wraps from word 127 to word 0")

  check(c.simple(OP_ERASE, 5) > 0, "ERASE: busy cycle")
  check(c.read_words(5, 2) == @[0xFFFF'u16, 0xBEEF'u16], "ERASE fills only the addressed word with ones")

  c.instruction(OP_EXT, EXT_WRAL)
  c.send(0xA5C3, 16)
  c.finish()
  check(c.poll_ready() > 0, "WRAL: busy cycle")
  c.finish()
  var all_wral = true
  for w in 0 ..< 128:
    if c.read_words(w, 1)[0] != 0xA5C3'u16: all_wral = false
  check(all_wral, "WRAL fills every word")

  check(c.simple(OP_EXT, EXT_ERAL) > 0, "ERAL: busy cycle")
  var all_erased = true
  for i in 0 ..< c.ram.len:
    if c.ram[i] != 0xFF: all_erased = false
  check(all_erased, "ERAL erases the whole array")

  discard c.simple(OP_EXT, EXT_EWDS)
  check(not c.eeprom_write_enabled, "EWDS disables programming")
  discard c.write_word(9, 0x5555)
  check(c.read_words(9, 1) == @[0xFFFF'u16], "WRITE after EWDS is refused")
  discard c.simple(OP_EXT, EXT_EWEN)
  discard c.write_word(9, 0x5555)
  check(c.read_words(9, 1) == @[0x5555'u16], "WRITE after a second EWEN works")

  # A command abandoned by dropping CS mid-way must not program anything.
  c.instruction(OP_WRITE, 9)
  c.send(0xAAAA, 7)
  c.finish()
  check(c.poll_ready() == 0 and c.read_words(9, 1) == @[0x5555'u16],
        "CS low mid-instruction resets the chip without programming")
  check(not dummy_bit_missing, "READ: a dummy 0 bit followed the last address bit every time")

echo "=== RAM enable gates ==="

block:
  let c = make_cart()
  discard c.simple(OP_EXT, EXT_EWEN)
  mbc_write(c, 0x4000, 0x00)   # drop gate 2 only
  check(mbc_read(c, 0xA020) == 0xFF and mbc_read(c, PORT) == 0xFF,
        "registers read $FF with only gate 1 set")
  c.port(CS)
  check(not c.eeprom_cs, "port writes are ignored with only gate 1 set")
  mbc_write(c, 0x4000, 0x40)
  mbc_write(c, 0x0000, 0x00)   # drop gate 1 only
  check(mbc_read(c, PORT) == 0xFF, "registers read $FF with only gate 2 set")
  mbc_write(c, 0x0000, 0x0A)
  check(mbc_read(c, 0xA060) == 0x00 and mbc_read(c, 0xA070) == 0xFF and
        mbc_read(c, 0xA090) == 0xFF and mbc_read(c, 0xB000) == 0xFF,
        "Ax6x = $00, Ax7x/Ax9x/$B000 = $FF")
  check(mbc_read(c, 0xAF25) == mbc_read(c, 0xA020), "address bits 0-3 and 8-11 are ignored")
  mbc_write(c, 0x2000, 0x83)
  check(mbc_rom_map(c) == (0, mbc_rom_bank_offset(c, 3)), "ROM bank register keeps 7 bits")

echo "=== accelerometer latch ==="

block:
  let c = make_cart()
  proc x(c: Mbc7): int = int(mbc_read(c, 0xA020)) or (int(mbc_read(c, 0xA030)) shl 8)
  proc y(c: Mbc7): int = int(mbc_read(c, 0xA040)) or (int(mbc_read(c, 0xA050)) shl 8)
  check(c.x() == 0x8000 and c.y() == 0x8000, "reads $8000 before the first latch")
  c.set_accelerometer(0.0, 0.0)
  mbc_write(c, 0xA000, 0x55)
  mbc_write(c, 0xA010, 0xAA)
  check(c.x() == 0x81D0 and c.y() == 0x81D0, "flat at rest latches the $81D0 centre")
  c.set_accelerometer(1.0, -1.0)
  mbc_write(c, 0xA010, 0xAA)
  check(c.x() == 0x81D0 and c.y() == 0x81D0, "re-latch without a $55 erase yields no change")
  mbc_write(c, 0xA000, 0x55)
  check(c.x() == 0x8000 and c.y() == 0x8000, "$55 resets both axes to $8000")
  mbc_write(c, 0xA010, 0xAA)
  check(c.x() == 0x81D0 + 0x70 and c.y() == 0x81D0 - 0x70, "one g moves an axis by $70")
  mbc_write(c, 0xA000, 0x56)
  mbc_write(c, 0xA010, 0xAB)
  check(c.x() == 0x81D0 + 0x70, "other values written to the latch registers do nothing")
  check(mbc_read(c, 0xA000) == 0xFF and mbc_read(c, 0xA010) == 0xFF, "latch registers read $FF")

echo ""
if failures == 0:
  echo "All MBC7 tests passed"
else:
  echo failures, " MBC7 test(s) FAILED"
  quit(1)
