import std/strformat
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/scheduler
import ../gba/gba

type
  GbaDebug* = ref object
    gba*:          GBA
    video_window*: bool
    io_window*:    bool
    sched_window*: bool
    exp_window*:   bool

proc new_gba_debug*(gba: GBA): GbaDebug =
  GbaDebug(gba: gba)

proc render_menu_items*(d: GbaDebug) =
  discard igMenuItem_BoolPtr("Video", nil, addr d.video_window, true)
  discard igMenuItem_BoolPtr("IO Registers", nil, addr d.io_window, true)
  discard igMenuItem_BoolPtr("Scheduler", nil, addr d.sched_window, true)
  discard igMenuItem_BoolPtr("Experimental Settings", nil, addr d.exp_window, true)

proc render_palettes(d: GbaDebug) =
  if igBeginTabItem("Palettes", nil, 0):
    let pram = cast[ptr UncheckedArray[uint16]](addr d.gba.ppu.pram[0])
    let flags = cint(ImGui_ColorEditFlags_NoAlpha) or
                cint(ImGui_ColorEditFlags_NoPicker) or
                cint(ImGui_ColorEditFlags_NoOptions) or
                cint(ImGui_ColorEditFlags_NoInputs) or
                cint(ImGui_ColorEditFlags_NoLabel) or
                cint(ImGui_ColorEditFlags_NoSidePreview) or
                cint(ImGui_ColorEditFlags_NoDragDrop) or
                cint(ImGui_ColorEditFlags_NoBorder)
    igPushStyleVar_Vec2(cint(ImGui_StyleVar_ItemSpacing), ImVec2(x: 0, y: 0))
    for palette_set in 0 ..< 2:
      igBeginGroup()
      for row in 0 ..< 16:
        for col in 0 ..< 16:
          let c = pram[palette_set * 256 + row * 16 + col]
          let r = cfloat(c and 0x1F'u16) / 31.0'f32
          let g = cfloat((c shr 5) and 0x1F'u16) / 31.0'f32
          let b = cfloat((c shr 10) and 0x1F'u16) / 31.0'f32
          let col_vec = ImVec4(x: r, y: g, z: b, w: 1.0'f32)
          discard igColorButton("", col_vec, flags, ImVec2(x: 10, y: 10))
          if col < 15:
            igSameLine(0, -1)
      igEndGroup()
      if palette_set == 0:
        igSameLine(0, 4)
    igPopStyleVar(1)
    igEndTabItem()

proc render_layers(d: GbaDebug) =
  if igBeginTabItem("Layers", nil, 0):
    igTextUnformatted("Debug visibility (display only; emulation unaffected)", nil)
    const names: array[5, cstring] = ["BG0", "BG1", "BG2", "BG3", "OBJ"]
    let ppu = d.gba.ppu
    for i in 0 .. 4:
      var shown = ((ppu.debug_layer_mask shr i) and 1) != 0
      if igCheckbox(names[i], addr shown):
        ppu.debug_layer_mask = ppu.debug_layer_mask xor (1'u16 shl i)
        # Re-composite now so the toggle shows while paused.
        ppu.rerender_frame()
    igEndTabItem()

proc tx(s: string) =
  igTextUnformatted(cstring(s), nil)

proc onoff(b: bool): string =
  if b: "on" else: "off"

proc layer_bits_str(bits: uint16): string =
  const names = ["BG0", "BG1", "BG2", "BG3", "OBJ"]
  result = ""
  for i in 0 .. 4:
    if ((bits shr i) and 1) != 0:
      if result.len > 0: result.add " "
      result.add names[i]
  if result.len == 0: result = "none"

proc irq_bits_str(v: uint16): string =
  const names = ["VBlank", "HBlank", "VCount", "Timer0", "Timer1", "Timer2",
                 "Timer3", "Serial", "DMA0", "DMA1", "DMA2", "DMA3",
                 "Keypad", "GamePak"]
  result = ""
  for i in 0 ..< names.len:
    if ((v shr i) and 1) != 0:
      if result.len > 0: result.add " "
      result.add names[i]
  if result.len == 0: result = "none"

proc render_io_display(d: GbaDebug) =
  let ppu = d.gba.ppu
  let dc = ppu.dispcnt
  tx(fmt"DISPCNT  {toU16(dc):04X}  mode {dc.bg_mode}, frame {uint16(dc.display_frame_select)}, " &
     fmt"forced blank {onoff(dc.forced_blank)}, obj {(if dc.obj_mapping_1d: '1' else: '2')}D")
  tx(fmt"  layers: {layer_bits_str(uint16(dc.default_enable_bits))}")
  var wins = ""
  if dc.window_0_display: wins.add " win0"
  if dc.window_1_display: wins.add " win1"
  if dc.obj_window_display: wins.add " objwin"
  if wins.len == 0: wins = " none"
  tx(fmt"  windows:{wins}")
  let ds = ppu.dispstat
  tx(fmt"DISPSTAT {toU16(ds):04X}  vblank {onoff(ds.vblank)}, hblank {onoff(ds.hblank)}, " &
     fmt"vcounter {onoff(ds.vcounter)}")
  var irqs = ""
  if ds.vblank_irq_enable: irqs.add " vblank"
  if ds.hblank_irq_enable: irqs.add " hblank"
  if ds.vcounter_irq_enable: irqs.add " vcounter"
  if irqs.len == 0: irqs = " none"
  tx(fmt"  IRQ enables:{irqs}  lyc={ds.vcount_setting}")
  tx(fmt"VCOUNT   {ppu.vcount:>4}")

proc render_io_backgrounds(d: GbaDebug) =
  let ppu = d.gba.ppu
  for bg in 0 .. 3:
    let cnt = ppu.bgcnt[bg]
    tx(fmt"BG{bg}CNT {toU16(cnt):04X}  prio {cnt.priority}, char {cnt.character_base_block}, " &
       fmt"screen {cnt.screen_base_block}, {(if cnt.color_mode_8bpp: 8 else: 4)}bpp, " &
       fmt"size {cnt.screen_size}" & (if cnt.mosaic: ", mosaic" else: ""))
    tx(fmt"  HOFS {ppu.bghofs[bg].offset:>3}  VOFS {ppu.bgvofs[bg].offset:>3}")

proc render_io_blending(d: GbaDebug) =
  let ppu = d.gba.ppu
  let bld = toU16(ppu.bldcnt)
  const modes = ["none", "alpha", "brighten", "darken"]
  tx(fmt"BLDCNT   {bld:04X}  mode {modes[ppu.bldcnt.blend_mode]}")
  const targets = ["BG0", "BG1", "BG2", "BG3", "OBJ", "BD"]
  var first = ""
  var second = ""
  for i in 0 .. 5:
    if ((bld shr i) and 1) != 0:
      if first.len > 0: first.add " "
      first.add targets[i]
    if ((bld shr (i + 8)) and 1) != 0:
      if second.len > 0: second.add " "
      second.add targets[i]
  if first.len == 0: first = "none"
  if second.len == 0: second = "none"
  tx(fmt"  1st: {first}")
  tx(fmt"  2nd: {second}")
  tx(fmt"BLDALPHA {toU16(ppu.bldalpha):04X}  eva {ppu.bldalpha.eva_coefficient}, " &
     fmt"evb {ppu.bldalpha.evb_coefficient}")
  tx(fmt"BLDY     {toU16(ppu.bldy):04X}  evy {ppu.bldy.evy_coefficient}")

proc render_io_windows(d: GbaDebug) =
  let ppu = d.gba.ppu
  tx(fmt"WIN0  x {ppu.win0h.x1:>3}..{ppu.win0h.x2:>3}  y {ppu.win0v.y1:>3}..{ppu.win0v.y2:>3}")
  tx(fmt"WIN1  x {ppu.win1h.x1:>3}..{ppu.win1h.x2:>3}  y {ppu.win1v.y1:>3}..{ppu.win1v.y2:>3}")
  let wi = ppu.winin
  tx(fmt"WININ  {toU16(wi):04X}")
  tx(fmt"  win0: {layer_bits_str(uint16(wi.window_0_enable_bits))}" &
     (if wi.window_0_color_special_effect: " +effect" else: ""))
  tx(fmt"  win1: {layer_bits_str(uint16(wi.window_1_enable_bits))}" &
     (if wi.window_1_color_special_effect: " +effect" else: ""))
  let wo = ppu.winout
  tx(fmt"WINOUT {toU16(wo):04X}")
  tx(fmt"  outside: {layer_bits_str(uint16(wo.outside_enable_bits))}" &
     (if wo.outside_color_special_effect: " +effect" else: ""))
  tx(fmt"  objwin:  {layer_bits_str(uint16(wo.obj_window_enable_bits))}" &
     (if wo.obj_window_color_special_effect: " +effect" else: ""))

proc render_io_timers(d: GbaDebug) =
  let tim = d.gba.timer
  const freqs = ["F/1", "F/64", "F/256", "F/1024"]
  for n in 0 .. 3:
    # Read through the IO handler so the counter reflects elapsed cycles.
    let base = 0x100'u32 + uint32(n) * 4
    let count = uint16(tim[base]) or (uint16(tim[base + 1]) shl 8)
    let cnt = tim.tmcnt[n]
    var flags = if cnt.cascade: "cascade" else: freqs[cnt.frequency]
    if cnt.irq_enable: flags.add " irq"
    flags.add (if cnt.enable: " ENABLED" else: " off")
    tx(fmt"TM{n}  count {count:04X}  reload {tim.tmd[n]:04X}  ctrl {toU16(cnt):04X}  {flags}")

proc render_io_dma(d: GbaDebug) =
  let dma = d.gba.dma
  const timings = ["immediate", "vblank", "hblank", "special"]
  for n in 0 .. 3:
    let cnt = dma.dmacnt_h[n]
    tx(fmt"DMA{n}  src {dma.dmasad[n]:08X}  dst {dma.dmadad[n]:08X}  " &
       fmt"count {dma.dmacnt_l[n]:04X}  ctrl {toU16(cnt):04X}")
    if cnt.enable:
      var flags = fmt"{timings[cnt.start_timing]}, {(if cnt.xfer_type == 1: 32 else: 16)}-bit"
      if cnt.repeat: flags.add ", repeat"
      if cnt.irq_enable: flags.add ", irq"
      tx(fmt"  ENABLED: {flags}  (cur src {dma.src[n]:08X} dst {dma.dst[n]:08X})")

proc render_io_interrupts(d: GbaDebug) =
  let intr = d.gba.interrupts
  let ie_v = toU16(intr.reg_ie)
  let if_v = toU16(intr.reg_if)
  tx(fmt"IME {onoff(intr.ime)}")
  tx(fmt"IE  {ie_v:04X}  {irq_bits_str(ie_v)}")
  tx(fmt"IF  {if_v:04X}  {irq_bits_str(if_v)}")

proc render_io_keypad(d: GbaDebug) =
  let ki = d.gba.keypad.keyinput
  let v = toU16(ki)
  const names = ["A", "B", "Select", "Start", "Right", "Left", "Up", "Down",
                 "R", "L"]
  var pressed = ""
  for i in 0 ..< names.len:
    if ((v shr i) and 1) == 0:  # active low
      if pressed.len > 0: pressed.add " "
      pressed.add names[i]
  if pressed.len == 0: pressed = "none"
  tx(fmt"KEYINPUT {v:04X}  pressed: {pressed}")

proc render_io_window(d: GbaDebug) =
  discard igBegin("IO Registers", addr d.io_window, 0)
  let header_flags = cint(ImGui_TreeNodeFlags_DefaultOpen)
  if igCollapsingHeader_TreeNodeFlags("Display", header_flags):
    d.render_io_display()
  if igCollapsingHeader_TreeNodeFlags("Backgrounds", header_flags):
    d.render_io_backgrounds()
  if igCollapsingHeader_TreeNodeFlags("Blending", 0):
    d.render_io_blending()
  if igCollapsingHeader_TreeNodeFlags("Windows", 0):
    d.render_io_windows()
  if igCollapsingHeader_TreeNodeFlags("Timers", 0):
    d.render_io_timers()
  if igCollapsingHeader_TreeNodeFlags("DMA", 0):
    d.render_io_dma()
  if igCollapsingHeader_TreeNodeFlags("Interrupts", 0):
    d.render_io_interrupts()
  if igCollapsingHeader_TreeNodeFlags("Keypad", 0):
    d.render_io_keypad()
  igEnd()

proc render_windows*(d: GbaDebug) =
  if d.video_window:
    discard igBegin("Video", addr d.video_window, 0)
    if igBeginTabBar("VideoTabBar", 0):
      d.render_palettes()
      d.render_layers()
      igEndTabBar()
    igEnd()

  if d.io_window:
    d.render_io_window()

  if d.sched_window:
    discard igBegin("Scheduler", addr d.sched_window, 0)
    let cycles = d.gba.scheduler.cycles
    igText("Total cycles: %llu", cycles)
    if igBeginTable("SchedulerTable", 2, 0, ImVec2(x: 0, y: 0), 0):
      igTableSetupColumn("Cycles", 0, 0, 0)
      igTableSetupColumn("Type", 0, 0, 0)
      igTableHeadersRow()
      for ev in d.gba.scheduler.events:
        igTableNextRow(0, 0)
        discard igTableSetColumnIndex(0)
        let delta = if ev.cycles >= cycles: ev.cycles - cycles else: CycleCount(0)
        igText("%llu", delta)
        discard igTableSetColumnIndex(1)
        igTextUnformatted(cstring($ev.kind), nil)
      igEndTable()
    igEnd()

  if d.exp_window:
    discard igBegin("Experimental Settings", addr d.exp_window, 0)
    discard igCheckbox("Attempt waitloop detection",
                       addr d.gba.cpu.attempt_waitloop_detection)
    discard igCheckbox("Cache waitloop results",
                       addr d.gba.cpu.cache_waitloop_results)
    let elapsed = d.gba.scheduler.cycles - d.gba.frame_start_cycles
    let progress = cfloat(elapsed) / 280896.0'f32
    igProgressBar(progress, ImVec2(x: 0, y: 0), nil)
    igEnd()
