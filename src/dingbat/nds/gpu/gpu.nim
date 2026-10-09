## Display controller: line/frame timing shared by both CPUs (each has its
## own DISPSTAT with its own VCOUNT-match setting and IRQ enables), POWCNT1,
## and the two output framebuffers. Owns both 2D engines, pulls the 3D line
## for engine A's BG0, and runs display capture (DISPCAPCNT 0x4000064).

import ../mem/vram
import ../gpu3d/gpu3d
import engine2d
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

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
    # HD 3D (docs/nds/hd3d.md; the frontend's setting, not machine state):
    # with hd > 1 the screens are also drawn at 256*hd x 192*hd, the 3D
    # layer from the HD renderer, everything else scaled up from 1x
    hd*: int                          ## 1 = off
    hd_top*, hd_bottom*: seq[uint16]  ## BGR555, (256*hd) x (192*hd)
    hd_sub: array[256, uint32]        ## scratch: one sub-dot column of a 3D line
    hd_out, hd_out2: array[256, uint16]
    hd_a_gfx, hd_a_line: seq[uint16]  ## scratch: engine A's line at HD (hd rows)
    hd_vline, hd_bline: array[256, uint16]  ## VRAM display's and capture source B's 1x
                                      ## halfwords, read before the capture writes
    cap_hd: array[4, seq[uint16]]     ## per bank A-D: display capture's HD sub-dots, hd*hd per halfword
    cap_1x: array[4, seq[uint32]]     ## ... and the halfword it wrote there (bit 16 = captured)

proc new_gpu*(): Gpu =
  result = Gpu(vram: new_vram(), hd: 1)
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

proc set_hd*(g: Gpu; scale: int) =
  ## HD 3D output at `scale` (1 = off, 2..4): hd_top/hd_bottom, with the
  ## 3D layer drawn at that resolution (gpu3d.set_hd) and the 2D layers
  ## scaled up whole dots. The 1x screens are unchanged.
  let k = clamp(scale, 1, 4)
  g.hd = k
  g.engine_a.hd_on = k > 1
  if g.gpu3d != nil: g.gpu3d.set_hd(k)
  for b in 0..3:
    g.cap_hd[b] = @[]
    g.cap_1x[b] = @[]
  if k == 1:
    g.hd_top = @[]
    g.hd_bottom = @[]
  else:
    g.hd_top = newSeq[uint16](256 * k * 192 * k)
    g.hd_bottom = newSeq[uint16](256 * k * 192 * k)

template hd_rows(g: Gpu; buf: var seq[uint16]; j: int): ptr UncheckedArray[uint16] =
  cast[ptr UncheckedArray[uint16]](addr buf[j * 256 * g.hd])

proc shadow(g: Gpu; bank, dot, sub: int; v1: uint16): uint16 {.inline.} =
  ## Sub-dot `sub` of VRAM halfword `dot` in bank A-D: the HD capture's
  ## when the halfword still holds what that capture wrote, else v1 itself.
  if g.cap_1x[bank].len > 0 and g.cap_1x[bank][dot] == (uint32(v1) or 0x10000'u32):
    g.cap_hd[bank][dot * g.hd * g.hd + sub]
  else: v1

proc hd_pre(g: Gpu; y: int) =
  ## Before display capture writes line y: the halfwords VRAM display and
  ## capture source B read (they may be the very ones it overwrites).
  let a = g.engine_a
  let capc = a.dispcapcnt
  let vb = g.vram.bank_ptr(VramBank((a.dispcnt shr 18) and 3))
  if a.display_mode == 2:
    for x in 0 ..< 256:
      let d = y * 256 + x
      g.hd_vline[x] = uint16(vb[d * 2]) or (uint16(vb[d * 2 + 1]) shl 8)
  let (cw, _) = CAPTURE_SIZE[(capc shr 20) and 3]
  let roff = if a.display_mode == 2: 0 else: int((capc shr 26) and 3) * 0x8000
  let rbase = roff + y * cw * 2
  for x in 0 ..< cw:
    let rd = ((rbase + x * 2) and 0x1FFFF) shr 1
    g.hd_bline[x] = uint16(vb[rd * 2]) or (uint16(vb[rd * 2 + 1]) shl 8)

proc hd_line(g: Gpu; y: int; a_top, lcd_on, cap: bool) =
  ## Line y of the HD screens (docs/nds/hd3d.md). Engine A's graphics
  ## composite is drawn again per sub-dot over the HD 3D frame when it
  ## holds the 3D layer; VRAM display shows a bank's HD capture where the
  ## bank still holds what was captured; display capture keeps an HD copy
  ## of what it writes (`cap_hd`). Everything else (engine B, 2D-only
  ## lines) repeats each dot hd x hd.
  let k = g.hd
  let wk = 256 * k
  let a = g.engine_a
  let g3 = g.gpu3d
  let (ta, tb) = if a_top: (addr g.hd_top, addr g.hd_bottom) else: (addr g.hd_bottom, addr g.hd_top)
  template scaled(dst: ptr seq[uint16]; src: array[256, uint16]) =
    for j in 0 ..< k:
      let row = (y * k + j) * wk
      for x in 0 ..< 256:
        let c = if lcd_on: src[x] else: 0'u16
        for i in 0 ..< k: dst[][row + x * k + i] = c
  scaled(tb, g.engine_b.line)
  let dm = a.display_mode
  let capc = a.dispcapcnt
  let (cw, ch) = CAPTURE_SIZE[(capc shr 20) and 3]
  let csrc = (capc shr 29) and 3
  let a_3d = (capc and (1'u32 shl 24)) != 0
  let cap_line = cap and y < ch
  let cap_gfx = cap_line and csrc != 1 and not a_3d
  let hd3 = g3 != nil and g3.hd_scale == k
  let has3d = hd3 and a.hd_gfx_3d() and not defined(hd_nocomposite)   # (the cost split, docs/nds/hd3d.md)
  if g.hd_a_gfx.len != k * wk: g.hd_a_gfx.setLen(k * wk)
  if g.hd_a_line.len != k * wk: g.hd_a_line.setLen(k * wk)
  # engine A's composite at HD (only where it holds 3D: else the 1x one)
  if has3d and (dm == 1 or cap_gfx):
    for j in 0 ..< k:
      let row = (y * k + j) * wk
      let og = g.hd_rows(g.hd_a_gfx, j)
      let ol = g.hd_rows(g.hd_a_line, j)
      for i in 0 ..< k:
        for x in 0 ..< 256: g.hd_sub[x] = g3.hd_frame[row + x * k + i]
        a.render_hd_sub(addr g.hd_sub, g.hd_out, g.hd_out2)
        for x in 0 ..< 256:
          og[x * k + i] = g.hd_out[x]
          ol[x * k + i] = g.hd_out2[x]
  # the display
  if lcd_on and a.enabled and dm == 1 and has3d:
    for j in 0 ..< k:
      copyMem(addr ta[][(y * k + j) * wk], addr g.hd_a_line[j * wk], wk * 2)
  elif lcd_on and a.enabled and dm == 2:
    let bank = int((a.dispcnt shr 18) and 3)
    for j in 0 ..< k:
      let row = (y * k + j) * wk
      for i in 0 ..< k:
        for x in 0 ..< 256:
          g.hd_out[x] = g.shadow(bank, y * 256 + x, j * k + i, g.hd_vline[x]) and 0x7FFF
        a.hd_bright(g.hd_out)
        for x in 0 ..< 256: ta[][row + x * k + i] = g.hd_out[x]
  else:
    scaled(ta, a.line)
  # display capture at HD, as capture_line (which has written the 1x line)
  if not cap_line: return
  let dst_bank = int((capc shr 16) and 3)
  if not g.vram.lcdc_mapped(VramBank(dst_bank)): return
  let kk = k * k
  if g.cap_1x[dst_bank].len == 0:
    g.cap_1x[dst_bank] = newSeq[uint32](65536)
  if g.cap_hd[dst_bank].len != 65536 * kk:
    g.cap_hd[dst_bank] = newSeq[uint16](65536 * kk)
    for v in g.cap_1x[dst_bank].mitems: v = 0
  let dst = g.vram.bank_ptr(VramBank(dst_bank))
  let eva = min(16'u32, capc and 0x1F)
  let evb = min(16'u32, (capc shr 8) and 0x1F)
  let b_fifo = (capc and (1'u32 shl 25)) != 0
  let wbase = int((capc shr 18) and 3) * 0x8000 + y * cw * 2
  let rb = int((a.dispcnt shr 18) and 3)
  let roff = if dm == 2: 0 else: int((capc shr 26) and 3) * 0x8000
  let rbase = roff + y * cw * 2
  let l3 = if g3 != nil: addr g3.line else: nil
  for x in 0 ..< cw:
    let wd = ((wbase + x * 2) and 0x1FFFF) shr 1
    let rd = ((rbase + x * 2) and 0x1FFFF) shr 1
    let rv1 = g.hd_bline[x]
    for j in 0 ..< k:
      for i in 0 ..< k:
        var ca, cb: uint16
        if csrc != 1:
          if a_3d:
            if hd3:
              let p = g3.hd_frame[(y * k + j) * wk + x * k + i]
              ca = to_bgr555(p) or (if alpha5(p) != 0: 0x8000'u16 else: 0)
            elif l3 != nil:
              ca = to_bgr555(l3[x]) or (if alpha5(l3[x]) != 0: 0x8000'u16 else: 0)
          else:
            ca = (if has3d: g.hd_a_gfx[j * wk + x * k + i] else: a.gfx[x]) or 0x8000
        if csrc != 0:
          cb = if b_fifo: a.mmem_line[x] else: g.shadow(rb, rd, j * k + i, rv1)
        var c: uint16
        case csrc
        of 0: c = ca
        of 1: c = cb
        else:
          let aa = if (ca and 0x8000) != 0: eva else: 0
          let ab = if (cb and 0x8000) != 0: evb else: 0
          template mix(sh: int): uint32 =
            min(31'u32, ((uint32(ca shr sh) and 0x1F) * aa + (uint32(cb shr sh) and 0x1F) * ab) shr 4)
          c = uint16(mix(0) or (mix(5) shl 5) or (mix(10) shl 10))
          if (aa > 0) or (ab > 0): c = c or 0x8000
        g.cap_hd[dst_bank][wd * kk + j * k + i] = c
    # what the 1x capture left there: the HD copy stands for it while it stays
    g.cap_1x[dst_bank][wd] = uint32(uint16(dst[wd * 2]) or (uint16(dst[wd * 2 + 1]) shl 8)) or 0x10000'u32

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
  if g.hd > 1: g.hd_pre(y)
  if cap: g.capture_line(y)
  a.end_line()
  g.engine_b.end_line()
  let a_top = (g.powcnt1 and 0x8000) != 0
  let lcd_on = (g.powcnt1 and 1) != 0
  let base = y * 256
  let (ta, tb) = if a_top: (addr g.top[base], addr g.bottom[base])
                 else: (addr g.bottom[base], addr g.top[base])
  if lcd_on:
    copyMem(ta, addr a.line[0], 512)
    copyMem(tb, addr g.engine_b.line[0], 512)
  else:
    zeroMem(ta, 512)
    zeroMem(tb, 512)
  if g.hd > 1: g.hd_line(y, a_top, lcd_on, cap)

{.pop.}
