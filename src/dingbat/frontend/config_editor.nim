import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config
import file_explorer
import bios_selection
import video_widget
import keybindings_widget
import controller_widget

type
  ConfigEditor* = ref object
    cfg*:         Config
    fe*:          FileExplorer
    bios*:        BiosSelection
    video*:       VideoWidget
    keybindings*: KeybindingsWidget
    controller*:  ControllerWidget
    open*:        bool
    prev_open:    bool

proc new_config_editor*(cfg: Config; fe: FileExplorer): ConfigEditor =
  ConfigEditor(
    cfg:         cfg,
    fe:          fe,
    bios:        new_bios_selection(cfg, fe),
    video:       new_video_widget(cfg),
    keybindings: new_keybindings_widget(cfg),
    controller:  new_controller_widget(cfg),
    open:        false,
    prev_open:   false,
  )

proc do_reset(ed: ConfigEditor) =
  ed.bios.reset()
  ed.video.reset()
  ed.keybindings.reset()
  ed.controller.reset()

proc do_apply(ed: ConfigEditor) =
  ed.bios.apply()
  ed.video.apply()
  ed.keybindings.apply()
  ed.controller.apply()
  save_config(ed.cfg)

proc render*(ed: ConfigEditor) =
  # Reset sub-widgets when window first opens
  if ed.open and not ed.prev_open:
    ed.do_reset()
  ed.prev_open = ed.open

  if not ed.open: return

  discard igBegin("Settings", addr ed.open, cint(ImGui_WindowFlags_AlwaysAutoResize))

  if igButton("Apply", ImVec2(x: 0, y: 0)):   ed.do_apply()
  igSameLine(0, -1)
  if igButton("Revert", ImVec2(x: 0, y: 0)):  ed.do_reset()
  igSameLine(0, -1)
  if igButton("OK", ImVec2(x: 0, y: 0)):
    ed.do_apply()
    ed.open = false

  igSeparator()

  if igBeginTabBar("SettingsTabBar", 0):
    ed.bios.visible = igBeginTabItem("BIOS", nil, 0)
    if ed.bios.visible:
      igBeginGroup()
      ed.bios.render()
      igEndGroup()
      igEndTabItem()

    ed.video.visible = igBeginTabItem("Video", nil, 0)
    if ed.video.visible:
      igBeginGroup()
      ed.video.render()
      igEndGroup()
      igEndTabItem()

    ed.keybindings.visible = igBeginTabItem("Keybindings", nil, 0)
    if ed.keybindings.visible:
      igBeginGroup()
      ed.keybindings.render()
      igEndGroup()
      igEndTabItem()

    ed.controller.visible = igBeginTabItem("Controller", nil, 0)
    if ed.controller.visible:
      igBeginGroup()
      ed.controller.render()
      igEndGroup()
      igEndTabItem()

    igEndTabBar()

  igEnd()
