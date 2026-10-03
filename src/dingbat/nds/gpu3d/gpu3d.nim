## The 3D engine as the rest of the DS sees it: the GXFIFO (0x4000400,
## packed commands) and command ports (0x4000440-0x40005CC), GXSTAT
## 0x4000600 and the FIFO IRQ, RAM_COUNT and the test/matrix result
## registers, DISP3DCNT 0x4000060 and the render registers
## 0x4000320-0x40003BF. geometry.nim runs the commands, render.nim draws.
##
## Output, for engine A's BG0 (and capture): call `render_line(y)` for each
## visible line; it fills `line` with 256 pixels, each
##   bits 0-5 red, 8-13 green, 16-21 blue (6-bit), bits 24-28 alpha (0..31),
## alpha 0 = transparent (`to_bgr555` drops to 15-bit colour).
##
## Render timing (GBATEK "DS 3D Overview" / "RDLINES_COUNT"): rendering
## starts at line 214 into a 48-line cache, 48 lines ahead of the display,
## with the render registers live ("not swapped ... must be kept intact
## during rendering"). So lines 0-47 are drawn at line 214 and line y >= 48
## when the display takes line y - 48 (at its start). `due_lines` says how
## many lines are drawn by a given time; a write that changes a render
## register (DISP3DCNT, 0x4000330-0x40003BF) first finishes the lines due
## with the old value. The rasteriser itself is whole-frame: the lines come
## from a full render (`ren.color`), redone when a register has changed since
## (docs/nds/accuracy.md).
##
## Timing (docs/nds/3d-timing.md): each command takes GBATEK's cycles
## ("DS 3D Geometry Commands", 33.51 MHz units) from the moment it starts,
## which is when the engine is free and all its parameters are in; its
## effect (matrices, polygons, test results, the stack level) is applied
## at that start and GXSTAT shows it busy until the end (bit 0 for the
## tests, bit 14 for MTX_PUSH/POP, bit 27 for anything). The engine runs
## lazily: `catch_up(t)` starts every command whose start time has come,
## called before anything observes the engine. SWAP_BUFFERS holds the
## engine until V-blank (`on_vblank`), then 392 cycles. A write that finds
## PIPE + FIFO full (260 entries) sets `stall_until`, the time the next
## command leaves the FIFO; the bus holds the writer (and the ARM7) until
## then. Without a scheduler (`sched` nil, the unit tests) every command
## takes no time.
##
## For DMA mode 7 (GX FIFO, the system side): start a 112-word burst
## whenever `fifo_wants_dma` (FIFO less than half full) holds; write the
## words to 0x4000400. `wake_at` says when the FIFO next drops below half
## (or empties) so the machine can schedule that.
## For the FIFO IRQ (IF bit 21, level-triggered): `update_irq` re-raises it
## while the GXSTAT 30-31 condition holds; it runs on every FIFO change and
## should also run after an IF acknowledge.
##
## The renderer's per-line budget (RDLINES_COUNT, DISP3DCNT.12) comes from
## render.nim's line costs at each frame's render, latched at V-blank.

import std/deques
import ../mem/vram
import ../io/irq
import ../sched
import geometry, render

export geometry.Vertex, geometry.Polygon, render.Renderer

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  FifoEntry = object
    cmd: uint8
    param: uint32
    at: int64                     ## master cycle it entered the PIPE/FIFO

  Gpu3d* = ref object
    geo*: Geometry
    ren*: Renderer
    vram {.cursor.}: Vram
    irq {.cursor.}: IrqCtl
    sched* {.cursor.}: NdsScheduler   ## the clock; nil = untimed (unit tests)
    disp3dcnt*: uint32
    irq_mode: uint32              ## GXSTAT 30-31
    fifo: Deque[FifoEntry]        ## PIPE (first 4) + FIFO, oldest first
    pk_cmds: uint32               ## packed command bytes still to issue
    pk_cmd: uint8                 ## packed command taking parameters
    pk_left: int                  ## its parameter words still to come
    ex_params: array[32, uint32]
    cur_cmd: uint8                ## the command started last...
    cur_end*: int64               ## ...and when the engine is free again
    stall_until*: int64           ## a full FIFO holds its writer until then
    next_vblank*: int64           ## start of the next line 192 (set by the machine)
    swap_pending*: bool           ## SWAP_BUFFERS waiting for V-blank
    swap_req: uint32              ## its parameter
    geo_param: uint32             ## swap parameter for the buffer being filled
    ren_param: uint32             ## ...and for the buffer being drawn
    polys*: seq[Polygon]          ## the rendering side of Polygon/Vertex RAM
    verts*: seq[Vertex]
    rendered: bool
    reuse_on*: bool               ## reuse an unchanged frame (DINGBAT_NDS_NO_SKIP=1 clears it)
    reuse_ok: bool                ## the last_* fields describe what `ren` holds
    reused*: int                  ## frames reused so far (a statistic)
    last_gen: uint64              ## vram.tex_gen, DISP3DCNT, swap parameter,
    last_disp3dcnt, last_param: uint32  ## render registers and buffers the
    last_regs: array[40, uint32]  ## last real render drew
    last_polys: seq[Polygon]
    last_verts: seq[Vertex]
    last_is_cur: bool             ## polys/verts are the very lists the last render drew
                                  ## (last_polys/verts hold them only from the next swap)
    rdlines: uint32               ## RDLINES_COUNT of the last frame
    underflow_next: bool          ## the frame being shown runs out of lines
    line*: array[256, uint32]     ## 0 alpha = transparent
    render_t0*: int64             ## master cycle of the line 214 this frame's rendering started at
    done_lines*: int              ## lines 0 ..< done_lines of `frame` are drawn
    scratch_ok: bool              ## ren.color is a full render with the current registers + lists
    frame*: array[256 * 192, uint32]  ## the frame as drawn line by line (what BG0 shows)

const
  RENDER_START_LINE = 214   ## GBATEK "RDLINES_COUNT": rendering starts in scanline 214
  CACHE_LINES = 48          ## ... into a 48-line cache; output begins after line 262

proc new_gpu3d*(vram: Vram; irq: IrqCtl): Gpu3d =
  # at power-on (line 0) the first frame counts as started 49 lines ago
  Gpu3d(geo: new_geometry(), ren: new_renderer(), vram: vram, irq: irq,
        fifo: initDeque[FifoEntry](512), rdlines: 46,
        render_t0: -int64(LINES - RENDER_START_LINE) * LINE_CYCLES)

proc to_bgr555*(p: uint32): uint16 {.inline.} =
  ## A 3D pixel's colour as the 2D engines' 15-bit BGR.
  uint16(((p shr 1) and 0x1F) or (((p shr 9) and 0x1F) shl 5) or (((p shr 17) and 0x1F) shl 10))

proc alpha5*(p: uint32): uint32 {.inline.} = (p shr 24) and 31

# ---------------------------------------------------------------------------
# FIFO and command timing

const
  PIPE = 4          ## entries held in the PIPE ahead of the FIFO (GBATEK "DS 3D Geometry Commands")
  FIFO_SIZE = 256
  NEVER = high(int64)

  ## Bus cycles (33.51 MHz) per command, GBATEK "DS 3D Geometry Commands".
  ## NORMAL's 9..12 and the mode-2 extra are added in `cmd_cycles`.
  CMD_CYCLES: array[256, int16] = block:
    var c: array[256, int16]
    for (id, n) in [(0x10, 1), (0x11, 17), (0x12, 36), (0x13, 17), (0x14, 36), (0x15, 19),
                    (0x16, 34), (0x17, 30), (0x18, 35), (0x19, 31), (0x1A, 28), (0x1B, 22),
                    (0x1C, 22), (0x20, 1), (0x21, 9), (0x22, 1), (0x23, 9), (0x24, 8),
                    (0x25, 8), (0x26, 8), (0x27, 8), (0x28, 8), (0x29, 1), (0x2A, 1),
                    (0x2B, 1), (0x30, 4), (0x31, 4), (0x32, 6), (0x33, 1), (0x34, 32),
                    (0x40, 1), (0x41, 1), (0x50, 392), (0x60, 1), (0x70, 103), (0x71, 9),
                    (0x72, 5)]:
      c[id] = int16(n)
    c
  SWAP_CYCLES = 392   ## SWAP_BUFFERS after the V-blank it waited for

proc cmd_cycles(g: Gpu3d; cmd: uint8; mode: int; attr: uint32): int64 =
  ## Master cycles (2 per bus cycle) `cmd` keeps the engine busy, given the
  ## matrix mode and the polygon attributes latched by BEGIN_VTXS.
  if g.sched == nil: return 0
  var n = int64(CMD_CYCLES[cmd])
  case cmd
  of 0x18, 0x19, 0x1A, 0x1C:
    # "In MTX_MODE=2 (Simultaneous Set), MTX_MULT/TRANS take additional 30
    # cycles" (GBATEK; MTX_SCALE has no asterisk and the reference runs
    # agree it pays none: 3d_timing_cmds SCAL)
    if mode == 2: n += 30
  of 0x21:
    # NORMAL: 9..12 for 0..4 lights per GBATEK, which leaves open which
    # counts share a value; the reference runs give 9, 9, 10, 11, 12
    # (3d_timing_cmds NRM; docs/oracles.md)
    var lights = 0
    for i in 0..3:
      if (attr and (1'u32 shl i)) != 0: inc lights
    n += max(0, lights - 1)
  else: discard
  2 * n

proc now(g: Gpu3d): int64 {.inline.} =
  if g.sched == nil: 0'i64 else: g.sched.now

proc write_time(g: Gpu3d): int64 {.inline.} =
  ## When a write lands: now, or later while a burst of writes (a DMA block)
  ## is held by a full FIFO.
  max(g.now(), g.stall_until)

proc fifo_level(g: Gpu3d): int {.inline.} =
  ## FIFO entries as GXSTAT counts them: the first PIPE entries queued
  ## behind a stalled command sit in the PIPE, not the FIFO (3d_status:
  ## 40 queued behind SWAP_BUFFERS read as 36 on the reference core)
  min(FIFO_SIZE, max(0, g.fifo.len - PIPE))

proc fifo_wants_dma*(g: Gpu3d): bool {.inline.} = g.fifo_level < 128

proc fifo_irq_mode*(g: Gpu3d): uint32 {.inline.} = g.irq_mode   ## GXSTAT 30-31

proc run_command(g: Gpu3d; cmd: uint8; start: int64) =
  let geo = g.geo
  g.cur_cmd = cmd
  g.cur_end = start + g.cmd_cycles(cmd, geo.mode, geo.attr)
  if cmd == 0x50:
    # SWAP_BUFFERS: the engine halts until V-blank (its cycles count from there)
    g.swap_pending = true
    g.swap_req = g.ex_params[0] and 3
    g.cur_end = start
  else:
    geo.execute(cmd, g.ex_params.toOpenArray(0, max(0, int(CMD_PARAMS[cmd]) - 1)))

proc catch_up*(g: Gpu3d; t: int64) =
  ## Start every command whose start time is at or before `t`: the engine
  ## is free and its last parameter has arrived.
  while not g.swap_pending and g.fifo.len > 0:
    let cmd = g.fifo[0].cmd
    let n = max(1, int(CMD_PARAMS[cmd]))
    if g.fifo.len < n: return
    let start = max(g.cur_end, g.fifo[n - 1].at)
    if start > t: return
    for i in 0 ..< n: g.ex_params[i] = g.fifo.popFirst().param
    g.run_command(cmd, start)

proc wake_at*(g: Gpu3d; below: int): int64 =
  ## When the FIFO count next drops below `below`, assuming no more writes
  ## (NEVER if it is below already, or waits on a swap or an incomplete
  ## command first). Commands leave the FIFO as they start, so this walks
  ## the queue's start times.
  if g.fifo_level < below: return NEVER
  if g.swap_pending: return NEVER
  var t = g.cur_end
  var i = 0
  var left = g.fifo.len
  while i < g.fifo.len:
    let cmd = g.fifo[i].cmd
    let n = max(1, int(CMD_PARAMS[cmd]))
    if i + n > g.fifo.len: return NEVER
    let start = max(t, g.fifo[i + n - 1].at)
    left -= n
    if min(FIFO_SIZE, max(0, left - PIPE)) < below: return start
    if cmd == 0x50: return NEVER
    t = start + g.cmd_cycles(cmd, g.geo.mode, g.geo.attr)
    i += n
  NEVER

proc raise_level_irq(g: Gpu3d) {.inline.} =
  ## IF.21 if the selected condition holds now (the engine caught up).
  if g.irq == nil: return
  case g.irq_mode
  of 1: (if g.fifo_level < 128: g.irq.raise_irq(irqGxFifo))
  of 2: (if g.fifo_level == 0: g.irq.raise_irq(irqGxFifo))
  else: discard

proc update_irq*(g: Gpu3d) =
  ## IF.21 is set as long as the selected condition holds.
  if g.irq == nil or g.irq_mode == 0: return
  g.catch_up(g.now())
  g.raise_level_irq()

proc push(g: Gpu3d; cmd: uint8; param: uint32) =
  var t = g.write_time()
  g.catch_up(t)
  if g.sched != nil and g.fifo.len >= FIFO_SIZE + PIPE:
    # FIFO full: "the STR opcode gets freezed" until the next command
    # leaves the FIFO (GBATEK "Sending Commands by Ports"); behind a pending
    # swap that is V-blank + the swap's 392 cycles
    t = if g.swap_pending: max(t, g.next_vblank + 2 * SWAP_CYCLES)
        else: max(t, g.cur_end)
    g.stall_until = t
    g.catch_up(t)
  g.fifo.addLast(FifoEntry(cmd: cmd, param: param, at: t))
  g.catch_up(t)
  # update_irq, whose catch_up to now (<= t) would find nothing to start
  g.raise_level_irq()

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
  let t = g.now()
  g.catch_up(t)
  let running = t < g.cur_end
  let busy = running or g.fifo.len > 0 or g.swap_pending or g.pk_left > 0
  # bit 0 while a test runs, bit 14 while a push/pop does (GBATEK; the
  # reference runs flag MTX_STORE/RESTORE as not stack-busy too:
  # 3d_timing_cmds MID)
  let testing = running and g.cur_cmd in 0x70'u8..0x72'u8
  let stacking = running and g.cur_cmd in 0x11'u8..0x12'u8
  result = (if testing: 1'u32 else: 0) or (if geo.box_result: 2'u32 else: 0) or
           (uint32(geo.pos_sp and 31) shl 8) or (uint32(geo.proj_sp and 1) shl 13) or
           (if stacking: 0x4000'u32 else: 0) or
           (if geo.stack_error: 0x8000'u32 else: 0) or
           (uint32(g.fifo_level()) shl 16) or
           (if g.fifo_level < 128: 1'u32 shl 25 else: 0) or
           (if g.fifo_level == 0: 1'u32 shl 26 else: 0) or
           (if busy: 1'u32 shl 27 else: 0) or (g.irq_mode shl 30)

proc read_reg*(g: Gpu3d; offset: uint32): uint32 =
  let geo = g.geo
  if offset >= 0x600: g.catch_up(g.now())
  case offset
  of 0x060:
    g.catch_up(g.now())
    g.disp3dcnt or (if geo.overflow: 0x2000'u32 else: 0)
  of 0x320: g.rdlines
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

proc render_frame*(g: Gpu3d)

proc due_lines(g: Gpu3d; t: int64): int =
  ## How many lines of the frame being rendered are drawn by master cycle
  ## `t`: none before line 214, the cache's 48 from then on (Assumed: the
  ## renderer fills it at once), then line y when the display takes line
  ## y - 48. Untimed (no scheduler): all of them.
  if g.sched == nil: return 192
  if t < g.render_t0: return 0
  let first_take = g.render_t0 + int64(LINES - RENDER_START_LINE) * LINE_CYCLES
  if t < first_take: return CACHE_LINES
  min(192, CACHE_LINES + 1 + int((t - first_take) div LINE_CYCLES))

proc draw_lines(g: Gpu3d; n: int) =
  ## Lines done_lines ..< n get their pixels, from a full render with the
  ## registers as they are now (re-rendered when something changed since).
  if n <= g.done_lines: return
  if not g.scratch_ok:
    g.render_frame()
    g.scratch_ok = true
  copyMem(addr g.frame[g.done_lines * 256], addr g.ren.color[g.done_lines * 256],
          (n - g.done_lines) * 256 * sizeof(uint32))
  g.done_lines = n

proc render_reg_changing(g: Gpu3d) =
  ## A render register is about to change: the lines already due keep the
  ## old value; the rest render with the new one.
  g.draw_lines(g.due_lines(g.now()))
  g.scratch_ok = false

proc write_reg*(g: Gpu3d; offset: uint32; v, mask: uint32) =
  case offset
  of 0x060:
    # bits 12/13 are acknowledged by writing 1
    g.catch_up(g.now())
    let w = v and mask
    let nv = (g.disp3dcnt and not (mask and 0x4FFF'u32)) or (w and 0x4FFF'u32)
    if ((nv xor g.disp3dcnt) and 0x4FFF'u32) != 0: g.render_reg_changing()
    g.disp3dcnt = nv
    if (w and 0x1000) != 0: g.disp3dcnt = g.disp3dcnt and not 0x1000'u32
    if (w and 0x2000) != 0: g.geo.overflow = false
  of 0x320 .. 0x3BC:
    let i = int((offset - 0x320) shr 2)
    let nv = (g.ren.regs[i] and not mask) or (v and mask)
    if nv != g.ren.regs[i]: g.render_reg_changing()
    g.ren.regs[i] = nv
  of 0x400 .. 0x43C: g.write_gxfifo(v)
  of 0x440 .. 0x5FC:
    let cmd = uint8((offset - 0x400) shr 2)
    if CMD_PARAMS[cmd] >= 0: g.push(cmd, v)
  of 0x600:
    g.catch_up(g.now())
    let m = mask and 0xC000_0000'u32
    g.irq_mode = ((g.irq_mode shl 30) and not m or (v and m)) shr 30
    if (v and mask and 0x8000) != 0: g.geo.ack_stack_error()
    g.update_irq()
  of 0x610:
    # not through the FIFO: applies to every polygon not yet assembled,
    # queued ones included (GBATEK DISP_1DOT_DEPTH)
    g.catch_up(g.now())
    if (mask and 0xFFFF) != 0: g.geo.one_dot_depth = v and 0x7FFF
  else: discard

# ---------------------------------------------------------------------------
# Frame hooks

proc on_vblank*(g: Gpu3d) =
  ## Line 192: a pending SWAP_BUFFERS hands the geometry buffer to the
  ## renderer and the geometry engine resumes 392 cycles later on what
  ## queued behind it; the next frame renders afresh (the same buffer again
  ## if nothing swapped). The frame just shown latches its RDLINES_COUNT
  ## and underflow flag.
  let t = g.now()
  g.catch_up(t)
  if g.swap_pending:
    if g.last_is_cur:
      # the lists the last render drew become last_polys/verts (by moving
      # buffers, not copying), and their old buffers go to the geometry side
      swap(g.last_polys, g.polys)
      swap(g.last_verts, g.verts)
      g.last_is_cur = false
    swap(g.polys, g.geo.polys)
    swap(g.verts, g.geo.verts)
    g.geo.reset_ram()
    # SWAP_BUFFERS' bits apply to the commands after it
    g.ren_param = g.geo_param
    g.geo_param = g.swap_req
    g.swap_pending = false
    g.cur_end = t + (if g.sched == nil: 0'i64 else: 2 * SWAP_CYCLES)
    g.catch_up(t)
    g.update_irq()
  if g.rendered:
    g.rdlines = g.ren.rdlines
    if g.ren.underflow: g.disp3dcnt = g.disp3dcnt or 0x1000
  g.rendered = false
  # the next frame renders from line 214 on, from the lists just swapped in
  g.render_t0 = t + int64(RENDER_START_LINE - 192) * LINE_CYCLES
  g.done_lines = 0
  g.scratch_ok = false

proc render_frame*(g: Gpu3d) =
  ## The renderer reads nothing but the swapped Polygon/Vertex buffers,
  ## DISP3DCNT, the swap parameter, the render registers and the texture
  ## and palette slots, and writes its colour buffer, line costs, RDLINES
  ## and underflow flag from them alone (render.nim; its other buffers are
  ## scratch, rewritten before they are read). A frame whose inputs all
  ## equal the last rendered frame's would come out the same, so it is
  ## not drawn again: a game standing still re-submits the same scene every
  ## frame (docs/nds/perf.md). Texture contents are covered by vram.tex_gen.
  if g.reuse_ok and g.reuse_on and g.last_gen == g.vram.tex_gen and
     g.last_disp3dcnt == g.disp3dcnt and g.last_param == g.ren_param and
     g.last_regs == g.ren.regs and
     (g.last_is_cur or g.last_polys == g.polys and g.last_verts == g.verts):
    g.rendered = true
    inc g.reused
    return
  g.ren.render_frame(g.vram, g.polys, g.verts, g.disp3dcnt, g.ren_param)
  g.rendered = true
  if g.reuse_on:
    g.reuse_ok = true
    g.last_gen = g.vram.tex_gen
    g.last_disp3dcnt = g.disp3dcnt
    g.last_param = g.ren_param
    g.last_regs = g.ren.regs
    # the lists drawn stay in polys/verts until the next swap moves them
    # to last_polys/verts (on_vblank): no copy
    g.last_is_cur = true

proc render_line*(g: Gpu3d; y: int) =
  ## Display line y (or capture) takes its 3D line: everything due by now
  ## is drawn, line y at the latest.
  g.draw_lines(max(y + 1, g.due_lines(g.now())))
  copyMem(addr g.line[0], addr g.frame[y * 256], 256 * sizeof(uint32))

{.pop.}
