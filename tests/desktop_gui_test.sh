#!/bin/sh
# The desktop app's SDL 3 input and window paths, driven through the real
# event loop (-d:gui_driver) in a hidden, muted window with a scratch HOME:
#
#   keys      z, and 'Z' as SDL 3 reports z under Shift or Caps Lock, all
#             press the button bound to z (GBA A), read from the input log
#   gamepad   a virtual SDL gamepad: plugged in mid-game, a button, the left
#             stick, Start, then unplugged while held (everything lets go)
#   pixels    the game picture fills the whole back buffer, which on a
#             Retina display is twice the window's size in points
#   fast-forward  a picture changed between presents and never again is
#             still the one on screen (generated GBA ROM)
#   ui scale  DINGBAT_UI_SCALE=1.5 (a Windows display at 150%) makes the
#             menu bar and the window half as big again
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

# shot.py <png> corner|bar|rgb <fx> <fy>: whether the bottom-right pixel is
# lit, how many rows down the right edge are dark (the menu bar, over a
# white game), or "r g b" of the pixel at fractions (0..1) of the shot
cat > "$work/shot.py" <<'EOF'
import struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
pos, idat = 8, b''
while pos < len(data):
    n, kind = struct.unpack('>I4s', data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    if kind == b'IHDR': w, h = struct.unpack('>II', body[:8])
    if kind == b'IDAT': idat += body
    pos += 12 + n
raw, stride, prev, rows, i = zlib.decompress(idat), w * 3, bytearray(w * 3), [], 0
for _ in range(h):     # undo the PNG row filters (8-bit RGB)
    f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
    for x in range(stride):
        a = line[x - 3] if x >= 3 else 0; b = prev[x]; c = prev[x - 3] if x >= 3 else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
x = (w - 2) * 3
if sys.argv[2] == 'rgb':
    x, y = int((w - 1) * float(sys.argv[3])), int((h - 1) * float(sys.argv[4]))
    print(*rows[y][x * 3:x * 3 + 3])
elif sys.argv[2] == 'corner':
    print('lit' if sum(rows[h - 2][x:x + 3]) > 0 else 'black')
else:
    n = 0
    while n < h and sum(rows[n][x:x + 3]) < 300: n += 1
    print(n)
EOF

echo "picture fills the back buffer (pixels, not points)"
# A hwverified ROM paints a verdict block in its bottom-right corner over a
# white screen. On a Retina display the back buffer is 2x the window; a
# viewport set in points would draw the picture into its bottom-left
# quarter, leaving the shot's bottom-right corner the black clear colour.
run tests/roms/hwverified/psrmask.gba "" "1 frames 120
2 shot $work/fill.png
3 quit"
echo "  ($(ack 2))"
lit=$(python3 -I "$work/shot.py" "$work/fill.png" corner)
check "the bottom-right corner of the shot is the picture's" "$lit" "lit"

echo "UI scale (DINGBAT_UI_SCALE=1.5, as a Windows display at 150%)"
# The menu bar over the same white screen, at 100% and at 150%: the bar
# (font and padding) half as tall again, and the window 3x scaled by
# 1.5, made a whole number of back-buffer pixels: 5x at a density of 1
# (the app rounds halves up), 4.5x at 2.
bar() {  # bar <tag> <scale>: one session's menu bar height, in pixels
  export DINGBAT_UI_SCALE=$2
  run tests/roms/hwverified/psrmask.gba "" "1 frames 60
2 move 200 200
3 frames 10
4 shot $work/$1.png
5 quit"
  unset DINGBAT_UI_SCALE
  ack 4 > "$work/$1.ack"
  python3 -I "$work/shot.py" "$work/$1.png" bar
}
bar1=$(bar ui1 1)
bar15=$(bar ui15 1.5)
echo "  (menu bar ${bar1} px, then ${bar15} px; $(cat "$work/ui15.ack"))"
check "the menu bar is 1.4-1.6x as tall" \
      "$(python3 -I -c "print(1.4 <= $bar15 / max($bar1, 1) <= 1.6)")" "True"
sizes=$(sed 's/^ok \([0-9]*\)x[0-9]* px, window \([0-9]*\)x\([0-9]*\) pt$/\1 \2 \3/' \
        "$work/ui15.ack")
check "the window is 3x scaled by 1.5, whole in pixels" "$(python3 -I -c "
px, w, h = map(int, '$sizes'.split())
d = px / w
k = int(3 * 1.5 * d + 0.5) / d
print(w == int(240 * k + 0.5) and h == int(160 * k + 0.5))")" "True"

echo "fast-forward shows a frame that changed between presents"
# Fast-forward runs many frames per present. This one's backdrop turns from
# black to red in the frames after A is pressed, then never changes again:
# the frames presented after it are all unchanged, and the texture must
# still be the red one (a desktop that uploaded only a presented frame
# that changed itself kept the black picture on screen).
python3 -I - "$work/onechange.gba" <<'EOF'
import struct, sys
code = [
  0xE3A00301,  # mov  r0, #0x04000000
  0xE3A01000,  # mov  r1, #0
  0xE1C010B0,  # strh r1, [r0]         DISPCNT 0: the backdrop only
  0xE3A02405,  # mov  r2, #0x05000000
  0xE1C210B0,  # strh r1, [r2]         backdrop black
  0xE2804E13,  # add  r4, r0, #0x130   KEYINPUT
  0xE1D430B0,  # loop: ldrh r3, [r4]
  0xE3130001,  # tst  r3, #1           A (active low)
  0x1AFFFFFC,  # bne  loop
  0xE3A0101F,  # mov  r1, #0x1F
  0xE1C210B0,  # strh r1, [r2]         backdrop red
  0xEAFFFFFE,  # b    .
]
open(sys.argv[1], 'wb').write(struct.pack('<%dI' % len(code), *code).ljust(0x8000, b'\0'))
EOF
run "$work/onechange.gba" "" "1 sleep 300
2 key Tab down
3 frames 2
4 key Tab up
5 sleep 300
6 key z down
7 sleep 150
8 key z up
9 sleep 700
10 shot $work/onechange.png
11 quit"
# Red through the default colour correction (248 59 122 on macOS), black
# when the change never reached the screen
hue=$(python3 -I "$work/shot.py" "$work/onechange.png" rgb 0.5 0.5 |
      awk '{ if ($1 > 160 && $1 > 2 * $2) print "red"
             else if ($1 + $2 + $3 == 0) print "black"; else print }')
check "the backdrop is red after A in fast-forward" "$hue" "red"

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
