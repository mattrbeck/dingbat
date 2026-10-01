## The 3D engine: geometry engine fed through GXFIFO 0x4000400 / command
## ports 0x4000440-0x40005CC, GXSTAT 0x4000600, DISP3DCNT 0x4000060, matrix
## stacks, polygon/vertex RAM, then a scanline rasteriser whose output is
## engine A's BG0. STUB: registers are swallowed, GXSTAT reports an empty,
## idle FIFO, and the 3D layer is transparent. Shape for the 3D subsystem:
##
##   write_fifo / write_port  -> command queue (geometry.nim)
##   swap_buffers at V-blank  -> polygon list handed to the renderer
##   render_line(y)           -> 256 RGBA pixels + depth for BG0
##
## docs/nds/gbatek-notes.md section 5 has the command table.

type
  Gpu3d* = ref object
    disp3dcnt*: uint32
    gxstat*: uint32
    swap_pending*: bool
    line*: array[256, uint32]   ## 0 alpha = transparent

proc new_gpu3d*(): Gpu3d = Gpu3d(gxstat: 0x0600_0000'u32)  # FIFO empty + less than half

proc read_reg*(g: Gpu3d; offset: uint32): uint32 =
  case offset
  of 0x060: g.disp3dcnt
  of 0x600: g.gxstat
  else: 0

proc write_reg*(g: Gpu3d; offset: uint32; v, mask: uint32) =
  case offset
  of 0x060: g.disp3dcnt = (g.disp3dcnt and not mask) or (v and mask)
  of 0x540: g.swap_pending = true   # SWAP_BUFFERS
  of 0x600:
    let m = mask and 0xC000_0000'u32
    g.gxstat = (g.gxstat and not m) or (v and m)
  else: discard   # TODO(3d): GXFIFO + command ports

proc on_vblank*(g: Gpu3d) =
  g.swap_pending = false

proc render_line*(g: Gpu3d; y: int) =
  for p in g.line.mitems: p = 0
