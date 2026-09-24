import std/options
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/[config, input]
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
    # Pushes settings no widget owns (color-correction uniform, master volume,
    # speed mode, frame size) into the live core. Set by the app; may be nil.
    live_sync*:   proc() {.closure.}

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

# Restore every setting to its default while keeping the user's data (file
# paths, recents, explorer directory, the runtime headless flag); the list of
# what is kept lives in reset_to_defaults, so a new setting resets too.
proc do_factory_reset(ed: ConfigEditor) =
  ed.cfg.reset_to_defaults()
  ed.do_reset()
  ed.do_apply()
  if ed.live_sync != nil:
    ed.live_sync()

proc capturing_keys*(ed: ConfigEditor): bool =
  ## A Keybindings capture takes key releases only while Settings is open and
  ## its tab is on screen
  ed.open and ed.keybindings.wants_input()

proc capturing_buttons*(ed: ConfigEditor): bool =
  ed.open and ed.controller.wants_input()

proc render*(ed: ConfigEditor) =
  if ed.open and not ed.prev_open:
    ed.do_reset()
  ed.prev_open = ed.open

  # Only the tab bar below says a tab is on screen: closed, or collapsed
  # (igBegin false), none is, so no capture keeps taking keys.
  ed.keybindings.visible = false
  ed.controller.visible = false
  if not ed.open: return

  # Sized window, not AlwaysAutoResize: auto-resize re-fits on every tab switch
  # and cannot host the negative-sized footer child below. Height clamps to
  # the viewport so the pinned action row never falls off a small window.
  let work_h = igGetMainViewport().WorkSize.y
  igSetNextWindowPos(ImVec2(x: 60, y: 28), cint(ImGui_Cond_FirstUseEver),
                     ImVec2(x: 0, y: 0))
  igSetNextWindowSize(ImVec2(x: 560, y: min(460.0'f32, work_h - 56.0'f32)),
                      cint(ImGui_Cond_FirstUseEver))
  if igBegin("Settings", addr ed.open, 0):
    # The tab pane reserves room for the action row: a too-short window
    # scrolls the pane, never the buttons.
    let footer = igGetFrameHeightWithSpacing() + 10.0'f32
    discard igBeginChild_Str("##settings_tabs", ImVec2(x: 0, y: -footer),
                             ImGuiChildFlags(0), ImGuiWindowFlags(0))
    if igBeginTabBar("SettingsTabBar", 0):
      ed.keybindings.visible = igBeginTabItem("Keybindings", nil, 0)
      if ed.keybindings.visible:
        igBeginGroup()
        ed.keybindings.render()
        igEndGroup()
        igEndTabItem()

      ed.video.visible = igBeginTabItem("Video", nil, 0)
      if ed.video.visible:
        igBeginGroup()
        ed.video.render()
        igEndGroup()
        igEndTabItem()

      ed.controller.visible = igBeginTabItem("Controller", nil, 0)
      if ed.controller.visible:
        igBeginGroup()
        ed.controller.render()
        igEndGroup()
        igEndTabItem()

      ed.bios.visible = igBeginTabItem("BIOS", nil, 0)
      if ed.bios.visible:
        igBeginGroup()
        ed.bios.render()
        igEndGroup()
        igEndTabItem()

      igEndTabBar()
    igEndChild()

    igSeparator()

    if igButton("Apply", ImVec2(x: 0, y: 0)):   ed.do_apply()
    igSameLine(0, -1)
    if igButton("Revert", ImVec2(x: 0, y: 0)):  ed.do_reset()
    igSameLine(0, -1)
    if igButton("OK", ImVec2(x: 0, y: 0)):
      ed.do_apply()
      ed.open = false
    igSameLine(0, -1)
    if igButton("Reset to Defaults", ImVec2(x: 0, y: 0)):
      igOpenPopup_Str("Reset settings?", 0)

    if igBeginPopupModal("Reset settings?", nil,
                         cint(ImGui_WindowFlags_AlwaysAutoResize)):
      igText("Restore all settings to their defaults?")
      igText("Your ROMs, saves, recents and BIOS paths are kept.")
      igSeparator()
      if igButton("Reset", ImVec2(x: 120, y: 0)):
        ed.do_factory_reset()
        igCloseCurrentPopup()
      igSameLine(0, -1)
      if igButton("Cancel", ImVec2(x: 120, y: 0)):
        igCloseCurrentPopup()
      igEndPopup()

  igEnd()
  # Closed with the X this frame: a capture in progress ends with the window
  if not ed.open:
    ed.keybindings.selection = none(Input)
    ed.controller.selection = none(Input)
