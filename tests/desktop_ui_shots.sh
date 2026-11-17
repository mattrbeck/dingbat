#!/bin/sh
# Screenshots of the desktop's ImGui UI, for looking at (not compared with
# anything): the home screen empty, with a few games and with many; the
# hero after Close Game; the menus open; every Settings tab; Cheats (with
# codes), Save States, Link Cable; a notice; the session offered in a toast.
# At UI scale 1 and 1.5 (DINGBAT_UI_SCALE, a Windows display at 150%), in a
# hidden, muted window with a scratch HOME, through the GUI driver. ImGui's
# menu bar and Settings window on macOS too (DINGBAT_IMGUI_MENU=1): what
# Windows and Linux show.
#
#   tests/desktop_ui_shots.sh BINARY OUTDIR
#
# BINARY is a -d:gui_driver build. CI runs it under Xvfb (test.yml's
# desktop-gui job) and on Windows (build-artifacts.yml's windows-smoke job,
# Git Bash) and uploads OUTDIR.
set -u

bin=${1:?usage: desktop_ui_shots.sh BINARY OUTDIR}
out=${2:?usage: desktop_ui_shots.sh BINARY OUTDIR}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SDL_AUDIO_DRIVER=${SDL_AUDIO_DRIVER:-dummy}
# A session that never quits (a message box on Windows) ends after a minute
limit=""
if command -v timeout > /dev/null; then limit="timeout 60"; fi

# A path as the app takes it: Windows' own on Windows (Git Bash rewrites
# only command-line arguments, not paths inside files)
native() { if command -v cygpath > /dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

home="$work/home"
# ~/.config/dingbat on Linux and macOS, %APPDATA%\dingbat on Windows
if command -v cygpath > /dev/null; then cfg="$work/appdata/dingbat"
else cfg="$home/.config/dingbat"; fi
fresh() {  # fresh <yml extra lines>: a new settings folder, no library
  rm -rf "$home" "$work/appdata"
  mkdir -p "$cfg" "$home"
  printf -- '---\nmute: true\n%s' "$1" > "$cfg/dingbat.yml"
}
# run <tag> <commands> [rom]: one session; its log is kept on failure
# A session a run left would be offered over the next run's game (a toast):
# gone, but for the shot of that offer (keep=1)
keep=0
run() {
  rm -rf "$work/drive"
  [ "$keep" = 1 ] || rm -f "$cfg"/states/*.session.state "$cfg"/states/*.session.state.battery
  mkdir -p "$work/drive"
  printf '%s\n' "$2" > "$work/drive/cmd"
  APPDATA=$(native "$work/appdata") HOME="$home" DINGBAT_DRIVE=$(native "$work/drive") \
    DINGBAT_IMGUI_MENU=1 $limit "$bin" ${3:+"$3"} > "$work/out.log" 2>&1 \
    || echo "  $1: exited $?"
  if grep -q ' error' "$work/drive/ack" 2> /dev/null; then
    echo "  $1: $(grep ' error' "$work/drive/ack" | head -3 | tr '\n' ' ')"
  fi
}
shot() { native "$out/$1-$scale.png"; }

games="$work/games"
mkdir -p "$games"
gba="$root/tests/roms/blendprobe.gba"
gb="$root/tests/roms/gbedge.gb"
gbc="$root/tests/roms/gbhdmatest.gbc"
cp "$gba" "$games/Blend Probe.gba"
cp "$gb" "$games/Edge Test.gb"
cp "$gbc" "$games/HDMA Test.gbc"
many=""
for n in "Mask Test.gba" "A Very Long Game Name That Will Not Fit (USA, Europe).gba" \
         "Sound Check.gb" "Window Edge.gbc" "Timer Probe.gba" "Serial Link.gb" \
         "Palette Ramp.gbc" "Sprite Wall.gba" "Mode 7 Test.gba" "Pocket Probe.gb"; do
  case $n in
    *.gba) cp "$gba" "$games/$n" ;;
    *.gbc) cp "$gbc" "$games/$n" ;;
    *) cp "$gb" "$games/$n" ;;
  esac
  many="$many- \"$(native "$games/$n")\"
"
done
few="- \"$(native "$games/Blend Probe.gba")\"
- \"$(native "$games/Edge Test.gb")\"
- \"$(native "$games/HDMA Test.gbc")\"
"

for scale in 1 1.5; do
  export DINGBAT_UI_SCALE=$scale
  echo "UI scale $scale"

  fresh ""
  run home-empty "1 sleep 500
2 shot $(shot home-empty)
3 quit"

  # A few games, one played (its last screen is its tile's picture)
  fresh "recents:
$few"
  run play "1 frames 240
2 quit" "$(native "$games/Blend Probe.gba")"
  run home-few "1 sleep 500
2 move 5 300
3 sleep 200
4 shot $(shot home-few)
5 quit"

  # More than 8: search, chips and sort above the grid. recents holds 8 at
  # most, so a library.json first, then the recents taken in after it.
  fresh ""
  {
    printf '{"version": 1, "sort": "recent", "games": [\n'
    sep=""
    for f in "$games"/*; do
      case $f in *.gba) sys=GBA ;; *.gbc) sys=GBC ;; *) sys=GB ;; esac
      printf '%s{"path": "%s", "rom": "%s", "system": "%s"}' \
        "$sep" "$(native "$f")" "$(basename "$f")" "$sys"
      sep=",
"
    done
    printf '\n]}\n'
  } > "$cfg/library.json"
  run home-many "1 sleep 600
2 move 5 300
3 sleep 200
4 shot $(shot home-many)
5 quit"

  # The hero: a game closed (Close Game) heads the page, in the game's own
  # window (a column), a wide one (beside its words) and with no other games
  for h in hero:"" hero-wide:"frame_size: 5
" hero-solo:"frame_size: 5
"; do
    name=${h%%:*} extra=${h#*:}
    if [ "$name" = hero-solo ]; then
      fresh "${extra}recents:
- \"$(native "$games/Blend Probe.gba")\"
"
    else
      fresh "${extra}recents:
$few"
    fi
    # Few frames: llvmpipe draws a frame_size 5 window at 1.5 slowly
    run "$name" "1 frames 30
2 app cmd mcCloseGame
3 frames 10
4 sleep 500
5 move 5 300
6 sleep 200
7 shot $(shot "$name")
8 quit" "$(native "$games/Blend Probe.gba")"
  done

  # A game running, with each window over it
  fresh "recents:
$few"
  g=$(native "$games/Blend Probe.gba")
  run menus "1 frames 60
2 move 14 10
3 sleep 100
4 click 14 10
5 sleep 300
6 shot $(shot menu-1)
7 move 120 10
8 sleep 300
9 shot $(shot menu-2)
10 move 200 10
11 sleep 300
12 shot $(shot menu-3)
13 key Escape down
14 key Escape up
15 sleep 200
16 move 300 300
17 sleep 300
18 shot $(shot game)
19 quit" "$g"
  run settings "1 frames 30
2 app cmd mcSettings
3 sleep 300
4 shot $(shot settings-0)
5 app tab 1
6 sleep 300
7 shot $(shot settings-1)
8 app tab 2
9 sleep 300
10 shot $(shot settings-2)
11 app tab 3
12 sleep 300
13 shot $(shot settings-3)
14 app tab 4
15 sleep 300
16 shot $(shot settings-4)
17 quit" "$g"
  # The session the last run left, offered as the game boots from its save
  run play "1 frames 30
2 quit" "$g"
  keep=1
  run offer "1 frames 30
2 move 300 300
3 sleep 300
4 shot $(shot offer)
5 quit" "$g"
  keep=0
  for w in cheats:mcCheats save-states:mcSaveStates link-cable:mcLinkCable \
           debug-io:mcGbaDebug:1 debug-video:mcGbaDebug:0 overlay:mcOverlay \
           notice:mcQuickLoad open-rom:mcOpenRom; do
    name=${w%%:*} rest=${w#*:}
    # Cheats with codes listed (drawn monospaced), beside the game as the
    # app keeps them
    if [ "$name" = cheats ]; then
      printf '[x] Keep the screen\n8203FFF0 0000\n\n[ ] Second slot\n8203FFF4 1234\n8203FFF6 ABCD\n' \
        > "$games/Blend Probe.cht"
    fi
    run "$name" "1 frames 30
2 app cmd $(echo "$rest" | tr ':' ' ')
3 sleep 300
4 shot $(shot "$name")
5 quit" "$g"
    rm -f "$games/Blend Probe.cht"
  done
done
unset DINGBAT_UI_SCALE
echo "$(ls "$out" | grep -c '\.png$') shots in $out"
