#!/bin/sh
# The notices as macOS alerts (src/dingbat/frontend/mac_alert.nim), driven
# through the real event loop (-d:gui_driver) with a scratch HOME. The game's
# window is hidden, so an alert is built but not shown as a sheet; the driver
# reads it and presses its keys:
#
#   order     a damaged settings file and a missing ROM: the Settings notice
#             first, the game one after its OK; a failed Quick Save
#             takes over, and the game notice comes back after it;
#             Return, Escape and Enter each answer (Z does not); then none
#             is left
#   window    no ImGui modal in the game's window meanwhile
#   imgui     DINGBAT_IMGUI_MENU=1: no alert, the ImGui modal as before
#
# macOS only. From the repo root:
#   tests/desktop_mac_alert_test.sh      (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_mac_alert_test.sh
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

conf="$work/home/.config/dingbat"
# run <yml extra> <commands> [env...]: one GBA session, commands acked in order
run() {
  yml=$1 cmds=$2
  shift 2
  rm -rf "$work/home" "$work/drive"
  mkdir -p "$conf" "$work/drive"
  printf -- '---\nmute: true\n%s' "$yml" > "$conf/dingbat.yml"
  : > "$conf/states"   # a file where the states folder goes: Quick Save fails
  printf '%s\n' "$cmds" > "$work/drive/cmd"
  env HOME="$work/home" DINGBAT_DRIVE="$work/drive" "$@" \
    "$bin" tests/roms/inputrec.gba > "$work/out.log" 2>&1
}
ack() { grep "^$1 " "$work/drive/ack" | cut -d' ' -f2-; }
title() { sed -n 2p "$1"; }

# shade <png>: whether the shot's centre pixel is white (the test ROM's
# screen) or dark (an ImGui modal's body)
cat > "$work/shade.py" <<'EOF'
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
px = rows[h // 2][w // 2 * 3:w // 2 * 3 + 3]
print('white' if min(px) == 255 else 'dark' if max(px) < 64 else 'other')
EOF
shade() { python3 -I "$work/shade.py" "$1"; }

echo "order, keys, the game's window"
# kVK_Return 0x24, kVK_Escape 0x35, kVK_ANSI_KeypadEnter 0x4C
run "frame_size: [damaged
" "1 frames 30
2 drop /nonexistent/dir/missing.gba
3 sleep 300
4 alert dump $work/a1.txt
5 alert shot $work/a1.png
6 shot $work/game.png
6a alert key 0x06
6b sleep 200
6c alert dump $work/a1z.txt
7 alert key 0x24
8 sleep 200
9 alert dump $work/a2.txt
10 key S down cmd
11 key S up cmd
12 sleep 300
13 alert dump $work/a3.txt
14 alert key 0x35
15 sleep 200
16 alert dump $work/a4.txt
17 alert key 0x4C
18 sleep 200
19 alert dump $work/a5.txt
20 alert ok
21 quit"
check "the Settings notice first" "$(title "$work/a1.txt" | cut -c1-36)" \
      "Your settings file could not be read"
check "built, not shown (hidden window)" "$(sed -n 1p "$work/a1.txt")" "asking"
check "the alert draws" "$(ack 5)" "ok"
check "no ImGui modal over the game" "$(shade "$work/game.png")" "white"
check "Z answers nothing" "$(title "$work/a1z.txt" | cut -c1-36)" \
      "Your settings file could not be read"
check "Return: the game notice next" "$(title "$work/a2.txt")" "missing.gba isn't there any more."
check "its hint below" "$(sed -n 3p "$work/a2.txt")" "/nonexistent/dir/missing.gba"
check "a failed Quick Save takes over" "$(title "$work/a3.txt" | cut -c1-24)" "Quick Save didn't work, "
check "Escape: the game notice is back" "$(title "$work/a4.txt")" "missing.gba isn't there any more."
check "Enter: none left" "$(cat "$work/a5.txt")" "none"
check "nothing to answer" "$(ack 20)" "error no alert"

echo "DINGBAT_IMGUI_MENU=1"
run "" "1 frames 30
2 drop /nonexistent/dir/missing.gba
3 sleep 600
4 alert dump $work/i1.txt
5 shot $work/imgui.png
6 quit" DINGBAT_IMGUI_MENU=1
check "no alert" "$(cat "$work/i1.txt")" "none"
check "the ImGui modal over the game" "$(shade "$work/imgui.png")" "dark"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
