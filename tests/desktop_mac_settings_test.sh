#!/bin/sh
# The native macOS Settings window (src/dingbat/frontend/mac_settings.nim)
# and the Edit menu, driven through the real event loop (-d:gui_driver) with
# a scratch HOME. The Settings window is built but never shown; the game's
# window is hidden, as in tests/desktop_gui_test.sh:
#
#   rows      Settings... opens it with every tab's rows; without a BIOS file
#             Run BIOS intro and the real-BIOS modes are greyed, with one
#             they are not; a missing file is marked invalid
#   edit      a toggle, a filter, a path and a key capture (A takes J, then
#             B waits), Apply: the settings file has them
#   close     an unapplied edit asks first; Discard leaves the file as it was;
#             Revert puts the edit back
#   ds beta   unticking DS Beta takes the DS rows away, before Apply
#   library   General's "Opening a game from the library": Resume, or From
#             save, which OK saves and the window shows chosen next time
#   edit menu greyed with no text field; with the Cheats window's name field
#             being typed in, enabled, and Select All and Undo reach it
#             (nothing here goes through the clipboard)
#
# macOS only. From the repo root:
#   tests/desktop_mac_settings_test.sh   (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_mac_settings_test.sh
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

yml="$work/home/.config/dingbat/dingbat.yml"
# run <rom or ""> <commands>: one session, commands acked in order
run() {
  rm -rf "$work/home" "$work/drive"
  mkdir -p "$work/home/.config/dingbat" "$work/drive"
  printf -- '---\nmute: true\nnds:\n  beta: true\n' > "$yml"
  printf '%s\n' "$2" > "$work/drive/cmd"
  HOME="$work/home" DINGBAT_DRIVE="$work/drive" "$bin" $1 > "$work/out.log" 2>&1
}
ack() { grep "^$1 " "$work/drive/ack" | cut -d' ' -f2-; }
line() { grep -qxF "$2" "$1" && echo present || echo missing; }
head -c 16384 /dev/zero > "$work/bios.bin"

echo "rows, edits, Apply"
run "" "1 sleep 200
2 menu pick dingbat>Settings...
3 sleep 300
4 settings dump $work/open.txt
5 settings do Video>LCD response
6 settings do Video>xBR
7 settings do BIOS>GBA BIOS:>$work/missing.bin
8 sleep 200
9 settings dump $work/missing.txt
10 settings do BIOS>GBA BIOS:>$work/bios.bin
11 settings do Keybindings>A
12 sleep 200
13 settings key 0x26
14 sleep 300
15 settings dump $work/edited.txt
16 settings do >Apply
17 sleep 300
18 quit"
check "every tab" "$(grep '^tab ' "$work/open.txt" | sed 's/ \[x\]//' | tr '\n' ' ')" \
      "tab Keybindings tab Video tab Controller tab BIOS tab General "
check "no BIOS file: the intro greyed" "$(line "$work/open.txt" 'toggle Run BIOS intro [off]')" present
check "no BIOS file: Real BIOS greyed" "$(line "$work/open.txt" 'option Real BIOS [off]')" present
check "the DS rows (DS Beta on)" "$(line "$work/open.txt" 'binding X (DS) = D')" present
check "a missing file is marked" "$(line "$work/missing.txt" "path GBA BIOS: = $work/missing.bin [invalid]")" present
check "with a BIOS file the intro can be ticked" "$(line "$work/edited.txt" 'toggle Run BIOS intro')" present
check "with a BIOS file Real BIOS can be chosen" "$(line "$work/edited.txt" 'option Real BIOS')" present
check "A took J" "$(line "$work/edited.txt" 'binding A = J')" present
check "B waits for its key" "$(line "$work/edited.txt" 'binding B = Press a key… [waiting]')" present
check "xBR chosen" "$(line "$work/edited.txt" 'option xBR [x]')" present
check "applied: LCD response" "$(grep -c '^lcd_response: true' "$yml")" 1
check "applied: xBR" "$(grep -c '^video_filter: xbr' "$yml")" 1
check "applied: the BIOS file" "$(grep -c "bios: $work/bios.bin" "$yml")" 1
check "applied: J is A" "$(grep -c '^  j: a' "$yml")" 1

echo "closing, Revert, DS Beta"
run "" "1 sleep 200
2 menu pick dingbat>Settings...
3 sleep 300
4 settings do Video>Preserve aspect ratio
5 settings close
6 sleep 300
7 settings dump $work/asking.txt
8 settings do >Discard
9 sleep 300
10 settings dump $work/discarded.txt
11 menu pick dingbat>Settings...
12 sleep 300
13 settings do Video>LCD response
14 settings do >Revert
15 sleep 300
16 settings dump $work/reverted.txt
17 settings do General>DS Beta
18 sleep 300
19 settings dump $work/nods.txt
20 settings close
21 sleep 300
22 settings do >Discard
23 sleep 300
24 quit"
check "an unapplied edit asks on closing" "$(head -1 "$work/asking.txt")" "window hidden [asking]"
check "Discard closes without asking again" "$(head -1 "$work/discarded.txt")" "window hidden"
check "Discard kept the file" "$(grep -c 'preserve_aspect' "$yml")" 0
check "Revert puts the edit back" "$(line "$work/reverted.txt" 'toggle LCD response')" present
check "DS Beta off: no DS keys" "$(line "$work/nods.txt" 'binding X (DS) = D')" missing
check "DS Beta off: no DS files" "$(grep -c 'path DS' "$work/nods.txt")" 0
check "DS Beta off: not applied" "$(grep -c 'beta: true' "$yml")" 1

echo "opening a game from the library (General)"
run "" "1 sleep 200
2 menu pick dingbat>Settings...
3 sleep 300
4 settings dump $work/lib0.txt
5 settings do General>From save
6 settings do >OK
7 sleep 300
8 menu pick dingbat>Settings...
9 sleep 300
10 settings dump $work/lib1.txt
11 settings close
12 sleep 300
13 quit"
check "the row, Resume chosen" \
      "$(grep -A2 '^label Opening a game from the library:$' "$work/lib0.txt" | tr '\n' ',')" \
      "label Opening a game from the library:,option Resume [x],option From save,"
check "From save, OK: saved" "$(grep -c '^library_open: save$' "$yml")" 1
check "  and chosen when it opens again" "$(line "$work/lib1.txt" 'option From save [x]')" present

echo "Edit menu (the Cheats window's name field, GBA game: its third row, at y 156)"
run tests/roms/hwverified/psrmask.gba "1 sleep 300
2 menu pick Emulation>Cheats
3 move 200 156
4 sleep 300
5 menu dump $work/m0.txt
6 click 200 156
7 sleep 300
8 text hello
9 sleep 300
10 menu dump $work/m1.txt
11 menu pick Edit>Select All
12 sleep 300
13 text x
14 sleep 300
15 menu pick Edit>Undo
16 sleep 300
17 quit"
check "greyed with no text field" "$(grep -c '^  Select All \[off\]' "$work/m0.txt")" 1
check "enabled while typing" "$(grep -c '^  Select All \[Cmd+A\]' "$work/m1.txt")" 1
check "Select All from the menu" "$(ack 11)" "ok"
check "Undo from the menu" "$(ack 15)" "ok"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
