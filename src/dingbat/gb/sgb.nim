# Super Game Boy (SGB) — command-packet receiver, screen colorization, border
# (included by gb.nim)
#
# PROTOTYPE. Everything here is gated behind `gb.sgb != nil`, which is only
# non-nil when the cart header unlocks SGB functions (0x0146 = 0x03 and
# 0x014B = 0x33 — Pan Docs, "Unlocking and Detecting SGB Functions") and the
# machine is not running in CGB mode. The two modes are mutually exclusive on
# real hardware: an SGB has no CGB, and a CGB ignores SGB packets.
#
# Sources: Pan Docs "SGB Functions" chapter (Command Packet Transfers, VRAM
# Transfers, Color Palettes, Palette/Attribute/Border/System commands). No
# emulator source was consulted for the decode.
#
# What is modelled and what is not:
#   * modelled: the P1 pulse receiver, PAL01/23/03/12, PAL_SET, PAL_TRN,
#     ATTR_BLK/LIN/DIV/CHR, ATTR_TRN, ATTR_SET, MASK_EN, CHR_TRN, PCT_TRN,
#     MLT_REQ's player count.
#   * not modelled: SOUND/SOU_TRN (the SNES APU), OBJ_TRN (SNES sprites),
#     DATA_SND/DATA_TRN/JUMP (SNES CPU), ATRC_EN/TEST_EN/ICON_EN/PAL_PRI
#     (SNES-side UI). All are accepted and dropped, which is what a GB program
#     sees anyway — none of them feed anything back to the Game Boy.
#   * the SGB's 2.4% faster master clock is NOT modelled: dingbat runs the GB
#     at handheld speed. See docs/research_sgb.md.

const SGB_ATTR_W* = 20
const SGB_ATTR_H* = 18
const SGB_BORDER_W* = 256
const SGB_BORDER_H* = 224

# Bit 15 of a BGR555 word is unused by the GB/SGB colour format, so the border
# image carries "this pixel is opaque" there. SNES colour 0 is transparent and
# shows the Game Boy window (or the backdrop) through it.
const SGB_OPAQUE* = 0x8000'u16

proc sgb_unlocked*(rom: seq[uint8]): bool =
  ## Pan Docs: SGB functions are unlocked only when the header carries
  ## SGB flag 0x03 AND old licensee code 0x33. Either one alone leaves the
  ## cart a plain monochrome game.
  rom.len > 0x14C and rom[0x0146] == 0x03'u8 and rom[0x014B] == 0x33'u8

proc new_sgb_state*(): SgbState =
  # prev_lines starts at 3 -- both select lines idle HIGH. The boot handoff
  # leaves P1 with neither group selected (memory.nim's skip_boot; Pan Docs
  # has the SGB reading 0xFF there), and starting at 0 instead would swallow
  # the very first reset pulse a game sends, losing its first packet.
  result = SgbState(players: 1, prev_lines: 3)
  # Power-on palettes: the SGB system ROM installs a default four-colour set
  # before handing the screen over. Until a game sends PAL*, every attribute
  # cell uses the same greenish DMG ramp dingbat already uses, so a cart that
  # unlocks SGB but never sends a palette looks exactly like it does today.
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
  ## Pan Docs: "Color 0 of each of the eight palettes is transparent, causing
  ## the backdrop color to be displayed instead. The backdrop color is
  ## typically defined by the most recently color being assigned to Color 0
  ## (regardless of the palette number)." So one colour 0 is shared.
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
  s.border_valid = true

# ==================== VRAM transfers ====================

proc sgb_read_transfer(gb: GB; dst: var array[4096, uint8]) =
  ## Reconstruct the 4 KiB a real SGB would read out of the Game Boy's video
  ## signal.
  ##
  ## Pan Docs, "VRAM Transfers", says the data is "normally" at 0x8000-0x8FFF
  ## and that the SNES "will automatically re-produce the same ordering of bits
  ## and bytes". Reading 0x8000-0x8FFF directly is therefore the obvious HLE --
  ## and it is WRONG on real carts. What the SNES actually gets is the picture:
  ## the preconditions Pan Docs lists ("BG Map must display unsigned characters
  ## $00-$FF on the screen; $00..$13 in first line, $14..$27 in next line",
  ## display enabled, no scroll, BGP = $E4) are what make that picture equal to
  ## the bytes at 0x8000. A cart that leaves LCDC.4 clear -- signed tile
  ## addressing, so character $00 is at 0x9000, not 0x8000 -- satisfies every
  ## one of those preconditions and still displays completely different memory.
  ## Pokemon Blue does exactly this: all three of its transfers run with
  ## LCDC = 0xE3, and a raw 0x8000 read returns mostly zeroes.
  ##
  ## So this walks the display the way the PPU would: for each character $00
  ## to $FF, find the screen cell it occupies, read the BG map there (honouring
  ## SCX/SCY and LCDC.3), and fetch that tile's 16 bytes through LCDC.4's
  ## addressing mode. With the documented preconditions met this is identical
  ## to a flat 0x8000 read, and it is right when they are not.
  ##
  ## Objects are ignored. Pan Docs requires that they not overlap the
  ## background during a transfer, and honouring them would mean running a
  ## whole extra frame of compositing for no gain.
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
  ## Timing: hardware starts reading at the beginning of the NEXT frame and
  ## finishes five frames later. dingbat reads at the instant the command
  ## packet completes. Pan Docs requires the data to be on screen *before* the
  ## packet is sent, so the earlier read sees the same picture -- verified on
  ## Pokemon Blue, whose display is byte-stable across all five frames after
  ## each of its three transfers -- and it is strictly safer for the "two
  ## CHR_TRNs around one VRAM rewrite" pattern, where a deferred read would
  ## see the second block for both.
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
  # Packet log for bringing a real cart up. Compiled out of every normal build.
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
  case cmd
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
    s.players = case d[1] and 3
      of 0: 1'u8
      of 1: 2'u8
      else: 4'u8
    s.cur_player = 0
  of 0x16:                          # ATTR_SET
    s.sgb_apply_atf(int(d[1] and 0x3F))
    if (d[1] and 0x40) != 0: s.mask = 0
  of 0x17: s.mask = d[1] and 3      # MASK_EN
  else: discard                     # sound / SNES-CPU / SNES-UI commands

# ==================== the P1 pulse receiver ====================

proc sgb_p1_write*(gb: GB; val: uint8) =
  ## Pan Docs, "Command Packet Transfers". P14 and P15 both low is the reset
  ## pulse that starts a packet; afterwards each low pulse on P14 sends a 0
  ## bit and each low pulse on P15 sends a 1 bit, LSB of each byte first,
  ## 16 bytes then a 0 stop bit. Bits are taken on the falling edge, so no
  ## timing model is needed — the encoding is self-clocking.
  let s = gb.sgb
  let cur = (val shr 4) and 3       # bit0 = P14 level, bit1 = P15 level
  let prev = s.prev_lines
  s.prev_lines = cur
  if cur == prev: return
  if cur == 0:
    # Reset pulse. Restarts the bit counter; a reset mid-group also restarts
    # the group, which is what a game does after a failed transfer.
    s.receiving = true
    s.bit_count = 0
    for i in 0 ..< 16: s.packet[i] = 0
    return
  # MLT_REQ player rotation. Pan Docs: "The next joypad is automatically
  # selected when P15 goes from LOW (0) to HIGH (1)". bit 1 of `cur` is P15.
  # Suppressed for the duration of a packet, whose 1 bits are P15 pulses --
  # otherwise a transfer would spin the counter and the read straight after
  # MLT_REQ would answer for the wrong player. (Hardware spins it too, which
  # is why sgb_execute re-zeroes it; this just keeps the answer stable.)
  if not s.receiving and (prev and 2) == 0 and (cur and 2) != 0 and s.players > 1:
    s.cur_player = (s.cur_player + 1) and (s.players - 1)
  if cur == 3 or prev != 3 or not s.receiving: return
  if s.bit_count >= 128:
    # The stop bit. Whatever it is, the packet is over.
    s.receiving = false
    return
  if cur == 1:                      # P15 low -> a 1 bit
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

proc sgb_screen_color*(ppu: GbPpu; x: int; shade: uint8): uint16 {.inline.} =
  ## The colour an SGB puts on the screen for a pixel at column `x` of line
  ## `ppu.ly` whose GB shade (already through BGP/OBP) is `shade`. Used by the
  ## scanline renderer; the FIFO renderer open-codes the same expression.
  let cell = (int(ppu.ly) shr 3) * SGB_ATTR_W + (x shr 3)
  ppu.sgb_pal[int(ppu.sgb_attr[cell]) * 4 + int(shade)]

proc sgb_attach*(gb: GB) =
  ## Wire the renderer's two SGB hooks. `sgb_pal` is the flat 4x4 palette
  ## table and `sgb_attr` the 20x18 attribute map; both are nil for every
  ## non-SGB machine, and the renderers test `sgb_attr` for nil once per
  ## emitted pixel (see fifo_ppu's emit).
  if gb.sgb == nil: return
  gb.ppu.sgb_pal = cast[ptr UncheckedArray[uint16]](addr gb.sgb.pal[0])
  gb.ppu.sgb_attr = cast[ptr UncheckedArray[uint8]](addr gb.sgb.attr[0])
