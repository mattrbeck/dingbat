## Settings > Controller as edited, until Apply, and its button capture
## (rows: config_editor.nim).

import std/[tables, options]
import sdl3
import ../common/[input, config]

type
  ControllerWidget* = ref object
    cfg*:         Config
    editing*:     Table[cint, Input]
    selection*:   Option[Input]
    rumble*:      bool
    visible*:     bool
    # The DS's X and Y, shown (and captured after R) only with DS Beta on
    show_ds*:      bool
    ds_editing*:   Table[cint, DsInput]
    ds_selection*: Option[DsInput]

proc new_controller_widget*(cfg: Config): ControllerWidget =
  ControllerWidget(
    cfg:         cfg,
    editing:     initTable[cint, Input](),
    selection:   none(Input),
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

proc find_button_for_input*(w: ControllerWidget; inp: Input): cint =
  for k, v in w.editing.pairs:
    if v == inp: return k
  return -1

proc ds_button_for*(w: ControllerWidget; inp: DsInput): cint =
  for k, v in w.ds_editing.pairs:
    if v == inp: return k
  -1

proc controller_connected*(): bool = hasGamepad()

proc load_defaults*(w: ControllerWidget) =
  w.editing = default_controller_bindings()
  w.selection = none(Input)
  w.ds_selection = none(DsInput)
  if w.show_ds: w.ds_editing = default_ds_controller_bindings()

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
