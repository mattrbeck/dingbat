## Draw menu_model's menus as the in-window Dear ImGui bar: Windows, Linux,
## and macOS with DINGBAT_IMGUI_MENU=1. A chosen item goes to the queue.

import imguin/cimgui
import menu_model
import util

proc render_items(items: seq[MenuItem]; mod_name: string) =
  for it in items:
    case it.kind
    of mkSeparator: igSeparator()
    of mkSystem, mkEdit: discard   # AppKit's own actions: macOS bar only
    of mkSubmenu:
      if igBeginMenu(cstring(it.title), it.enabled):
        render_items(it.items, mod_name)
        igEndMenu()
    of mkAction:
      let hint = if it.hint.len > 0: cstring(it.hint) else: nil
      if igMenuItem_Bool(cstring(imgui_label(it, mod_name)), hint, it.checked,
                         it.enabled):
        push_cmd(it.cmd, it.arg)
    of mkSlider:
      var v = cint(it.value)
      igSetNextItemWidth(ui_px(120))
      if igSliderInt(cstring(it.title), addr v, cint(it.lo), cint(it.hi),
                     "%d%%", 0):
        push_cmd(it.cmd, int(v))
      # Persist when the edit completes, not every frame of the drag
      if igIsItemDeactivatedAfterEdit():
        push_cmd(it.done, int(v))

proc render_menu_bar*(bar: seq[MenuItem]; mod_name: string): float32 =
  ## The whole bar; returns its height (0 when ImGui drew none).
  if not igBeginMainMenuBar(): return 0
  render_items(bar, mod_name)
  var win_size = ImVec2(x: 0, y: 0)
  # imguin <= 1.92.4 uses a pOut out-param; later versions return by value
  when compiles(igGetWindowSize(addr win_size)):
    igGetWindowSize(addr win_size)
  else:
    let ws = igGetWindowSize()
    win_size = ImVec2(x: ws.x, y: ws.y)
  igEndMainMenuBar()
  win_size.y
