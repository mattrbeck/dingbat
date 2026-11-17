## The Settings window in Dear ImGui: config_editor's tabs drawn row by row,
## the Apply / Revert / OK / Reset to Defaults row, and the questions on
## closing. Windows, Linux, and macOS with DINGBAT_IMGUI_MENU=1.
##
## It opens as tall as its tallest tab, so no tab scrolls, up to the app
## window's height less a margin; only a window too short for that scrolls
## the tab pane, never the button row. Each open measures every tab first,
## drawn unseen for a frame each, so changing tab never resizes it. A height
## the player drags it to holds for the rest of the run (not saved: the next
## run fits it again); either way it never reaches past the window's bottom,
## and grows back when the window does.

import std/[strutils, tables]
import imguin/cimgui
import config_editor
import settings_model
import file_explorer
import notice
import util, ui_fonts
from save_states_widget import calc_text_size

const INDENT = 106'f32   # rows under a label, in points
const BUF_SIZE = 512

var tab_request* = -1  ## a tab to show at the next frame (gui_driver `app tab`)

const TOP = 28.0f32      # where it first opens, in points: just under the menu bar
const MARGIN = 12.0f32   # below it, at its tallest

type DrawnRow = object
  tab, label: string
  a, b: ImVec2

var
  measuring = -1         # the tab being measured at the open; -1 none
  content_h: seq[float32]  # each tab's rows' height as last drawn (-1 not yet)
  chrome_h = 0'f32       # the window less its tab pane
  back_tab = 0           # the tab to show once measured
  shown_tab = 0          # the tab on screen
  settling = false       # measured, back_tab not yet on screen: still unseen
  user_h = 0'f32         # a height the player dragged it to (0: none)
  last_h, last_w, last_y = 0'f32  # the window as the last frame left it
  scrolls = false        # the tab pane has more than it shows
  drawn: seq[DrawnRow]   # the rows as last drawn (gui_driver `settings imgui`)
  drawing_tab = ""
  win_a, win_b: ImVec2

proc item_rect(): (ImVec2, ImVec2) =
  ## The last item's corners (imguin's out-param or by-value binding)
  var a, b: ImVec2
  when compiles(igGetItemRectMin(addr a)):
    igGetItemRectMin(addr a)
    igGetItemRectMax(addr b)
  else:
    let p = igGetItemRectMin()
    let q = igGetItemRectMax()
    a = ImVec2(x: p.x, y: p.y)
    b = ImVec2(x: q.x, y: q.y)
  (a, b)

proc note(label: string) =
  let (a, b) = item_rect()
  drawn.add DrawnRow(tab: drawing_tab, label: label, a: a, b: b)

proc fit_h(): float32 =
  ## Tall enough for every tab measured
  for h in content_h: result = max(result, h)
  result += chrome_h

proc dump*(): string =
  ## The window as last drawn (gui_driver `settings imgui`)
  proc rect(a, b: ImVec2): string =
    $int(a.x) & " " & $int(a.y) & " " & $int(b.x - a.x) & " " & $int(b.y - a.y)
  if last_h <= 0: return "closed\n"
  result = "window|" & rect(win_a, win_b) & "|" & (if scrolls: "scroll" else: "noscroll") &
           "|fit " & $int(fit_h()) & "\n"
  for r in drawn: result.add r.tab & "|" & r.label & "|" & rect(r.a, r.b) & "\n"

# The text each path field edits; ImGui writes into it in place
var path_bufs: Table[SettingId, array[BUF_SIZE, char]]

proc buf_text(b: var array[BUF_SIZE, char]): string = $cast[cstring](addr b[0])

proc put_text(b: var array[BUF_SIZE, char]; s: string) =
  zeroMem(addr b[0], BUF_SIZE)
  let n = min(s.len, BUF_SIZE - 1)
  if n > 0: copyMem(addr b[0], cstring(s), n)

proc binding_width(rows: seq[SettingRow]): float32 =
  ## One width for a list's binding buttons: theirs, or the widest key name's
  for r in rows:
    if r.kind == rkBinding:
      result = max(result, max(ui_px(r.width), calc_text_size(r.text).x +
                                             igGetStyle().FramePadding.x * 2))

proc render_rows(ed: ConfigEditor; rows: seq[SettingRow]) =
  let bind_w = binding_width(rows)
  for r in rows:
    if not r.shown: continue
    case r.kind
    of rkLabel:
      if r.title.len > 0:
        igText(cstring(r.title))
        note(r.title)
        if r.help.len > 0:
          igSameLine(0, -1)
          help_marker(r.help)
      if r.rows.len > 0:
        igIndent(ui_px(INDENT))
        ed.render_rows(r.rows)
        igUnindent(ui_px(INDENT))
    of rkToggle:
      var on = r.on
      igBeginDisabled(not r.enabled)
      if igCheckbox(cstring(r.title), addr on): ed.set_value(r.id, ord(on))
      note((if r.on: "[x] " else: "") & r.title)
      igEndDisabled()
      if r.help.len > 0:
        igSameLine(0, -1)
        help_marker(r.help)
    of rkChoice:
      var v = cint(r.value)
      for i, opt in r.options:
        if r.inline and i > 0: igSameLine(0, -1)
        igBeginDisabled(not r.option_on[i])
        if igRadioButton_IntPtr(cstring(opt & "##" & $r.id), addr v, cint(r.values[i])):
          ed.set_value(r.id, int(v))
        note((if r.values[i] == r.value: "[x] " else: "") & opt)
        igEndDisabled()
    of rkPath:
      igText(cstring(r.title))
      igSameLine(ui_px(r.label_col), -1)
      help_marker(r.help)
      igSameLine(0, -1)
      var buf = path_bufs.getOrDefault(r.id)
      if buf.buf_text != r.text: buf.put_text(r.text)
      if not r.valid:
        igPushStyleColor_Vec4(cint(ImGui_Col_Text),
                              ImVec4(x: 1.0'f32, y: 0.5'f32, z: 0.5'f32, w: 1.0'f32))
      if r.width > 0: igSetNextItemWidth(ui_px(r.width))
      discard igInputTextWithHint(cstring("##" & $r.id), cstring(r.hint),
                                  cast[cstring](addr buf[0]), BUF_SIZE.csize_t, 0, nil, nil)
      if not r.valid: igPopStyleColor(1)
      path_bufs[r.id] = buf
      if buf.buf_text != r.text: ed.set_value(r.id, 0, buf.buf_text)
      igSameLine(0, -1)
      let browse = igButton(cstring("Browse##" & $r.id), ImVec2(x: 0, y: 0))
      let id = r.id
      ed.fe.render(r.title.strip(chars = {':'}), browse, [], proc(path: string) =
        ed.set_value(id, 0, path))
    of rkNote:
      with_font(fRegular, SMALL_PX):
        for line in r.text.split('\n'): igTextDisabled("%s", cstring(line))
    of rkText:
      igText("%s", cstring(r.text))
    of rkSeparator:
      igSeparator()
    of rkFold:
      if igCollapsingHeader_TreeNodeFlags(cstring(r.title), 0):
        ed.render_rows(r.rows)
    of rkPreset:
      if igBeginCombo(cstring(r.title), cstring(r.hint), 0):
        for i, opt in r.options:
          if igSelectable_Bool(cstring(opt), false, 0, ImVec2(x: 0, y: 0)):
            ed.activate(r.id, i)
        igEndCombo()
    of rkBinding:
      if r.on:
        let col = igGetStyleColorVec4(cint(ImGui_Col_ButtonHovered))
        igPushStyleColor_Vec4(cint(ImGui_Col_Button),
          if col != nil: col[] else: ImVec4(x: 0.4, y: 0.4, z: 0.8, w: 1.0))
      if igButton(cstring(r.text & "##" & $r.id & $r.arg), ImVec2(x: bind_w, y: 0)):
        ed.activate(r.id, r.arg)
      if r.on: igPopStyleColor(1)
      igSameLine(0, -1)
      igText(cstring(r.title))
    of rkButton:
      if igButton(cstring(r.title), ImVec2(x: 0, y: 0)): ed.activate(r.id, r.arg)
      note(r.title)

proc render*(ed: ConfigEditor) =
  if ed.native: return
  let n_tabs = TAB_TITLES.len
  if ed.open and not ed.prev_open:
    ed.do_reset()
    measuring = 0
    settling = false
    content_h = newSeq[float32](n_tabs)
    for h in content_h.mitems: h = -1
    back_tab = shown_tab
  ed.prev_open = ed.open
  # Only the tab bar below says a tab is on screen: closed, or collapsed
  # (igBegin false), none is, so no capture keeps taking keys.
  ed.show_tab(-1)
  drawn.setLen(0)
  if not ed.open:
    last_h = 0
    return

  # Sized here, not AlwaysAutoResize: that re-fits on every tab switch and
  # cannot host the negative-sized footer child below.
  let vp = igGetMainViewport()
  let unseen = measuring >= 0 or settling
  igSetNextWindowPos(ImVec2(x: ui_px(60), y: ui_px(TOP)),
                     cint(ImGui_Cond_FirstUseEver), ImVec2(x: 0, y: 0))
  igSetNextWindowSize(ImVec2(x: ui_px(560),
                             y: min(ui_px(460), vp.WorkSize.y - ui_px(TOP + MARGIN))),
                      cint(ImGui_Cond_FirstUseEver))
  var set_h = 0'f32
  if not unseen and last_h > 0:
    let bottom = vp.WorkPos.y + vp.WorkSize.y - ui_px(MARGIN)
    var top = last_y
    # Too low for a usable window: up, as far as the window's top
    if bottom - top < ui_px(160):
      top = max(vp.WorkPos.y, bottom - ui_px(160))
      igSetNextWindowPos(ImVec2(x: win_a.x, y: top), cint(ImGui_Cond_Always),
                         ImVec2(x: 0, y: 0))
    let want = max(ui_px(80), min(if user_h > 0: user_h else: fit_h(), bottom - top))
    if abs(want - last_h) > 0.5:
      set_h = want
      igSetNextWindowSize(ImVec2(x: last_w, y: want), cint(ImGui_Cond_Always))
  # Unseen: below one 8-bit step, not 0, at which Begin draws nothing at all
  if unseen: igPushStyleVar_Float(cint(ImGui_StyleVar_Alpha), 0.001)
  let shown = igBegin("Settings", addr ed.open,
                      if unseen: cint(ImGui_WindowFlags_NoInputs) else: 0)
  if shown and not igIsWindowCollapsed():
    let h = igGetWindowHeight()
    # A height this frame did not ask for is the player's drag
    if not unseen and last_h > 0 and abs(h - (if set_h > 0: set_h else: last_h)) > 0.5:
      user_h = h
    last_h = h
    last_w = igGetWindowWidth()
    var p: ImVec2
    when compiles(igGetWindowPos(addr p)): igGetWindowPos(addr p)
    else:
      let q = igGetWindowPos()
      p = ImVec2(x: q.x, y: q.y)
    last_y = p.y
    win_a = p
    win_b = ImVec2(x: p.x + last_w, y: p.y + h)
  # The X: a capture in progress ends with it; edits Apply would save are
  # asked about first, and the window stays open until the answer.
  if not ed.open:
    ed.end_captures()
    if ed.has_unapplied_edits():
      ed.open = true
      igOpenPopup_Str("Discard changes?", 0)
  if shown:
    # The tab pane reserves room for the action row: a too-short window
    # scrolls the pane, never the buttons.
    let footer = igGetFrameHeightWithSpacing() + ui_px(10)
    let win_h = igGetWindowHeight()
    discard igBeginChild_Str("##settings_tabs", ImVec2(x: 0, y: -footer),
                             ImGuiChildFlags(0), ImGuiWindowFlags(0))
    let pick = if measuring >= 0: measuring elif settling: back_tab else: tab_request
    var on_screen = -1
    if igBeginTabBar("SettingsTabBar", 0):
      for i, tab in ed.tabs():
        let flags = if i == pick: cint(ImGui_TabItemFlags_SetSelected) else: 0
        if igBeginTabItem(cstring(tab.title), nil, flags):
          ed.show_tab(i)
          on_screen = i
          drawing_tab = tab.title
          igBeginGroup()
          ed.render_rows(tab.rows)
          igEndGroup()
          igEndTabItem()
      igEndTabBar()
      if not unseen: tab_request = -1
    # The pane's content, less the spacing after its last row
    if on_screen >= 0:
      content_h[on_screen] = igGetCursorPosY() - igGetStyle().ItemSpacing.y
      chrome_h = win_h - igGetWindowHeight()
      shown_tab = on_screen
      scrolls = igGetScrollMaxY() > 0
    igEndChild()
    if measuring >= 0 and on_screen == measuring:
      inc measuring
      while measuring < n_tabs and content_h[measuring] >= 0: inc measuring
      if measuring >= n_tabs:
        measuring = -1
        settling = true
    elif settling and on_screen == back_tab:
      settling = false

    igSeparator()

    drawing_tab = ""
    if igButton("Apply", ImVec2(x: 0, y: 0)):   ed.do_apply()
    note("Apply")
    igSameLine(0, -1)
    if igButton("Revert", ImVec2(x: 0, y: 0)):  ed.do_reset()
    note("Revert")
    igSameLine(0, -1)
    if igButton("OK", ImVec2(x: 0, y: 0)):
      ed.do_apply()
      ed.open = false
    note("OK")
    igSameLine(0, -1)
    if igButton("Reset to Defaults", ImVec2(x: 0, y: 0)):
      igOpenPopup_Str("Reset settings?", 0)
    note("Reset to Defaults")

    if igBeginPopupModal("Reset settings?", nil,
                         cint(ImGui_WindowFlags_AlwaysAutoResize)):
      igText("Restore all settings to their defaults?")
      igText("Your ROMs, saves, recents and BIOS paths are kept.")
      igSeparator()
      if igButton("Reset", ImVec2(x: ui_px(120), y: 0)):
        ed.do_factory_reset()
        igCloseCurrentPopup()
      igSameLine(0, -1)
      # Escape cancels; Return does nothing here (Reset is not undoable)
      if igButton("Cancel", ImVec2(x: ui_px(120), y: 0)) or modal_key() == mkCancel:
        igCloseCurrentPopup()
      igEndPopup()

  # Outside `shown`: the X of a collapsed window asks too
  if igBeginPopupModal("Discard changes?", nil,
                       cint(ImGui_WindowFlags_AlwaysAutoResize)):
    igText("These settings have not been applied.")
    igSeparator()
    if igButton("Apply", ImVec2(x: ui_px(100), y: 0)):
      ed.do_apply()
      ed.open = false
      igCloseCurrentPopup()
    igSameLine(0, -1)
    if igButton("Discard", ImVec2(x: ui_px(100), y: 0)):
      ed.open = false
      igCloseCurrentPopup()
    igSameLine(0, -1)
    # Escape cancels. Return does nothing: Apply and Discard each act on
    # edits the player may not have looked at.
    if igButton("Cancel", ImVec2(x: ui_px(100), y: 0)) or modal_key() == mkCancel:
      igCloseCurrentPopup()
    igEndPopup()

  igEnd()
  if unseen: igPopStyleVar(1)
