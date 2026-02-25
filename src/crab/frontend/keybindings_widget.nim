import std/[tables, options]
import sdl2 except init, quit
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/[input, config]

type
  KeybindingsWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    visible*:     bool
    hovered_col:  ImVec4

proc new_keybindings_widget*(cfg: Config): KeybindingsWidget =
  let col_ptr = igGetStyleColorVec4(cint(ImGui_Col_ButtonHovered))
  let col = if col_ptr != nil: col_ptr[] else: ImVec4(x: 0.4, y: 0.4, z: 0.8, w: 1.0)
  result = KeybindingsWidget(
    cfg:         cfg,
    editing:     initTable[cint, Input](),
    selection:   none(Input),
    hovered_col: col,
  )

proc wants_input*(w: KeybindingsWidget): bool =
  w.visible and w.selection.isSome()

proc key_released*(w: KeybindingsWidget; keycode: cint) =
  if w.selection.isSome():
    let sel = w.selection.get()
    # Remove old binding for this input
    var old_key: cint = -1
    for k, v in w.editing.pairs:
      if v == sel: old_key = k; break
    if old_key >= 0: w.editing.del(old_key)
    w.editing[keycode] = sel
    # Advance to next input
    let next_ord = ord(sel) + 1
    if next_ord <= ord(high(Input)):
      w.selection = some(Input(next_ord))
    else:
      w.selection = none(Input)

proc find_key_for_input(w: KeybindingsWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc render*(w: KeybindingsWidget) =
  let btn_size = ImVec2(x: 48, y: 0)
  for inp in Input:
    let selected = w.selection.isSome() and w.selection.get() == inp
    let keycode  = w.find_key_for_input(inp)
    # getKeyName returns the printable character for printable keycodes (e.g. ";")
    # and a word name for non-printable ones (e.g. "Return").
    # For scancode-masked keycodes (bit 30 set), convert back through the
    # scancode to get the printable character from the keyboard map.
    let btn_text =
      if keycode < 0: "---"
      elif (keycode and 0x40000000) != 0:
        $getKeyName(getKeyFromScancode(ScanCode(keycode xor 0x40000000)))
      else: $getKeyName(keycode)
    if selected:
      igPushStyleColor_Vec4(cint(ImGui_Col_Button), w.hovered_col)
    if igButton(cstring(btn_text & "##" & $inp), btn_size):
      w.selection = some(inp)
    if selected:
      igPopStyleColor(1)
    igSameLine(0, -1)
    igText(cstring($inp))

proc reset*(w: KeybindingsWidget) =
  w.selection = none(Input)
  w.editing = initTable[cint, Input]()
  for k, v in w.cfg.keybindings.pairs:
    w.editing[k] = v

proc apply*(w: KeybindingsWidget) =
  w.cfg.keybindings = initTable[cint, Input]()
  for k, v in w.editing.pairs:
    w.cfg.keybindings[k] = v
  w.selection = none(Input)
