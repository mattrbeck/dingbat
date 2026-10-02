## One of the DS's two 2D engines: A (0x4000000, can show 3D, capture and
## VRAM/FIFO display) and B (0x4001000, BG/OBJ only). The engine is the GBA
## PPU grown: same text/affine BGs, OBJs, windows and blending, plus
## extended BG modes, extended palettes, bigger VRAM offsets and master
## brightness (docs/nds/spec.md, "2D engines"; docs/nds/gbatek-notes.md
## section 4).
##
## A line is drawn whole at H-blank: OBJs first (they feed the OBJ window),
## then the window mask, then each enabled BG into its own colour line, then
## one compositing pass that finds the top two layers per pixel and applies
## the colour effect. Every layer line holds BGR555 with bit 15 set where the
## layer is opaque, so palette lookups (standard or extended) happen once,
## in the BG/OBJ pass. VRAM is read through mem/vram.nim's region views.
##
## The algorithms follow the GBA PPU (src/dingbat/gba/ppu.nim, AGB-measured)
## where the hardware is shared: text-BG tile walk and screen-block layout,
## affine stepping and the reference-point latch, vertical mosaic,
## window latches, layer order, and the effect rules including the forced
## alpha of semi-transparent OBJs. DS changes on top: OBJ-vs-OBJ order is the
## plain 9-bit (priority, index) key (no GBA priority bug), OBJs wrap
## vertically, X is 0..255 wide, and the 1D/bitmap OBJ mappings.

import ../mem/vram
import ../gpu3d/gpu3d

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

const
  MMEM_FIFO_WORDS* = 16   ## DISP_MMEM_FIFO depth (Assumed: 4 requests of 4 words)

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
    bgx*, bgy*: array[2, int32]           ## internal reference points
    bgx_latch*, bgy_latch*: array[2, int32]  ## the BGxX/BGxY registers (28-bit)
    winh*, winv*: array[2, uint16]        ## +0x40..0x47 (X2/Y2 low, X1/Y1 high)
    winin*, winout*: uint16               ## +0x48 / +0x4A
    mosaic*: uint16                       ## +0x4C
    bldcnt*, bldalpha*, bldy*: uint16     ## +0x50 / +0x52 / +0x54
    dispcapcnt*: uint32                   ## +0x64 (engine A)
    master_bright*: uint16                ## +0x6C
    line*: array[256, uint16]             ## the displayed line, BGR555
    gfx*: array[256, uint16]              ## the BG/OBJ/3D composite (capture source A)
    enabled*: bool                        ## POWCNT1 bit 1 (A) / 9 (B)
    line3d*: ptr array[256, uint32]       ## engine A: the 3D line (nil = none)
    # line latches
    win_inside*: array[2, bool]
    mos_bgx, mos_bgy: array[2, int32]     ## affine refs latched on a mosaic block's first line
    # main-memory display FIFO (DISP_MMEM_FIFO 0x4000068): pixels in from
    # the CPU or DMA mode 4, 256 out per visible line into mmem_line for
    # display mode 3 and capture source B (gpu.nim drives the line)
    mmem_fifo: array[MMEM_FIFO_WORDS * 2, uint16]
    mmem_rd, mmem_n: int                  ## ring read index, pixels held
    mmem_last: uint16                     ## repeated while the FIFO is dry
    mmem_line*: array[256, uint16]
    # per-line scratch
    bgpix: array[4, array[256, uint16]]   ## bit 15 = opaque
    objpix: array[256, uint16]
    objprio: array[256, uint8]            ## 4 = no OBJ pixel
    objattr: array[256, uint8]            ## OBJ_* flags
    winmask: array[256, uint8]            ## bits 0-3 BG, 4 OBJ, 5 effects
    line_semi: bool                       ## any blending OBJ pixel on this line
    line_objwin: bool
    # line reuse (`render_line`): what each visible line was drawn from last
    # time, and the line it gave; none of it is machine state (not saved)
    lc_on*: bool                          ## reuse enabled (the machine sets it)
    mem_gen*: uint64                      ## bumped by the bus for every change to
                                          ## this engine's palette or OAM half
    touch: Touch                          ## the VRAM blocks the line being drawn read
    lc_valid: array[192, bool]
    lc_key: array[192, LineKey]
    lc_touch: array[192, Touch]           ## the VRAM blocks each line read...
    lc_vsum: array[192, uint64]           ## ...and their change count then
    lc_line: array[192, array[256, uint16]]
    lc_3d: seq[array[256, uint32]]        ## engine A: the 3D line each was drawn with
    lc_reused*: int                       ## lines reused so far (a statistic)

  LineKey = object
    ## Everything a visible line's pixels depend on besides the VRAM it
    ## reads (`lc_touch`) and the 3D line: palette and OAM contents and the
    ## VRAM mapping (counted by `gen`), the registers, the window and affine
    ## latches as the line starts.
    gen: uint64
    dispcnt: uint32
    bgcnt, bghofs, bgvofs: array[4, uint16]
    bgpa, bgpb, bgpc, bgpd: array[2, int16]
    bgx, bgy, mos_bgx, mos_bgy: array[2, int32]
    winh: array[2, uint16]
    winin, winout, mosaic, bldcnt, bldalpha, bldy, master_bright: uint16
    win_inside: array[2, bool]
    uses3d: bool

const
  BG_LAYER_MASK = 0x1F00'u32
  OBJ_SEMI = 0x10'u8        ## OBJ mode 1: forces alpha with BLDALPHA
  OBJ_BITMAP = 0x20'u8      ## bitmap OBJ: forces alpha with its own (low nibble = alpha)
  OBJ_WINDOW = 0x40'u8      ## an OBJ-window pixel
  LAYER_OBJ = 4
  LAYER_BD = 5
  OPAQUE = 0x8000'u16

  # OBJ sizes [shape][size] = (w, h)
  OBJ_SIZES: array[3, array[4, (int, int)]] = [
    [(8, 8), (16, 16), (32, 32), (64, 64)],
    [(16, 8), (32, 8), (32, 16), (64, 32)],
    [(8, 16), (8, 32), (16, 32), (32, 64)]]

  # BG kinds per mode for BG2/BG3 (BG0/1 are text, or 3D for A's BG0)
  bkNone = 0
  bkText = 1
  bkAffine = 2
  bkExt = 3
  bkLarge = 4
  BG23_KIND: array[8, (int, int)] = [
    (bkText, bkText), (bkText, bkAffine), (bkAffine, bkAffine), (bkText, bkExt),
    (bkAffine, bkExt), (bkExt, bkExt), (bkLarge, bkNone), (bkNone, bkNone)]

proc new_engine2d*(id: EngineId; vram: Vram; palette, oam: pointer): Engine2D =
  Engine2D(id: id, vram: vram,
           palette: cast[ptr UncheckedArray[uint16]](palette),
           oam: cast[ptr UncheckedArray[uint16]](oam))

proc display_mode*(e: Engine2D): uint32 = (e.dispcnt shr 16) and 3
proc bg_mode*(e: Engine2D): uint32 = e.dispcnt and 7
proc bg0_is_3d*(e: Engine2D): bool {.inline.} =
  e.id == engA and ((e.dispcnt and 8) != 0 or e.bg_mode == 6)

template bg_region(e: Engine2D): VramRegion = (if e.id == engA: vrABg else: vrBBg)
template obj_region(e: Engine2D): VramRegion = (if e.id == engA: vrAObj else: vrBObj)
template bg_ext_region(e: Engine2D): VramRegion =
  (if e.id == engA: vrABgExtPal else: vrBBgExtPal)
template obj_ext_region(e: Engine2D): VramRegion =
  (if e.id == engA: vrAObjExtPal else: vrBObjExtPal)

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
  of 0x64: (if e.id == engA: e.dispcapcnt else: 0)
  of 0x6C: uint32(e.master_bright)
  else: 0

proc merge16(old: uint16; v, mask: uint32; shift: int): uint16 {.inline.} =
  let m = uint16((mask shr shift) and 0xFFFF)
  (old and not m) or (uint16((v shr shift) and 0xFFFF) and m)

proc mmem_push(e: Engine2D; v: uint32) =
  ## A word into DISP_MMEM_FIFO: two pixels, dropped when the FIFO is full
  ## (Assumed: GBATEK gives the 4-word request size, not the overflow rule).
  if e.mmem_n > MMEM_FIFO_WORDS * 2 - 2: return
  for p in [uint16(v and 0xFFFF), uint16(v shr 16)]:
    e.mmem_fifo[(e.mmem_rd + e.mmem_n) mod (MMEM_FIFO_WORDS * 2)] = p
    inc e.mmem_n

proc mmem_room*(e: Engine2D): bool {.inline.} =
  ## Room for a 4-word (8-pixel) request (GBATEK: "The FIFO can receive 4
  ## words (8 pixels) at a time").
  e.mmem_n <= MMEM_FIFO_WORDS * 2 - 8

proc mmem_take*(e: Engine2D; x0: int) =
  ## The display takes 8 pixels for mmem_line[x0 ..< x0 + 8]; a dry FIFO
  ## repeats the last pixel taken (Assumed; the reference runs show a
  ## repeated pixel too: disp_mmem phase E).
  for x in x0 ..< x0 + 8:
    if e.mmem_n > 0:
      e.mmem_last = e.mmem_fifo[e.mmem_rd]
      e.mmem_rd = (e.mmem_rd + 1) mod (MMEM_FIFO_WORDS * 2)
      dec e.mmem_n
    e.mmem_line[x] = e.mmem_last

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
    # A write reloads the internal reference point (as on the GBA)
    let i = int((offset - 0x28) shr 4)
    let isy = (offset and 4) != 0
    var cur = cast[uint32](if isy: e.bgy_latch[i] else: e.bgx_latch[i])
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
  of 0x64:
    if e.id == engA:
      e.dispcapcnt = (e.dispcapcnt and not mask) or (v and mask and 0xEF3F_1F1F'u32)
  of 0x68:
    if e.id == engA and mask == 0xFFFF_FFFF'u32: e.mmem_push(v)
  of 0x6C: e.master_bright = merge16(e.master_bright, v, mask, 0) and 0xC01F
  else: discard

# The renderer below indexes its fixed 256-entry line buffers and VRAM
# page views with in-range values only; runtime checks off as in the GBA bus.
{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

# ---------------------------------------------------------------------------
# Line latches (every line, V-blank included)

proc start_line*(e: Engine2D; vcount: int) =
  ## Line start: the window Y latches compare the low 8 bits of VCOUNT, so a
  ## Y1 of 0..6 already opens the window in lines 256..262 (GBATEK "DS
  ## Video"); at V-blank the affine reference points reload.
  let v = uint16(vcount and 0xFF)
  for i in 0..1:
    if v == (e.winv[i] shr 8): e.win_inside[i] = true
    if v == (e.winv[i] and 0xFF): e.win_inside[i] = false
  if vcount == 192:
    e.bgx = e.bgx_latch
    e.bgy = e.bgy_latch

# ---------------------------------------------------------------------------
# Colour helpers (5-bit channels)

template ch_r(c: uint32): uint32 = c and 0x1F
template ch_g(c: uint32): uint32 = (c shr 5) and 0x1F
template ch_b(c: uint32): uint32 = (c shr 10) and 0x1F

proc blend_alpha(a, b: uint16; eva, evb: uint32): uint16 {.inline.} =
  ## (a*EVA + b*EVB) >> 4 per channel, saturated (one shift after the sum,
  ## as measured on the AGB; the DS shares the colour-effect unit).
  let a32 = uint32(a)
  let b32 = uint32(b)
  let r = min(31'u32, (ch_r(a32) * eva + ch_r(b32) * evb) shr 4)
  let g = min(31'u32, (ch_g(a32) * eva + ch_g(b32) * evb) shr 4)
  let bl = min(31'u32, (ch_b(a32) * eva + ch_b(b32) * evb) shr 4)
  uint16(r or (g shl 5) or (bl shl 10))

proc brighten(a: uint16; evy: uint32): uint16 {.inline.} =
  let a32 = uint32(a)
  let r = ch_r(a32)
  let g = ch_g(a32)
  let b = ch_b(a32)
  uint16((r + (((31 - r) * evy) shr 4)) or ((g + (((31 - g) * evy) shr 4)) shl 5) or
         ((b + (((31 - b) * evy) shr 4)) shl 10))

proc darken(a: uint16; evy: uint32): uint16 {.inline.} =
  let a32 = uint32(a)
  let k = 16 - evy
  uint16(((ch_r(a32) * k) shr 4) or (((ch_g(a32) * k) shr 4) shl 5) or
         (((ch_b(a32) * k) shr 4) shl 10))

# 3D layer pixels (gpu3d.line): one uint32 per pixel, red/green/blue in
# bytes 0/1/2 as 6-bit values (0..63) and alpha in byte 3 as 0..31; alpha 0
# is transparent (gpu3d.to_bgr555 / alpha5).

proc blend_3d(p: uint32; below: uint16): uint16 {.inline.} =
  ## 3D over a 2nd-target layer: the 3D pixel's own alpha weights it,
  ## (c3d*(a+1) + c2d*(31-a)) / 32 on 6-bit channels, 2D widened to 6 bits.
  let a = alpha5(p)
  let b = uint32(below)
  template mix(c3, c2: uint32): uint32 =
    (((c3 * (a + 1) + (c2 * 2) * (31 - a)) shr 5) shr 1) and 0x1F
  let r = mix(p and 0x3F, ch_r(b))
  let g = mix((p shr 8) and 0x3F, ch_g(b))
  let bl = mix((p shr 16) and 0x3F, ch_b(b))
  uint16(r or (g shl 5) or (bl shl 10))

# ---------------------------------------------------------------------------
# BG layers

template mosaic_bg_h(e: Engine2D): int = int(e.mosaic and 0xF) + 1
template mosaic_bg_v(e: Engine2D): int = int((e.mosaic shr 4) and 0xF) + 1
template mosaic_obj_h(e: Engine2D): int = int((e.mosaic shr 8) and 0xF) + 1
template mosaic_obj_v(e: Engine2D): int = int((e.mosaic shr 12) and 0xF) + 1

proc apply_mosaic_h(e: Engine2D; bg: int) =
  let h = e.mosaic_bg_h
  if h > 1 and (e.bgcnt[bg] and 0x40) != 0:
    for x in 0 ..< 256:
      e.bgpix[bg][x] = e.bgpix[bg][x - x mod h]

proc ext_slot(e: Engine2D; bg: int): int {.inline.} =
  ## BG ext palette slot: BG0..3 use 0..3; BG0/BG1 move to 2/3 with BGxCNT.13.
  result = bg
  if bg < 2 and (e.bgcnt[bg] and 0x2000) != 0: result += 2

proc render_text(e: Engine2D; bg, y: int) =
  let cnt = e.bgcnt[bg]
  let w = e.vram.view(e.bg_region, addr e.touch)
  var char_base = int((cnt shr 2) and 0xF) * 0x4000
  var screen_base = int((cnt shr 8) and 0x1F) * 0x800
  if e.id == engA:
    char_base += int((e.dispcnt shr 24) and 7) * 0x10000
    screen_base += int((e.dispcnt shr 27) and 7) * 0x10000
  let size = int(cnt shr 14)
  let wmask = if (size and 1) != 0: 511 else: 255
  let hmask = if (size and 2) != 0: 511 else: 255
  var vy = y
  if (cnt and 0x40) != 0: vy -= vy mod e.mosaic_bg_v
  let yy = (vy + int(e.bgvofs[bg])) and hmask
  let ty = yy shr 3
  let row = yy and 7
  # 32x32-entry screen blocks: the second column of blocks follows the
  # first, and a 512-tall map's lower half follows both (GBATEK "BG Map")
  var row_base = screen_base + (ty and 31) * 64
  if ty >= 32: row_base += (if size == 3: 0x1000 else: 0x800)
  let is8 = (cnt and 0x80) != 0
  let ext = is8 and (e.dispcnt and 0x4000_0000'u32) != 0
  let xw = e.vram.view(e.bg_ext_region, addr e.touch)
  let ext_base = e.ext_slot(bg) * 0x2000
  let pal = e.palette
  let dst = cast[ptr UncheckedArray[uint16]](addr e.bgpix[bg][0])
  let hofs = int(e.bghofs[bg])
  var x = 0
  while x < 256:
    let xx = (x + hofs) and wmask
    let tx = xx shr 3
    let se = w.rd16(row_base + (tx and 31) * 2 + (if tx >= 32: 0x800 else: 0))
    let tile = int(se and 0x3FF)
    let fx = if (se and 0x400) != 0: 7 else: 0
    let r = if (se and 0x800) != 0: 7 - row else: row
    let x0 = xx and 7
    let span = min(8 - x0, 256 - x)
    if is8:
      var row8: array[8, uint8]
      w.fetch8(char_base + tile * 64 + r * 8, row8)
      if cast[uint64](row8) == 0:
        # a transparent tile row, common on UI layers
        for k in 0 ..< span: dst[x + k] = 0
      elif ext:
        let pbase = ext_base + int(se shr 12) * 512
        for k in 0 ..< span:
          let idx = int(row8[(x0 + k) xor fx])
          dst[x + k] = if idx == 0: 0'u16 else: xw.rd16(pbase + idx * 2) or OPAQUE
      else:
        for k in 0 ..< span:
          let idx = int(row8[(x0 + k) xor fx])
          dst[x + k] = if idx == 0: 0'u16 else: pal[idx] or OPAQUE
    else:
      let bits = w.rd32(char_base + tile * 32 + r * 4)
      let bank = int(se shr 12) * 16
      if bits == 0:
        for k in 0 ..< span: dst[x + k] = 0
      elif fx == 0 and span == 8:
        # whole unflipped tile row: no per-dot flip or span arithmetic
        for k in 0 ..< 8:
          let idx = int((bits shr (uint32(k) * 4)) and 0xF)
          dst[x + k] = if idx == 0: 0'u16 else: pal[bank + idx] or OPAQUE
      else:
        for k in 0 ..< span:
          let idx = int((bits shr (uint32((x0 + k) xor fx) * 4)) and 0xF)
          dst[x + k] = if idx == 0: 0'u16 else: pal[bank + idx] or OPAQUE
    x += span
  e.apply_mosaic_h(bg)

proc render_3d(e: Engine2D) =
  ## BG0 as the 3D layer: BG0HOFS scrolls it across 512 pixels (256 of
  ## image, 256 transparent); no vertical scroll, no mosaic.
  let dst = cast[ptr UncheckedArray[uint16]](addr e.bgpix[0][0])
  if e.line3d == nil:
    for x in 0 ..< 256: dst[x] = 0
    return
  let hofs = int(e.bghofs[0])
  for x in 0 ..< 256:
    let sx = (x + hofs) and 511
    if sx >= 256:
      dst[x] = 0
      continue
    let p = e.line3d[sx]
    dst[x] = if alpha5(p) == 0: 0'u16 else: to_bgr555(p) or OPAQUE

template affine_walk(e: Engine2D; bg, y, width, height: int; sample: untyped) =
  ## Step the internal reference point across the line (PA/PC per pixel)
  ## and fill bgpix[bg] with `sample`, which sees `px`/`py` inside the
  ## width x height plane. Outside it the pixel is transparent unless
  ## BGxCNT.13 wraps (sizes are powers of two). With vertical mosaic the
  ## point latched on the block's first line is reused, as on the GBA.
  block:
    let i = bg - 2
    var rx = e.bgx[i]
    var ry = e.bgy[i]
    if (e.bgcnt[bg] and 0x40) != 0:
      if y mod e.mosaic_bg_v == 0:
        e.mos_bgx[i] = rx
        e.mos_bgy[i] = ry
      else:
        rx = e.mos_bgx[i]
        ry = e.mos_bgy[i]
    let pa = int32(e.bgpa[i])
    let pc = int32(e.bgpc[i])
    let wrap = (e.bgcnt[bg] and 0x2000) != 0
    let dst = cast[ptr UncheckedArray[uint16]](addr e.bgpix[bg][0])
    for x in 0 ..< 256:
      var px {.inject.} = int(rx shr 8)
      var py {.inject.} = int(ry shr 8)
      rx += pa
      ry += pc
      if wrap:
        px = px and (width - 1)
        py = py and (height - 1)
      elif px < 0 or px >= width or py < 0 or py >= height:
        dst[x] = 0
        continue
      dst[x] = sample
    e.apply_mosaic_h(bg)

proc render_affine(e: Engine2D; bg, y: int) =
  ## GBA-style affine BG: 8-bit map entries, 8bpp tiles, standard palette.
  let cnt = e.bgcnt[bg]
  let w = e.vram.view(e.bg_region, addr e.touch)
  var char_base = int((cnt shr 2) and 0xF) * 0x4000
  var screen_base = int((cnt shr 8) and 0x1F) * 0x800
  if e.id == engA:
    char_base += int((e.dispcnt shr 24) and 7) * 0x10000
    screen_base += int((e.dispcnt shr 27) and 7) * 0x10000
  let size = 128 shl (cnt shr 14)
  let tiles = size shr 3
  let pal = e.palette
  affine_walk(e, bg, y, size, size):
    let tile = int(w.rd8(screen_base + (py shr 3) * tiles + (px shr 3)))
    let idx = int(w.rd8(char_base + tile * 64 + (py and 7) * 8 + (px and 7)))
    if idx == 0: 0'u16 else: pal[idx] or OPAQUE

proc render_ext(e: Engine2D; bg, y: int) =
  ## Extended BG (BGxCNT.7 / .2): 16-bit-entry tiled affine, 256-colour
  ## bitmap or direct-colour bitmap.
  let cnt = e.bgcnt[bg]
  let w = e.vram.view(e.bg_region, addr e.touch)
  let pal = e.palette
  if (cnt and 0x80) == 0:
    var char_base = int((cnt shr 2) and 0xF) * 0x4000
    var screen_base = int((cnt shr 8) and 0x1F) * 0x800
    if e.id == engA:
      char_base += int((e.dispcnt shr 24) and 7) * 0x10000
      screen_base += int((e.dispcnt shr 27) and 7) * 0x10000
    let size = 128 shl (cnt shr 14)
    let tiles = size shr 3
    let ext = (e.dispcnt and 0x4000_0000'u32) != 0
    let xw = e.vram.view(e.bg_ext_region, addr e.touch)
    let ext_base = bg * 0x2000
    affine_walk(e, bg, y, size, size):
      let se = w.rd16(screen_base + ((py shr 3) * tiles + (px shr 3)) * 2)
      let tx = if (se and 0x400) != 0: 7 - (px and 7) else: px and 7
      let ty = if (se and 0x800) != 0: 7 - (py and 7) else: py and 7
      let idx = int(w.rd8(char_base + int(se and 0x3FF) * 64 + ty * 8 + tx))
      if idx == 0: 0'u16
      elif ext: xw.rd16(ext_base + (int(se shr 12) * 256 + idx) * 2) or OPAQUE
      else: pal[idx] or OPAQUE
  else:
    const SIZES = [(128, 128), (256, 256), (512, 256), (512, 512)]
    let (bw, bh) = SIZES[cnt shr 14]
    let base = int((cnt shr 8) and 0x1F) * 0x4000
    if (cnt and 4) != 0:
      affine_walk(e, bg, y, bw, bh):
        let c = w.rd16(base + (py * bw + px) * 2)
        if (c and 0x8000) != 0: c else: 0'u16
    else:
      affine_walk(e, bg, y, bw, bh):
        let idx = int(w.rd8(base + py * bw + px))
        if idx == 0: 0'u16 else: pal[idx] or OPAQUE

proc render_large(e: Engine2D; y: int) =
  ## Mode 6 BG2: one 256-colour bitmap over all 512K of BG VRAM.
  let cnt = e.bgcnt[2]
  let w = e.vram.view(e.bg_region, addr e.touch)
  let pal = e.palette
  let (bw, bh) = if (cnt and 0x4000) != 0: (1024, 512) else: (512, 1024)
  affine_walk(e, 2, y, bw, bh):
    let idx = int(w.rd8(py * bw + px))
    if idx == 0: 0'u16 else: pal[idx] or OPAQUE

# ---------------------------------------------------------------------------
# OBJs

proc render_objs(e: Engine2D; y: int) =
  for x in 0 ..< 256:
    e.objprio[x] = 4
    e.objattr[x] = 0
  e.line_semi = false
  e.line_objwin = false
  if (e.dispcnt and 0x1000) == 0: return
  let w = e.vram.view(e.obj_region, addr e.touch)
  let xw = e.vram.view(e.obj_ext_region, addr e.touch)
  let oam = e.oam
  let pal = cast[ptr UncheckedArray[uint16]](addr e.palette[256])
  let dc = e.dispcnt
  let map1d = (dc and 0x10) != 0
  let tile_shift = if map1d: 5 + int((dc shr 20) and 3) else: 5
  let ext = (dc and 0x8000_0000'u32) != 0
  let bmp_1d = (dc and 0x40) != 0
  let bmp_wide = (dc and 0x20) != 0
  let bmp_bound = if e.id == engA and (dc and 0x40_0000) != 0: 256 else: 128
  let mos_h = e.mosaic_obj_h
  let mos_v = e.mosaic_obj_v
  for i in 0 ..< 128:
    let a0 = oam[i * 4]
    let a1 = oam[i * 4 + 1]
    let a2 = oam[i * 4 + 2]
    let affine = (a0 and 0x100) != 0
    if not affine and (a0 and 0x200) != 0: continue   # disabled
    let shape = int(a0 shr 14)
    if shape == 3: continue
    let mode = int((a0 shr 10) and 3)
    let (ow, oh) = OBJ_SIZES[shape][a1 shr 14]
    var bw = ow
    var bh = oh
    if affine and (a0 and 0x200) != 0:      # double-size box
      bw *= 2
      bh *= 2
    # Y wraps mod 256 (a sprite near the bottom also shows at the top)
    let line_in = (y - int(a0 and 0xFF)) and 0xFF
    if line_in >= bh: continue
    var sx = int(a1 and 0x1FF)
    if sx >= 256: sx -= 512
    if sx + bw <= 0: continue
    let mosaic = (a0 and 0x1000) != 0
    var iy = line_in
    if mosaic:
      let ym = y - y mod mos_v
      iy = (ym - int(a0 and 0xFF)) and 0xFF
    var pa = 0x100
    var pb = 0
    var pc = 0
    var pd = 0x100
    if affine:
      let g = int((a1 shr 9) and 0x1F) * 16
      pa = int(cast[int16](oam[g + 3]))
      pb = int(cast[int16](oam[g + 7]))
      pc = int(cast[int16](oam[g + 11]))
      pd = int(cast[int16](oam[g + 15]))
    let flip_x = not affine and (a1 and 0x1000) != 0
    let flip_y = not affine and (a1 and 0x2000) != 0
    let prio = uint8((a2 shr 10) and 3)
    let tile = int(a2 and 0x3FF)
    let is8 = (a0 and 0x2000) != 0
    let palnum = int(a2 shr 12)
    # bitmap OBJ addressing; alpha 0 hides it
    var bmp_base, bmp_stride: int
    if mode == 3:
      if palnum == 0: continue
      if bmp_1d:
        if bmp_wide: continue                 # reserved combination
        bmp_base = tile * bmp_bound
        bmp_stride = ow
      else:
        let mask_x = if bmp_wide: 0x1F else: 0x0F
        bmp_base = (tile and mask_x) * 0x10 + (tile and not mask_x) * 0x80
        bmp_stride = if bmp_wide: 256 else: 128
    let flag =
      case mode
      of 1: OBJ_SEMI
      of 3: OBJ_BITMAP or uint8(palnum)
      else: 0'u8
    let cy = iy - bh div 2
    let x0 = max(0, sx)
    let x1 = min(256, sx + bw)
    for col in x0 ..< x1:
      # an earlier OBJ already holds this pixel at this priority or better
      if mode != 2 and prio >= e.objprio[col]: continue
      var ix = col - sx
      if mosaic and mos_h > 1: ix = (col - col mod mos_h) - sx
      var tx, ty: int
      if affine:
        let cx = ix - bw div 2
        tx = ((pa * cx + pb * cy) shr 8) + ow div 2
        ty = ((pc * cx + pd * cy) shr 8) + oh div 2
        if tx < 0 or tx >= ow or ty < 0 or ty >= oh: continue
      else:
        tx = if flip_x: ow - 1 - ix else: ix
        ty = if flip_y: oh - 1 - iy else: iy
        if ty < 0 or ty >= oh or tx < 0 or tx >= ow: continue
      var color: uint16
      if mode == 3:
        let c = w.rd16(bmp_base + (ty * bmp_stride + tx) * 2)
        if (c and 0x8000) == 0: continue
        color = c
      else:
        var idx: int
        if is8:
          var a: int
          if map1d:
            a = (tile shl tile_shift) + ((ty shr 3) * (ow shr 3) + (tx shr 3)) * 64
          else:
            a = (tile and not 1) * 32 + (ty shr 3) * 0x400 + (tx shr 3) * 64
          idx = int(w.rd8(a + (ty and 7) * 8 + (tx and 7)))
          if idx == 0: continue
          color = if ext: xw.rd16((palnum * 256 + idx) * 2) else: pal[idx]
        else:
          var a: int
          if map1d:
            a = (tile shl tile_shift) + ((ty shr 3) * (ow shr 3) + (tx shr 3)) * 32
          else:
            a = tile * 32 + (ty shr 3) * 0x400 + (tx shr 3) * 32
          let b = w.rd8(a + (ty and 7) * 4 + ((tx and 7) shr 1))
          idx = int((b shr (uint8(tx and 1) * 4)) and 0xF)
          if idx == 0: continue
          color = pal[palnum * 16 + idx]
      if mode == 2:
        e.objattr[col] = e.objattr[col] or OBJ_WINDOW
        e.line_objwin = true
      elif prio < e.objprio[col]:
        # OAM order with a strict compare: the lower index wins ties
        e.objprio[col] = prio
        e.objpix[col] = color and 0x7FFF
        e.objattr[col] = (e.objattr[col] and OBJ_WINDOW) or flag
        if flag != 0: e.line_semi = true

# ---------------------------------------------------------------------------
# Windows

proc fill_window(e: Engine2D; winh: uint16; bits: uint8) =
  ## [X1, X2), wrapping round the right edge when X1 > X2; X1 = X2 is empty.
  let x1 = int(winh shr 8)
  let x2 = int(winh and 0xFF)
  if x1 <= x2:
    for x in x1 ..< x2: e.winmask[x] = bits
  else:
    for x in 0 ..< x2: e.winmask[x] = bits
    for x in x1 ..< 256: e.winmask[x] = bits

proc compute_windows(e: Engine2D): bool =
  ## Fill winmask; false (mask untouched) when no window is enabled.
  let dc = e.dispcnt
  if (dc and 0xE000) == 0: return false
  result = true
  let outside = uint8(e.winout and 0x3F)
  for x in 0 ..< 256: e.winmask[x] = outside
  if (dc and 0x8000) != 0 and e.line_objwin:
    let ob = uint8((e.winout shr 8) and 0x3F)
    for x in 0 ..< 256:
      if (e.objattr[x] and OBJ_WINDOW) != 0: e.winmask[x] = ob
  if (dc and 0x4000) != 0 and e.win_inside[1]:
    e.fill_window(e.winh[1], uint8((e.winin shr 8) and 0x3F))
  if (dc and 0x2000) != 0 and e.win_inside[0]:
    e.fill_window(e.winh[0], uint8(e.winin and 0x3F))

# ---------------------------------------------------------------------------
# Compositing

proc composite(e: Engine2D; bgs: uint32; windows: bool) =
  ## Top two layers per pixel in priority order (OBJ before BGs of equal
  ## priority, lower BG number first), then the colour effect. The loop is
  ## instantiated for "windows on the line" x "an effect can apply", so the
  ## common no-window, no-effect line is a plain top-layer search.
  var walk: array[4, int]
  var walk_prio: array[4, int]
  var n = 0
  for p in 0..3:
    for bg in 0..3:
      if (bgs and (1'u32 shl bg)) != 0 and int(e.bgcnt[bg] and 3) == p:
        walk[n] = bg
        walk_prio[n] = p
        inc n
  let backdrop = e.palette[0] and 0x7FFF
  let bld = uint32(e.bldcnt)
  let mode = (bld shr 6) and 3
  let eva = min(16'u32, uint32(e.bldalpha and 0x1F))
  let evb = min(16'u32, uint32((e.bldalpha shr 8) and 0x1F))
  let evy = min(16'u32, uint32(e.bldy and 0x1F))
  let is3d = e.bg0_is_3d and (bgs and 1) != 0
  let want2 = mode == 1 or e.line_semi or is3d
  let obj_on = (e.dispcnt and 0x1000) != 0
  let effects = (mode != 0 and (bld and 0x3F) != 0) or e.line_semi or is3d

  template pixel_loop(WIN, FX: static bool) {.dirty.} =
    for x in 0 ..< 256:
      let m = when WIN: uint32(e.winmask[x]) else: 0x3F'u32
      let need2 = when FX: want2 and (m and 0x20) != 0 else: false
      var found = 0
      var l0, l1: int
      var c0, c1: uint16
      template take(layer: int; color: uint16) {.dirty.} =
        if found == 0:
          l0 = layer
          c0 = color
        else:
          l1 = layer
          c1 = color
        inc found
        if found == 2 or not need2: break search
      let op = int(e.objprio[x])
      var obj_pending = obj_on and op < 4 and (when WIN: (m and 0x10) != 0 else: true)
      block search:
        for i in 0 ..< n:
          if obj_pending and op <= walk_prio[i]:
            obj_pending = false
            take(LAYER_OBJ, e.objpix[x])
          let bg = walk[i]
          if (when WIN: (m and (1'u32 shl bg)) != 0 else: true):
            let c = e.bgpix[bg][x]
            if (c and OPAQUE) != 0: take(bg, c and 0x7FFF)
        if obj_pending: take(LAYER_OBJ, e.objpix[x])
        take(LAYER_BD, backdrop)
      var c = c0
      when FX:
        if (m and 0x20) != 0:
          let bot_second = found == 2 and (bld and (0x100'u32 shl l1)) != 0
          let attr = e.objattr[x]
          if l0 == LAYER_OBJ and (attr and (OBJ_SEMI or OBJ_BITMAP)) != 0 and bot_second:
            if (attr and OBJ_BITMAP) != 0:
              let a = uint32(attr and 0xF)
              c = blend_alpha(c, c1, a + 1, 15 - a)
            else:
              c = blend_alpha(c, c1, eva, evb)
          elif l0 == 0 and is3d and bot_second:
            c = blend_3d(e.line3d[(x + int(e.bghofs[0])) and 511], c1)
          elif (bld and (1'u32 shl l0)) != 0:
            case mode
            of 1:
              if bot_second: c = blend_alpha(c, c1, eva, evb)
            of 2: c = brighten(c, evy)
            of 3: c = darken(c, evy)
            else: discard
      e.gfx[x] = c

  if windows:
    if effects: pixel_loop(true, true) else: pixel_loop(true, false)
  else:
    if effects: pixel_loop(false, true) else: pixel_loop(false, false)

proc shown_bgs(e: Engine2D): uint32 =
  ## The BGs this line draws: DISPCNT's enables, less those the mode lacks.
  let mode = int(e.bg_mode)
  result = (e.dispcnt and BG_LAYER_MASK) shr 8
  let (k2, k3) = BG23_KIND[mode]
  if mode == 7 or (mode == 6 and e.id == engB): result = 0
  if mode == 6: result = result and 0x5         # BG0 (3D) and BG2 only
  if k2 == bkNone: result = result and not 4'u32
  if k3 == bkNone: result = result and not 8'u32

proc render_gfx*(e: Engine2D; y: int) =
  ## The graphics pipeline into e.gfx (display mode 1, and capture source A).
  if (e.dispcnt and 0x80) != 0:            # forced blank
    for x in 0 ..< 256: e.gfx[x] = 0x7FFF
    return
  let mode = int(e.bg_mode)
  let bgs = e.shown_bgs()
  let (k2, k3) = BG23_KIND[mode]
  e.render_objs(y)
  let windows = e.compute_windows()
  if (bgs and 1) != 0:
    if e.bg0_is_3d: e.render_3d() else: e.render_text(0, y)
  if (bgs and 2) != 0: e.render_text(1, y)
  for bg in 2..3:
    if (bgs and (1'u32 shl bg)) == 0: continue
    case (if bg == 2: k2 else: k3)
    of bkText: e.render_text(bg, y)
    of bkAffine: e.render_affine(bg, y)
    of bkExt: e.render_ext(bg, y)
    of bkLarge: e.render_large(y)
    else: discard
  e.composite(bgs, windows)

proc end_line*(e: Engine2D) =
  ## After a visible line: the affine reference points step by PB/PD.
  for i in 0..1:
    e.bgx[i] += int32(e.bgpb[i])
    e.bgy[i] += int32(e.bgpd[i])

# ---------------------------------------------------------------------------
# Display output

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
  ## The graphics line straight to the display line (display mode 1).
  e.render_gfx(y)
  e.line = e.gfx

# ---------------------------------------------------------------------------
# Line reuse
#
# A graphics line (display mode 1) reads the engine's registers and line
# latches, its palette and OAM halves, the VRAM banks mapped into its BG,
# OBJ and extended-palette regions, and (engine A) the 3D line; what it
# writes that outlives the line is e.line and, with affine mosaic, the
# reference-point latch (everything else -- bgpix, objpix, the window mask
# -- is scratch, rewritten before it is read, and not saved). So a line
# whose inputs all equal those it had when last drawn comes out the same,
# and is copied instead of drawn. The bus counts every change to the
# palette or OAM half (`mem_gen`, a store of an equal value is not a
# change); vram.nim counts the changes to each 1 KB block of the banks
# (`vgen`) and the remaps, and the views mark every block the line reads
# (`touch`), so the line is redrawn only when one of those blocks changed
# (`touched_sum`); the registers and latches are compared as a key, the 3D
# line by value. Display capture, VRAM and main-memory display draw every
# line. Off without the machine (`lc_on`, the 2D unit tests poke memory
# directly) and with DINGBAT_NDS_NO_SKIP=1 (docs/nds/perf.md).

proc line_key(e: Engine2D): LineKey =
  LineKey(gen: e.mem_gen + e.vram.remap_gen, dispcnt: e.dispcnt,
          bgcnt: e.bgcnt, bghofs: e.bghofs, bgvofs: e.bgvofs,
          bgpa: e.bgpa, bgpb: e.bgpb, bgpc: e.bgpc, bgpd: e.bgpd,
          bgx: e.bgx, bgy: e.bgy, mos_bgx: e.mos_bgx, mos_bgy: e.mos_bgy,
          winh: e.winh, winin: e.winin, winout: e.winout, mosaic: e.mosaic,
          bldcnt: e.bldcnt, bldalpha: e.bldalpha, bldy: e.bldy,
          master_bright: e.master_bright, win_inside: e.win_inside,
          uses3d: e.line3d != nil)

proc latch_mosaic(e: Engine2D; y: int) =
  ## What `affine_walk` leaves behind: an affine BG with mosaic latches its
  ## reference point on a mosaic block's first line.
  let bgs = e.shown_bgs()
  let (k2, k3) = BG23_KIND[int(e.bg_mode)]
  for bg in 2..3:
    let k = if bg == 2: k2 else: k3
    if (bgs and (1'u32 shl bg)) != 0 and k in [bkAffine, bkExt, bkLarge] and
       (e.bgcnt[bg] and 0x40) != 0 and y mod e.mosaic_bg_v == 0:
      e.mos_bgx[bg - 2] = e.bgx[bg - 2]
      e.mos_bgy[bg - 2] = e.bgy[bg - 2]

proc render_line*(e: Engine2D; y: int; need_gfx = false) =
  ## One visible line into e.line. Called at H-blank start of lines 0-191.
  ## `need_gfx` renders the graphics composite into e.gfx even when the
  ## display shows something else (display capture source A).
  if not e.enabled:
    for x in 0 ..< 256: e.line[x] = 0
    return
  let dm = e.display_mode
  let cache = e.lc_on and dm == 1 and not need_gfx and y < 192
  var key: LineKey
  if cache:
    key = e.line_key()
    if e.lc_valid[y] and e.lc_key[y] == key and
       (e.line3d == nil or e.lc_3d[y] == e.line3d[]) and
       e.vram.touched_sum(e.lc_touch[y]) == e.lc_vsum[y]:
      e.latch_mosaic(y)
      e.line = e.lc_line[y]
      inc e.lc_reused
      return
  if cache:
    for w in e.touch.mitems: w = 0
  if dm == 1 or need_gfx: e.render_gfx(y)
  case dm
  of 0:
    for x in 0 ..< 256: e.line[x] = 0x7FFF   # display off: white
  of 1:
    e.line = e.gfx
  of 2:
    # VRAM display (engine A only): a bank in LCDC mode, 256x192 BGR555
    let bank = VramBank((e.dispcnt shr 18) and 3)
    let src = e.vram.bank_ptr(bank)
    let base = y * 512
    for x in 0 ..< 256:
      let i = base + x * 2
      e.line[x] = (uint16(src[i]) or (uint16(src[i + 1]) shl 8)) and 0x7FFF
  else:
    # main-memory display: the line the FIFO delivered (bit 15 unused)
    for x in 0 ..< 256: e.line[x] = e.mmem_line[x] and 0x7FFF
  e.apply_master_brightness()
  if cache and (e.touch[TOUCH_ALL shr 6] and (1'u64 shl (TOUCH_ALL and 63))) == 0:
    e.lc_valid[y] = true
    e.lc_key[y] = key
    e.lc_touch[y] = e.touch
    e.lc_vsum[y] = e.vram.touched_sum(e.touch)
    e.lc_line[y] = e.line
    if e.line3d != nil:
      if e.lc_3d.len == 0: e.lc_3d.setLen(192)
      e.lc_3d[y] = e.line3d[]
  elif y < 192:
    e.lc_valid[y] = false   # overlapping banks, capture, other display modes

{.pop.}

{.pop.}
