## ImGui "Save States" window: a 3x3 grid of nine slots, each showing a
## thumbnail of the saved state (or an "Empty" placeholder). The user clicks a
## slot to select it, then Save or Load. Slot 0 is the "Quick" slot shared with
## the Quick Save / Quick Load menu items and hotkeys.
##
## The widget owns no core state and does no file or GL work itself: the app
## supplies each slot's thumbnail texture + metadata via `set_slot`, refreshes
## on open through `on_open`, and performs the actual save/load in the
## `on_save` / `on_load` callbacks.

import imguin/cimgui

const NUM_SLOTS* = 9

type
  StateSlot* = object
    used*:  bool
    label*: string     ## timestamp text, or "" when empty
    tex*:   uint64     ## GL texture id (0 = none), used as ImTextureID
    w*, h*: float32    ## thumbnail display size in pixels
  SaveStatesWidget* = ref object
    window*:   bool
    selected*: int
    have_rom*: bool
    slots*:    array[NUM_SLOTS, StateSlot]
    on_open*:   proc() {.closure.}         ## (re)populate slots + textures
    on_save*:   proc(slot: int) {.closure.}
    on_load*:   proc(slot: int) {.closure.}
    on_delete*: proc(slot: int) {.closure.}
    was_open:  bool

proc new_save_states_widget*(): SaveStatesWidget =
  SaveStatesWidget(window: false, selected: 0)

proc set_slot*(w: SaveStatesWidget; i: int; used: bool; label: string;
               tex: uint64; tw, th: float32) =
  if i notin 0 ..< NUM_SLOTS: return
  w.slots[i] = StateSlot(used: used, label: label, tex: tex, w: tw, h: th)

proc dim(): ImVec4 = ImVec4(x: 0.6, y: 0.6, z: 0.6, w: 1.0)
proc sel_col(): ImVec4 = ImVec4(x: 0.26, y: 0.59, z: 0.98, w: 1.0)

proc render*(w: SaveStatesWidget) =
  if not w.window:
    w.was_open = false
    return
  # Refresh slot thumbnails/metadata the moment the window opens.
  if not w.was_open:
    w.was_open = true
    if w.on_open != nil: w.on_open()

  igSetNextWindowSize(ImVec2(x: 452, y: 392), cint(ImGui_Cond_FirstUseEver))
  if igBegin("Save States", addr w.window, 0):
    if not w.have_rom:
      igTextUnformatted("Load a game to use save states.", nil)
    else:
      igTextUnformatted("Click a slot, then Save or Load.", nil)
      igTextColored(dim(), "Slot 1 is the Quick slot (Quick Save / Quick Load).")
      igSeparator()

      const CELL_W = 120.0'f32
      const CELL_H = 80.0'f32
      for i in 0 ..< NUM_SLOTS:
        igPushID_Int(cint(i))
        let selected = i == w.selected
        if selected:
          igPushStyleColor_Vec4(cint(ImGui_Col_Button), sel_col())
        igBeginGroup()
        let slot = w.slots[i]
        var clicked = false
        if slot.used and slot.tex != 0:
          let tref = ImTextureRef(internal_TexData: nil,
                                  internal_TexID: ImTextureID(slot.tex))
          clicked = igImageButton("##thumb", tref, ImVec2(x: slot.w, y: slot.h),
                                  ImVec2(x: 0, y: 0), ImVec2(x: 1, y: 1),
                                  ImVec4(x: 0, y: 0, z: 0, w: 1),
                                  ImVec4(x: 1, y: 1, z: 1, w: 1))
        else:
          clicked = igButton("Empty", ImVec2(x: CELL_W, y: CELL_H))
        let tag = $(i + 1) & (if i == 0: "  Quick" else: "")
        igTextColored(dim(), cstring(tag))
        if slot.label.len > 0:
          igTextUnformatted(cstring(slot.label), nil)
        else:
          igTextColored(dim(), "(empty)")
        igEndGroup()
        if selected:
          igPopStyleColor(1)
        if clicked: w.selected = i
        igPopID()
        if i mod 3 != 2:
          igSameLine(0, 10)

      igSeparator()
      let sel = w.slots[w.selected]
      const BTN_W = 90.0'f32
      const GAP = 10.0'f32
      # Delete on the left (disabled when the slot is empty).
      if not sel.used: igBeginDisabled(true)
      if igButton("Delete", ImVec2(x: BTN_W, y: 0)):
        if w.on_delete != nil: w.on_delete(w.selected)
        if w.on_open != nil: w.on_open()
      if not sel.used: igEndDisabled()
      # Save + Load, right-aligned.
      igSameLine(0, 0)
      var avail: ImVec2
      igGetContentRegionAvail(addr avail)
      igSetCursorPosX(igGetCursorPosX() + max(0.0'f32, avail.x - (BTN_W * 2 + GAP)))
      if igButton("Save", ImVec2(x: BTN_W, y: 0)):
        if w.on_save != nil: w.on_save(w.selected)
        if w.on_open != nil: w.on_open()   # refresh the just-written thumbnail
      igSameLine(0, GAP)
      if not sel.used: igBeginDisabled(true)
      if igButton("Load", ImVec2(x: BTN_W, y: 0)):
        if w.on_load != nil: w.on_load(w.selected)
      if not sel.used: igEndDisabled()
  igEnd()
