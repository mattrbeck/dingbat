#!/bin/sh
# The macOS menu bar (src/dingbat/frontend/mac_menu.nim), driven through the
# real event loop (-d:gui_driver) in a hidden, muted window with a scratch
# HOME, as tests/desktop_gui_test.sh drives the rest:
#
#   home      the app, File, Edit, View, Emulation, Audio, Debug, Window and
#             Help menus; with no game, the game's items greyed out
#   game      a GBA game: its items enabled, Open Recent lists it, the speed
#             items show Tab and Shift+Tab
#   choose    Pause from the menu, then Cmd+P through the menu bar, ticks
#             and unticks it; Mute and Frame Size from the menu change the
#             setting and the window
#   view      a filter, Preserve Aspect Ratio and LCD Response from the View
#             menu are saved, and an open Settings window shows them
#   aspect    the window's aspect lock (SDL's and the NSWindow's): free on the
#             home screen and in fullscreen (Fullscreen on the hidden window
#             only sets the flag), 3:2 in a GBA game
#   close     Cmd+W is Close Game while a game runs (Close Window moves to
#             Shift+Cmd+W) and Close Window at home; Close Game goes home
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
      "dingbat File Edit View Emulation Audio Debug Window Help "
check "Settings… in the app menu" "$(item "$work/home.txt" 'Settings… [Cmd+,]')" present
check "Quit dingbat" "$(item "$work/home.txt" 'Quit dingbat [Cmd+Q]')" present
check "Add a Game…" "$(item "$work/home.txt" 'Add a Game… [Cmd+O]')" present
check "no Open ROM" "$(grep -c 'Open ROM' "$work/home.txt")" "0"
# Close Window is greyed here only because the driver's hidden window is not
# the key window
check "home: Cmd+W closes the window" "$(item "$work/home.txt" 'Close Window [off] [Cmd+W]')" present
check "home: no Close Game" "$(grep -c 'Close Game' "$work/home.txt")" "0"
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
10 menu pick Audio>Mute
11 menu pick View>Frame Size>2x
12 frames 5
13 state
14 menu dump $work/after.txt
15 menu pick dingbat>Quit dingbat
16 frames 600"
check "Quick Save enabled" "$(item "$work/game.txt" 'Quick Save [Cmd+S]')" present
check "Fast Forward shows Tab" "$(item "$work/game.txt" 'Fast Forward [Tab]')" present
check "2x Speed shows Shift+Tab" "$(item "$work/game.txt" '2x Speed [Shift+Tab]')" present
check "Open Recent lists the game" "$(item "$work/game.txt" 'inputrec.gba')" present
check "a game: Cmd+W is Close Game" "$(item "$work/game.txt" 'Close Game [Cmd+W]')" present
check "Close Window takes Shift+Cmd+W" "$(item "$work/game.txt" 'Close Window [off] [Shift+Cmd+W]')" present
check "Pause from the menu ticks it" "$(item "$work/paused.txt" 'Pause [x] [Cmd+P]')" present
check "Frame Advance enabled while paused" "$(item "$work/paused.txt" 'Frame Advance [Cmd+N]')" present
check "Cmd+P through the menu bar unticks it" "$(item "$work/resumed.txt" 'Pause [Cmd+P]')" present
check "Mute unticked (it started on)" "$(item "$work/after.txt" 'Mute')" present
check "Frame Size 2x ticked" "$(item "$work/after.txt" '2x [x]')" present
check "the window is 2x" "$(ack 13 | sed 's/.*window=//')" "480x320"
check "Quit from the menu ends the session" "$(ack 16)" ""

echo "View menu"
run tests/roms/inputrec.gba "1 frames 30
2 menu pick dingbat>Settings...
3 sleep 300
4 menu pick View>Filter>xBR
5 menu pick View>LCD Response
6 menu pick View>Preserve Aspect Ratio
7 frames 5
8 menu dump $work/view.txt
9 settings dump $work/view_settings.txt
10 quit"
yml="$work/home/.config/dingbat/dingbat.yml"
check "xBR ticked" "$(item "$work/view.txt" 'xBR [x]')" present
check "None unticked" "$(item "$work/view.txt" 'None (crisp)')" present
check "LCD Response ticked" "$(item "$work/view.txt" 'LCD Response [x]')" present
check "Preserve Aspect Ratio unticked (it started on)" "$(item "$work/view.txt" 'Preserve Aspect Ratio')" present
check "Enter Full Screen, Cmd+F" "$(item "$work/view.txt" 'Enter Full Screen [Cmd+F]')" present
check "saved: xBR" "$(grep -c '^video_filter: xbr' "$yml")" 1
check "saved: LCD response" "$(grep -c '^lcd_response: true' "$yml")" 1
check "saved: aspect" "$(grep -c '^preserve_aspect: false' "$yml")" 1
check "Settings shows xBR" "$(item "$work/view_settings.txt" 'option xBR [x]')" present
check "Settings shows LCD response" "$(item "$work/view_settings.txt" 'toggle LCD response [x]')" present
check "Settings shows aspect off" "$(item "$work/view_settings.txt" 'toggle Preserve aspect ratio')" present

echo "the window's aspect lock"
# SDL's limits and AppKit's own: a content aspect ratio, or (free) none and
# resize increments of 1, as a fresh window has
run "" "1 frames 10
2 aspect
3 drop tests/roms/inputrec.gba
4 frames 10
5 aspect
6 menu pick View>Frame Size>2x
7 frames 5
8 aspect
9 menu pick View>Enter Full Screen
10 frames 5
11 aspect
12 menu pick View>Exit Full Screen
13 frames 5
14 aspect
15 state
16 quit"
check "home screen: free" "$(ack 2)" "ok min=0.0000 max=0.0000 ns=0:0 inc=1:1"
check "a GBA game: 3:2" "$(ack 5 | cut -d' ' -f1-4)" "ok min=1.5000 max=1.5000 ns=3:2"
check "Frame size keeps it" "$(ack 8 | cut -d' ' -f1-4)" "ok min=1.5000 max=1.5000 ns=3:2"
check "fullscreen: free" "$(ack 11)" "ok min=0.0000 max=0.0000 ns=0:0 inc=1:1"
check "back: 3:2" "$(ack 14 | cut -d' ' -f1-4)" "ok min=1.5000 max=1.5000 ns=3:2"
check "the window as it was" "$(ack 15)" "ok fullscreen=0 window=480x320"

echo "Close Game"
run tests/roms/inputrec.gba "1 frames 60
2 key W down cmd
3 key W up cmd
4 frames 10
5 sleep 200
6 home dump $work/closed.txt
7 menu dump $work/closed-menu.txt
8 drop tests/roms/inputrec.gba
9 frames 30
10 menu pick File>Close Game
11 frames 10
12 sleep 200
13 home dump $work/picked.txt
14 quit"
check "Cmd+W: home, the game heading it" "$(grep -c '^@hero|inputrec|resume play' "$work/closed.txt")" "1"
check "home again: Cmd+W closes the window" "$(item "$work/closed-menu.txt" 'Close Window [off] [Cmd+W]')" present
check "File > Close Game: the same" "$(grep -c '^@hero|inputrec|resume play' "$work/picked.txt")" "1"

echo "DINGBAT_IMGUI_MENU=1"
run "" "1 frames 10
2 menu dump $work/none.txt
3 quit" DINGBAT_IMGUI_MENU=1
check "no macOS menus" "$(ack 2)" "error no macOS menu bar"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
