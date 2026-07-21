## ImGui "Cheats" window. Lists the loaded game's cheats, lets the user add /
## toggle / delete them, and shows parse errors inline. The widget owns no core
## state itself — it mutates a `CheatEngine` handed to it by the app and calls
## `on_change` after any edit so the app can re-apply ROM patches and persist.

import std/strutils
import imguin/cimgui
import ../common/cheats

type
  CheatsWidget* = ref object
    engine*:    CheatEngine          ## live core's engine (nil when no ROM)
    window*:    bool
    on_change*: proc() {.closure.}   ## called after any mutation
    platform*:  CheatPlatform
    # "Add cheat" input buffers.
    name_buf:   array[128, char]
    code_buf:   array[512, char]
    add_error:  string

proc new_cheats_widget*(): CheatsWidget =
  CheatsWidget(window: false)

proc attach*(w: CheatsWidget; engine: CheatEngine; platform: CheatPlatform) =
  ## Point the widget at a freshly loaded game's engine.
  w.engine = engine
  w.platform = platform
  w.add_error = ""

proc buf_to_string(buf: openArray[char]): string =
  for c in buf:
    if c == '\0': break
    result.add c

proc set_buf(buf: var openArray[char]; s: string) =
  let n = min(s.len, buf.len - 1)
  for i in 0 ..< n: buf[i] = s[i]
  buf[n] = '\0'

const HINT_GB  = "Game Genie: ABC-DEF-GHI   GameShark: 011234C0"
const HINT_GBA = "GameShark/AR v3: XXXXXXXX YYYYYYYY   CodeBreaker: 82XXXXXX YYYY"

proc red(): ImVec4 = ImVec4(x: 1.0, y: 0.35, z: 0.35, w: 1.0)
proc dim(): ImVec4 = ImVec4(x: 0.6, y: 0.6, z: 0.6, w: 1.0)

proc do_add(w: CheatsWidget) =
  let codes = buf_to_string(w.code_buf).strip()
  if codes.len == 0:
    w.add_error = "enter at least one code"
    return
  var name = buf_to_string(w.name_buf).strip()
  if name.len == 0: name = "Cheat " & $(w.engine.cheats.len + 1)
  # Format (incl. encrypted-vs-raw for GBA) is auto-detected by the engine.
  var c = Cheat(name: name, codes: codes, format: cfAuto, enabled: true)
  w.engine.reparse(c)
  if c.error.len > 0:
    w.add_error = c.error
    return
  w.engine.cheats.add c
  w.add_error = ""
  set_buf(w.name_buf, "")
  set_buf(w.code_buf, "")
  if w.on_change != nil: w.on_change()

proc render*(w: CheatsWidget) =
  if not w.window: return
  igSetNextWindowSize(ImVec2(x: 420, y: 380), cint(ImGui_Cond_FirstUseEver))
  if igBegin("Cheats", addr w.window, 0):
    if w.engine == nil:
      igTextColored(dim(), "Load a game to manage cheats.")
      igEnd()
      return

    # ---- existing cheats ----
    if w.engine.cheats.len == 0:
      igTextColored(dim(), "No cheats yet. Add one below.")
    else:
      var delete_idx = -1
      var changed = false
      for i in 0 ..< w.engine.cheats.len:
        igPushID_Int(cint(i))
        var en = w.engine.cheats[i].enabled
        if igCheckbox("##en", addr en):
          w.engine.cheats[i].enabled = en
          changed = true
        igSameLine(0, -1)
        if igSmallButton("x"):
          delete_idx = i
        igSameLine(0, -1)
        let nm = w.engine.cheats[i].name
        igTextUnformatted(cstring(nm), nil)
        # code line(s), dimmed; error in red if any
        let err = w.engine.cheats[i].error
        if err.len > 0:
          igTextColored(red(), "  %s", cstring(err))
        else:
          let summary = w.engine.cheats[i].codes.replace("\n", "  ")
          igTextColored(dim(), "  %s", cstring(summary))
        igPopID()
      if delete_idx >= 0:
        w.engine.cheats.delete(delete_idx)
        changed = true
      if changed and w.on_change != nil:
        w.on_change()

    igSeparator()

    # ---- add a cheat ----
    igTextUnformatted("Add cheat", nil)
    igSetNextItemWidth(-1)
    discard igInputTextWithHint("##name", "name (optional)",
      cast[cstring](addr w.name_buf[0]), csize_t(w.name_buf.len), 0, nil, nil)
    let hint = if w.platform == cpGBA: HINT_GBA else: HINT_GB
    discard igInputTextMultiline("##codes",
      cast[cstring](addr w.code_buf[0]), csize_t(w.code_buf.len),
      ImVec2(x: -1, y: 60), 0, nil, nil)
    igTextColored(dim(), "%s", cstring(hint))
    if igButton("Add", ImVec2(x: 0, y: 0)):
      w.do_add()
    if w.add_error.len > 0:
      igSameLine(0, -1)
      igTextColored(red(), "%s", cstring(w.add_error))
  igEnd()
