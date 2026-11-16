## The desktop menus as data (src/dingbat/frontend/menu_model.nim): the ImGui
## bar's shortcut labels, state filled into every action and submenu, finding
## an item by its path, and the queue a chosen item waits in. The macOS bar
## itself is driven in tests/desktop_mac_menu_test.sh.

import dingbat/frontend/menu_model

# ImGui writes a bound shortcut into the title, the hint into its own column
doAssert imgui_label(action("Quick Save", mcQuickSave, key = "s"), "Ctrl") ==
         "Quick Save  Ctrl+S"
doAssert imgui_label(action("Fast Forward", mcFastForward, hint = "Tab"), "Cmd") ==
         "Fast Forward"

var bar = @[
  submenu("File", @[
    action("Quick Save", mcQuickSave, key = "s"),
    submenu("Recent", @[action("a.gba", mcOpenRecent, 0)], mcRecentMenu),
    separator()]),
  submenu("Audio/Video", @[
    submenu("Frame size", @[action("2x", mcFrameSize, 2), action("3x", mcFrameSize, 3)])])]

# Every action and greyable submenu takes its state; the rest stay enabled
var asked: seq[(MenuCmd, int)]
bar.apply_state(proc(cmd: MenuCmd; arg: int): MenuState =
  asked.add((cmd, arg))
  case cmd
  of mcQuickSave, mcRecentMenu: (false, false)
  of mcFrameSize: (true, arg == 3)
  else: (true, false))
doAssert asked == @[(mcQuickSave, 0), (mcRecentMenu, 0), (mcOpenRecent, 0),
                    (mcFrameSize, 2), (mcFrameSize, 3)]

var it: MenuItem
doAssert bar.find(["File", "Quick Save"], it) and not it.enabled
doAssert bar.find(["File", "Recent"], it) and not it.enabled
# "Audio/Video" is one title: paths are lists, not "/"-joined
doAssert bar.find(["Audio/Video", "Frame size", "3x"], it) and it.checked
doAssert bar.find(["Audio/Video", "Frame size", "2x"], it) and not it.checked
doAssert bar.find(["Audio/Video"], it) and it.enabled  # no cmd: never greyed
doAssert not bar.find(["File", "Nope"], it)
doAssert not bar.find(["Audio/Video", "Frame size", "3x", "deeper"], it)

# Chosen items wait in order until the main loop takes them, once
push_cmd(mcPause)
push_cmd(mcFrameSize, 4)
doAssert take_cmds() == @[(mcPause, 0), (mcFrameSize, 4)]
doAssert take_cmds().len == 0

# ── Settings rows (settings_model.nim) ──

import dingbat/frontend/settings_model

proc video(filter: int; ds: bool; border_help = ""): seq[SettingRow] =
  result = @[label("Filter:", "help", @[choice(siFilter, ["None", "xBR"], [0, 2], filter)]),
             toggle(siSgbBorder, "Show SGB border", true, border_help, enabled = filter == 0)]
  if ds: result.add choice(siNdsHd, ["Native", "2x"], [1, 2], 1, inline = true)

# The shape changes with rows coming and going, not with values, text,
# greying or help: a window updates those in place
doAssert signature(video(0, false)) == signature(video(2, false, "other help"))
doAssert signature(video(0, false)) != signature(video(0, true))
# Nested rows are part of the shape
doAssert signature(@[group(@[note("a")])]) != signature(@[group(@[note("a"), note("b")])])

var r: SettingRow
doAssert video(2, false).find(siFilter, 0, r) and r.value == 2 and r.options.len == 2
doAssert r.option_on == @[true, true]   # every option open unless said otherwise
doAssert video(2, false).find(siSgbBorder, 0, r) and not r.enabled
doAssert not video(2, false).find(siNdsHd, 0, r)
doAssert binding(siKeyBinding, DS_ARG + 1, "Y (DS)", "C", false, 48).arg == DS_ARG + 1

echo "desktop menu tests passed"
