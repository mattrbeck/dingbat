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

echo "desktop menu tests passed"
