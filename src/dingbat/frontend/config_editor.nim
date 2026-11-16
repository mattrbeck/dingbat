## The Settings window's edit: what each tab holds (`tabs`, settings_model's
## rows), how a row changes it (`set_value`, `activate`), and Apply / Revert /
## Reset to Defaults. Drawn by imgui_settings.nim, or on macOS by
## mac_settings.nim.

import std/[options, strutils]
import ../common/[config, input]
import file_explorer
import bios_selection
import video_widget
import keybindings_widget
import controller_widget
import general_widget
import settings_model


type
  ConfigEditor* = ref object
    cfg*:         Config
    fe*:          FileExplorer   # the ImGui window's Browse
    bios*:        BiosSelection
    video*:       VideoWidget
    keybindings*: KeybindingsWidget
    controller*:  ControllerWidget
    general*:     GeneralWidget
    open*:        bool
    prev_open*:   bool
    native*:      bool   # macOS: the native window draws it, not ImGui
    # Pushes settings no widget owns (color-correction uniform, master volume,
    # the audio niceties, frame size) into the live core. Set by the app; may
    # be nil.
    live_sync*:   proc() {.closure.}

const TAB_TITLES* = ["Keybindings", "Video", "Controller", "BIOS", "General"]

proc new_config_editor*(cfg: Config; fe: FileExplorer): ConfigEditor =
  ConfigEditor(
    cfg:         cfg,
    fe:          fe,
    bios:        new_bios_selection(cfg),
    video:       new_video_widget(cfg),
    keybindings: new_keybindings_widget(cfg),
    controller:  new_controller_widget(cfg),
    general:     new_general_widget(cfg),
    open:        false,
    prev_open:   false,
  )

proc do_reset*(ed: ConfigEditor) =
  ed.bios.reset()
  ed.video.reset()
  ed.keybindings.reset()
  ed.controller.reset()
  ed.general.reset()

proc do_apply*(ed: ConfigEditor) =
  ed.bios.apply()
  ed.video.apply()
  ed.keybindings.apply()
  ed.controller.apply()
  ed.general.apply()
  save_config(ed.cfg)

proc has_unapplied_edits*(ed: ConfigEditor): bool =
  ## Apply would change the settings file: closing asks before dropping them.
  let pending = Config()
  pending[] = ed.cfg[]
  ed.bios.apply_to(pending)
  ed.video.apply_to(pending)
  ed.keybindings.apply_to(pending)
  ed.controller.apply_to(pending)
  ed.general.apply_to(pending)
  not same_file(pending, ed.cfg)

proc end_captures*(ed: ConfigEditor) =
  ed.keybindings.selection = none(Input)
  ed.controller.selection = none(Input)
  ed.keybindings.ds_selection = none(DsInput)
  ed.controller.ds_selection = none(DsInput)

# Restore every setting to its default while keeping the user's data (file
# paths, recents, explorer directory, the runtime headless flag); the list of
# what is kept lives in reset_to_defaults, so a new setting resets too.
proc do_factory_reset*(ed: ConfigEditor) =
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

proc sync*(ed: ConfigEditor) =
  ## Before each frame of either window. The DS's rows follow the DS Beta box
  ## as it is ticked, before Apply; a pad capture ends when no pad is left.
  let ds = ed.general.ds_beta
  ed.keybindings.show_ds = ds
  ed.controller.show_ds = ds
  ed.bios.show_ds = ds
  ed.video.show_ds = ds
  if not controller_connected():
    ed.controller.selection = none(Input)
    ed.controller.ds_selection = none(DsInput)

proc show_tab*(ed: ConfigEditor; tab: int) =
  ## Which tab is on screen (-1: none, the window closed or folded): only
  ## there does a capture take keys or buttons.
  ed.keybindings.visible = tab == 0
  ed.video.visible = tab == 1
  ed.controller.visible = tab == 2
  ed.bios.visible = tab == 3
  ed.general.visible = tab == 4

# ── The rows ──

const DS_HELP = [
  ("DS ARM9 BIOS:", "bios9.bin (4 KB). Optional: without it the DS's ARM9 " &
                    "BIOS calls are answered by HLE."),
  ("DS ARM7 BIOS:", "bios7.bin (16 KB). Optional: without it the DS's ARM7 " &
                    "BIOS calls are answered by HLE."),
  ("DS firmware:",  "firmware.bin (128, 256 or 512 KB). Optional: without it " &
                    "a built-in firmware is used. What games write to it (your " &
                    "name, birthday, language, Wi-Fi settings) is kept apart, " &
                    "never written into this file."),
]

proc keybindings_rows(ed: ConfigEditor): seq[SettingRow] =
  let w = ed.keybindings
  result.add preset(siKeyPreset, "Preset", "Select preset...", ["Default", "Home-row"])
  for inp in Input:
    let on = w.selection.isSome() and w.selection.get() == inp
    result.add binding(siKeyBinding, ord(inp), $inp,
                       key_label(w.find_key_for_input(inp)), on, 48)
  if not w.show_ds: return
  for inp in DsInput:
    let on = w.ds_selection.isSome() and w.ds_selection.get() == inp
    result.add binding(siKeyBinding, DS_ARG + ord(inp),
                       toUpperAscii($inp) & " (DS)", key_label(w.ds_key_for(inp)), on, 48)
  result.add note("X and Y count only in DS games, where they come before\n" &
                  "the keys above.")

proc video_rows(ed: ConfigEditor): seq[SettingRow] =
  let v = ed.video
  result.add label("Filter:",
    "One look for the picture, GPU-drawn either way. hq4x and xBR " &
    "are clean-room implementations of the well-known " &
    "edge-directed smoothers; LCD grid and RGB subpixels draw the " &
    "screen's own structure instead of smoothing (the grid is the " &
    "pixel matrix every Game Boy LCD shows; RGB subpixels imitates " &
    "the GBC/GBA TFT's stripe triads; a DMG panel has none, so there " &
    "it is a stylized look). \"None\" keeps crisp " &
    "nearest-neighbor pixels. Color correction still applies on top.",
    @[choice(siFilter, ["None (crisp)", "hq4x", "xBR", "LCD grid", "RGB subpixels"],
             [0, 1, 2, 3, 4], int(v.filter))])
  result.add separator()
  result.add toggle(siPreserveAspect, "Preserve aspect ratio", v.preserve_aspect,
    "Letterbox the picture instead of stretching it to fill the " &
    "window. Only visible when the window is not an exact multiple " &
    "of the console's resolution: fullscreen, or after a manual resize.")
  result.add toggle(siLcdResponse, "LCD response", v.lcd_resp,
    "Emulate how slowly the real screen's pixels settle: quick to " &
    "darken, slow to fade back to light, which is why a moving dark " &
    "object on hardware has a crisp leading edge and a trail behind " &
    "it. Games that flicker a sprite every other frame to fake " &
    "transparency were counting on this. Without it they strobe. " &
    "The response follows whichever console the game runs on, and " &
    "stays out of the way under Super Game Boy, where the picture " &
    "leaves through a television and never meets an LCD.")
  result.add separator()
  result.add label("Super Game Boy:",
    "Run monochrome carts whose header unlocks SGB functions on the " &
    "Super Game Boy adapter: per-region color palettes and, where " &
    "the cart ships one, a 256x224 border. Carts without the SGB " &
    "header bits are unaffected, and a Game Boy Color cart always " &
    "runs as a Game Boy Color even if it is also SGB-enhanced. " &
    "Off by default: stock Game Boy behavior until you ask for it.",
    @[toggle(siSgbEnable, "Super Game Boy mode", v.sgb_enable),
      # Kept visible: the adapter is chosen at cartridge insertion, so
      # ticking this changes nothing about the running game.
      note("Applies on the next ROM load or reset."),
      toggle(siSgbBorder, "Show SGB border", v.sgb_border,
        "The border makes the picture 256x224 instead of 160x144, so " &
        "the window resizes when one appears. This one takes effect " &
        "immediately, since it only hides a layer the core already has." &
        (if not v.sgb_enable: " (Super Game Boy mode is off.)" else: ""),
        enabled = v.sgb_enable)])
  if v.show_ds:
    result.add separator()
    result.add label("Nintendo DS:", rows = @[
      label("3D resolution:",
        "Draws the 3D scenes at a higher resolution: sharper edges " &
        "and models, the same textures. 2D stays as it is. Each step " &
        "costs a lot more work a frame, so a slower computer may not " &
        "keep full speed."),
      choice(siNdsHd, ["Native", "2x", "3x", "4x"], [1, 2, 3, 4], int(v.nds_hd),
             inline = true)])

proc controller_rows(ed: ConfigEditor): seq[SettingRow] =
  let w = ed.controller
  # Rumble also drives the viewport shake, so it sits above the
  # no-controller early-out.
  result.add toggle(siRumble, "Rumble", w.rumble,
    "Vibrate the controller and shake the screen while a rumble " &
    "cartridge's motor runs (GB MBC5 and GBA rumble carts)")
  result.add separator()
  if not controller_connected():
    result.add text("No controller detected")
    return
  result.add button(siPadDefaults, "Reset to defaults")
  proc pad_label(on: bool; button: cint): string =
    if on: "..." elif button < 0: "---" else: controller_button_name(button)
  for inp in Input:
    let on = w.selection.isSome() and w.selection.get() == inp
    result.add binding(siPadBinding, ord(inp), $inp,
                       pad_label(on, w.find_button_for_input(inp)), on, 96)
  if w.show_ds:
    for inp in DsInput:
      let on = w.ds_selection.isSome() and w.ds_selection.get() == inp
      result.add binding(siPadBinding, DS_ARG + ord(inp), toUpperAscii($inp) & " (DS)",
                         pad_label(on, w.ds_button_for(inp)), on, 96)
    result.add note("X and Y count only in DS games, where they come\n" &
                    "before the buttons above.")
  result.add note("Left stick acts as the D-pad; holding the right\n" &
                  "trigger fast-forwards. These are not rebindable.")

proc bios_rows(ed: ConfigEditor): seq[SettingRow] =
  let b = ed.bios
  # The intro and the real-BIOS modes need an image: without one the core
  # has only a stub that answers interrupts, and load_rom boots HLE instead.
  let have_file = gba_bios_file_ok(b.path)
  result.add path(siGbaBios, "GBA BIOS:", b.path, "optional (leave empty for HLE)",
    path_valid(b.path),
    "Optional. Without a BIOS file, BIOS calls are answered by HLE " &
    "(a built-in reimplementation) and the intro is skipped.")
  result.add group(@[
    toggle(siRunBios, "Run BIOS intro", b.run_bios, enabled = have_file),
    label("SWI handling:",
      "How GBA BIOS calls are serviced. HLE needs no BIOS file; " &
      "the mode takes effect on the next ROM load."),
    choice(siBiosMode, ["HLE (no BIOS file needed)", "Real BIOS",
                        "Real BIOS init, HLE SWI calls"], [0, 1, 2],
           int(b.bios_mode), option_on = [true, have_file, have_file]),
    note("No BIOS file: GBA games use HLE and skip the intro.",
         shown = not have_file and (b.bios_mode != 0 or b.run_bios)),
    note("This run only, from the command line: " & b.overrides,
         shown = b.overrides.len > 0)])
  if not b.show_ds: return
  result.add separator()
  for i, (title, help) in DS_HELP:
    result.add path(SettingId(ord(siNdsBios9) + i), title, b.ds_paths[i], "optional",
                    path_valid(b.ds_paths[i]), help, width = 280, label_col = 110)
  result.add note("DS games use these from the next DS game loaded. A save " &
                  "state made with one BIOS\ndoes not load on the other (HLE or a dump).")

proc general_rows(ed: ConfigEditor): seq[SettingRow] =
  @[fold("Advanced", @[
    toggle(siDsBeta, "DS Beta", ed.general.ds_beta,
           "Lets DS games load. An early, incomplete Nintendo DS core."),
    note("Takes effect on the next game opened.")])]

proc tabs*(ed: ConfigEditor): seq[SettingsTab] =
  ## Every tab as it would show now.
  ed.sync()
  @[SettingsTab(title: TAB_TITLES[0], rows: ed.keybindings_rows()),
    SettingsTab(title: TAB_TITLES[1], rows: ed.video_rows()),
    SettingsTab(title: TAB_TITLES[2], rows: ed.controller_rows()),
    SettingsTab(title: TAB_TITLES[3], rows: ed.bios_rows()),
    SettingsTab(title: TAB_TITLES[4], rows: ed.general_rows())]

# ── Changing the edit ──

proc set_value*(ed: ConfigEditor; id: SettingId; value: int; text = "") =
  ## A toggle (`value` 0/1), a choice (the option's value) or a path (`text`).
  case id
  of siFilter: ed.video.filter = cint(clamp(value, 0, ord(VideoFilter.high)))
  of siPreserveAspect: ed.video.preserve_aspect = value != 0
  of siLcdResponse: ed.video.lcd_resp = value != 0
  of siSgbEnable: ed.video.sgb_enable = value != 0
  of siSgbBorder: ed.video.sgb_border = value != 0
  of siNdsHd: ed.video.nds_hd = cint(clamp(value, 1, 4))
  of siGbaBios: ed.bios.path = text
  of siRunBios: ed.bios.run_bios = value != 0
  of siBiosMode: ed.bios.bios_mode = cint(clamp(value, 0, 2))
  of siNdsBios9, siNdsBios7, siNdsFirmware:
    ed.bios.ds_paths[ord(id) - ord(siNdsBios9)] = text
  of siDsBeta: ed.general.ds_beta = value != 0
  of siRumble: ed.controller.rumble = value != 0
  of siNone, siKeyPreset, siKeyBinding, siPadDefaults, siPadBinding: discard

proc activate*(ed: ConfigEditor; id: SettingId; arg = 0) =
  ## A button, a binding (wait for its key or button) or a preset (`arg`).
  case id
  of siKeyPreset:
    if arg == 0: ed.keybindings.load_preset(default_keybindings(), default_ds_keybindings())
    else: ed.keybindings.load_preset(homerow_keybindings(), homerow_ds_keybindings())
  of siKeyBinding:
    let w = ed.keybindings
    if arg >= DS_ARG:
      w.ds_selection = some(DsInput(clamp(arg - DS_ARG, 0, ord(DsInput.high))))
      w.selection = none(Input)
    else:
      w.selection = some(Input(clamp(arg, 0, ord(Input.high))))
      w.ds_selection = none(DsInput)
  of siPadBinding:
    let w = ed.controller
    if arg >= DS_ARG:
      w.ds_selection = some(DsInput(clamp(arg - DS_ARG, 0, ord(DsInput.high))))
      w.selection = none(Input)
    else:
      w.selection = some(Input(clamp(arg, 0, ord(Input.high))))
      w.ds_selection = none(DsInput)
  of siPadDefaults: ed.controller.load_defaults()
  else: discard
