import std/[tables, options, strutils]
import sdl2 except init, quit
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/[input, config]
import held_input

type
  KeybindingsWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    visible*:     bool
    hovered_col:  ImVec4
    # The DS's X and Y, shown (and captured after R) only with DS Beta on
    show_ds*:      bool
    ds_editing*:   Table[cint, DsInput]
    ds_selection*: Option[DsInput]

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
  w.visible and (w.selection.isSome() or w.ds_selection.isSome())

proc key_released*(w: KeybindingsWidget; keycode: cint) =
  # A key the game can never receive is refused; the capture stays on the
  # input, which keeps its old key.
  if not bindable_key(keycode): return
  if w.selection.isSome():
    let sel = w.selection.get()
    var old_key: cint = -1
    for k, v in w.editing.pairs:
      if v == sel: old_key = k; break
    if old_key >= 0: w.editing.del(old_key)
    w.editing[keycode] = sel
    let next_ord = ord(sel) + 1
    if next_ord <= ord(high(Input)):
      w.selection = some(Input(next_ord))
    else:
      w.selection = none(Input)
      if w.show_ds: w.ds_selection = some(DsInput.low)
  elif w.ds_selection.isSome():
    let sel = w.ds_selection.get()
    var old_key: cint = -1
    for k, v in w.ds_editing.pairs:
      if v == sel: old_key = k; break
    if old_key >= 0: w.ds_editing.del(old_key)
    w.ds_editing[keycode] = sel
    w.ds_selection = if sel < DsInput.high: some(succ(sel)) else: none(DsInput)

proc find_key_for_input(w: KeybindingsWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc load_preset(w: KeybindingsWidget; bindings: Table[cint, Input];
                 ds: Table[cint, DsInput]) =
  w.editing = initTable[cint, Input]()
  for k, v in bindings.pairs:
    w.editing[k] = v
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
  # The DS keys are left as they are where they are not on screen
  if w.show_ds: w.ds_editing = ds

proc key_label(keycode: cint): string =
  # Scancode-masked keycodes (bit 30) go back through the scancode so
  # getKeyName yields the keyboard map's printable character.
  if keycode < 0: "---"
  elif (keycode and 0x40000000) != 0:
    $getKeyName(getKeyFromScancode(cast[ScanCode](keycode xor 0x40000000)))
  else: $getKeyName(keycode)

proc render*(w: KeybindingsWidget) =
  if igBeginCombo("Preset", "Select preset...", 0):
    if igSelectable_Bool("Default", false, 0, ImVec2(x: 0, y: 0)):
      w.load_preset(default_keybindings(), default_ds_keybindings())
    if igSelectable_Bool("Home-row", false, 0, ImVec2(x: 0, y: 0)):
      w.load_preset(homerow_keybindings(), homerow_ds_keybindings())
    igEndCombo()

  let btn_size = ImVec2(x: 48, y: 0)
  for inp in Input:
    let selected = w.selection.isSome() and w.selection.get() == inp
    let btn_text = key_label(w.find_key_for_input(inp))
    if selected:
      igPushStyleColor_Vec4(cint(ImGui_Col_Button), w.hovered_col)
    if igButton(cstring(btn_text & "##" & $inp), btn_size):
      w.selection = some(inp)
      w.ds_selection = none(DsInput)
    if selected:
      igPopStyleColor(1)
    igSameLine(0, -1)
    igText(cstring($inp))

  if not w.show_ds: return
  for inp in DsInput:
    let selected = w.ds_selection.isSome() and w.ds_selection.get() == inp
    var keycode: cint = -1
    for k, v in w.ds_editing.pairs:
      if v == inp: keycode = k; break
    if selected:
      igPushStyleColor_Vec4(cint(ImGui_Col_Button), w.hovered_col)
    if igButton(cstring(key_label(keycode) & "##ds" & $inp), btn_size):
      w.ds_selection = some(inp)
      w.selection = none(Input)
    if selected:
      igPopStyleColor(1)
    igSameLine(0, -1)
    igText(cstring(toUpperAscii($inp) & " (DS)"))
  igTextDisabled("X and Y count only in DS games, where they come before")
  igTextDisabled("the keys above.")

proc reset*(w: KeybindingsWidget) =
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
  w.editing = initTable[cint, Input]()
  for k, v in w.cfg.keybindings.pairs:
    w.editing[k] = v
  w.ds_editing = w.cfg.nds_keybindings

proc apply_to*(w: KeybindingsWidget; cfg: Config) =
  cfg.keybindings = initTable[cint, Input]()
  for k, v in w.editing.pairs:
    cfg.keybindings[k] = v
  cfg.nds_keybindings = w.ds_editing

proc apply*(w: KeybindingsWidget) =
  w.apply_to(w.cfg)
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
