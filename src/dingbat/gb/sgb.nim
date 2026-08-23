# Super Game Boy: command-packet receiver, screen colorization, border
# (included by gb.nim). Active only when `gb.sgb != nil`: the header unlocks
# SGB functions (Pan Docs, "Unlocking and Detecting SGB Functions") and the
# machine is not in CGB mode.
#
# Pan Docs, "SGB Functions". Modelled: the P1 pulse receiver, PAL01/23/03/12,
# PAL_SET, PAL_TRN, ATTR_BLK/LIN/DIV/CHR, ATTR_TRN, ATTR_SET, MASK_EN, CHR_TRN,
# PCT_TRN, MLT_REQ's player count. SNES-side commands (SOUND/SOU_TRN, OBJ_TRN,
# DATA_SND/DATA_TRN/JUMP, ATRC_EN/TEST_EN/ICON_EN/PAL_PRI) are accepted and
# dropped; none feeds anything back to the Game Boy. The SGB's 2.4% faster
# master clock is not modelled (docs/sgb.md).

const SGB_ATTR_W* = 20
const SGB_ATTR_H* = 18
const SGB_BORDER_W* = 256
const SGB_BORDER_H* = 224

# Bit 15 of a BGR555 word is unused, so the border image carries "opaque"
# there; SNES colour 0 is transparent and shows the Game Boy window through.
const SGB_OPAQUE* = 0x8000'u16

proc sgb_unlocked*(rom: seq[uint8]): bool =
  ## Pan Docs: SGB flag 0x03 AND old licensee code 0x33; either alone leaves
  ## the cart a plain monochrome game.
  rom.len > 0x14C and rom[0x0146] == 0x03'u8 and rom[0x014B] == 0x33'u8

proc new_sgb_state*(): SgbState =
  # prev_lines starts at 3, both select lines idle high (the boot handoff
  # leaves neither group selected); starting at 0 would swallow the first
  # reset pulse a game sends.
  result = SgbState(players: 1, prev_lines: 3)
  # Power-on palettes: the DMG ramp until a game sends PAL*.
  for p in 0 ..< 4:
    for c in 0 ..< 4:
      result.pal[p * 4 + c] = DMG_COLORS[c]
  result.border = newSeq[uint16](SGB_BORDER_W * SGB_BORDER_H)
  result.frozen = newSeq[uint16](GB_WIDTH * GB_HEIGHT)

# ==================== attribute helpers ====================

proc sgb_set_attr(s: SgbState; x, y: int; pal: uint8) {.inline.} =
  if x >= 0 and x < SGB_ATTR_W and y >= 0 and y < SGB_ATTR_H:
    s.attr[y * SGB_ATTR_W + x] = pal and 3

proc sgb_apply_atf(s: SgbState; n: int) =
  ## Copy Attribute File `n` (90 bytes: 18 lines x 5 bytes x 4 cells, MSB
  ## pair first) into the live attribute map.
  if n < 0 or n > 44: return
  let base = n * 90
  for row in 0 ..< SGB_ATTR_H:
    for b in 0 ..< 5:
      let byt = s.atf[base + row * 5 + b]
      for k in 0 ..< 4:
        let x = b * 4 + k
        s.attr[row * SGB_ATTR_W + x] = (byt shr (6 - k * 2)) and 3

# ==================== palette commands ====================

proc sgb_le16(p: openArray[uint8]; i: int): uint16 {.inline.} =
  uint16(p[i]) or (uint16(p[i + 1]) shl 8)

proc sgb_set_backdrop(s: SgbState; col: uint16) {.inline.} =
  ## Pan Docs: colour 0 of every palette is the shared backdrop, the most
  ## recent colour 0 assigned regardless of palette number.
  for p in 0 ..< 4: s.pal[p * 4] = col

proc sgb_cmd_pal(s: SgbState; p: openArray[uint8]; a, b: int) =
  ## PAL01/23/03/12: palette `a` gets colours 0-3, palette `b` gets 1-3 and
  ## shares the colour 0 just written.
  let c0 = sgb_le16(p, 1) and 0x7FFF
  sgb_set_backdrop(s, c0)
  for c in 1 .. 3: s.pal[a * 4 + c] = sgb_le16(p, 1 + c * 2) and 0x7FFF
  for c in 1 .. 3: s.pal[b * 4 + c] = sgb_le16(p, 7 + c * 2) and 0x7FFF

proc sgb_cmd_pal_set(s: SgbState; p: openArray[uint8]) =
  for i in 0 ..< 4:
    let id = int(sgb_le16(p, 1 + i * 2)) and 0x1FF
    for c in 0 ..< 4:
      s.pal[i * 4 + c] = s.syspal[id * 4 + c] and 0x7FFF
  # The four palettes still share one colour 0 (the backdrop).
  sgb_set_backdrop(s, s.pal[0])
  let flags = p[9]
  if (flags and 0x80) != 0: s.sgb_apply_atf(int(flags and 0x3F))
  if (flags and 0x40) != 0: s.mask = 0

# ==================== attribute commands ====================

proc sgb_cmd_attr_blk(s: SgbState; d: openArray[uint8]) =
  let n = min(int(d[1]), 0x12)
  for i in 0 ..< n:
    let o = 2 + i * 6
    if o + 5 >= d.len: break
    let ctrl = d[o] and 7
    let pals = d[o + 1]
    let x1 = int(d[o + 2] and 0x1F); let y1 = int(d[o + 3] and 0x1F)
    let x2 = int(d[o + 4] and 0x1F); let y2 = int(d[o + 5] and 0x1F)
    let p_in = pals and 3
    let p_line = (pals shr 2) and 3
    let p_out = (pals shr 4) and 3
    # "Exception: When changing only the Inside or Outside, then the
    # Surrounding line becomes automatically changed to same color."
    let do_in = (ctrl and 1) != 0
    let do_line = (ctrl and 2) != 0
    let do_out = (ctrl and 4) != 0
    let line_pal =
      if do_line: p_line
      elif do_in and not do_out: p_in
      elif do_out and not do_in: p_out
      else: p_line
    let line_on = do_line or (do_in xor do_out)
    for y in 0 ..< SGB_ATTR_H:
      for x in 0 ..< SGB_ATTR_W:
        let on_edge = (x == x1 or x == x2) and y >= y1 and y <= y2 or
                      (y == y1 or y == y2) and x >= x1 and x <= x2
        if on_edge:
          if line_on: s.sgb_set_attr(x, y, line_pal)
        elif x > x1 and x < x2 and y > y1 and y < y2:
          if do_in: s.sgb_set_attr(x, y, p_in)
        else:
          if do_out: s.sgb_set_attr(x, y, p_out)

proc sgb_cmd_attr_lin(s: SgbState; d: openArray[uint8]) =
  let n = min(int(d[1]), 0x6E)
  for i in 0 ..< n:
    let o = 2 + i
    if o >= d.len: break
    let v = d[o]
    let line = int(v and 0x1F)
    let pal = (v shr 5) and 3
    if (v and 0x80) != 0:
      for x in 0 ..< SGB_ATTR_W: s.sgb_set_attr(x, line, pal)
    else:
      for y in 0 ..< SGB_ATTR_H: s.sgb_set_attr(line, y, pal)

proc sgb_cmd_attr_div(s: SgbState; d: openArray[uint8]) =
  let v = d[1]
  let p_lo = v and 3            # below / right of the line
  let p_hi = (v shr 2) and 3    # above / left
  let p_ln = (v shr 4) and 3
  let horiz = (v and 0x40) != 0
  let coord = int(d[2] and 0x1F)
  for y in 0 ..< SGB_ATTR_H:
    for x in 0 ..< SGB_ATTR_W:
      let k = if horiz: y else: x
      s.sgb_set_attr(x, y, if k < coord: p_hi elif k == coord: p_ln else: p_lo)

proc sgb_cmd_attr_chr(s: SgbState; d: openArray[uint8]) =
  var x = int(d[1] and 0x1F)
  var y = int(d[2] and 0x1F)
  let count = min(int(sgb_le16(d, 3)), 360)
  let top_down = (d[5] and 1) != 0
  for i in 0 ..< count:
    let o = 6 + (i shr 2)
    if o >= d.len: break
    let pal = (d[o] shr (6 - (i and 3) * 2)) and 3
    s.sgb_set_attr(x, y, pal)
    if top_down:
      inc y
      if y >= SGB_ATTR_H:
        y = 0; inc x
        if x >= SGB_ATTR_W: x = 0
    else:
      inc x
      if x >= SGB_ATTR_W:
        x = 0; inc y
        if y >= SGB_ATTR_H: y = 0

# ==================== border ====================

proc sgb_render_border*(s: SgbState) =
  ## Decode the 32x28 SNES tilemap + 4bpp tiles into a 256x224 BGR555 image.
  ## Colour index 0 is transparent (SGB_OPAQUE clear), which is how the Game
  ## Boy window shows through the middle of the frame.
  for i in 0 ..< s.border.len: s.border[i] = 0
  var opaque = false
  for ty in 0 ..< 28:
    for tx in 0 ..< 32:
      let e = s.map[ty * 32 + tx]
      let tile = int(e and 0xFF)
      let pal = int((e shr 10) and 7)
      # Only palettes 4-6 exist for the border; anything else is a malformed
      # map entry, and the SGB's own palette 0-3 would be the GB screen's.
      let pbase = (if pal >= 4 and pal <= 6: (pal - 4) else: 0) * 16
      let xflip = (e and 0x4000) != 0
      let yflip = (e and 0x8000) != 0
      let tbase = tile * 32
      for row in 0 ..< 8:
        let sr = if yflip: 7 - row else: row
        let p0 = s.chr[tbase + sr * 2]
        let p1 = s.chr[tbase + sr * 2 + 1]
        let p2 = s.chr[tbase + 16 + sr * 2]
        let p3 = s.chr[tbase + 16 + sr * 2 + 1]
        let dst = (ty * 8 + row) * SGB_BORDER_W + tx * 8
        for col in 0 ..< 8:
          let sc = if xflip: 7 - col else: col
          let sh = 7 - sc
          let ci = int(((p0 shr sh) and 1) or
                       (((p1 shr sh) and 1) shl 1) or
                       (((p2 shr sh) and 1) shl 2) or
                       (((p3 shr sh) and 1) shl 3))
          if ci != 0:
            s.border[dst + col] = (s.border_pal[pbase + ci] and 0x7FFF) or SGB_OPAQUE
            opaque = true
  # "Valid" means something to show: between CHR_TRN and PCT_TRN the tilemap
  # is all zeroes and decodes fully transparent, and a 256x224 window with an
  # empty margin for those frames is worse than none.
  s.border_valid = opaque
  inc s.border_gen

# ==================== VRAM transfers ====================

proc sgb_read_transfer(gb: GB; dst: var array[4096, uint8]) =
  ## Reconstruct the 4 KiB a real SGB reads out of the Game Boy's video
  ## signal. Pan Docs, "VRAM Transfers", says the data is "normally" at
  ## 0x8000-0x8FFF, but what the SNES gets is the picture: a cart with LCDC.4
  ## clear (signed tile addressing) meets every listed precondition and
  ## displays different memory. Pokemon Blue runs all three transfers with
  ## LCDC = 0xE3, where a flat 0x8000 read returns mostly zeroes. So walk the
  ## display as the PPU would: for each character $00-$FF read its BG map cell
  ## (SCX/SCY, LCDC.3) and fetch the tile through LCDC.4's addressing.
  ## Objects are ignored (Pan Docs requires they not overlap the background).
  let ppu = gb.ppu
  let map_base = if (ppu.lcd_control and 0x08'u8) != 0: 0x1C00 else: 0x1800
  let signed_tiles = (ppu.lcd_control and 0x10'u8) == 0
  for n in 0 ..< 256:
    let cx = n mod 20
    let cy = n div 20
    let mx = ((cx * 8 + int(ppu.scx)) shr 3) and 31
    let my = ((cy * 8 + int(ppu.scy)) shr 3) and 31
    let tn = ppu.vram[0][map_base + my * 32 + mx]
    let tile_addr =
      if signed_tiles: 0x1000 + int(cast[int8](tn)) * 16
      else:            int(tn) * 16
    for k in 0 ..< 16:
      dst[n * 16 + k] = ppu.vram[0][(tile_addr + k) and 0x1FFF]

proc sgb_vram_transfer(gb: GB; cmd, arg: uint8) =
  ## Hardware reads over the five frames after the packet; dingbat reads when
  ## the packet completes. Pan Docs requires the data on screen before the
  ## packet is sent, so the picture is the same (Pokemon Blue's is byte-stable
  ## across those frames), and an immediate read is safer for two CHR_TRNs
  ## around one VRAM rewrite.
  let s = gb.sgb
  var buf: array[4096, uint8]
  sgb_read_transfer(gb, buf)
  template b(i: int): uint8 = buf[i]
  when defined(sgb_trace):
    var nz = 0
    for i in 0 ..< 4096:
      if buf[i] != 0: inc nz
    s.trace_watch = 8
    echo "  VRAM transfer cmd $" & toHex(cmd, 2) & " arg " & toHex(arg, 2) &
         ": " & $nz & "/4096 nonzero, LCDC=" & toHex(gb.ppu.lcd_control, 2) &
         " LY=" & $gb.ppu.ly
  case cmd
  of 0x0B:  # PAL_TRN — 512 palettes x 4 colours
    for i in 0 ..< 2048:
      s.syspal[i] = uint16(b(i * 2)) or (uint16(b(i * 2 + 1)) shl 8)
  of 0x15:  # ATTR_TRN — 45 attribute files x 90 bytes
    for i in 0 ..< 4050: s.atf[i] = b(i)
  of 0x13:  # CHR_TRN — 128 tiles into the low or high half of border CHR RAM
    let base = (int(arg) and 1) * 4096
    for i in 0 ..< 4096: s.chr[base + i] = b(i)
    s.border_dirty = true
  of 0x14:  # PCT_TRN — 32x28 (+1 hidden row) tilemap, then palettes 4-6
    for i in 0 ..< 32 * 28:
      s.map[i] = uint16(b(i * 2)) or (uint16(b(i * 2 + 1)) shl 8)
    for i in 0 ..< 48:
      s.border_pal[i] = uint16(b(0x800 + i * 2)) or (uint16(b(0x801 + i * 2)) shl 8)
    s.border_dirty = true
  else: discard

# ==================== command dispatch ====================

when defined(sgb_trace):
  # Packet log (tools only).
  const SGB_CMD_NAMES = [
    "PAL01", "PAL23", "PAL03", "PAL12", "ATTR_BLK", "ATTR_LIN", "ATTR_DIV",
    "ATTR_CHR", "SOUND", "SOU_TRN", "PAL_SET", "PAL_TRN", "ATRC_EN", "TEST_EN",
    "ICON_EN", "DATA_SND", "DATA_TRN", "MLT_REQ", "JUMP", "CHR_TRN", "PCT_TRN",
    "ATTR_TRN", "ATTR_SET", "MASK_EN", "OBJ_TRN", "PAL_PRI"]

proc sgb_execute(gb: GB; d: openArray[uint8]) =
  let s = gb.sgb
  let cmd = d[0] shr 3
  when defined(sgb_trace):
    var hex = ""
    for i in 0 ..< 16: hex.add(" " & toHex(d[i], 2))
    let nm = if int(cmd) < SGB_CMD_NAMES.len: SGB_CMD_NAMES[int(cmd)] else: "?"
    echo "SGB cmd $" & toHex(cmd, 2) & " " & nm & " len " & $(d[0] and 7) & hex
  if s.packets_locked: return       # ICON_EN bit 2 latched — see SgbState
  case cmd
  of 0x0E:                          # ICON_EN
    if (d[1] and 0x04) != 0: s.packets_locked = true
  of 0x00: s.sgb_cmd_pal(d, 0, 1)   # PAL01
  of 0x01: s.sgb_cmd_pal(d, 2, 3)   # PAL23
  of 0x02: s.sgb_cmd_pal(d, 0, 3)   # PAL03
  of 0x03: s.sgb_cmd_pal(d, 1, 2)   # PAL12
  of 0x04: s.sgb_cmd_attr_blk(d)
  of 0x05: s.sgb_cmd_attr_lin(d)
  of 0x06: s.sgb_cmd_attr_div(d)
  of 0x07: s.sgb_cmd_attr_chr(d)
  of 0x0A: s.sgb_cmd_pal_set(d)
  of 0x0B, 0x13, 0x14, 0x15: sgb_vram_transfer(gb, cmd, d[1])
  of 0x11:                          # MLT_REQ
    # The joypad-ID counter free-runs on P15 edges (sgb_p1_write) and is NOT
    # reset by MLT_REQ: the packet's own pulses land first and the command only
    # ANDs the counter down (SameSuite sgb/command_mlt_req). `players` is the
    # modulus, mask players-1: requests 0/1/3 give 1/2/4 players. Request 2 is
    # not a real mode (Pan Docs lists three): the counter wraps on mask 2 and
    # sticks at 0 or 2, which command_mlt_req's last groups pin.
    let req = d[1] and 3
    s.players = req + 1
    if req == 2:
      # Request 2 also advances the counter once as it lands: hardware answers
      # ((n+1) and 2) for counters 0..3 (command_mlt_req rows 16-19) where
      # request 1 answers (n and 1) with no advance.
      s.cur_player = (s.cur_player + 1) and req
    else:
      s.cur_player = s.cur_player and req
  of 0x16:                          # ATTR_SET
    s.sgb_apply_atf(int(d[1] and 0x3F))
    if (d[1] and 0x40) != 0: s.mask = 0
  of 0x17: s.mask = d[1] and 3      # MASK_EN
  else: discard                     # sound / SNES-CPU / SNES-UI commands

# ==================== the P1 pulse receiver ====================

proc sgb_p1_write*(gb: GB; val: uint8) =
  ## Pan Docs, "Command Packet Transfers": P14 and P15 both low is the reset
  ## pulse; each low pulse on P14 sends a 0 bit, on P15 a 1 bit, LSB first, 16
  ## bytes then a stop bit. Self-clocking, so no timing model.
  ##
  ## The bit is taken on the RELEASE back to both-high, from whichever line is
  ## low then, and only if that line went low FROM both-high (`pending`):
  ## cpp/sgb-ext-test's SendPacket20To10/10To20 read the line still low at
  ## release, SendPacketShortStart (no $30 after the reset) loses its first
  ## bit, and SendPacketAvoid30 (never both-high) receives nothing.
  let s = gb.sgb
  let cur = (val shr 4) and 3       # bit0 = P14 level, bit1 = P15 level
  let prev = s.prev_lines
  s.prev_lines = cur
  if cur == prev: return
  if cur == 0:
    # Reset pulse: restarts the bit counter and abandons any bit in flight
    # (cpp/sgb-ext-test SendPacket10To00, SendPacket20To00).
    s.receiving = true
    s.pending = false
    s.bit_count = 0
    for i in 0 ..< 16: s.packet[i] = 0
    return
  # MLT_REQ player rotation (Pan Docs: "The next joypad is automatically
  # selected when P15 goes from LOW (0) to HIGH (1)"); bit 1 of `cur` is P15.
  # Not suppressed while a packet is clocked in: the packet's own 1 bits are
  # P15 pulses and hardware counts every one (SameSuite sgb/command_mlt_req,
  # sgb/command_mlt_req_1_incrementing). In one-player mode the mask is 0 and
  # the ID stays 0xF.
  if (prev and 2) == 0 and (cur and 2) != 0:
    s.cur_player = (s.cur_player + 1) and (s.players - 1)
  if prev == 3: s.pending = true    # a line just left both-high: bit incoming
  if cur != 3: return               # still low, and `prev` will name which line
  if not s.pending: return          # a release with no pulse behind it
  s.pending = false
  if not s.receiving: return
  if s.bit_count >= 128:
    # The stop bit. Whatever it is, the packet is over.
    s.receiving = false
    return
  if prev == 1:                     # P15 was the line held low -> a 1 bit
    s.packet[s.bit_count shr 3] = s.packet[s.bit_count shr 3] or
                                  (1'u8 shl (s.bit_count and 7))
  inc s.bit_count
  if s.bit_count < 128: return
  # Packet complete.
  if s.pkt_index == 0:
    s.pkt_total = int(s.packet[0] and 7)
    if s.pkt_total == 0:            # length 0 is not a valid header
      s.receiving = false
      return
  if s.pkt_index < 7:
    for i in 0 ..< 16: s.group[s.pkt_index * 16 + i] = s.packet[i]
  inc s.pkt_index
  if s.pkt_index >= s.pkt_total:
    sgb_execute(gb, s.group)
    s.pkt_index = 0
    s.pkt_total = 0

# ==================== per-frame ====================

proc sgb_frame_end*(gb: GB) =
  ## Runs at the frame boundary, after the PPU has pushed a frame.
  let s = gb.sgb
  when defined(sgb_trace):
    if s.trace_watch > 0:
      dec s.trace_watch
      var nz = 0
      for i in 0 ..< 4096:
        if gb.ppu.vram[0][i] != 0: inc nz
      echo "    +frame: vram0 4K nonzero = ", nz, " LCDC=", toHex(gb.ppu.lcd_control, 2)
  if s.border_dirty:
    s.sgb_render_border()
    s.border_dirty = false
  case s.mask
  of 0:
    # Not masked: remember this picture so a later MASK_EN 1 can freeze it.
    copyMem(addr s.frozen[0], addr gb.ppu.framebuffer[0], s.frozen.len * 2)
  of 1:
    copyMem(addr gb.ppu.framebuffer[0], addr s.frozen[0], s.frozen.len * 2)
  of 2:
    for i in 0 ..< gb.ppu.framebuffer.len: gb.ppu.framebuffer[i] = 0
  else:
    let c = s.pal[0]
    for i in 0 ..< gb.ppu.framebuffer.len: gb.ppu.framebuffer[i] = c

proc sgb_active*(gb: GB): bool {.inline.} =
  ## Gates the border surface, the output size and the UI.
  gb != nil and gb.sgb != nil

proc sgb_has_border*(gb: GB): bool {.inline.} =
  ## As above, and a border has been transferred: a cart that only sends
  ## palettes must not get a 256x224 window with an empty margin.
  gb != nil and gb.sgb != nil and gb.sgb.border_valid

proc sgb_border_gen*(gb: GB): uint32 {.inline.} = gb.sgb.border_gen

proc sgb_border_ptr*(gb: GB): ptr uint16 =
  ## The 256x224 border image, BGR555 with bit 15 = opaque. Colour index 0 is
  ## transparent and shows the Game Boy window (or the backdrop) through it.
  addr gb.sgb.border[0]

proc sgb_backdrop*(gb: GB): uint16 {.inline.} =
  ## SGB colour 0, shared by all four screen palettes. What shows wherever the
  ## border is transparent and the Game Boy window is not.
  gb.sgb.pal[0]

proc sgb_screen_color*(ppu: GbPpu; x: int; shade: uint8): uint16 {.inline.} =
  ## The colour an SGB puts on the screen for a pixel at column `x` of line
  ## `ppu.ly` whose GB shade (already through BGP/OBP) is `shade`. Used by the
  ## scanline renderer; the FIFO renderer open-codes the same expression.
  let cell = (int(ppu.ly) shr 3) * SGB_ATTR_W + (x shr 3)
  ppu.sgb_pal[int(ppu.sgb_attr[cell]) * 4 + int(shade)]

proc sgb_attach*(gb: GB) =
  ## Wire the renderer's two SGB hooks: the flat 4x4 palette table and the
  ## 20x18 attribute map. Both stay nil on a non-SGB machine, and the
  ## renderers test `sgb_attr` for nil per emitted pixel.
  if gb.sgb == nil: return
  gb.ppu.sgb_pal = cast[ptr UncheckedArray[uint16]](addr gb.sgb.pal[0])
  gb.ppu.sgb_attr = cast[ptr UncheckedArray[uint8]](addr gb.sgb.attr[0])
