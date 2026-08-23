# Game Boy Printer, a GbSerialDriver (serial.nim). Every solo GB session
# keeps one plugged in: games that never print send no packets, and asking
# first cannot win because the opening INIT completes in ~8 ms, inside one
# frame, before any prompt (Game Boy Camera Gold errors out). Pure byte-echo
# state machine: the reply for slot k goes out while byte k is received, so
# feed() computes the reply from the state BEFORE consuming the byte.
#
# Pan Docs, "Gameboy Printer". Packet framing (GB -> printer), replies in
# parentheses:
#   0x88 0x33 (0,0) | cmd (0) | compression (0) | len lo,hi (0,0) |
#   payload xN (0 xN) | checksum lo,hi (0,0) | dummy (0x81) | dummy (STATUS)
# Checksum = 16-bit sum of cmd + compression + len + payload. Any non-0x88
# byte outside a packet keeps the parser in MAGIC1, so mid-packet aborts and
# state loads self-heal.
#
# Status bits: 0 checksum error, 1 printing, 2 print done, 3 unprocessed data
# present. Sequence: 0x00 idle -> 0x08 data buffered -> 0x06 printing -> 0x04
# done -> 0x00 once the game has seen the 0x04. Assumed; no ROM pins this.

import gb

const
  PRN_MAX_IMAGE   = 160 * 200 div 4      # 8 KiB printer RAM
  PRN_BAND_TILES  = 40                    # DATA bands are 20x2 tiles
  # Print time, ~7.5 frames per pixel row (a 160x144 photo ~18 s); GB Camera
  # animates its progress display off the status polls for that long.
  # Assumed; no ROM pins this.
  PRN_FRAMES_PER_ROW_NUM = 15
  PRN_FRAMES_PER_ROW_DEN = 2
  # Paper-feed jobs print a few blank rows to eject the sheet. They are not
  # photographs, so they never reach the gallery.
  PRN_MIN_PHOTO_ROWS = 24

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
    reply*:       uint8      # status latched at ACK time (see psStatus)
    buffer:       seq[uint8]  # printer RAM: 2bpp tile bands, INIT clears it
    strip:        seq[uint8]  # assembled shade rows (0..3), 160 per pixel row
    print_left:   int         # frames of "printing" remaining
    feed_after:   bool        # this print ends the strip when it completes
    outbox*:      seq[seq[uint8]]  # finished strips (shade rows, w=160)
    log*:         seq[uint16]    # RX<<8|TX ring of the last exchanges
    muted*:       bool        # clip replay: reply 0, mutate nothing
    idle_frames:  int         # frames since the last serial byte (timeout)

  GbPrinterDriver* = ref object of GbSerialDriver
    printer*: GbPrinter


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
  if prn.strip.len div 160 >= PRN_MIN_PHOTO_ROWS:
    prn.outbox.add(prn.strip)
  prn.strip = @[]

# ---- per-frame time -------------------------------------------------------

const PRN_TIMEOUT_FRAMES = 6  # 100 ms at 59.7 fps

proc tick_frame*(prn: GbPrinter) =
  ## Advance the print countdown; call once per emulated frame.
  # Pan Docs: a 100 ms packet timeout returns the printer to its initialized
  # state (link and graphics buffers reset). An active print is left to
  # finish: the game only polls status while the motor runs, and aborting on
  # a slow poll re-breaks Hello Kitty Pocket Camera (see below).
  inc prn.idle_frames
  if prn.idle_frames >= PRN_TIMEOUT_FRAMES and prn.print_left == 0 and
     (prn.state != psMagic1 or prn.buffer.len > 0):
    prn.state = psMagic1
    prn.buffer.setLen(0)
    prn.status = 0
  if prn.print_left > 0:
    dec prn.print_left
    if prn.print_left == 0:
      # "Done" (bit 2) stays latched until a later INIT or DATA, never cleared
      # by a status read: clear-on-read leaves Hello Kitty Pocket Camera
      # re-PRINTing forever because a second poll reports idle.
      prn.status = 0x04
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
      prn.print_left = max(30, printed_rows * PRN_FRAMES_PER_ROW_NUM div PRN_FRAMES_PER_ROW_DEN)
      prn.status = 0x06          # printing
  of 0x04:  # DATA: append a band (empty payload = the conventional flush)
    let chunk = if prn.compressed: rle_decode(prn.payload) else: prn.payload
    # Only a full band counts: a short/zero-length packet (the conventional
    # flush) is ignored and leaves the status be. Assumed; no ROM pins this.
    if chunk.len == PRN_BAND_TILES * 16:
      if prn.buffer.len + chunk.len <= PRN_MAX_IMAGE:
        prn.buffer.add(chunk)
      # Overflow drops the band and sets no bit: bit 2 must only ever mean
      # "print complete". Assignment, not `or`: this clears a latched done
      # from the previous job; ORing reported 0x0C where hardware reports
      # 0x08 and Game Boy Camera Gold sat on "transferring" forever.
      prn.status = 0x08                  # unprocessed data present
  of 0x08:  # BREAK: abort
    prn.print_left = 0
    prn.buffer.setLen(0)
    prn.status = 0
  of 0x0F:  # STATUS inquiry: nothing to execute
    discard
  else:
    prn.status = prn.status or 0x10      # packet error (unknown command)

# ---- the byte engine ------------------------------------------------------

proc log_pair(prn: GbPrinter; rx, tx: uint8) =
  if prn.log.len >= 512: prn.log.delete(0)
  prn.log.add((uint16(rx) shl 8) or uint16(tx))

proc feed*(prn: GbPrinter; b: uint8): uint8 =
  ## Consume one byte from the GB, return the printer's reply for this slot.
  prn.idle_frames = 0   # any traffic re-arms the 100 ms timeout (tick_frame)
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
    # Latch the status reply NOW, before the command runs: the status byte is
    # captured during this ACK transfer and the command executes afterwards,
    # so a packet reports the status as of before its own command. Executing
    # first makes PRINT ack 0x06 where hardware acks 0x08, and Game Boy
    # Camera Gold re-PRINTs forever.
    if prn.chk_recv != prn.chk:
      prn.status = prn.status or 0x01
    else:
      prn.status = prn.status and not 0x01'u8
    # INIT's status slot always reads 0x00 (Pan Docs: "games expect INIT
    # commands to return 0"), whatever was latched before it.
    prn.reply = if (prn.cmd and 0x0F) == 0x01: 0'u8 else: prn.status
    prn.state = psStatus
  of psStatus:
    result = prn.reply            # latched at psAck, pre-execution
    if (prn.status and 0x01) == 0:
      prn.exec_command()
    prn.state = psMagic1
  prn.log_pair(b, result)

# ---- runahead snapshot ----------------------------------------------------

proc copy_into*(src, dst: GbPrinter) =
  ## Field-wise copy for run-ahead: lookahead frames feed the printer bytes
  ## the canonical timeline has not sent yet, so the shim snapshots before and
  ## restores after (outbox included, or a lookahead frame emits a phantom
  ## print).
  dst.state = src.state
  dst.cmd = src.cmd
  dst.compressed = src.compressed
  dst.length = src.length
  dst.data_left = src.data_left
  dst.payload = src.payload
  dst.chk = src.chk
  dst.chk_recv = src.chk_recv
  dst.status = src.status
  dst.reply = src.reply
  dst.buffer = src.buffer
  dst.strip = src.strip
  dst.print_left = src.print_left
  dst.feed_after = src.feed_after
  dst.outbox = src.outbox
  dst.muted = src.muted
  dst.idle_frames = src.idle_frames

proc clone*(prn: GbPrinter): GbPrinter =
  result = new_gb_printer()
  copy_into(prn, result)

# ---- rewind ---------------------------------------------------------------

proc resync*(prn: GbPrinter) =
  ## Return the link protocol to idle, dropping any half-received packet. The
  ## printer is not in the GB save state, so a rewind leaves it mid-packet
  ## with bytes the core will never send; resetting is what an unplug/replug
  ## does. Printer RAM, the strip and the outbox survive: a photo that came
  ## out does not un-print (rewinding across a print and printing again
  ## yields it twice).
  prn.state = psMagic1
  prn.cmd = 0
  prn.compressed = false
  prn.length = 0
  prn.data_left = 0
  prn.payload = @[]
  prn.chk = 0
  prn.chk_recv = 0

# ---- serial drivers -------------------------------------------------------

method serial_peer_committed*(drv: GbPrinterDriver): bool =
  ## The completed byte has already been fed to the printer's packet state
  ## machine, which cannot be un-fed. See the base method in serial.nim.
  true

method serial_complete*(drv: GbPrinterDriver; gb: GB) =
  if drv.printer.muted:
    gb.serial.sb = 0x00
  else:
    gb.serial.sb = drv.printer.feed(gb.serial.out_latch)
  serial_finish_transfer(gb.serial, gb)

