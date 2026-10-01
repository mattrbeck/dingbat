## Display controller: line/frame timing shared by both CPUs (each has its
## own DISPSTAT with its own VCOUNT-match setting and IRQ enables), POWCNT1,
## and the two output framebuffers. Owns both 2D engines and drives the 3D
## engine's per-frame hooks.

import ../mem/vram
import engine2d

type
  DispStat* = object
    vcount_setting*: uint16   ## 9-bit LYC (bits 8-15 + bit 7 = bit 8)
    vblank_irq*, hblank_irq*, vcount_irq*: bool

  Gpu* = ref object
    vram*: Vram
    palette*: array[1024, uint16]     ## A BG/OBJ 0x05000000, B 0x05000400
    oam*: array[1024, uint16]         ## A 0x07000000, B 0x07000400
    engine_a*, engine_b*: Engine2D
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

proc render_line*(g: Gpu; y: int) =
  ## Called at H-blank of a visible line: both engines, then routed to the
  ## screens. POWCNT1 bit 15: 1 = engine A on the top screen.
  g.engine_a.render_line(y)
  g.engine_b.render_line(y)
  let a_top = (g.powcnt1 and 0x8000) != 0
  let lcd_on = (g.powcnt1 and 1) != 0
  let base = y * 256
  for x in 0 ..< 256:
    let a = if lcd_on: g.engine_a.line[x] else: 0'u16
    let b = if lcd_on: g.engine_b.line[x] else: 0'u16
    if a_top:
      g.top[base + x] = a
      g.bottom[base + x] = b
    else:
      g.top[base + x] = b
      g.bottom[base + x] = a
  # TODO(2d): display capture (DISPCAPCNT 0x4000064) taps engine A's line here
