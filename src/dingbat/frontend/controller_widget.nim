import std/[tables, options]
import sdl3_nim
import imguin/cimgui
import ../common/[input, config]

type
  ControllerWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    visible*:     bool
    hovered_col:  ImVec4

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
  w.visible and w.selection.isSome()

proc button_released*(w: ControllerWidget; button: cint) =
  # Buttons past DPAD_RIGHT (paddles, touchpad on newer SDL) have no name in
  # our table and would not round-trip through the yaml config
  if controller_button_name(button).len == 0: return
  if w.selection.isSome():
    let sel = w.selection.get()
    # Remove old binding for this input
    var old_btn: cint = -1
    for k, v in w.editing.pairs:
      if v == sel: old_btn = k; break
    if old_btn >= 0: w.editing.del(old_btn)
    w.editing[button] = sel
    # Advance to next input
    let next_ord = ord(sel) + 1
    if next_ord <= ord(high(Input)):
      w.selection = some(Input(next_ord))
    else:
      w.selection = none(Input)

proc find_button_for_input(w: ControllerWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc controller_connected(): bool =
  SDL_HasGamepad()

proc render*(w: ControllerWidget) =
  if not controller_connected():
    igText("No controller detected")
    w.selection = none(Input)
    return

  if igButton("Reset to defaults", ImVec2(x: 0, y: 0)):
    w.editing = default_controller_bindings()
    w.selection = none(Input)

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
    if selected:
      igPopStyleColor(1)
    igSameLine(0, -1)
    igText(cstring($inp))

  igTextDisabled("Left stick acts as the D-pad; holding the right")
  igTextDisabled("trigger fast-forwards. These are not rebindable.")

proc reset*(w: ControllerWidget) =
  w.selection = none(Input)
  w.editing = initTable[cint, Input]()
  for k, v in w.cfg.controller_bindings.pairs:
    w.editing[k] = v

proc apply*(w: ControllerWidget) =
  w.cfg.controller_bindings = initTable[cint, Input]()
  for k, v in w.editing.pairs:
    w.cfg.controller_bindings[k] = v
  w.selection = none(Input)
