#!/bin/sh
# The macOS menu bar (src/dingbat/frontend/mac_menu.nim), driven through the
# real event loop (-d:gui_driver) in a hidden, muted window with a scratch
# HOME, as tests/desktop_gui_test.sh drives the rest:
#
#   home      the app, File, Edit, Emulation, Audio/Video, Debug, Window and Help
#             menus; with no game, the game's items greyed out
#   game      a GBA game: its items enabled, Open Recent lists it, the speed
#             items show Tab and Shift+Tab
#   choose    Pause from the menu, then Cmd+P through the menu bar, ticks
#             and unticks it; Mute and Frame size from the menu change the
#             setting and the window
#   imgui     DINGBAT_IMGUI_MENU=1 keeps the in-window bar: no macOS menus
#
# macOS only. From the repo root:
#   tests/desktop_mac_menu_test.sh       (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_mac_menu_test.sh
set -u

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 0; }
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=${DINGBAT_GUI_BIN:-}
if [ -z "$bin" ]; then
  bin="$root/dingbat_gui_test"
  echo "building $bin ..."
  nim c -d:release -d:gui_driver --hints:off -o:"$bin" src/dingbat.nim \
    > "$work/build.log" 2>&1 \
    || { tail -20 "$work/build.log"; exit 1; }
fi
fails=0
check() {  # check <what> <got> <want>
  if [ "$2" = "$3" ]; then echo "  ok    $1"
  else echo "  FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}

# run <rom or ""> <commands> [env...]: one session, commands acked in order
run() {
  rom=$1 cmds=$2
  shift 2
  rm -rf "$work/home" "$work/drive"
  mkdir -p "$work/home/.config/dingbat" "$work/drive"
  printf -- '---\nmute: true\n' > "$work/home/.config/dingbat/dingbat.yml"
  printf '%s\n' "$cmds" > "$work/drive/cmd"
  env HOME="$work/home" DINGBAT_DRIVE="$work/drive" "$@" \
    "$bin" $rom > "$work/out.log" 2>&1
}
ack() { grep "^$1 " "$work/drive/ack" | cut -d' ' -f2-; }
# item <dump> <exact line, indent stripped>: present or missing
item() { sed 's/^ *//' "$1" | grep -qxF "$2" && echo present || echo missing; }

echo "home screen"
run "" "1 frames 30
2 menu dump $work/home.txt
3 menu pick File>Quick Save
4 quit"
check "menus" "$(grep -v '^ ' "$work/home.txt" | tr '\n' ' ')" \
      "dingbat File Edit Emulation Audio/Video Debug Window Help "
check "Settings… in the app menu" "$(item "$work/home.txt" 'Settings… [Cmd+,]')" present
check "Quit dingbat" "$(item "$work/home.txt" 'Quit dingbat [Cmd+Q]')" present
check "Open ROM…" "$(item "$work/home.txt" 'Open ROM… [Cmd+O]')" present
check "Quick Save greyed" "$(item "$work/home.txt" 'Quick Save [off] [Cmd+S]')" present
check "Open Recent greyed" "$(item "$work/home.txt" 'Open Recent [off]')" present
check "Volume slider" "$(item "$work/home.txt" 'Volume [slider 100]')" present
check "picking a greyed item" "$(ack 3)" "error greyed"

echo "a GBA game"
run tests/roms/inputrec.gba "1 frames 30
2 menu dump $work/game.txt
3 menu pick Emulation>Pause
4 frames 3
5 menu dump $work/paused.txt
6 key P down cmd
7 key P up cmd
8 frames 3
9 menu dump $work/resumed.txt
10 menu pick Audio/Video>Mute
11 menu pick Audio/Video>Frame size>2x
12 frames 5
13 state
14 menu dump $work/after.txt
15 menu pick dingbat>Quit dingbat
16 frames 600"
check "Quick Save enabled" "$(item "$work/game.txt" 'Quick Save [Cmd+S]')" present
check "Fast Forward shows Tab" "$(item "$work/game.txt" 'Fast Forward [Tab]')" present
check "2x Speed shows Shift+Tab" "$(item "$work/game.txt" '2x Speed [Shift+Tab]')" present
check "Open Recent lists the game" "$(item "$work/game.txt" 'inputrec.gba')" present
check "Pause from the menu ticks it" "$(item "$work/paused.txt" 'Pause [x] [Cmd+P]')" present
check "Frame Advance enabled while paused" "$(item "$work/paused.txt" 'Frame Advance [Cmd+N]')" present
check "Cmd+P through the menu bar unticks it" "$(item "$work/resumed.txt" 'Pause [Cmd+P]')" present
check "Mute unticked (it started on)" "$(item "$work/after.txt" 'Mute')" present
check "Frame size 2x ticked" "$(item "$work/after.txt" '2x [x]')" present
check "the window is 2x" "$(ack 13 | sed 's/.*window=//')" "480x320"
check "Quit from the menu ends the session" "$(ack 16)" ""

echo "DINGBAT_IMGUI_MENU=1"
run "" "1 frames 10
2 menu dump $work/none.txt
3 quit" DINGBAT_IMGUI_MENU=1
check "no macOS menus" "$(ack 2)" "error no macOS menu bar"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
