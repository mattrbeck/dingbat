#!/bin/sh
# The desktop app's SDL 3 input and window paths, driven through the real
# event loop (-d:gui_driver) in a hidden, muted window with a scratch HOME:
#
#   keys      z, and 'Z' as SDL 3 reports z under Shift or Caps Lock, all
#             press the button bound to z (GBA A), read from the input log
#   gamepad   a virtual SDL gamepad: plugged in mid-game, a button, the left
#             stick, Start, then unplugged while held (everything lets go)
#   rumble    an MBC5 rumble cart (generated: it switches its motor on and
#             spins) buzzes the pad
#   fullscreen (GUI_TEST_FULLSCREEN=1, macOS) a VISIBLE window taken
#             fullscreen by AppKit's own toggle (the green button's), a Game
#             Boy game loaded meanwhile, and back: the app's fullscreen flag
#             follows, and the window comes back Game Boy-shaped
#
# Needs SDL 3 and a display: macOS, or Linux under X (CI runs it in Xvfb,
# test.yml's desktop-gui job; there SDL_AUDIO_DRIVER=dummy). From the repo
# root:
#   tests/desktop_gui_test.sh            (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_gui_test.sh
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

# run <rom> <yml extra lines> <commands>: one session, commands acked in order
run() {
  rm -rf "$work/home" "$work/drive"
  mkdir -p "$work/home/.config/dingbat" "$work/drive"
  printf -- '---\nmute: true\n%s' "$2" > "$work/home/.config/dingbat/dingbat.yml"
  printf '%s\n' "$3" > "$work/drive/cmd"
  HOME="$work/home" DINGBAT_DRIVE="$work/drive" DINGBAT_INPUT_LOG="$work/input.log" \
    "$bin" "$1" > "$work/out.log" 2>&1
}
ack() { grep "^$1 " "$work/drive/ack" | cut -d' ' -f2-; }
masks() {  # the GBA keypad masks the input log recorded, in order
  grep -E '^[0-9]+ [0-9]+$' "$work/input.log" | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//'
}

echo "keys and gamepad (GBA, input log)"
rm -f "$work/input.log"
# KEYINPUT bits: A 1, B 2, Start 8, Left 32
run tests/roms/inputrec.gba "" "1 frames 60
2 key z down
3 sleep 150
4 key z up
5 sleep 150
6 key 0x5A down shift
7 sleep 150
8 key 0x5A up shift
9 sleep 150
10 key 0x5A down caps
11 sleep 150
12 key 0x5A up caps
13 sleep 150
14 pad attach
15 sleep 300
16 pad button 1 down
17 sleep 150
18 pad button 1 up
19 sleep 150
20 pad axis 0 -32768
21 sleep 150
22 pad button 6 down
23 sleep 150
24 pad detach
25 sleep 150
26 quit"
check "z, Shift+Z, Caps Lock Z press A; pad B, stick left, Start; unplug lets go" \
      "$(masks)" "1 0 1 0 1 0 2 0 32 40 0"
check "virtual pad plugged in" "$(ack 14 | cut -c1-5)" "ok id"

echo "rumble (generated MBC5 rumble cart)"
python3 -I - "$work/rumble.gb" <<'EOF'
import sys
rom = bytearray(0x8000)
rom[0x100:0x104] = b'\x00\xc3\x50\x01'               # nop; jp $0150
rom[0x134:0x13f] = b'RUMBLETEST'.ljust(11, b'\0')
rom[0x147] = 0x1C                                     # MBC5+RUMBLE
rom[0x150:0x157] = b'\x3e\x08\xea\x00\x40\x18\xfe'    # ld a,8; ld ($4000),a; jr @
x = 0
for b in rom[0x134:0x14d]: x = (x - b - 1) & 0xFF
rom[0x14d] = x
open(sys.argv[1], 'wb').write(rom)
EOF
run "$work/rumble.gb" "" "1 pad attach
2 sleep 1000
3 pad rumble
4 quit"
check "the motor buzzes the pad" "$(ack 3 | sed 's/rumbles=[1-9][0-9]*/rumbles=N/')" "ok rumbles=N on=1"

if [ "${GUI_TEST_FULLSCREEN:-}" = 1 ]; then
  echo "fullscreen via AppKit (visible window)"
  python3 -I - "$work/gb.gb" <<'EOF'
import sys
rom = bytearray(0x8000)
rom[0x100:0x104] = b'\x00\xc3\x50\x01'
rom[0x134:0x13f] = b'SHAPETEST'.ljust(11, b'\0')
rom[0x150:0x152] = b'\x18\xfe'                        # jr @
x = 0
for b in rom[0x134:0x14d]: x = (x - b - 1) & 0xFF
rom[0x14d] = x
open(sys.argv[1], 'wb').write(rom)
EOF
  yml="$work/home/.config/dingbat/dingbat.yml"
  run tests/roms/inputrec.gba "" "1 show
2 sleep 500
3 state
4 fullscreen os
5 sleep 2500
6 state
7 quit"
  check "starts windowed, GBA 3x" "$(ack 3)" "ok fullscreen=0 window=720x480"
  check "AppKit's toggle: SDL flags it" "$(ack 6 | cut -d' ' -f1-2)" "ok fullscreen=1"
  check "the app took it up (saved at quit)" "$(grep -c '^fullscreen: true' "$yml")" "1"
  run tests/roms/inputrec.gba "" "1 show
2 sleep 500
3 fullscreen os
4 sleep 2500
5 drop $work/gb.gb
6 sleep 500
7 fullscreen os
8 sleep 2500
9 state
10 quit"
  check "back to a window, Game Boy-shaped" "$(ack 9)" "ok fullscreen=0 window=480x432"
  check "the app saw it leave" "$(grep -c '^fullscreen: false' "$yml")" "1"
fi

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
