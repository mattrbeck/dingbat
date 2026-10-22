## The 3D scene handed to a host-GPU renderer (docs/nds/gpu3d.md): the
## swapped Polygon/Vertex lists in the order the rasteriser draws them,
## each vertex with its sub-dot screen position, the render registers, and
## the texture and palette slots as flat images. Display only, like HD
## (docs/nds/hd3d.md): nothing here is machine state.
##
## Scene words (little-endian uint32):
##   0  magic "G3D1"           1  polygon count       2  vertex count
##   3  DISP3DCNT              4  swap parameter      5  bit 0: positions exact
##   6  scene generation       7  texture generation (bumped with the images)
##   8..47  render registers 0x4000320-0x40003BF (render.nim `regs`)
##   then per polygon, in drawing order, 4 words:
##     attr, TEXIMAGE_PARAM, PLTT_BASE,
##     first | count << 16 | translucent << 24 | left chain forward << 25
##   then per vertex 8 words:
##     x, y (1/HD_SUB dots), Z-buffer depth, w, r | g << 8 | b << 16 (5-bit),
##     s, t (12.4), 0

import std/algorithm
import ../mem/vram
import geometry, render

const
  GPU_MAGIC* = 0x31443347'u32          ## "G3D1"
  GPU_HEADER* = 48
  GPU_POLY_WORDS* = 4
  GPU_VERT_WORDS* = 8
  TEX_IMAGE_SIZE* = 0x80000            ## texture slots 0-3
  PAL_IMAGE_SIZE* = 0x18000            ## palette slots 0-5

proc export_scene*(dst: var seq[uint32]; polys: openArray[Polygon]; verts: openArray[Vertex];
                   hpos: openArray[array[2, int32]]; disp3dcnt, swap_param: uint32;
                   regs: array[40, uint32]; gen, tex_ver: uint32) =
  let exact = hpos.len == verts.len
  dst.setLen(GPU_HEADER + polys.len * GPU_POLY_WORDS + verts.len * GPU_VERT_WORDS)
  dst[0] = GPU_MAGIC
  dst[1] = uint32(polys.len)
  dst[2] = uint32(verts.len)
  dst[3] = disp3dcnt
  dst[4] = swap_param
  dst[5] = (if exact: 1'u32 else: 0'u32)
  dst[6] = gen
  dst[7] = tex_ver
  for i in 0 ..< 40: dst[8 + i] = regs[i]
  # the rasteriser's order (render.nim render_frame_body): opaque polygons
  # by bottom row, top row, submission; then translucent ones the same way,
  # or as submitted when SWAP_BUFFERS bit 0 asked for manual order
  template key(i: int): int64 =
    ((int64(polys[i].ymax) + 0x400) shl 40) or ((int64(polys[i].ymin) + 0x400) shl 20) or int64(i)
  var order = newSeqOfCap[int64](polys.len)
  for i in 0 ..< polys.len:
    if not polys[i].translucent: order.add key(i)
  let n_opaque = order.len
  let manual = (swap_param and 1) != 0
  for i in 0 ..< polys.len:
    if polys[i].translucent: order.add (if manual: int64(i) else: key(i))
  order.toOpenArray(0, n_opaque - 1).sort()
  if not manual and order.len > n_opaque: order.toOpenArray(n_opaque, order.len - 1).sort()
  var o = GPU_HEADER
  for k in order:
    let p = polys[int(k and 0xFFFFF)]
    dst[o] = p.attr
    dst[o + 1] = p.tex
    dst[o + 2] = p.pltt
    let fwd = facing(verts, int(p.first), int(p.count)) >= 0
    dst[o + 3] = uint32(p.first) or (uint32(p.count) shl 16) or
                 (if p.translucent: 1'u32 shl 24 else: 0) or (if fwd: 1'u32 shl 25 else: 0)
    o += GPU_POLY_WORDS
  for i in 0 ..< verts.len:
    let v = verts[i]
    if exact:
      dst[o] = cast[uint32](hpos[i][0])
      dst[o + 1] = cast[uint32](hpos[i][1])
    else:
      # lists drawn before positions were kept: the middle of each dot
      dst[o] = cast[uint32](v.sx * HD_SUB + HD_SUB div 2)
      dst[o + 1] = cast[uint32](v.sy * HD_SUB + HD_SUB div 2)
    dst[o + 2] = cast[uint32](v.z24)
    dst[o + 3] = cast[uint32](v.w)
    dst[o + 4] = uint32(v.r) or (uint32(v.g) shl 8) or (uint32(v.b) shl 16)
    dst[o + 5] = cast[uint32](v.s)
    dst[o + 6] = cast[uint32](v.t)
    dst[o + 7] = 0
    o += GPU_VERT_WORDS

proc slot_images*(vram: Vram; tex, pal: var seq[uint8]) =
  ## The texture slots (512 KB) and palette slots (96 KB) as the renderer
  ## reads them (render.nim page_ptr): each 16 KB page from the bank mapped
  ## there, the OR of several, or zeros.
  tex.setLen(TEX_IMAGE_SIZE)
  pal.setLen(PAL_IMAGE_SIZE)
  proc fill(vram: Vram; reg: VramRegion; page: int; dst: ptr UncheckedArray[uint8]) =
    zeroMem(dst, 0x4000)
    let mask = vram.page_banks(reg, page)
    for b in VramBank:
      if (mask and (1'u16 shl ord(b))) != 0:
        let src = vram.bank_ptr(b)
        let base = (page * 0x4000) and (BANK_SIZE[b] - 1)
        if (mask and (mask - 1)) == 0:
          copyMem(dst, addr src[base], 0x4000)
        else:
          for i in 0 ..< 0x4000: dst[i] = dst[i] or src[base + i]
  for p in 0..31:
    fill(vram, vrTexture, p, cast[ptr UncheckedArray[uint8]](addr tex[p * 0x4000]))
  for p in 0..5:
    fill(vram, vrTexPal, p, cast[ptr UncheckedArray[uint8]](addr pal[p * 0x4000]))
