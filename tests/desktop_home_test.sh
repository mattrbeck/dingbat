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
#   hero      a fresh start has none; Close Game (Cmd/Ctrl+W) from a running
#             game heads the page with it, its tile stood down, and writes
#             its battery and a session; Resume puts the session back exactly
#             (the state's hash) without booting, so the battery stays as it
#             was; Play boots from the battery (a generated cart counts its
#             boots in it); Down then Return is Resume
#   find      Find the File relinks a missing game to its renamed file and
#             keeps its save states; another game's file is refused
#   labels    the in-window bar says Add a game and Close Game, never Open ROM
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
    "$bin" ${2:+"$2"} > "$work/out.log" 2>&1
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
names() { grep -v '^@' "$1" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'; }
# at <dump> <first field>: the centre ("x y") of that line's rect (the hero's
# buttons, a menu's items, the file dialog's rows)
at() {
  grep -F -m1 "$2|" "$1" | cut -d'|' -f2 | awk '{ print int($1 + $3 / 2), int($2 + $4 / 2) }'
}
# Shortcuts take Cmd on macOS, Ctrl elsewhere
if [ "$(uname)" = Darwin ]; then mod=cmd modname=Cmd; else mod=ctrl modname=Ctrl; fi

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
run "1 sleep 400
2 move $xy
3 sleep 100
4 click $xy right
5 sleep 300
6 home dump $work/menu.txt
7 quit"
check "a missing game's menu: Find the File, then Remove" \
      "$(grep '^@menu' "$work/menu.txt" | cut -d'|' -f1 | tr '\n' ',')" \
      "@menu Play,@menu Find the File...,@menu Remove from Library,"
rxy=$(at "$work/menu.txt" "@menu Remove from Library")
run "1 sleep 400
2 move $xy
3 sleep 100
4 click $xy right
5 sleep 300
6 move $rxy
7 sleep 100
8 click $rxy
9 sleep 300
10 home dump $work/removed.txt
11 quit"
check "the tile is gone" "$(grep -c '^Gone (USA)|' "$work/removed.txt")" "0"
check "the others stay" "$(grep -c '|present|' "$work/removed.txt")" "2"
check "out of the recents too" "$(grep -c 'Gone (USA)' "$cfg/dingbat.yml")" "0"

echo "close game: the hero"
# A window wide enough for the hero beside its words and the grid under it
settings "frame_size: 5
"
# A cart that counts its boots in battery RAM ($A000), then counts in WRAM
# for ever, so its state moves every frame
python3 -I - "$work/games/Counter.gb" <<'EOF'
import sys
rom = bytearray(0x8000)
rom[0x100:0x104] = b'\x00\xc3\x50\x01'               # nop; jp $0150
rom[0x134:0x13f] = b'COUNTER'.ljust(11, b'\0')
rom[0x147] = 0x03                                     # MBC1+RAM+BATTERY
rom[0x149] = 0x02                                     # 8 KB
rom[0x150:0x162] = bytes([
  0x3e, 0x0a, 0xea, 0x00, 0x00,                       # RAM on
  0xfa, 0x00, 0xa0, 0x3c, 0xea, 0x00, 0xa0,           # ($A000)++
  0x21, 0x00, 0xc0, 0x34, 0x18, 0xfa])                # loop: ($C000)++
x = 0
for b in rom[0x134:0x14d]: x = (x - b - 1) & 0xFF
rom[0x14d] = x
open(sys.argv[1], 'wb').write(rom)
EOF
boots() { od -An -tu1 -N1 "$work/games/Counter.sav" | tr -d ' '; }
close="key W down $mod
key W up $mod
frames 10
sleep 200"
# steps <lines>: numbered commands
steps() { printf '%s\n' "$1" | awk '{ print NR " " $0 }'; }
run "$(steps "sleep 400
home dump $work/fresh.txt
quit")"
check "a fresh start: no hero" "$(grep -c '^@hero' "$work/fresh.txt")" "0"
run "$(steps "frames 120
$close
home dump $work/hero.txt
quit")" "$work/games/Counter.gb"
check "Close Game: the hero, with Resume and Play" "$(grep '^@hero' "$work/hero.txt")" \
      "@hero|Counter|resume play"
check "its tile stands down" "$(grep -c '^Counter|' "$work/hero.txt")" "0"
check "the others stay" "$(names "$work/hero.txt")" "Mask Test Edge Pack"
check "the battery written" "$(boots)" "1"
check "a session beside the slots" \
      "$(ls "$cfg/states" | grep -c '^Counter.gb-[0-9A-F]*\.session\.state$')" "1"
check "the session is written after the battery" \
      "$(grep -c '^Session saved' "$work/out.log")" "1"

echo "resume, play"
r1=$(at "$work/hero.txt" "@resume")
p1=$(at "$work/hero.txt" "@play")
run "$(steps "frames 120
$close
move $r1
sleep 100
click $r1
sleep 300
home dump $work/resumed.txt
frames 60
$close
quit")" "$work/games/Counter.gb"
check "Resume: the game runs" "$(cat "$work/resumed.txt")" "none"
taken=$(grep '^session hash' "$work/out.log" | head -1 | cut -d' ' -f3)
back=$(grep '^resumed hash' "$work/out.log" | cut -d' ' -f3)
check "Resume puts back exactly the state taken" "${back:-none}" "$taken"
check "Resume boots nothing: the battery as it was" "$(boots)" "2"
run "$(steps "frames 60
$close
move $p1
sleep 100
click $p1
sleep 300
home dump $work/played.txt
frames 60
$close
home dump $work/played2.txt
quit")" "$work/games/Counter.gb"
check "Play: the game runs" "$(cat "$work/played.txt")" "none"
check "Play boots from the battery" "$(boots)" "4"
check "and puts no session back" "$(grep -c '^resumed hash' "$work/out.log")" "0"
check "closed again: the hero" "$(grep -c '^@hero|Counter' "$work/played2.txt")" "1"

echo "keys reach the hero"
run "$(steps "frames 60
$close
key W down $mod
key W up $mod
frames 5
key Down down
sleep 100
key Down up
sleep 100
key Return down
sleep 100
key Return up
sleep 300
home dump $work/keyed.txt
quit")" "$work/games/Counter.gb"
check "Close Game at home does nothing" "$(grep -c '^Game closed' "$work/out.log")" "1"
check "Down, Return: Resume" "$(grep -c '^Session resumed' "$work/out.log")" "1"

echo "Find the File"
run "$(steps "frames 60
key S down $mod
key S up $mod
frames 10
quit")" "$work/games/Mask Test.gba"
check "a Quick Save to keep" "$(grep -c '^State saved' "$work/out.log")" "1"
mv "$work/games/Mask Test.gba" "$work/games/Mask Test (moved).gba"
run "$(steps "sleep 400
home dump $work/f1.txt
quit")"
check "the moved game is missing" "$(tile "$work/f1.txt" "Mask Test" state)" "missing|picture"
xy=$(tile "$work/f1.txt" "Mask Test" centre)
menu="move $xy
sleep 100
click $xy right
sleep 300"
run "$(steps "sleep 400
$menu
home dump $work/f2.txt
quit")"
fxy=$(at "$work/f2.txt" "@menu Find the File...")
find="$menu
move $fxy
sleep 100
click $fxy
sleep 400"
run "$(steps "sleep 400
$find
explorer dump $work/f3.txt
quit")"
check "the dialog opens in the old file's folder" \
      "$(grep -c '^\[F\] Mask Test (moved).gba|' "$work/f3.txt")" "1"
row=$(at "$work/f3.txt" "[F] Mask Test (moved).gba")
open=$(at "$work/f3.txt" "Open")
pick="move $row
sleep 100
click $row
sleep 200
move $open
sleep 100
click $open
sleep 400"
run "$(steps "sleep 400
$find
$pick
home dump $work/f4.txt
quit")"
check "the tile is the new file's" "$(tile "$work/f4.txt" "Mask Test (moved)" state)" \
      "present|picture"
check "one tile for the game" "$(grep -c '^Mask Test' "$work/f4.txt")" "1"
check "the recents follow" "$(grep -c 'Mask Test (moved).gba' "$cfg/dingbat.yml")" "1"
run "$(steps "frames 60
key L down $mod
key L up $mod
frames 10
quit")" "$work/games/Mask Test (moved).gba"
check "its Quick Save loads" "$(grep -c '^State loaded' "$work/out.log")" "1"
# Another game's file in its place is refused
mv "$work/games/Mask Test (moved).gba" "$work/games/away.bin"
cp tests/roms/inputrec.gba "$work/games/Other.gba"
xy=$(tile "$work/f4.txt" "Mask Test (moved)" centre)
menu="move $xy
sleep 100
click $xy right
sleep 300"
run "$(steps "sleep 400
$menu
home dump $work/g0.txt
quit")"
fxy=$(at "$work/g0.txt" "@menu Find the File...")
find="$menu
move $fxy
sleep 100
click $fxy
sleep 400"
run "$(steps "sleep 400
$find
explorer dump $work/g1.txt
quit")"
row=$(at "$work/g1.txt" "[F] Other.gba")
pick="move $row
sleep 100
click $row
sleep 200
move $open
sleep 100
click $open
sleep 400"
run "$(steps "sleep 400
$find
$pick
home dump $work/g2.txt
quit")"
check "another game's file: refused" \
      "$(grep -c 'Other.gba is a different game from Mask Test (moved)' "$work/out.log")" "1"
check "and nothing changed" "$(tile "$work/g2.txt" "Mask Test (moved)" state)" "missing|picture"
mv "$work/games/away.bin" "$work/games/Mask Test (moved).gba"

echo "labels"
run "$(steps "sleep 300
menu imgui $work/bar.txt
quit")"
check "Add a game" "$(grep -c '^  Add a game$' "$work/bar.txt")" "1"
check "Close Game, greyed at home" \
      "$(grep -cF "  Close Game  $modname+W [off]" "$work/bar.txt")" "1"
check "no Open ROM" "$(grep -c 'Open ROM' "$work/bar.txt")" "0"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
