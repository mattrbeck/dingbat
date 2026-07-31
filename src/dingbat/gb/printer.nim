# Game Boy Printer, attached like a link-cable peer (a GbSerialDriver — see
# serial.nim's device seam). The printer is a pure byte-echo state machine:
# it emits its reply for slot k while receiving byte k, so feed() computes
# the reply from the state BEFORE consuming the incoming byte.
#
# Written from Pan Docs (gbdev.io/pandocs/Gameboy_Printer.html); SameBoy's
# printer.c used as a cross-check for the status-byte sequencing only.
#
# Packet framing (GB -> printer), replies in parentheses:
#   0x88 0x33 (0,0) | cmd (0) | compression (0) | len lo,hi (0,0) |
#   payload xN (0 xN) | checksum lo,hi (0,0) | dummy (0x81) | dummy (STATUS)
# Checksum = 16-bit sum of cmd + compression + len bytes + payload (the
# magic bytes are excluded). Any non-0x88 byte outside a packet keeps the
# parser in MAGIC1, which is what makes state loads / mid-packet aborts
# self-healing without serializing anything.
#
# Status bits: 0 checksum error, 1 printing, 2 image-buffer/print done,
# 3 unprocessed data present. Observed sequence (SameBoy): 0x00 idle ->
# 0x08 data buffered -> 0x06 printing -> 0x04 done -> 0x00 once the game
# has seen the 0x04.

import gb

const
  PRN_ROW_BYTES   = 40                    # 160 px at 2bpp
  PRN_MAX_IMAGE   = 160 * 200 div 4      # 8 KiB printer RAM
  PRN_BAND_TILES  = 40                    # DATA bands are 20x2 tiles
  # Rows-proportional print time, matching real hardware's seconds-per-photo
  # feel (a full 160x144 print ~= 7 s at 60 fps). GB Camera renders a live
  # progress display off the status polls, so an instantly-done printer
  # breaks it; this is the "match hardware" setting.
  PRN_FRAMES_PER_ROW = 3

type
  PrnState = enum
    psMagic1, psMagic2, psCmd, psCompress, psLenLo, psLenHi,
    psData, psChkLo, psChkHi, psAck, psStatus

  GbPrinter* = ref object
    state:        PrnState
    cmd:          uint8
    compressed:   bool
    length:       int
    data_left:    int
    payload:      seq[uint8]
    chk:          uint16      # running sum over cmd/compression/len/payload
    chk_recv:     uint16
    status*:      uint8
    buffer:       seq[uint8]  # printer RAM: 2bpp tile bands, INIT clears it
    strip:        seq[uint8]  # assembled shade rows (0..3), 160 per pixel row
    print_left:   int         # frames of "printing" remaining
    feed_after:   bool        # this print ends the strip when it completes
    done_seen:    bool        # 0x04 delivered once -> next inquiry reads 0x00
    outbox*:      seq[seq[uint8]]  # finished strips (shade rows, w=160)
    muted*:       bool        # clip replay: reply 0, mutate nothing

  GbPrinterDriver* = ref object of GbSerialDriver
    printer*: GbPrinter

  # Passive print-intent detector for the no-cable state: watches outgoing
  # bytes for the packet magic so the frontend can offer to connect a
  # printer at the moment the game first tries to print. Replies exactly
  # like the base no-cable driver (line floats high).
  GbPrintSniffer* = ref object of GbSerialDriver
    saw88:   bool
    wanted*: bool

proc new_gb_printer*(): GbPrinter =
  GbPrinter(payload: @[], buffer: @[], strip: @[], outbox: @[])

# ---- image assembly -------------------------------------------------------

proc render_buffer_to_strip(prn: GbPrinter; palette: uint8) =
  ## Decode the RAM buffer's 20x2-tile bands into shade rows and append them
  ## to the strip. 16 bytes/tile, tiles row-major within each band.
  let bands = prn.buffer.len div (PRN_BAND_TILES * 16)
  for band in 0 ..< bands:
    let base = band * PRN_BAND_TILES * 16
    for y in 0 ..< 16:
      let tile_row = y shr 3
      let y7 = y and 7
      for x in 0 ..< 160:
        let tile_col = x shr 3
        let tile_idx = tile_row * 20 + tile_col
        let off = base + tile_idx * 16 + y7 * 2
        let bit = 7 - (x and 7)
        let lo = (prn.buffer[off] shr bit) and 1
        let hi = (prn.buffer[off + 1] shr bit) and 1
        let shade = (hi shl 1) or lo
        prn.strip.add((palette shr (shade * 2)) and 3)

proc emit_strip(prn: GbPrinter) =
  if prn.strip.len >= 160:
    prn.outbox.add(prn.strip)
  prn.strip = @[]

# ---- per-frame time -------------------------------------------------------

proc tick_frame*(prn: GbPrinter) =
  ## Advance the print countdown; call once per emulated frame.
  if prn.print_left > 0:
    dec prn.print_left
    if prn.print_left == 0:
      prn.status = 0x04          # done; cleared after the game observes it
      prn.done_seen = false
      if prn.feed_after:
        prn.emit_strip()

# ---- command execution ----------------------------------------------------

proc rle_decode(payload: seq[uint8]): seq[uint8] =
  ## Pan Docs RLE: control bit7 set = (len&0x7F)+2 copies of the next byte,
  ## clear = (len&0x7F)+1 literal bytes.
  result = @[]
  var i = 0
  while i < payload.len and result.len < PRN_MAX_IMAGE:
    let b = int(payload[i])
    inc i
    if (b and 0x80) != 0:
      if i >= payload.len: break
      let n = (b and 0x7F) + 2
      for _ in 0 ..< n: result.add(payload[i])
      inc i
    else:
      let n = (b and 0x7F) + 1
      for j in 0 ..< n:
        if i + j >= payload.len: break
        result.add(payload[i + j])
      i += n

proc exec_command(prn: GbPrinter) =
  case prn.cmd and 0x0F
  of 0x01:  # INIT: clear the RAM buffer (NOT the strip — sheets=0 prints
            # deliberately span INIT boundaries while a tall image assembles)
    prn.buffer.setLen(0)
    prn.status = 0
    prn.print_left = 0
  of 0x02:  # PRINT: payload = sheets, margins, palette, exposure
    if prn.payload.len >= 4:
      let sheets  = prn.payload[0]
      let palette = prn.payload[2]
      let rows_before = prn.strip.len div 160
      prn.render_buffer_to_strip(palette)
      let printed_rows = prn.strip.len div 160 - rows_before
      prn.buffer.setLen(0)
      prn.feed_after = sheets != 0
      prn.print_left = max(30, printed_rows * PRN_FRAMES_PER_ROW)
      prn.status = 0x06          # printing
  of 0x04:  # DATA: append a band (empty payload = the conventional flush)
    if prn.payload.len > 0:
      let chunk = if prn.compressed: rle_decode(prn.payload) else: prn.payload
      if prn.buffer.len + chunk.len <= PRN_MAX_IMAGE:
        prn.buffer.add(chunk)
      else:
        prn.status = prn.status or 0x04  # buffer full
      prn.status = prn.status or 0x08    # unprocessed data present
  of 0x08:  # BREAK: abort
    prn.print_left = 0
    prn.buffer.setLen(0)
    prn.status = 0
  of 0x0F:  # STATUS inquiry: nothing to execute
    discard
  else:
    prn.status = prn.status or 0x10      # packet error (unknown command)

# ---- the byte engine ------------------------------------------------------

proc feed*(prn: GbPrinter; b: uint8): uint8 =
  ## Consume one byte from the GB, return the printer's reply for this slot.
  case prn.state
  of psMagic1:
    result = 0
    if b == 0x88: prn.state = psMagic2
  of psMagic2:
    result = 0
    if b == 0x33: prn.state = psCmd
    elif b != 0x88: prn.state = psMagic1
  of psCmd:
    result = 0
    prn.cmd = b
    prn.chk = uint16(b)
    prn.state = psCompress
  of psCompress:
    result = 0
    prn.compressed = (b and 1) != 0
    prn.chk += uint16(b)
    prn.state = psLenLo
  of psLenLo:
    result = 0
    prn.length = int(b)
    prn.chk += uint16(b)
    prn.state = psLenHi
  of psLenHi:
    result = 0
    prn.length = prn.length or (int(b) shl 8)
    prn.chk += uint16(b)
    prn.data_left = prn.length
    prn.payload.setLen(0)
    prn.state = if prn.length > 0: psData else: psChkLo
  of psData:
    result = 0
    if prn.payload.len < PRN_MAX_IMAGE: prn.payload.add(b)
    prn.chk += uint16(b)
    dec prn.data_left
    if prn.data_left <= 0: prn.state = psChkLo
  of psChkLo:
    result = 0
    prn.chk_recv = uint16(b)
    prn.state = psChkHi
  of psChkHi:
    result = 0
    prn.chk_recv = prn.chk_recv or (uint16(b) shl 8)
    prn.state = psAck
  of psAck:
    result = 0x81                # device id / alive
    prn.state = psStatus
  of psStatus:
    if prn.chk_recv != prn.chk:
      prn.status = prn.status or 0x01
    else:
      prn.status = prn.status and not 0x01'u8
      prn.exec_command()
    result = prn.status
    # The game has now observed the completed print; the next packet reads
    # idle (SameBoy's 0x06 -> 0x04 -> 0x00 sequence).
    if prn.status == 0x04:
      prn.status = 0
    prn.state = psMagic1

# ---- runahead snapshot ----------------------------------------------------

proc copy_into*(src, dst: GbPrinter) =
  ## Field-wise copy for run-ahead: lookahead frames feed the printer bytes
  ## the canonical timeline hasn't sent yet, so the shim snapshots before
  ## the lookahead and restores after (outbox included — a lookahead frame
  ## must not emit a phantom print).
  dst.state = src.state
  dst.cmd = src.cmd
  dst.compressed = src.compressed
  dst.length = src.length
  dst.data_left = src.data_left
  dst.payload = src.payload
  dst.chk = src.chk
  dst.chk_recv = src.chk_recv
  dst.status = src.status
  dst.buffer = src.buffer
  dst.strip = src.strip
  dst.print_left = src.print_left
  dst.feed_after = src.feed_after
  dst.done_seen = src.done_seen
  dst.outbox = src.outbox
  dst.muted = src.muted

proc clone*(prn: GbPrinter): GbPrinter =
  result = new_gb_printer()
  copy_into(prn, result)

# ---- serial drivers -------------------------------------------------------

method serial_complete*(drv: GbPrinterDriver; gb: GB) =
  if drv.printer.muted:
    gb.serial.sb = 0x00
  else:
    gb.serial.sb = drv.printer.feed(gb.serial.out_latch)
  serial_finish_transfer(gb.serial, gb)

method serial_complete*(drv: GbPrintSniffer; gb: GB) =
  let b = gb.serial.out_latch
  if b == 0x88:
    drv.saw88 = true
  else:
    if drv.saw88 and b == 0x33: drv.wanted = true
    drv.saw88 = false
  # No cable attached: the input line floats high (base behavior)
  serial_finish_transfer(gb.serial, gb)
