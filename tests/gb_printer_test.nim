# Game Boy Printer protocol unit tests: drive GbPrinter.feed directly with
# hand-built packets and assert the byte-exact replies, image assembly, RLE,
# checksum handling, and resync.

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
  for _ in 0 ..< 3:  # 3 bands = 48 rows, a real (if small) photo
    discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x04, @[]))  # conventional flush
  discard prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  check(prn.printing, "PRINT starts printing")
  var frames = 0
  while prn.printing and frames < 1000:
    prn.tick_frame()
    inc frames
  check(frames >= 30, "print takes hardware-ish time, took " & $frames)
  check(prn.outbox.len == 1, "sheets=1 emitted a strip")
  check(prn.outbox[0].len == 160 * 48, "three bands = 160x48 pixels")
  var all_white = true
  for px in prn.outbox[0]:
    if px != 0: all_white = false
  check(all_white, "zero tile data maps to shade 0 via palette 0xE4")

# Pan Docs, "Game Boy Printer", Example: INIT $00; DATA $00, then $08; the
# empty DATA $08; PRINT $08; STATUS $06 until the print ends, then $04.
echo "status sequence (Pan Docs example)"
block:
  let prn = new_gb_printer()
  let status_pkt = build_packet(0x0F, @[])
  check(prn.send(build_packet(0x01, @[])).last == 0x00, "INIT replies $00")
  check(prn.send(build_packet(0x04, band(0x00, 0x00))).last == 0x00,
        "DATA's own reply is still $00")
  check(prn.send(status_pkt).last == 0x08, "STATUS after DATA: $08, ready to print")
  check(prn.send(build_packet(0x04, band(0x00, 0x00))).last == 0x08,
        "a second DATA replies $08")
  check(prn.send(build_packet(0x04, @[])).last == 0x08, "the empty DATA replies $08")
  check(prn.send(status_pkt).last == 0x08, "the empty DATA changes nothing")
  check(prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40])).last == 0x08,
        "PRINT's own reply is still $08")
  check(prn.printing, "PRINT starts the print")
  var polls, busy = 0
  while prn.printing and polls < 1000:
    if prn.send(status_pkt).last == 0x06: inc busy
    inc polls
    prn.tick_frame()
  check(polls >= 30 and busy == polls,
        "every STATUS during the print reads $06 (" & $busy & " of " & $polls & ")")
  check(prn.send(status_pkt).last == 0x04, "STATUS after the print: $04, done")
  check(prn.send(status_pkt).last == 0x04, "$04 holds while the game keeps talking")
  check(prn.send(build_packet(0x01, @[])).last == 0x00,
        "INIT straight after a print replies $00, not the old $04")
  check(prn.send(status_pkt).last == 0x00, "and leaves $00")

echo "a slow poller still reads the end of the print"
block:
  # One STATUS every 10 frames, past the 100 ms (6-frame) packet timeout: the
  # timeout neither aborts the print nor takes the $04 away. Hello Kitty
  # Pocket Camera is reported to send PRINT again for ever if a poll after
  # the print reads $00, so done stays until the game starts something new.
  let prn = new_gb_printer()
  let status_pkt = build_packet(0x0F, @[])
  discard prn.send(build_packet(0x01, @[]))
  for _ in 0 ..< 3: discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x04, @[]))
  discard prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  var seen: seq[uint8] = @[]
  for _ in 0 ..< 60:
    for _ in 0 ..< 10: prn.tick_frame()
    let s = prn.send(status_pkt).last
    if seen.len == 0 or seen[^1] != s: seen.add(s)
  check(seen == @[0x06'u8, 0x04],
        "polls 10 frames apart read $06, then $04 and nothing after (got " & $seen & ")")
  check(prn.outbox.len == 1 and prn.outbox[0].len == 160 * 48,
        "the print ran to its end under slow polls")
  for _ in 0 ..< 600: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x04, "ten seconds of silence later: still $04")
  check(not prn.printing and prn.outbox.len == 1, "and nothing printed twice")
  for _ in 0 ..< 10: prn.tick_frame()
  check(prn.send(build_packet(0x01, @[])).last == 0x00, "INIT ends it: $00")
  for _ in 0 ..< 10: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x00, "and it stays $00")

echo "a new transfer without INIT ends the done state"
block:
  let prn = new_gb_printer()
  let status_pkt = build_packet(0x0F, @[])
  for _ in 0 ..< 3: discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x04, @[]))
  discard prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x04, "print done: $04")
  check(prn.send(build_packet(0x04, @[])).last == 0x04, "an empty DATA leaves $04")
  var replies: seq[uint8] = @[]
  for _ in 0 ..< 3: replies.add(prn.send(build_packet(0x04, band(0xFF, 0xFF))).last)
  replies.add(prn.send(build_packet(0x04, @[])).last)
  replies.add(prn.send(status_pkt).last)
  check(replies == @[0x04'u8, 0x08, 0x08, 0x08, 0x08],
        "DATA after done replies $04 then $08, never $0C (got " & $replies & ")")
  discard prn.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  check(prn.send(status_pkt).last == 0x06, "the second print runs: $06")
  while prn.printing: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x04 and prn.outbox.len == 2 and
        prn.outbox[1].len == 160 * 48,
        "and ends $04 with its own 48 rows")
  # A DATA while a print is still running does not take its $06 away.
  let prn2 = new_gb_printer()
  for _ in 0 ..< 3: discard prn2.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn2.send(build_packet(0x02, @[1'u8, 0x13, 0xE4, 0x40]))
  discard prn2.send(build_packet(0x04, band(0x00, 0x00)))
  check((prn2.send(status_pkt).last and 0x06) == 0x06, "DATA during a print keeps bits 2 and 1")

echo "idle timeout returns the printer to $00"
block:
  let prn = new_gb_printer()
  let status_pkt = build_packet(0x0F, @[])
  discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  check(prn.send(status_pkt).last == 0x08, "data waiting")
  for _ in 0 ..< 6: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x00, "100 ms of silence drops the buffer and its $08")
  discard prn.send(build_packet(0x07, @[]))
  check(prn.send(status_pkt).last == 0x10, "packet error set")
  for _ in 0 ..< 6: prn.tick_frame()
  check(prn.send(status_pkt).last == 0x00, "and the timeout clears that too")
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
  check(prn.outbox.len == 0, "nothing was left to print")

echo "break and error bits"
block:
  let prn = new_gb_printer()
  let status_pkt = build_packet(0x0F, @[])
  for _ in 0 ..< 3: discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  check(prn.send(status_pkt).last == 0x06, "printing")
  discard prn.send(build_packet(0x08, @[]))
  check(not prn.printing and prn.send(status_pkt).last == 0x00, "BREAK stops the print: $00")
  let bad = prn.send(build_packet(0x04, band(0, 0), corrupt_chk = true))
  check(bad.last == 0x01, "a bad checksum reports bit 0 alone")
  check(prn.send(status_pkt).last == 0x00, "and the rejected DATA is not waiting")
  discard prn.send(build_packet(0x07, @[]))
  check(prn.send(status_pkt).last == 0x10, "an unknown command sets the packet-error bit")
  check(prn.send(build_packet(0x01, @[])).last == 0x00, "INIT clears it")

echo "paper-feed strips stay out of the gallery"
block:
  let prn = new_gb_printer()
  discard prn.send(build_packet(0x04, band(0x00, 0x00)))   # 16 rows only
  discard prn.send(build_packet(0x02, @[1'u8, 0x03, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
  check(prn.outbox.len == 0, "a 16-row feed is not a photograph")

echo "pixel decode + palette"
block:
  let prn = new_gb_printer()
  for _ in 0 ..< 3: discard prn.send(build_packet(0x04, band(0xFF, 0x00)))  # shade 1
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
  discard prn.send(build_packet(0x0F, @[]))
  check(prn.outbox.len == 1 and prn.outbox[0][0] == 1,
        "lo-plane bits decode to shade 1 under identity palette")
  let prn2 = new_gb_printer()
  for _ in 0 ..< 3: discard prn2.send(build_packet(0x04, band(0xFF, 0xFF)))  # shade 3
  discard prn2.send(build_packet(0x02, @[1'u8, 0, 0x1B, 0x40]))  # inverted pal
  while prn2.printing: prn2.tick_frame()
  check(prn2.outbox.len == 1 and prn2.outbox[0][0] == 0,
        "shade 3 under inverted palette 0x1B maps to 0")

echo "multi-print strips (sheets=0 appends)"
block:
  let prn = new_gb_printer()
  for _ in 0 ..< 2: discard prn.send(build_packet(0x04, band(0x00, 0x00)))
  discard prn.send(build_packet(0x02, @[0'u8, 0, 0xE4, 0x40]))  # no feed
  while prn.printing: prn.tick_frame()
  check(prn.outbox.len == 0, "sheets=0 holds the strip open")
  discard prn.send(build_packet(0x01, @[]))  # INIT between segments
  for _ in 0 ..< 2: discard prn.send(build_packet(0x04, band(0xFF, 0xFF)))
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))  # feed
  while prn.printing: prn.tick_frame()
  check(prn.outbox.len == 1 and prn.outbox[0].len == 160 * 64,
        "second print with feed emits the combined 64-row strip")

echo "checksum failure"
block:
  let prn = new_gb_printer()
  let r = prn.send(build_packet(0x04, band(0, 0), corrupt_chk = true))
  check((r.last and 0x01) != 0, "bad checksum reports the error in its own ack")
  let p = prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
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
  check(r.last == 0x00, "compressed DATA accepted")
  for _ in 0 ..< 2: discard prn.send(build_packet(0x04, comp, compressed = true))
  discard prn.send(build_packet(0x02, @[1'u8, 0, 0xE4, 0x40]))
  while prn.printing: prn.tick_frame()
  check(prn.outbox.len == 1 and prn.outbox[0].len == 160 * 48,
        "three decompressed bands = a 48-row strip")

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
