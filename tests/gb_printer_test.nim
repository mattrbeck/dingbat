# Game Boy Printer protocol unit tests: drive GbPrinter.feed directly with
# hand-built packets and assert the byte-exact replies, the status state
# machine, image assembly, RLE, checksum handling, and resync.

import ../src/dingbat/gb/printer

var failures = 0

proc check(cond: bool; label: string) =
  if cond:
    echo "  ok: ", label
  else:
    echo "  FAIL: ", label
    inc failures

proc build_packet(cmd: uint8; payload: seq[uint8]; compressed = false;
                  corrupt_chk = false): seq[uint8] =
  result = @[0x88'u8, 0x33, cmd, (if compressed: 1'u8 else: 0'u8),
             uint8(payload.len and 0xFF), uint8(payload.len shr 8)]
  result.add(payload)
  var chk = uint16(cmd) + (if compressed: 1'u16 else: 0'u16) +
            uint16(payload.len and 0xFF) + uint16(payload.len shr 8)
  for b in payload: chk += uint16(b)
  if corrupt_chk: chk += 1
  result.add(uint8(chk and 0xFF))
  result.add(uint8(chk shr 8))
  result.add(0)  # ack slot
  result.add(0)  # status slot

proc send(prn: GbPrinter; packet: seq[uint8]): seq[uint8] =
  result = @[]
  for b in packet: result.add(prn.feed(b))

proc last(s: seq[uint8]): uint8 = s[s.len - 1]
proc ack(s: seq[uint8]): uint8 = s[s.len - 2]

# One full 20x2-tile band of a given per-tile (lo, hi) row byte pair
proc band(lo, hi: uint8): seq[uint8] =
  result = newSeq[uint8](40 * 16)
  for t in 0 ..< 40:
    for row in 0 ..< 8:
      result[t * 16 + row * 2] = lo
      result[t * 16 + row * 2 + 1] = hi

echo "init/status basics"
block:
  let prn = new_gb_printer()
  let r = prn.send(build_packet(0x01, @[]))
  check(r.len == 10, "INIT packet is 10 reply slots")
  for i in 0 ..< 8: check(r[i] == 0, "pre-ack slot " & $i & " replies 0")
  check(r.ack == 0x81, "ack slot replies 0x81")
  check(r.last == 0x00, "status after INIT is idle")

echo "data + print lifecycle"
block:
  let prn = new_gb_printer()
  discard prn.send(build_packet(0x01, @[]))
  let d = prn.send(build_packet(0x04, band(0x00, 0x00)))
  check(d.last == 0x08, "full DATA band -> unprocessed-data status")
  discard prn.send(build_packet(0x04, @[]))  # conventional flush
  let p = prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  check(p.last == 0x06, "PRINT -> printing status")
  var frames = 0
  while prn.status == 0x06 and frames < 1000:
    prn.tick_frame()
    inc frames
  check(prn.status == 0x04, "printing completes to the done state")
  check(frames >= 30, "print takes hardware-ish time, took " & $frames)
  let s1 = prn.send(build_packet(0x0F, @[]))
  check(s1.last == 0x04, "first inquiry observes done")
  let s2 = prn.send(build_packet(0x0F, @[]))
  check(s2.last == 0x04, "done LATCHES (SameBoy): repeat polls still read done")
  let i2 = prn.send(build_packet(0x01, @[]))
  check(i2.last == 0x00, "a later INIT clears done to idle")
  check(prn.outbox.len == 1, "sheets=1 emitted a strip")
  check(prn.outbox[0].len == 160 * 16, "one band = 160x16 pixels")
  var all_white = true
  for px in prn.outbox[0]:
    if px != 0: all_white = false
  check(all_white, "zero tile data maps to shade 0 via palette 0xE4")

echo "pixel decode + palette"
block:
  let prn = new_gb_printer()
  discard prn.send(build_packet(0x04, band(0xFF, 0x00)))  # shade 1 everywhere
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.status == 0x06: prn.tick_frame()
  discard prn.send(build_packet(0x0F, @[]))
  check(prn.outbox.len == 1 and prn.outbox[0][0] == 1,
        "lo-plane bits decode to shade 1 under identity palette")
  let prn2 = new_gb_printer()
  discard prn2.send(build_packet(0x04, band(0xFF, 0xFF)))  # shade 3
  discard prn2.send(build_packet(0x02, @[1'u8, 0, 0x1B, 0x40]))  # inverted pal
  while prn2.status == 0x06: prn2.tick_frame()
  check(prn2.outbox.len == 1 and prn2.outbox[0][0] == 0,
        "shade 3 under inverted palette 0x1B maps to 0")

echo "multi-print strips (sheets=0 appends)"
block:
  let prn = new_gb_printer()
  discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x02, @[0'u8, 0, 0xE4, 0x40]))  # no feed
  while prn.status == 0x06: prn.tick_frame()
  check(prn.outbox.len == 0, "sheets=0 holds the strip open")
  discard prn.send(build_packet(0x01, @[]))  # INIT between segments
  discard prn.send(build_packet(0x04, band(0xFF, 0xFF)))
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))  # feed
  while prn.status == 0x06: prn.tick_frame()
  check(prn.outbox.len == 1 and prn.outbox[0].len == 160 * 32,
        "second print with feed emits the combined 32-row strip")

echo "checksum failure"
block:
  let prn = new_gb_printer()
  let r = prn.send(build_packet(0x04, band(0, 0), corrupt_chk = true))
  check((r.last and 0x01) != 0, "bad checksum sets status bit 0")
  let p = prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.status == 0x06: prn.tick_frame()
  discard prn.send(build_packet(0x0F, @[]))
  check(prn.outbox.len == 0 or prn.outbox[0].len == 0,
        "rejected DATA never reached the buffer")

echo "rle compression"
block:
  # 640 zero bytes: 4 runs of 129 + one run of 124
  var comp: seq[uint8] = @[]
  for _ in 0 ..< 4:
    comp.add(0xFF)  # 0x80 | 0x7F -> 129 copies
    comp.add(0x00)
  comp.add(0x80'u8 or 122)  # 124 copies
  comp.add(0x00)
  let prn = new_gb_printer()
  let r = prn.send(build_packet(0x04, comp, compressed = true))
  check(r.last == 0x08, "compressed DATA accepted")
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.status == 0x06: prn.tick_frame()
  check(prn.outbox.len == 1 and prn.outbox[0].len == 160 * 16,
        "640 decompressed bytes = one 16-row band")

echo "resync after garbage"
block:
  let prn = new_gb_printer()
  for b in [0x12'u8, 0x88, 0x21, 0xFF, 0x33]: discard prn.feed(b)
  let r = prn.send(build_packet(0x01, @[]))
  check(r.ack == 0x81 and r.last == 0x00, "parser resyncs on the next magic")

if failures == 0:
  echo "ALL PRINTER TESTS PASSED"
else:
  echo $failures & " PRINTER TEST(S) FAILED"
  quit(1)
