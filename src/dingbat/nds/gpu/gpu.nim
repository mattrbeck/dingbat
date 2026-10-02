## Display controller: line/frame timing shared by both CPUs (each has its
## own DISPSTAT with its own VCOUNT-match setting and IRQ enables), POWCNT1,
## and the two output framebuffers. Owns both 2D engines, pulls the 3D line
## for engine A's BG0, and runs display capture (DISPCAPCNT 0x4000064).

import ../mem/vram
import ../gpu3d/gpu3d
import engine2d

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  DispStat* = object
    vcount_setting*: uint16   ## 9-bit LYC (bits 8-15 + bit 7 = bit 8)
    vblank_irq*, hblank_irq*, vcount_irq*: bool

  Gpu* = ref object
    vram*: Vram
    palette*: array[1024, uint16]     ## A BG/OBJ 0x05000000, B 0x05000400
    oam*: array[1024, uint16]         ## A 0x07000000, B 0x07000400
    engine_a*, engine_b*: Engine2D
    gpu3d* {.cursor.}: Gpu3d          ## set by the machine; nil = no 3D layer
    capturing*: bool                  ## a capture started at line 0 is running
    mmem_req*: proc (ctx: pointer): bool {.nimcall.}  ## DMA mode 4: one request, false if none ran
    mmem_ctx*: pointer                ## its machine (raw: no ref cycle)
    mmem_need: int                    ## pixels still to request this frame
    powcnt1*: uint16
    vcount*: int
    in_hblank*, in_vblank*: bool
    stat9*, stat7*: DispStat
    top*, bottom*: array[256 * 192, uint16]  ## output, BGR555
    frame_count*: int

proc new_gpu*(): Gpu =
  result = Gpu(vram: new_vram())
  result.engine_a = new_engine2d(engA, result.vram, addr result.palette[0], addr result.oam[0])
  result.engine_b = new_engine2d(engB, result.vram, addr result.palette[512], addr result.oam[512])

proc dispstat_read*(g: Gpu; s: DispStat): uint16 =
  result = (if g.in_vblank: 1'u16 else: 0) or (if g.in_hblank: 2'u16 else: 0) or
           (if g.vcount == int(s.vcount_setting): 4'u16 else: 0)
  if s.vblank_irq: result = result or 8
  if s.hblank_irq: result = result or 0x10
  if s.vcount_irq: result = result or 0x20
  result = result or ((s.vcount_setting and 0x100) shr 1) or ((s.vcount_setting and 0xFF) shl 8)

proc dispstat_write*(s: var DispStat; v: uint16; mask: uint16) =
  if (mask and 0x00FF) != 0:
    s.vblank_irq = (v and 8) != 0
    s.hblank_irq = (v and 0x10) != 0
    s.vcount_irq = (v and 0x20) != 0
    s.vcount_setting = (s.vcount_setting and 0xFF) or ((v and 0x80) shl 1)
  if (mask and 0xFF00) != 0:
    s.vcount_setting = (s.vcount_setting and 0x100) or (v shr 8)

proc write_powcnt1*(g: Gpu; v: uint16) =
  g.powcnt1 = v and 0x820F
  g.engine_a.enabled = (v and 2) != 0
  g.engine_b.enabled = (v and 0x200) != 0

proc start_line*(g: Gpu) =
  ## Line start (every line, V-blank included), after VCOUNT has advanced.
  g.engine_a.start_line(g.vcount)
  g.engine_b.start_line(g.vcount)
  if g.vcount == 0:
    g.capturing = (g.engine_a.dispcapcnt and 0x8000_0000'u32) != 0
    g.mmem_need = 256 * 192
  elif g.vcount == 192 and g.capturing:
    # "the capture enable/busy bit is then automatically cleared (in line
    # 192, regardless of the capture size)" (GBATEK)
    g.capturing = false
    g.engine_a.dispcapcnt = g.engine_a.dispcapcnt and not 0x8000_0000'u32

const CAPTURE_SIZE = [(128, 128), (256, 64), (256, 128), (256, 192)]

proc capture_line(g: Gpu; y: int) =
  ## DISPCAPCNT: source A (graphics composite or 3D alone) and source B (a
  ## VRAM bank or the main-memory FIFO), one of them or their EVA/EVB blend,
  ## written as 15-bit + alpha into an LCDC-mapped bank. Offsets wrap in
  ## the bank's 128K. Busy (bit 31) clears at line 192 (`start_line`).
  let e = g.engine_a
  let cap = e.dispcapcnt
  let (w, h) = CAPTURE_SIZE[(cap shr 20) and 3]
  if y >= h: return
  let dst_bank = VramBank((cap shr 16) and 3)
  let src = (cap shr 29) and 3
  let eva = min(16'u32, cap and 0x1F)
  let evb = min(16'u32, (cap shr 8) and 0x1F)
  let a_3d = (cap and (1'u32 shl 24)) != 0
  let b_fifo = (cap and (1'u32 shl 25)) != 0
  let dst = g.vram.bank_ptr(dst_bank)
  let write_ok = g.vram.lcdc_mapped(dst_bank)
  let wbase = int((cap shr 18) and 3) * 0x8000 + y * w * 2
  # source B: VRAM reads the DISPCNT bank; the read offset is ignored in
  # VRAM display mode, where the display already reads that bank from 0
  let rbank = g.vram.bank_ptr(VramBank((e.dispcnt shr 18) and 3))
  let roff = if e.display_mode == 2: 0 else: int((cap shr 26) and 3) * 0x8000
  let rbase = roff + y * w * 2
  let l3 = if g.gpu3d != nil: addr g.gpu3d.line else: nil
  for x in 0 ..< w:
    var ca, cb: uint16
    if src != 1:
      if a_3d:
        # "Dest_Intensity = SrcA_Intensity; Dest_Alpha = SrcA_Alpha"
        # (GBATEK): a transparent 3D dot keeps its colour, without bit 15
        # (disp_capture SRC3: the rear plane's colour, as all three
        # reference cores have it)
        if l3 != nil:
          ca = to_bgr555(l3[x]) or (if alpha5(l3[x]) != 0: 0x8000'u16 else: 0)
      else:
        ca = e.gfx[x] or 0x8000
    if src != 0:
      if b_fifo:
        cb = e.mmem_line[x]
      else:
        let i = (rbase + x * 2) and 0x1FFFF
        cb = uint16(rbank[i]) or (uint16(rbank[i + 1]) shl 8)
    var c: uint16
    case src
    of 0: c = ca
    of 1: c = cb
    else:
      let aa = if (ca and 0x8000) != 0: eva else: 0
      let ab = if (cb and 0x8000) != 0: evb else: 0
      template mix(sh: int): uint32 =
        min(31'u32, ((uint32(ca shr sh) and 0x1F) * aa + (uint32(cb shr sh) and 0x1F) * ab) shr 4)
      c = uint16(mix(0) or (mix(5) shl 5) or (mix(10) shl 10))
      if (aa > 0) or (ab > 0): c = c or 0x8000
    if write_ok:
      let i = (wbase + x * 2) and 0x1FFFF
      dst[i] = uint8(c)
      dst[i + 1] = uint8(c shr 8)

proc mmem_fetch(g: Gpu) =
  ## The main-memory display FIFO hands out a line, 8 pixels at a time;
  ## before each 8 it asks DMA mode 4 for 4-word blocks while it has room
  ## (GBATEK "DS Video Capture and Main Memory Display Mode"), but never
  ## for more than the frame's 256x192 pixels, so a DMA restarted each
  ## frame lines up with line 0 (Assumed).
  let a = g.engine_a
  for x0 in countup(0, 248, 8):
    if g.mmem_req != nil:
      while g.mmem_need > 0 and a.mmem_room() and g.mmem_req(g.mmem_ctx):
        g.mmem_need -= 8
    a.mmem_take(x0)

proc render_line*(g: Gpu; y: int) =
  ## Called at H-blank of a visible line: both engines, display capture,
  ## then routed to the screens. POWCNT1 bit 15: 1 = engine A on the top
  ## screen.
  let a = g.engine_a
  let cap = g.capturing and a.enabled
  # the main-memory FIFO runs when display mode 3 or capture source B reads it
  if a.display_mode == 3 or
     cap and (a.dispcapcnt and (1'u32 shl 25)) != 0 and ((a.dispcapcnt shr 29) and 3) != 0:
    g.mmem_fetch()
  # the 3D line is pulled when something shows or captures it
  if g.gpu3d != nil and ((a.bg0_is_3d and (a.dispcnt and 0x100) != 0) or
                         (cap and (a.dispcapcnt and (1'u32 shl 24)) != 0)):
    g.gpu3d.render_line(y)
    a.line3d = addr g.gpu3d.line
  else:
    a.line3d = nil
  let need_gfx = cap and ((a.dispcapcnt shr 29) and 3) != 1 and
                 (a.dispcapcnt and (1'u32 shl 24)) == 0
  a.render_line(y, need_gfx)
  g.engine_b.render_line(y)
  if cap: g.capture_line(y)
  a.end_line()
  g.engine_b.end_line()
  let a_top = (g.powcnt1 and 0x8000) != 0
  let lcd_on = (g.powcnt1 and 1) != 0
  let base = y * 256
  for x in 0 ..< 256:
    let la = if lcd_on: a.line[x] else: 0'u16
    let lb = if lcd_on: g.engine_b.line[x] else: 0'u16
    if a_top:
      g.top[base + x] = la
      g.bottom[base + x] = lb
    else:
      g.top[base + x] = lb
      g.bottom[base + x] = la

{.pop.}
