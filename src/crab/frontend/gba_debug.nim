import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../gba/gba

type
  GbaDebug* = ref object
    gba*:          GBA
    video_window*: bool
    sched_window*: bool
    exp_window*:   bool

proc new_gba_debug*(gba: GBA): GbaDebug =
  GbaDebug(gba: gba)

proc render_menu_items*(d: GbaDebug) =
  discard igMenuItem_BoolPtr("Video", nil, addr d.video_window, true)
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

proc render_windows*(d: GbaDebug) =
  if d.video_window:
    discard igBegin("Video", addr d.video_window, 0)
    if igBeginTabBar("VideoTabBar", 0):
      d.render_palettes()
      igEndTabBar()
    igEnd()

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
        let delta = if ev.cycles >= cycles: ev.cycles - cycles else: 0'u64
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
    let progress = cfloat(d.gba.cpu.count_cycles) / 280896.0'f32
    igProgressBar(progress, ImVec2(x: 0, y: 0), nil)
    igEnd()
