import std/[tables, options, strutils]
import sdl3
import imguin/cimgui
import ../common/[input, config]
import util

type
  ControllerWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    rumble*:      bool
    visible*:     bool
    hovered_col:  ImVec4
    # The DS's X and Y, shown (and captured after R) only with DS Beta on
    show_ds*:      bool
    ds_editing*:   Table[cint, DsInput]
    ds_selection*: Option[DsInput]

proc new_controller_widget*(cfg: Config): ControllerWidget =
  let col_ptr = igGetStyleColorVec4(cint(ImGui_Col_ButtonHovered))
  let col = if col_ptr != nil: col_ptr[] else: ImVec4(x: 0.4, y: 0.4, z: 0.8, w: 1.0)
  result = ControllerWidget(
    cfg:         cfg,
    editing:     initTable[cint, Input](),
    selection:   none(Input),
    hovered_col: col,
  )

proc wants_input*(w: ControllerWidget): bool =
  w.visible and (w.selection.isSome() or w.ds_selection.isSome())

proc button_released*(w: ControllerWidget; button: cint) =
  # Buttons past DPAD_RIGHT (paddles, touchpad on newer SDL) have no name in
  # the table and would not round-trip through the yaml config.
  if controller_button_name(button).len == 0: return
  if w.selection.isSome():
    let sel = w.selection.get()
    var old_btn: cint = -1
    for k, v in w.editing.pairs:
      if v == sel: old_btn = k; break
    if old_btn >= 0: w.editing.del(old_btn)
    w.editing[button] = sel
    let next_ord = ord(sel) + 1
    if next_ord <= ord(high(Input)):
      w.selection = some(Input(next_ord))
    else:
      w.selection = none(Input)
      if w.show_ds: w.ds_selection = some(DsInput.low)
  elif w.ds_selection.isSome():
    let sel = w.ds_selection.get()
    var old_btn: cint = -1
    for k, v in w.ds_editing.pairs:
      if v == sel: old_btn = k; break
    if old_btn >= 0: w.ds_editing.del(old_btn)
    w.ds_editing[button] = sel
    w.ds_selection = if sel < DsInput.high: some(succ(sel)) else: none(DsInput)

proc find_button_for_input(w: ControllerWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc controller_connected(): bool = hasGamepad()

proc render*(w: ControllerWidget) =
  # Rumble also drives the viewport shake, so it sits above the
  # no-controller early-out.
  discard igCheckbox("Rumble", addr w.rumble)
  igSameLine(0, -1)
  help_marker("Vibrate the controller and shake the screen while a rumble " &
              "cartridge's motor runs (GB MBC5 and GBA rumble carts)")
  igSeparator()
  if not controller_connected():
    igText("No controller detected")
    w.selection = none(Input)
    w.ds_selection = none(DsInput)
    return

  if igButton("Reset to defaults", ImVec2(x: 0, y: 0)):
    w.editing = default_controller_bindings()
    w.selection = none(Input)
    w.ds_selection = none(DsInput)
    if w.show_ds: w.ds_editing = default_ds_controller_bindings()

  let btn_size = ImVec2(x: 96, y: 0)
  for inp in Input:
    let selected = w.selection.isSome() and w.selection.get() == inp
    let button   = w.find_button_for_input(inp)
    let btn_text =
      if selected: "..."
      elif button < 0: "---"
      else: controller_button_name(button)
    if selected:
      igPushStyleColor_Vec4(cint(ImGui_Col_Button), w.hovered_col)
    if igButton(cstring(btn_text & "##pad" & $inp), btn_size):
      w.selection = some(inp)
      w.ds_selection = none(DsInput)
    if selected:
      igPopStyleColor(1)
    igSameLine(0, -1)
    igText(cstring($inp))

  if w.show_ds:
    for inp in DsInput:
      let selected = w.ds_selection.isSome() and w.ds_selection.get() == inp
      var button: cint = -1
      for k, v in w.ds_editing.pairs:
        if v == inp: button = k; break
      let btn_text =
        if selected: "..."
        elif button < 0: "---"
        else: controller_button_name(button)
      if selected:
        igPushStyleColor_Vec4(cint(ImGui_Col_Button), w.hovered_col)
      if igButton(cstring(btn_text & "##padds" & $inp), btn_size):
        w.ds_selection = some(inp)
        w.selection = none(Input)
      if selected:
        igPopStyleColor(1)
      igSameLine(0, -1)
      igText(cstring(toUpperAscii($inp) & " (DS)"))
    igTextDisabled("X and Y count only in DS games, where they come")
    igTextDisabled("before the buttons above.")

  igTextDisabled("Left stick acts as the D-pad; holding the right")
  igTextDisabled("trigger fast-forwards. These are not rebindable.")

proc reset*(w: ControllerWidget) =
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
  w.rumble = w.cfg.gb_rumble
  w.editing = initTable[cint, Input]()
  for k, v in w.cfg.controller_bindings.pairs:
    w.editing[k] = v
  w.ds_editing = w.cfg.nds_controller_bindings

proc apply_to*(w: ControllerWidget; cfg: Config) =
  cfg.controller_bindings = initTable[cint, Input]()
  for k, v in w.editing.pairs:
    cfg.controller_bindings[k] = v
  cfg.nds_controller_bindings = w.ds_editing
  cfg.gb_rumble = w.rumble

proc apply*(w: ControllerWidget) =
  w.apply_to(w.cfg)
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
