#!/bin/sh
# The desktop home screen's library (frontend/library_view.nim), driven
# through the real event loop (-d:gui_driver) in a hidden, muted window with
# a scratch HOME, as tests/desktop_gui_test.sh drives the rest:
#
#   empty     no games: the drop box, no tiles
#   recents   a first run of a build with the library takes in the recents
#             an older build wrote: a GBA game, a zip (known by the ROM
#             inside), one whose file is gone (a dashed tile); a DS game
#             only with DS Beta on
#   missing   clicking the missing game says so and stays home
#   open      clicking a tile opens its game, which heads the library next
#             time; leaving it keeps its last screen as the tile's picture
#   keys/pad  Down then Return, and a pad's d-pad then A, open the most
#             recent game
#   remove    the tile's menu takes a game out of the library and the recents
#
# Needs SDL 3 and a display. From the repo root:
#   tests/desktop_home_test.sh           (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_home_test.sh
set -u

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

home="$work/home"
cfg="$home/.config/dingbat"
# settings <yml extra lines>: a fresh settings file (the library stays)
settings() {
  mkdir -p "$cfg"
  printf -- '---\nmute: true\n%s' "$1" > "$cfg/dingbat.yml"
}
# run <commands> [rom]: one session, commands acked in order
run() {
  rm -rf "$work/drive"
  mkdir -p "$work/drive"
  printf '%s\n' "$1" > "$work/drive/cmd"
  HOME="$home" DINGBAT_DRIVE="$work/drive" DINGBAT_IMGUI_MENU=1 \
    "$bin" ${2:-} > "$work/out.log" 2>&1
}
# tile <dump> <name> <field>: a tile's line, or its centre ("x y"), or state
tile() {
  line=$(grep "^$2|" "$1")
  case $3 in
    centre) echo "$line" | cut -d'|' -f2 | awk '{ print int($1 + $3 / 2), int($2 + $4 / 2) }' ;;
    state) echo "$line" | cut -d'|' -f3-4 ;;
  esac
}
# press <dump> <name>: the commands that point at a tile and click it. Sleeps,
# not frames: at home a loop iteration that draws nothing takes a millisecond
press() {
  xy=$(tile "$1" "$2" centre)
  printf 'p1 move %s\np2 sleep 100\np3 click %s\np4 sleep 300' "$xy" "$xy"
}
names() { cut -d'|' -f1 "$1" | tr '\n' ' ' | sed 's/ $//'; }

echo "empty library"
settings ""
run "1 sleep 400
2 home dump $work/empty.txt
3 quit"
check "the drop box, no tiles" "$(cat "$work/empty.txt")" "empty"

echo "recents from an older build"
rm -rf "$home"
mkdir -p "$work/games"
cp tests/roms/hwverified/psrmask.gba "$work/games/Mask Test.gba"
python3 -c "import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w'); z.write(sys.argv[2], 'edge.gb'); z.close()" \
  "$work/games/Edge Pack.zip" tests/roms/gbedge.gb
printf 'not a DS game' > "$work/games/Pocket.nds"
recents="recents:
- \"$work/games/Mask Test.gba\"
- \"$work/games/Gone (USA).gba\"
- \"$work/games/Edge Pack.zip\"
- \"$work/games/Pocket.nds\"
"
settings "$recents"
run "1 sleep 400
2 home dump $work/first.txt
3 quit"
check "three tiles in recents order, no DS game" "$(names "$work/first.txt")" \
      "Mask Test Gone (USA) Edge Pack"
check "the gone file is a missing tile" "$(tile "$work/first.txt" "Gone (USA)" state)" \
      "missing|cart"
check "nothing played yet: no picture" "$(tile "$work/first.txt" "Mask Test" state)" \
      "present|cart"
check "the zip known by the ROM inside" \
      "$(grep -c '"rom": "edge.gb"' "$cfg/library.json")" "1"

settings "${recents}nds:
  beta: true
"
run "1 sleep 400
2 home dump $work/ds.txt
3 quit"
check "DS Beta shows the DS game" "$(names "$work/ds.txt")" \
      "Mask Test Gone (USA) Edge Pack Pocket"

echo "a missing game, clicked"
settings "$recents"
run "1 sleep 400
2 home dump $work/a.txt
3 quit"
run "1 sleep 400
$(press "$work/a.txt" "Gone (USA)")
3 frames 10
4 home dump $work/after-missing.txt
5 quit"
check "says the file is gone" "$(grep -c "Gone (USA).gba isn't there any more" "$work/out.log")" "1"
check "still home" "$(names "$work/after-missing.txt")" "Mask Test Gone (USA) Edge Pack"

echo "a tile opens its game"
run "1 sleep 400
$(press "$work/a.txt" "Edge Pack")
3 frames 120
4 home dump $work/playing.txt
5 quit"
check "the game is running" "$(cat "$work/playing.txt")" "none"
run "1 sleep 400
2 home dump $work/back.txt
3 quit"
check "it heads the library" "$(names "$work/back.txt" | cut -d' ' -f1-2)" "Edge Pack"

echo "keys and pad"
run "1 sleep 400
$(press "$work/back.txt" "Mask Test")
3 frames 200
4 quit"
run "1 sleep 400
2 home dump $work/pic.txt
3 key Down down
4 sleep 100
5 key Down up
6 sleep 100
7 key Return down
8 sleep 100
9 key Return up
10 sleep 300
11 frames 60
12 home dump $work/keys.txt
13 quit"
check "the last screen is the tile's picture" "$(tile "$work/pic.txt" "Mask Test" state)" \
      "present|picture"
check "Down, Return: the most recent game runs" "$(cat "$work/keys.txt")" "none"
# SDL gamepad buttons: 0 south (A), 12 d-pad down
run "1 sleep 400
2 pad attach
3 sleep 300
4 pad button 12 down
5 sleep 100
6 pad button 12 up
7 sleep 100
8 pad button 0 down
9 sleep 100
10 pad button 0 up
11 frames 60
12 home dump $work/pad.txt
13 quit"
check "d-pad, A: the most recent game runs" "$(cat "$work/pad.txt")" "none"

echo "remove from the library"
run "1 sleep 400
2 home dump $work/before-remove.txt
3 quit"
xy=$(tile "$work/before-remove.txt" "Gone (USA)" centre)
# The tile's menu opens at the pointer; its last item, Remove from Library,
# is four lines of 14 px text below it (the name, the missing note, a
# separator, Play: ~88 pt, each item ~22 pt tall) and right of it
rx=$(( ${xy% *} + 70 )) ry=$(( ${xy#* } + 88 ))
run "1 sleep 400
2 move $xy
3 sleep 100
4 click $xy right
5 sleep 300
6 move $rx $ry
7 sleep 100
8 click $rx $ry
9 sleep 300
10 home dump $work/removed.txt
11 quit"
check "the tile is gone" "$(grep -c '^Gone (USA)|' "$work/removed.txt")" "0"
check "the others stay" "$(grep -c '|present|' "$work/removed.txt")" "2"
check "out of the recents too" "$(grep -c 'Gone (USA)' "$cfg/dingbat.yml")" "0"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
