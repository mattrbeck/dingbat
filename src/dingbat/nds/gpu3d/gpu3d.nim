## The 3D engine as the rest of the DS sees it: the GXFIFO (0x4000400,
## packed commands) and command ports (0x4000440-0x40005CC), GXSTAT
## 0x4000600 and the FIFO IRQ, RAM_COUNT and the test/matrix result
## registers, DISP3DCNT 0x4000060 and the render registers
## 0x4000320-0x40003BF. geometry.nim runs the commands, render.nim draws.
##
## Output, for engine A's BG0 (and capture): call `render_line(y)` for each
## visible line; it fills `line` with 256 pixels, each
##   bits 0-5 red, 8-13 green, 16-21 blue (6-bit), bits 24-28 alpha (0..31),
## alpha 0 = transparent (`to_bgr555` drops to 15-bit colour). The frame is
## rendered whole, from the swapped buffers and the render registers as they
## are, on the first `render_line` after V-blank (the hardware starts at line
## 214 with a 48-line cache, so this sees the same V-blank writes).
##
## Timing model (TODO(3d) timing): commands execute the moment they reach
## the FIFO, so it is only ever occupied while SWAP_BUFFERS waits for
## V-blank. Entries queued behind a pending swap are kept even past 256
## (the hardware would stall the writing CPU instead); GXSTAT reports at
## most 256.
##
## For DMA mode 7 (GX FIFO, the system side): start a 112-word burst
## whenever `fifo_wants_dma` (FIFO less than half full) holds; write the
## words to 0x4000400.
## For the FIFO IRQ (IF bit 21, level-triggered): `update_irq` re-raises it
## while the GXSTAT 30-31 condition holds; it runs on every FIFO change and
## should also run after an IF acknowledge.

import std/deques
import ../mem/vram
import ../io/irq
import geometry, render

export geometry.Vertex, geometry.Polygon, render.Renderer

type
  FifoEntry = object
    cmd: uint8
    param: uint32

  Gpu3d* = ref object
    geo*: Geometry
    ren*: Renderer
    vram {.cursor.}: Vram
    irq {.cursor.}: IrqCtl
    disp3dcnt*: uint32
    irq_mode: uint32              ## GXSTAT 30-31
    fifo: Deque[FifoEntry]
    pk_cmds: uint32               ## packed command bytes still to issue
    pk_cmd: uint8                 ## packed command taking parameters
    pk_left: int                  ## its parameter words still to come
    ex_cmd: uint8                 ## command being gathered from entries
    ex_n: int
    ex_params: array[32, uint32]
    swap_pending*: bool           ## SWAP_BUFFERS waiting for V-blank
    swap_req: uint32              ## its parameter
    geo_param: uint32             ## swap parameter for the buffer being filled
    ren_param: uint32             ## ...and for the buffer being drawn
    polys*: seq[Polygon]          ## the rendering side of Polygon/Vertex RAM
    verts*: seq[Vertex]
    rendered: bool
    line*: array[256, uint32]     ## 0 alpha = transparent

proc new_gpu3d*(vram: Vram; irq: IrqCtl): Gpu3d =
  Gpu3d(geo: new_geometry(), ren: new_renderer(), vram: vram, irq: irq,
        fifo: initDeque[FifoEntry](512))

proc to_bgr555*(p: uint32): uint16 {.inline.} =
  ## A 3D pixel's colour as the 2D engines' 15-bit BGR.
  uint16(((p shr 1) and 0x1F) or (((p shr 9) and 0x1F) shl 5) or (((p shr 17) and 0x1F) shl 10))

proc alpha5*(p: uint32): uint32 {.inline.} = (p shr 24) and 31

# ---------------------------------------------------------------------------
# FIFO

const PIPE = 4   ## entries held in the PIPE ahead of the FIFO (GBATEK "DS 3D Geometry Commands")

proc fifo_level(g: Gpu3d): int {.inline.} =
  ## FIFO entries as GXSTAT counts them: the first PIPE entries queued
  ## behind a stalled command sit in the PIPE, not the FIFO (3d_status:
  ## 40 queued behind SWAP_BUFFERS read as 36 on the reference core)
  min(256, max(0, g.fifo.len - PIPE))

proc fifo_wants_dma*(g: Gpu3d): bool {.inline.} = g.fifo_level < 128

proc update_irq*(g: Gpu3d) =
  ## IF.21 is set as long as the selected condition holds.
  if g.irq == nil: return
  case g.irq_mode
  of 1: (if g.fifo_level < 128: g.irq.raise_irq(irqGxFifo))
  of 2: (if g.fifo_level == 0: g.irq.raise_irq(irqGxFifo))
  else: discard

proc run_command(g: Gpu3d; cmd: uint8) =
  if cmd == 0x50:
    # SWAP_BUFFERS: the engine halts until V-blank
    g.swap_pending = true
    g.swap_req = g.ex_params[0] and 3
  else:
    g.geo.execute(cmd, g.ex_params.toOpenArray(0, max(0, int(CMD_PARAMS[cmd]) - 1)))

proc feed(g: Gpu3d; e: FifoEntry) =
  ## One entry into the engine: a command runs once its parameters are in.
  if g.ex_n == 0: g.ex_cmd = e.cmd
  let n = int(CMD_PARAMS[g.ex_cmd])
  if n <= 0:
    g.run_command(g.ex_cmd)
    return
  g.ex_params[g.ex_n] = e.param
  inc g.ex_n
  if g.ex_n == n:
    g.ex_n = 0
    g.run_command(g.ex_cmd)

proc drain(g: Gpu3d) =
  while g.fifo.len > 0 and not g.swap_pending:
    g.feed(g.fifo.popFirst())

proc push(g: Gpu3d; cmd: uint8; param: uint32) =
  let e = FifoEntry(cmd: cmd, param: param)
  if g.fifo.len == 0 and not g.swap_pending: g.feed(e)
  else: g.fifo.addLast(e)
  g.update_irq()

proc next_packed(g: Gpu3d) =
  ## Issue the packed word's parameterless commands up to the next one that
  ## takes parameters (NOPs and invalid IDs take none and are dropped).
  while g.pk_cmds != 0:
    let c = uint8(g.pk_cmds and 0xFF)
    g.pk_cmds = g.pk_cmds shr 8
    let n = CMD_PARAMS[c]
    if c == 0 or n < 0: continue
    if n == 0:
      g.push(c, 0)
      continue
    g.pk_cmd = c
    g.pk_left = int(n)
    return

proc write_gxfifo(g: Gpu3d; v: uint32) =
  if g.pk_left > 0:
    g.push(g.pk_cmd, v)
    dec g.pk_left
    if g.pk_left == 0: g.next_packed()
  else:
    g.pk_cmds = v
    g.next_packed()

# ---------------------------------------------------------------------------
# Registers (offset = address - 0x4000000, aligned words with a byte mask)

proc gxstat(g: Gpu3d): uint32 =
  let geo = g.geo
  let busy = g.fifo.len > 0 or g.swap_pending or g.ex_n > 0 or g.pk_left > 0
  result = (if geo.box_result: 2'u32 else: 0) or
           (uint32(geo.pos_sp and 31) shl 8) or (uint32(geo.proj_sp and 1) shl 13) or
           (if geo.stack_error: 0x8000'u32 else: 0) or
           (uint32(g.fifo_level()) shl 16) or
           (if g.fifo_level < 128: 1'u32 shl 25 else: 0) or
           (if g.fifo_level == 0: 1'u32 shl 26 else: 0) or
           (if busy: 1'u32 shl 27 else: 0) or (g.irq_mode shl 30)

proc read_reg*(g: Gpu3d; offset: uint32): uint32 =
  let geo = g.geo
  case offset
  of 0x060: g.disp3dcnt or (if geo.overflow: 0x2000'u32 else: 0)
  of 0x320: 46            # RDLINES_COUNT: the renderer never falls behind
  of 0x600: g.gxstat()
  of 0x604: uint32(geo.polys.len) or (uint32(geo.vram_count) shl 16)
  of 0x620 .. 0x62C: cast[uint32](geo.pos_result[(offset - 0x620) shr 2])
  of 0x630:
    uint32(cast[uint16](geo.vec_result[0])) or (uint32(cast[uint16](geo.vec_result[1])) shl 16)
  of 0x634: uint32(cast[uint16](geo.vec_result[2]))
  of 0x640 .. 0x67C: cast[uint32](geo.clip[(offset - 0x640) shr 2])
  of 0x680 .. 0x6A0:
    let k = int((offset - 0x680) shr 2)
    cast[uint32](geo.vec[(k div 3) * 4 + k mod 3])
  else: 0

proc write_reg*(g: Gpu3d; offset: uint32; v, mask: uint32) =
  case offset
  of 0x060:
    # bits 12/13 are acknowledged by writing 1
    let w = v and mask
    g.disp3dcnt = (g.disp3dcnt and not (mask and 0x4FFF'u32)) or (w and 0x4FFF'u32)
    if (w and 0x2000) != 0: g.geo.overflow = false
  of 0x320 .. 0x3BC:
    let i = int((offset - 0x320) shr 2)
    g.ren.regs[i] = (g.ren.regs[i] and not mask) or (v and mask)
  of 0x400 .. 0x43C: g.write_gxfifo(v)
  of 0x440 .. 0x5FC:
    let cmd = uint8((offset - 0x400) shr 2)
    if CMD_PARAMS[cmd] >= 0: g.push(cmd, v)
  of 0x600:
    let m = mask and 0xC000_0000'u32
    g.irq_mode = ((g.irq_mode shl 30) and not m or (v and m)) shr 30
    if (v and mask and 0x8000) != 0: g.geo.ack_stack_error()
    g.update_irq()
  of 0x610:
    if (mask and 0xFFFF) != 0: g.geo.one_dot_depth = v and 0x7FFF
  else: discard

# ---------------------------------------------------------------------------
# Frame hooks

proc on_vblank*(g: Gpu3d) =
  ## Line 192: a pending SWAP_BUFFERS hands the geometry buffer to the
  ## renderer, the geometry engine resumes on what queued behind it, and
  ## the next frame renders afresh (the same buffer again if nothing swapped).
  if g.swap_pending:
    swap(g.polys, g.geo.polys)
    swap(g.verts, g.geo.verts)
    g.geo.reset_ram()
    # SWAP_BUFFERS' bits apply to the commands after it
    g.ren_param = g.geo_param
    g.geo_param = g.swap_req
    g.swap_pending = false
    g.drain()
    g.update_irq()
  g.rendered = false

proc render_frame*(g: Gpu3d) =
  g.ren.render_frame(g.vram, g.polys, g.verts, g.disp3dcnt, g.ren_param)
  g.rendered = true

proc render_line*(g: Gpu3d; y: int) =
  if not g.rendered: g.render_frame()
  for x in 0 ..< 256: g.line[x] = g.ren.color[y * 256 + x]
