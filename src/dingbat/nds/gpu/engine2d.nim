## One of the DS's two 2D engines: A (0x4000000, can show 3D, capture and
## VRAM/FIFO display) and B (0x4001000, BG/OBJ only). The engine is the GBA
## PPU grown: same text/affine BGs, OBJs, windows and blending, plus
## extended BG modes, extended palettes, bigger VRAM offsets and master
## brightness (docs/nds/spec.md, "2D engines").
##
## SKELETON: display modes 0 (off), 2 (VRAM display) and the backdrop of
## mode 1 work. BG/OBJ rendering is the 2D subsystem's job (render_bg_line,
## render_obj_line are the seams).

import ../mem/vram

type
  EngineId* = enum engA, engB

  Engine2D* = ref object
    id*: EngineId
    vram* {.cursor.}: Vram
    palette*: ptr UncheckedArray[uint16]   ## this engine's 512 BG+OBJ entries
    oam*: ptr UncheckedArray[uint16]       ## this engine's 1 KB of OAM
    # registers (offsets from the engine base)
    dispcnt*: uint32          ## +0x00
    bgcnt*: array[4, uint16]  ## +0x08
    bghofs*, bgvofs*: array[4, uint16]  ## +0x10..
    bgpa*, bgpb*, bgpc*, bgpd*: array[2, int16]  ## +0x20 / +0x30 (BG2, BG3)
    bgx*, bgy*: array[2, int32]           ## reference points (28-bit)
    bgx_latch*, bgy_latch*: array[2, int32]
    winh*, winv*: array[2, uint16]        ## +0x40..0x47
    winin*, winout*: uint16               ## +0x48 / +0x4A
    mosaic*: uint16                       ## +0x4C
    bldcnt*, bldalpha*, bldy*: uint16     ## +0x50 / +0x52 / +0x54
    master_bright*: uint16                ## +0x6C
    line*: array[256, uint16]             ## the composited line, BGR555
    enabled*: bool                        ## POWCNT1 bit 1 (A) / 9 (B)

const
  BG_LAYER_MASK = 0x1F00'u32

proc new_engine2d*(id: EngineId; vram: Vram; palette, oam: pointer): Engine2D =
  Engine2D(id: id, vram: vram,
           palette: cast[ptr UncheckedArray[uint16]](palette),
           oam: cast[ptr UncheckedArray[uint16]](oam))

proc display_mode*(e: Engine2D): uint32 = (e.dispcnt shr 16) and 3
proc bg_mode*(e: Engine2D): uint32 = e.dispcnt and 7

# ---------------------------------------------------------------------------
# Register file (offset = address - engine base, 0x00..0x6F)

proc read_reg*(e: Engine2D; offset: uint32): uint32 =
  ## Aligned 32-bit read; the bus shifts out narrower reads.
  case offset
  of 0x00: e.dispcnt
  of 0x08: uint32(e.bgcnt[0]) or (uint32(e.bgcnt[1]) shl 16)
  of 0x0C: uint32(e.bgcnt[2]) or (uint32(e.bgcnt[3]) shl 16)
  of 0x48: uint32(e.winin) or (uint32(e.winout) shl 16)
  of 0x50: uint32(e.bldcnt) or (uint32(e.bldalpha) shl 16)
  of 0x6C: uint32(e.master_bright)
  else: 0

proc merge16(old: uint16; v, mask: uint32; shift: int): uint16 {.inline.} =
  let m = uint16((mask shr shift) and 0xFFFF)
  (old and not m) or (uint16((v shr shift) and 0xFFFF) and m)

proc write_reg*(e: Engine2D; offset: uint32; v, mask: uint32) =
  ## Aligned 32-bit write; `mask` selects the bytes actually written.
  case offset
  of 0x00:
    var m = mask
    if e.id == engB: m = m and 0xC0B1_FFF7'u32  # no 3D, capture, VRAM display bits
    e.dispcnt = (e.dispcnt and not m) or (v and m)
  of 0x08:
    e.bgcnt[0] = merge16(e.bgcnt[0], v, mask, 0)
    e.bgcnt[1] = merge16(e.bgcnt[1], v, mask, 16)
  of 0x0C:
    e.bgcnt[2] = merge16(e.bgcnt[2], v, mask, 0)
    e.bgcnt[3] = merge16(e.bgcnt[3], v, mask, 16)
  of 0x10, 0x14, 0x18, 0x1C:
    let i = int((offset - 0x10) shr 2)
    e.bghofs[i] = merge16(e.bghofs[i], v, mask, 0) and 0x1FF
    e.bgvofs[i] = merge16(e.bgvofs[i], v, mask, 16) and 0x1FF
  of 0x20, 0x30:
    let i = int((offset - 0x20) shr 4)
    e.bgpa[i] = cast[int16](merge16(cast[uint16](e.bgpa[i]), v, mask, 0))
    e.bgpb[i] = cast[int16](merge16(cast[uint16](e.bgpb[i]), v, mask, 16))
  of 0x24, 0x34:
    let i = int((offset - 0x24) shr 4)
    e.bgpc[i] = cast[int16](merge16(cast[uint16](e.bgpc[i]), v, mask, 0))
    e.bgpd[i] = cast[int16](merge16(cast[uint16](e.bgpd[i]), v, mask, 16))
  of 0x28, 0x2C, 0x38, 0x3C:
    let i = int((offset - 0x28) shr 4)
    let isy = (offset and 4) != 0
    var cur = cast[uint32](if isy: e.bgy[i] else: e.bgx[i])
    cur = (cur and not mask) or (v and mask)
    let val = cast[int32](cur shl 4) shr 4   # 28-bit signed
    if isy: e.bgy[i] = val; e.bgy_latch[i] = val
    else: e.bgx[i] = val; e.bgx_latch[i] = val
  of 0x40:
    e.winh[0] = merge16(e.winh[0], v, mask, 0)
    e.winh[1] = merge16(e.winh[1], v, mask, 16)
  of 0x44:
    e.winv[0] = merge16(e.winv[0], v, mask, 0)
    e.winv[1] = merge16(e.winv[1], v, mask, 16)
  of 0x48:
    e.winin = merge16(e.winin, v, mask, 0) and 0x3F3F
    e.winout = merge16(e.winout, v, mask, 16) and 0x3F3F
  of 0x4C: e.mosaic = merge16(e.mosaic, v, mask, 0)
  of 0x50:
    e.bldcnt = merge16(e.bldcnt, v, mask, 0) and 0x3FFF
    e.bldalpha = merge16(e.bldalpha, v, mask, 16) and 0x1F1F
  of 0x54: e.bldy = merge16(e.bldy, v, mask, 0) and 0x1F
  of 0x6C: e.master_bright = merge16(e.master_bright, v, mask, 0) and 0xC01F
  else: discard

# ---------------------------------------------------------------------------
# Rendering

proc apply_master_brightness(e: Engine2D) =
  let mode = e.master_bright shr 14
  let factor = min(16'u32, uint32(e.master_bright and 0x1F))
  if mode == 0 or mode == 3 or factor == 0: return
  for c in e.line.mitems:
    var r = uint32(c and 0x1F)
    var g = uint32((c shr 5) and 0x1F)
    var b = uint32((c shr 10) and 0x1F)
    if mode == 1:
      r += ((31 - r) * factor) shr 4
      g += ((31 - g) * factor) shr 4
      b += ((31 - b) * factor) shr 4
    else:
      r -= (r * factor) shr 4
      g -= (g * factor) shr 4
      b -= (b * factor) shr 4
    c = uint16(r or (g shl 5) or (b shl 10))

proc render_bg_line*(e: Engine2D; y: int) =
  ## SEAM (2D subsystem): text/affine/extended BGs, OBJs, windows, blending
  ## composited over the backdrop into e.line. Engine A's BG0 may be the 3D
  ## layer (DISPCNT bit 3).
  let backdrop = e.palette[0] and 0x7FFF
  for x in 0 ..< 256: e.line[x] = backdrop
  if (e.dispcnt and BG_LAYER_MASK) == 0: return
  # TODO(2d): BG layers and OBJs

proc render_line*(e: Engine2D; y: int) =
  ## One visible line into e.line. Called at H-blank start of lines 0-191.
  if not e.enabled:
    for x in 0 ..< 256: e.line[x] = 0
    return
  case e.display_mode
  of 0:
    for x in 0 ..< 256: e.line[x] = 0x7FFF   # display off: white
  of 1:
    if (e.dispcnt and 0x80) != 0:            # forced blank
      for x in 0 ..< 256: e.line[x] = 0x7FFF
    else:
      e.render_bg_line(y)
  of 2:
    # VRAM display (engine A only): a bank in LCDC mode, 256x192 BGR555
    let bank = VramBank((e.dispcnt shr 18) and 3)
    let src = e.vram.bank_ptr(bank)
    let base = y * 512
    for x in 0 ..< 256:
      let i = base + x * 2
      e.line[x] = (uint16(src[i]) or (uint16(src[i + 1]) shl 8)) and 0x7FFF
  else:
    # TODO(2d): main memory display FIFO (DMA-fed, 0x4000068)
    for x in 0 ..< 256: e.line[x] = 0
  e.apply_master_brightness()
