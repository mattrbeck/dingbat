## Settings > Keybindings as edited, until Apply, and its key capture
## (rows: config_editor.nim).

import std/[tables, options]
import sdl3
import ../common/[input, config]
import held_input

type
  KeybindingsWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    visible*:     bool
    # The DS's X and Y, shown (and captured after R) only with DS Beta on
    show_ds*:      bool
    ds_editing*:   Table[cint, DsInput]
    ds_selection*: Option[DsInput]

proc new_keybindings_widget*(cfg: Config): KeybindingsWidget =
  KeybindingsWidget(
    cfg:         cfg,
    editing:     initTable[cint, Input](),
    selection:   none(Input),
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

proc find_key_for_input*(w: KeybindingsWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc load_preset*(w: KeybindingsWidget; bindings: Table[cint, Input];
                 ds: Table[cint, DsInput]) =
  w.editing = initTable[cint, Input]()
  for k, v in bindings.pairs:
    w.editing[k] = v
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
  # The DS keys are left as they are where they are not on screen
  if w.show_ds: w.ds_editing = ds

proc key_label*(keycode: cint): string =
  # Scancode-masked keycodes (bit 30) go back through the scancode so
  # getKeyName yields the keyboard map's printable character.
  if keycode < 0: "---"
  elif (keycode and 0x40000000) != 0:
    $getKeyName(getKeyFromScancode(cast[Scancode](keycode xor 0x40000000), 0, false))
  else: $getKeyName(Keycode(keycode))

proc ds_key_for*(w: KeybindingsWidget; inp: DsInput): cint =
  for k, v in w.ds_editing.pairs:
    if v == inp: return k
  -1

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
