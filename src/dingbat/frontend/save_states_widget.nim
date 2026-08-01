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
    notice*:   string  ## last load failure, shown under the grid.
                       ## The core says exactly why a state was
                       ## refused; before this the native app threw
                       ## that away and the user saw nothing at all.
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

proc mark_stale*(w: SaveStatesWidget) =
  ## Re-run on_open on the next render. Call after a state file changes
  ## outside the widget (Quick Save writes slot 1 while the window is open,
  ## which otherwise kept showing "Empty").
  w.was_open = false

proc dim(): ImVec4 = ImVec4(x: 0.6, y: 0.6, z: 0.6, w: 1.0)
proc sel_col(): ImVec4 = ImVec4(x: 0.26, y: 0.59, z: 0.98, w: 1.0)
# Surround for an unselected thumbnail cell: near-black, so the bright blue
# sel_col ring is unmistakably "selected" (the default Col_Button blue read
# as a second selection ring around every thumbnail).
proc thumb_bg(): ImVec4 = ImVec4(x: 0.09, y: 0.10, z: 0.12, w: 1.0)

# imguin's igCalcTextSize tracks a cimgui signature change: older releases
# fill an out-pointer, current ones return the ImVec2 by value. CI installs
# the latest imguin while dev machines may hold the older pin, so support
# both — the two signatures are disjoint, exactly one branch compiles.
proc calc_text_size(text: string): ImVec2 =
  when compiles(igCalcTextSize(cstring(text), nil, false, -1.0'f32)):
    let s = igCalcTextSize(cstring(text), nil, false, -1.0'f32)
    ImVec2(x: s.x, y: s.y)
  else:
    var sz: ImVec2
    igCalcTextSize(addr sz, cstring(text), nil, false, -1.0'f32)
    sz

proc fit_caption(text: string; avail: float32): string =
  ## Truncate `text` with a trailing ".." so it renders within `avail` px.
  ## Slot captions are plain ASCII (timestamps), so byte truncation is safe.
  if calc_text_size(text).x <= avail: return text
  result = text
  while result.len > 1:
    result.setLen(result.len - 1)
    let test = result & ".."
    if calc_text_size(test).x <= avail: return test
  result = ""

proc render*(w: SaveStatesWidget) =
  if not w.window:
    w.was_open = false
    return
  # Refresh slot thumbnails/metadata the moment the window opens.
  if not w.was_open:
    w.was_open = true
    if w.on_open != nil: w.on_open()

  # Tall enough that all three rows AND the action row fit without scrolling
  # (the old 392 default put Save/Load/Delete below the fold), but never
  # taller than the app window itself: at the default 3x GBA size the fixed
  # 580 default overflowed the viewport and clipped the pinned action row
  # entirely. Uniform one-caption-line cells need ~500px; the grid child
  # scrolls when even that doesn't fit, the action row stays pinned.
  # (Position is pinned too: imgui's cascading default of y=60 pushed even a
  # height-clamped window past the bottom edge.)
  let work_h = igGetMainViewport().WorkSize.y
  igSetNextWindowPos(ImVec2(x: 60, y: 28), cint(ImGui_Cond_FirstUseEver),
                     ImVec2(x: 0, y: 0))
  # Width 470: 3 x 136px cells + 2 x 10 spacing + window padding + room for
  # the grid child's scrollbar, which otherwise ate into the third column's
  # captions whenever the grid had to scroll.
  igSetNextWindowSize(ImVec2(x: 470, y: min(500.0'f32, work_h - 56.0'f32)),
                      cint(ImGui_Cond_FirstUseEver))
  if igBegin("Save States", addr w.window, 0):
    if not w.have_rom:
      igTextUnformatted("Load a game to use save states.", nil)
    else:
      igTextUnformatted("Click a slot, then Save or Load.", nil)
      igTextColored(dim(), "Slot 1 is the Quick slot (Quick Save / Quick Load).")
      igSeparator()

      # The slot grid lives in a child region that reserves room for the
      # action row below, so Save/Load/Delete stay reachable at any window
      # size — a too-small window scrolls the grid, never the buttons.
      let footer = igGetFrameHeightWithSpacing() + 10.0'f32
      discard igBeginChild_Str("##slots", ImVec2(x: 0, y: -footer),
                               ImGuiChildFlags(0), ImGuiWindowFlags(0))
      # Every cell is the same fixed-size button whether it holds a thumbnail
      # or not — the old code sized ImageButton to the thumbnail's native
      # framebuffer dimensions (240x160 for GBA), so used slots dwarfed empty
      # ones and the grid rows fell out of alignment. Thumbnails are drawn
      # letterboxed and centered inside the cell instead; the small inset
      # keeps a visible ring of button color around a full-bleed thumb so the
      # blue selected state still reads.
      const CELL_W = 136.0'f32
      const CELL_H = 90.0'f32   # 3:2 like the GBA screen; GB (10:9) letterboxes
      const THUMB_INSET = 3.0'f32
      for i in 0 ..< NUM_SLOTS:
        igPushID_Int(cint(i))
        let selected = i == w.selected
        let has_thumb = w.slots[i].used and w.slots[i].tex != 0
        if selected:
          igPushStyleColor_Vec4(cint(ImGui_Col_Button), sel_col())
        elif has_thumb:
          igPushStyleColor_Vec4(cint(ImGui_Col_Button), thumb_bg())
        igBeginGroup()
        let cell_x = igGetCursorPosX()
        let slot = w.slots[i]
        var clicked = false
        if has_thumb:
          clicked = igButton("##thumb", ImVec2(x: CELL_W, y: CELL_H))
          var rmin, rmax: ImVec2
          # imguin <= 1.92.4 uses a pOut out-param; later versions return by
          # value (same drift calc_text_size above absorbs for igCalcTextSize)
          when compiles(igGetItemRectMin(addr rmin)):
            igGetItemRectMin(addr rmin)
            igGetItemRectMax(addr rmax)
          else:
            let pmin = igGetItemRectMin()
            let pmax = igGetItemRectMax()
            rmin = ImVec2(x: pmin.x, y: pmin.y)
            rmax = ImVec2(x: pmax.x, y: pmax.y)
          let fit_w = CELL_W - THUMB_INSET * 2
          let fit_h = CELL_H - THUMB_INSET * 2
          let scale = min(fit_w / max(slot.w, 1.0'f32),
                          fit_h / max(slot.h, 1.0'f32))
          let dw = slot.w * scale
          let dh = slot.h * scale
          let x0 = (rmin.x + rmax.x - dw) * 0.5'f32
          let y0 = (rmin.y + rmax.y - dh) * 0.5'f32
          let tref = ImTextureRef(internal_TexData: nil,
                                  internal_TexID: ImTextureID(slot.tex))
          ImDrawList_AddImage(igGetWindowDrawList(), tref,
                              ImVec2(x: x0, y: y0),
                              ImVec2(x: x0 + dw, y: y0 + dh),
                              ImVec2(x: 0, y: 0), ImVec2(x: 1, y: 1),
                              0xFFFFFFFF'u32)
        elif slot.used:
          # State file with no embedded thumbnail (older save format).
          clicked = igButton("No preview", ImVec2(x: CELL_W, y: CELL_H))
        else:
          clicked = igButton("Empty", ImVec2(x: CELL_W, y: CELL_H))
        # Caption: slot number (+ "Quick" tag) on the left, timestamp (or
        # "empty") right-aligned to the cell's edge — one line per slot, so
        # every row of cells sits at the same height. The caption must never
        # exceed CELL_W or it widens the whole group and misaligns the grid
        # columns, so the timestamp truncates to the space the tag leaves.
        let tag = $(i + 1) & (if i == 0: " · Quick" else: "")
        igTextColored(dim(), cstring(tag))
        igSameLine(0, 0)
        let avail = cell_x + CELL_W - igGetCursorPosX() - 8.0'f32
        let cap = fit_caption(if slot.label.len > 0: slot.label else: "empty",
                              avail)
        igSetCursorPosX(cell_x + CELL_W - calc_text_size(cap).x)
        if slot.label.len > 0:
          igTextUnformatted(cstring(cap), nil)
        else:
          igTextColored(dim(), cstring(cap))
        igEndGroup()
        if selected or has_thumb:
          igPopStyleColor(1)
        if clicked: w.selected = i
        igPopID()
        if i mod 3 != 2:
          igSameLine(0, 10)
      igEndChild()

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
      # Save + Load, right-aligned. Positioned from the window width (a stable
      # imguin API) rather than igGetContentRegionAvail, whose ImVec2-return
      # signature differs across imguin versions and broke the Windows build.
      const PAD = 8.0'f32
      igSameLine(0, 0)
      igSetCursorPosX(max(igGetCursorPosX(),
                          igGetWindowWidth() - (BTN_W * 2 + GAP + PAD)))
      if igButton("Save", ImVec2(x: BTN_W, y: 0)):
        if w.on_save != nil: w.on_save(w.selected)
        if w.on_open != nil: w.on_open()   # refresh the just-written thumbnail
      igSameLine(0, GAP)
      if not sel.used: igBeginDisabled(true)
      if igButton("Load", ImVec2(x: BTN_W, y: 0)):
        w.notice = ""
        if w.on_load != nil: w.on_load(w.selected)
      if not sel.used: igEndDisabled()
      if w.notice.len > 0:
        igTextColored(ImVec4(x: 1.0, y: 0.45, z: 0.42, w: 1.0),
                      cstring(w.notice))
  igEnd()
