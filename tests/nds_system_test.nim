## DS system devices (src/dingbat/nds/io/): the maths unit, the RTC's
## serial protocol, the card's save chip and its type detection, the IPC
## FIFOs' IRQ edges and the card's timed transfers -- each driven through
## its registers as the CPUs would, checked against GBATEK.
##
## Run with: nimble test_ndssystem

import std/times
import dingbat/nds/sched
import dingbat/nds/io/[irq, divsqrt, rtc, backup, ipc, cart]
import dingbat/gba/rtc_calendar

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

const ALL = 0xFFFF_FFFF'u32

# ---------------------------------------------------------------------------
# Maths unit

proc div64(d: DivSqrt; mode: uint32; n, m: int64) =
  d.write_reg(0x280, mode, ALL)
  d.write_reg(0x290, uint32(cast[uint64](n)), ALL)
  d.write_reg(0x294, uint32(cast[uint64](n) shr 32), ALL)
  d.write_reg(0x298, uint32(cast[uint64](m)), ALL)
  d.write_reg(0x29C, uint32(cast[uint64](m) shr 32), ALL)

proc q64(d: DivSqrt): uint64 =
  uint64(d.read_reg(0x2A0)) or (uint64(d.read_reg(0x2A4)) shl 32)

proc r64(d: DivSqrt): uint64 =
  uint64(d.read_reg(0x2A8)) or (uint64(d.read_reg(0x2AC)) shl 32)

block divsqrt_unit:
  echo "maths unit"
  let s = new_nds_scheduler()
  let d = new_divsqrt(s)
  d.div64(0, 100, -7)
  check d.q64 == cast[uint64](-14'i64) and d.r64 == 2'u64, "32/32: 100 / -7 = -14 r 2"
  d.div64(0, 5, 0)
  # DIV0: result -1 (sign opposite to the numerator), upper half inverted
  check d.q64 == 0x0000_0000_FFFF_FFFF'u64 and d.r64 == 5, "32/32 by zero: -1 with upper half inverted"
  check (d.read_reg(0x280) and 0x4000) != 0, "DIV0 flag on a zero 64-bit denominator"
  d.div64(0, int64(low(int32)), -1)
  check d.q64 == 0x0000_0000_8000_0000'u64, "32/32 -MAX/-1: -MAX with upper half inverted"
  d.div64(1, -1_000_000_000_000'i64, 3)
  check cast[int64](d.q64) == -333_333_333_333'i64 and cast[int64](d.r64) == -1,
        "64/32: -10^12 / 3"
  d.div64(2, low(int64), -1)
  check d.q64 == 0x8000_0000_0000_0000'u64, "64/64 -MAX/-1 = -MAX"
  d.div64(1, 9, 0x1_0000_0000'i64)
  check (d.read_reg(0x280) and 0x4000) == 0 and d.q64 == 0xFFFF_FFFF_FFFF_FFFF'u64,
        "64/32 by a denominator whose low half is 0: -1, no DIV0 flag"
  # busy: 34 bus cycles = 68 master
  s.now = 1000
  d.div64(2, 10, 3)
  check (d.read_reg(0x280) and 0x8000) != 0, "busy right after the write"
  s.now = 1000 + 67
  check (d.read_reg(0x280) and 0x8000) != 0, "busy at 33.5 bus cycles"
  s.now = 1000 + 68
  check (d.read_reg(0x280) and 0x8000) == 0, "ready after 34 bus cycles"
  # roots
  d.write_reg(0x2B0, 1, ALL)
  d.write_reg(0x2B8, ALL, ALL)
  d.write_reg(0x2BC, ALL, ALL)
  check d.read_reg(0x2B4) == 0xFFFF_FFFF'u32, "sqrt(2^64 - 1) = 2^32 - 1"
  d.write_reg(0x2B8, 0, ALL)
  d.write_reg(0x2BC, 0x4000_0000'u32, ALL)
  check d.read_reg(0x2B4) == 0x8000_0000'u32, "sqrt(2^62) = 2^31"
  d.write_reg(0x2B0, 0, ALL)   # 32-bit mode ignores the upper word
  check d.read_reg(0x2B4) == 0, "32-bit root ignores PARAM's upper half"
  s.now = 5000
  d.write_reg(0x2B8, 99, ALL)
  check d.read_reg(0x2B4) == 9 and (d.read_reg(0x2B0) and 0x8000) != 0, "sqrt(99) = 9, busy"
  s.now = 5000 + 26
  check (d.read_reg(0x2B0) and 0x8000) == 0, "root ready after 13 bus cycles"

# ---------------------------------------------------------------------------
# RTC: bit-banged through the GPIO port as calico does

const
  CS = 4'u16
  SCK = 2'u16
  DIR = 0x70'u16      # data, clock and select driven by the CPU
  DIR_IN = 0x60'u16   # data as input

proc rtc_begin(r: Rtc) =
  r.write_reg(DIR or SCK)
  r.write_reg(DIR or SCK or CS)

proc rtc_out(r: Rtc; b: uint8; msb_first = false) =
  for i in 0..7:
    let bit = if msb_first: (b shr (7 - i)) and 1 else: (b shr i) and 1
    r.write_reg(DIR or CS or uint16(bit))
    r.write_reg(DIR or CS or SCK or uint16(bit))

proc rtc_in(r: Rtc): uint8 =
  for i in 0..7:
    r.write_reg(DIR_IN or CS)
    r.write_reg(DIR_IN or CS or SCK)
    result = result or (uint8(r.read_reg() and 1) shl i)

proc rtc_end(r: Rtc) = r.write_reg(DIR or SCK)

block rtc_unit:
  echo "RTC"
  let r = new_rtc()
  r.rtc_begin(); r.rtc_out(0x86)          # status 1, read (LSB-first command)
  let st1 = r.rtc_in(); r.rtc_end()
  check (st1 and 0x02) != 0, "status 1 reads 24-hour mode", "0x" & $st1
  # date+time read, command sent MSB first (0x65 = reg 2 read in that order)
  r.rtc_begin(); r.rtc_out(0x65, msb_first = true)
  var t: array[7, uint8]
  for i in 0..6: t[i] = r.rtc_in()
  r.rtc_end()
  let now = getTime().toUnix
  let host = from_calendar_seconds(now + local_zone_offset(now))
  check from_bcd(t[0]) == host.year mod 100 and from_bcd(t[1]) == host.month,
        "date read gives the host's year and month (MSB-first command)"
  # write 2031-07-04 23:59:58, read back
  r.rtc_begin(); r.rtc_out(0x26)          # date+time write
  for b in [0x31'u8, 0x07, 0x04, 0x05, 0x23, 0x59, 0x58]: r.rtc_out(b)
  r.rtc_end()
  r.rtc_begin(); r.rtc_out(0xA6)
  for i in 0..6: t[i] = r.rtc_in()
  r.rtc_end()
  check t[0] == 0x31 and t[1] == 0x07 and t[2] == 0x04 and t[3] == 0x05,
        "written date reads back with its weekday"
  check (t[4] and 0x3F) == 0x23 and (t[4] and 0x40) != 0 and t[5] == 0x59,
        "hour reads back with the PM flag (bit 6) in 24-hour mode"

# ---------------------------------------------------------------------------
# Save chip

proc spi(b: Backup; bytes: openArray[uint8]; pcs: openArray[uint32]): seq[uint8] =
  for i, v in bytes: result.add b.transfer(v, pcs[min(i, pcs.len - 1)])
  b.deselect()

block backup_unit:
  echo "save chip"
  # EEPROM 64K detected from a write with 2 address bytes sent from one pc
  var b = new_backup()
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0x02'u8, 0x12, 0x34, 0xAA, 0xBB], [0x100'u32, 0x200, 0x200, 0x300, 0x300])
  check b.kind == bkEeprom and b.data.len == 64 * 1024, "2 address bytes: 16-bit EEPROM"
  let r = b.spi([0x03'u8, 0x12, 0x34, 0, 0], [0x100'u32, 0x200, 0x200, 0x300, 0x300])
  check r[3] == 0xAA and r[4] == 0xBB, "EEPROM write then read back"
  discard b.spi([0x02'u8, 0x00, 0x00, 0x11], [0x100'u32, 0x200, 0x200, 0x300])
  let r2 = b.spi([0x03'u8, 0x00, 0x00, 0], [0x100'u32, 0x200, 0x200, 0x300])
  check r2[3] == 0xFF, "a write without WREN is ignored (WEL dropped by the last write)"
  let st = b.spi([0x05'u8, 0], [0x100'u32])
  check st[1] == 0x00, "16-bit EEPROM status reads 0"
  # 0.5K EEPROM: one address byte, A8 in the command (0B = read high half)
  b = new_backup()
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0x0A'u8, 0x05, 0x77], [0x100'u32, 0x200, 0x300])
  check b.kind == bkEeprom512, "1 address byte: 0.5K EEPROM"
  check b.data[0x105] == 0x77, "WRHI writes the upper 256 bytes"
  check (b.spi([0x05'u8, 0], [0x100'u32])[1] and 0xF0) == 0xF0, "0.5K EEPROM status has bits 4-7 set"
  # FLASH: RDID picks it; page program clears bits, page write replaces, erase
  b = new_backup()
  let id = b.spi([0x9F'u8, 0, 0, 0], [0x100'u32])
  check b.kind == bkFlash and id[1] == 0x20 and id[2] == 0x40 and id[3] == 0x13,
        "RDID picks FLASH, 512K ST id 20 40 13"
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0x0A'u8, 0x00, 0x01, 0x00, 0xF0, 0x0F], [0x100'u32])
  check b.data[0x100] == 0xF0 and b.data[0x101] == 0x0F, "FLASH page write"
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0x02'u8, 0x00, 0x01, 0x00, 0x3C], [0x100'u32])
  check b.data[0x100] == 0x30, "FLASH page program only clears bits"
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0xDB'u8, 0x00, 0x01, 0x80], [0x100'u32])
  check b.data[0x100] == 0xFF and b.data[0x101] == 0xFF, "FLASH page erase"
  discard b.spi([0x06'u8], [0x100'u32])
  discard b.spi([0x0A'u8, 0x00, 0x02, 0x00, 0x5A], [0x100'u32])
  let fr = b.spi([0x0B'u8, 0x00, 0x02, 0x00, 0xEE, 0], [0x100'u32])
  check fr[5] == 0x5A, "FLASH fast read skips one dummy byte"
  # a save file picks the chip by its size
  b = new_backup()
  var sv = newSeq[uint8](8192)
  sv[5] = 0x42
  b.set_data(sv)
  check b.kind == bkEeprom and b.spi([0x03'u8, 0, 5, 0], [0x100'u32])[3] == 0x42,
        "an 8K save loads as a 16-bit EEPROM"

# ---------------------------------------------------------------------------
# IPC FIFO IRQ edges

block ipc_unit:
  echo "IPC"
  let i9 = IrqCtl()
  let i7 = IrqCtl()
  let p = new_ipc(i9, i7)
  p.write_fifocnt(true, 0x8000 or 0x4, ALL)        # ARM9: enable, send-empty IRQ
  check (i9.iff and (1'u32 shl 17)) != 0, "enabling send-empty IRQ over an empty FIFO raises IF.17"
  i9.iff = 0
  p.write_fifocnt(false, 0x8000 or 0x400, ALL)     # ARM7: enable, recv IRQ
  p.send(true, 0x1234)
  check (i7.iff and (1'u32 shl 18)) != 0, "a word into an empty FIFO raises the receiver's IF.18"
  check p.recv(false) == 0x1234 and (i9.iff and (1'u32 shl 17)) != 0,
        "emptying the FIFO raises the sender's IF.17"
  check p.recv(false) == 0x1234 and (p.read_fifocnt(false) and 0x4000) != 0,
        "reading an empty FIFO repeats the last word and sets the error bit"
  i9.iff = 0
  p.send(true, 1); p.send(true, 2)
  p.write_fifocnt(true, 0x8000 or 0x4 or 0x8, ALL) # clear
  check (i9.iff and (1'u32 shl 17)) != 0 and (p.read_fifocnt(true) and 1) != 0,
        "clearing a non-empty send FIFO raises IF.17"
  for k in 0..16: p.send(true, uint32(k))
  check (p.read_fifocnt(true) and 0x4000) != 0 and (p.read_fifocnt(true) and 2) != 0,
        "a 17th word sets the error bit and the FIFO reads full"

# ---------------------------------------------------------------------------
# Card: timed KEY2 data reads

block cart_unit:
  echo "card"
  let s = new_nds_scheduler()
  var rom = newSeq[uint8](0x10000)
  for k in 0 ..< rom.len: rom[k] = uint8(k and 0xFF) xor uint8(k shr 8)
  let c = new_cart(rom, IrqCtl(), IrqCtl(), s)
  c.write_reg(0x1A0, 0x8000 or 0x4000, 0xFFFF)     # slot on, transfer IRQ
  c.write_reg(0x1A8, 0x8000_00B7'u32, ALL)         # B7 00 00 80 00 -> 0x8000
  c.write_reg(0x1AC, 0, ALL)
  s.now = 100
  c.write_reg(0x1A4, 0xA100_0000'u32, ALL)         # start, 0x200 bytes, bus/5
  check not c.data_ready(), "no word at the start of the transfer"
  # 8 command + 4 data bytes at 5 bus cycles (10 master) each
  check s.next_at() == 100 + 12 * 10, "first word due after 12 card bytes", $s.next_at()
  var ev: NdsEvent
  var at: int64
  s.now = s.next_at()
  discard s.pop_due(ev, at)
  c.word_ready()
  check c.data_ready(), "DRQ set when the word arrives"
  let w = c.read_data()
  let want = uint32(rom[0x8000]) or (uint32(rom[0x8001]) shl 8) or
             (uint32(rom[0x8002]) shl 16) or (uint32(rom[0x8003]) shl 24)
  check w == want and not c.data_ready(), "first word is ROM 0x8000, DRQ clears"
  check s.next_at() == s.now + 4 * 10, "next word 4 card bytes later"
  for k in 1 ..< 128:
    s.now = s.next_at()
    discard s.pop_due(ev, at)
    c.word_ready()
    discard c.read_data()
  check (c.read_reg(0x1A4) and 0x8000_0000'u32) == 0 and
        (c.irq9.iff and (1'u32 shl 19)) != 0, "0x200 bytes end the transfer with IF.19"

if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
