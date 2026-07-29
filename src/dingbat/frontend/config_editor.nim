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
    # Pushes settings that no widget owns (color-correction GL uniform, master
    # volume) into the live core after cfg changes. Set by the app; may be nil.
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

# Factory reset: restore every *setting* to its default while keeping the user's
# data — file paths (bios_path, gb_bootrom_path), the recents list, the explorer
# directory, and the runtime headless flag are all left untouched. Settings are
# copied from a fresh new_config() so defaults live in exactly one place.
proc do_factory_reset(ed: ConfigEditor) =
  let d = new_config()
  ed.cfg.keybindings         = d.keybindings
  ed.cfg.controller_bindings = d.controller_bindings
  ed.cfg.run_bios            = d.run_bios
  ed.cfg.use_hle             = d.use_hle
  ed.cfg.hle_after_bios      = d.hle_after_bios
  ed.cfg.gb_fifo             = d.gb_fifo
  ed.cfg.gb_rumble           = d.gb_rumble
  ed.cfg.volume              = d.volume
  ed.cfg.mute                = d.mute
  ed.cfg.color_correction    = d.color_correction
  ed.cfg.video_filter        = d.video_filter
  ed.cfg.scanlines           = d.scanlines
  ed.cfg.frame_blend         = d.frame_blend
  ed.cfg.rewind              = d.rewind
  ed.cfg.pitch_correct_ff    = d.pitch_correct_ff
  ed.cfg.audio_lowpass       = d.audio_lowpass
  ed.cfg.mp2k_hle            = d.mp2k_hle
  ed.do_reset()          # reload every widget's UI state from the reset cfg
  ed.do_apply()          # push widget-owned settings live + persist to disk
  if ed.live_sync != nil:
    ed.live_sync()       # color-correction uniform + master volume (no widget)

proc render*(ed: ConfigEditor) =
  # Reset sub-widgets when window first opens
  if ed.open and not ed.prev_open:
    ed.do_reset()
  ed.prev_open = ed.open

  if not ed.open: return

  # Sized window instead of AlwaysAutoResize: auto-resize re-fit the window on
  # every tab switch (buttons jumped with it) and can't host the negative-sized
  # footer child below. Height clamps to the viewport like the Save States
  # window, so the pinned action row never falls off a small app window.
  let work_h = igGetMainViewport().WorkSize.y
  igSetNextWindowPos(ImVec2(x: 60, y: 28), cint(ImGui_Cond_FirstUseEver),
                     ImVec2(x: 0, y: 0))
  igSetNextWindowSize(ImVec2(x: 560, y: min(460.0'f32, work_h - 56.0'f32)),
                      cint(ImGui_Cond_FirstUseEver))
  if igBegin("Settings", addr ed.open, 0):
    # Tab content lives in a child that reserves room for the action row, so
    # Apply/OK stay reachable at any window size — a too-short window scrolls
    # the tab pane, never the buttons (same pattern as the Save States window).
    let footer = igGetFrameHeightWithSpacing() + 10.0'f32
    discard igBeginChild_Str("##settings_tabs", ImVec2(x: 0, y: -footer),
                             ImGuiChildFlags(0), ImGuiWindowFlags(0))
    # Tabs ordered by user relevance — the window opens on the first tab, so
    # input setup greets a new user and the technical BIOS pane comes last.
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
