#!/bin/sh
# The desktop app linking online, end to end: the real app (-d:gui_driver:
# hidden, muted, scratch HOME) started with --online CODE pairs through a
# local signaling server (web/signaling/server.js) with tests/online_peer.nim,
# both play attachtest.gba to frame N, and each logs both cores' checksum
# there: equal, and the ROM's link rounds done, or the link is broken.
# A shot of the window is left at $OUT_SHOT if set.
#
# Needs node, SDL 3 and a display (macOS, or Linux under X). From the repo
# root:  tests/desktop_online_e2e.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d)
srv=""
trap 'kill $srv 2>/dev/null; rm -rf "$work"' EXIT
frames=${FRAMES:-900}
bin=${DINGBAT_GUI_BIN:-$work/dingbat_gui}
peer=${ONLINE_PEER_BIN:-$work/online_peer}
if [ ! -x "$bin" ]; then
  nim c -d:release -d:gui_driver --hints:off -o:"$bin" src/dingbat.nim > "$work/build.log" 2>&1 \
    || { tail -20 "$work/build.log"; exit 1; }
fi
if [ ! -x "$peer" ]; then
  nim c -d:release -d:test_harness --hints:off --path:src -o:"$peer" tests/online_peer.nim \
    > "$work/build.log" 2>&1 || { tail -20 "$work/build.log"; exit 1; }
fi

port=$((20000 + $$ % 20000))
node web/signaling/server.js "$port" > "$work/server.log" 2>&1 &
srv=$!
sleep 1
code="E2E$$"

mkdir -p "$work/home/.config/dingbat" "$work/drive"
printf -- '---\nmute: true\n' > "$work/home/.config/dingbat/dingbat.yml"
shot=${OUT_SHOT:-$work/shot.png}
# The app plays to the stop frame by itself; the driver waits, shoots, quits.
printf '1 sleep %s\n2 shot %s\n3 quit\n' "$(( (frames / 60 + 12) * 1000 ))" "$shot" > "$work/drive/cmd"
HOME="$work/home" DINGBAT_DRIVE="$work/drive" DINGBAT_LINK_STOP_AT="$frames" SDL_AUDIO_DRIVER=dummy \
  "$bin" --signal "ws://127.0.0.1:$port" --online "$code" tests/roms/attachtest.gba \
  > "$work/app.log" 2>&1 &
app=$!
"$peer" tests/roms/attachtest.gba "$code" --signal="ws://127.0.0.1:$port" --frames="$frames" \
  --timeout=$((frames / 60 + 40)) --warmup=20 > "$work/peer.log" 2>&1
peer_rc=$?
wait $app
app_rc=$?

fails=0
check() {  # check <what> <got> <want>
  if [ "$2" = "$3" ]; then echo "  ok    $1"
  else echo "  FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
app_sum=$(grep '^ONLINE CHECKSUM' "$work/app.log" | head -1)
peer_sum=$(grep '^ONLINE CHECKSUM' "$work/peer.log" | head -1)
check "peer finished" "$peer_rc" "0"
check "app quit cleanly" "$app_rc" "0"
check "app reached frame $frames with the friend's inputs" "$(echo "$app_sum" | cut -d' ' -f3)" "$frames"
check "both sides' cores agree" "$app_sum" "$peer_sum"
check "link rounds done on both cores" "$(grep -c 'linktest mark 0xCAFE' "$work/peer.log")" "2"
check "the friend heard the app's goodbye" "$(grep -c 'Your friend disconnected' "$work/peer.log")" "1"
if [ $fails -ne 0 ]; then
  echo "--- app.log"; tail -30 "$work/app.log"
  echo "--- peer.log"; tail -30 "$work/peer.log"
  exit 1
fi
echo "all passed"
