#!/bin/sh
# A link kept while a macOS menu is open: AppKit holds the main loop in its
# menu-tracking run loop, the game stops as for a pause, and the link goes on
# as a paused one does (dingbat.nim link_while_blocked). Two hidden, muted
# windows (-d:gui_driver, scratch HOMEs) linked over 127.0.0.1 on
# linktest.gba; the host's loop is held in menu tracking for 35 s, longer
# than the 30 s a peer waits for a silent one:
#
#   held      the joiner says "Your friend has paused." (peer_paused) and
#             keeps the link; the host emulates nothing meanwhile
#   after     both still linked, the pause gone, and both run frames again
#   goodbye   the friend quits meanwhile: the link ends when the loop runs
#
# macOS only. From the repo root:
#   tests/desktop_mac_link_test.sh       (builds ./dingbat_gui_test)
#   DINGBAT_GUI_BIN=path tests/desktop_mac_link_test.sh
set -u

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 0; }
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$work"' EXIT
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

# start <name> <args...>: one window in the background, its own HOME and drive
start() {
  name=$1
  shift
  mkdir -p "$work/$name/home/.config/dingbat" "$work/$name/drive"
  printf -- '---\nmute: true\n' > "$work/$name/home/.config/dingbat/dingbat.yml"
  : > "$work/$name/drive/cmd"
  HOME="$work/$name/home" DINGBAT_DRIVE="$work/$name/drive" \
    "$bin" tests/roms/linktest.gba "$@" > "$work/$name/out.log" 2>&1 &
  pids="$pids $!"
}
send() { printf '%s\n' "$2" >> "$work/$1/drive/cmd"; }
ack() { grep "^$2 " "$work/$1/drive/ack" 2>/dev/null | cut -d' ' -f2-; }
# wait_for <seconds> <command...>: until the command succeeds
wait_for() {
  n=$(($1 * 10))
  shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}
linked() { grep -q "NETLINK: linked as unit" "$work/$1/out.log"; }
acked() { [ -n "$(ack "$1" "$2")" ]; }
field() { ack "$1" "$2" | tr ' ' '\n' | sed -n "s/^$3=//p"; }
frames() { v=$(field "$1" "$2" frames); echo "${v:-0}"; }
stopped() { for p in $pids; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }

port=$((47800 + $$ % 100))
echo "a menu held open 35 s on one of two linked windows"
start host --listen "$port"
start join --connect "127.0.0.1:$port"
if ! wait_for 20 linked host || ! wait_for 20 linked join; then
  echo "  FAIL  the two windows did not link"
  cat "$work/host/out.log" "$work/join/out.log"
  exit 1
fi
send host "1 sleep 2000
2 link
3 track 35000
4 link
5 sleep 3000
6 link"
send join "1 sleep 12000
2 link
3 sleep 30000
4 link
5 sleep 3000
6 link"
wait_for 70 acked host 6
wait_for 70 acked join 6
send host "7 quit"
send join "7 quit"
check "held: the joiner still linked" "$(field join 2 linked)" "1"
check "held: the joiner sees a pause" "$(field join 2 peer_paused)" "1"
check "held: the host emulated nothing" \
      "$(( $(frames host 4) - $(frames host 2) <= 1 ))" "1"
check "after: the host still linked" "$(field host 4 linked)" "1"
check "after: the joiner still linked" "$(field join 4 linked)" "1"
check "after: no pause" "$(field join 4 peer_paused)" "0"
check "after: the host runs again" \
      "$(( $(frames host 6) - $(frames host 4) > 60 ))" "1"
check "after: the joiner runs again" \
      "$(( $(frames join 6) - $(frames join 4) > 60 ))" "1"
check "no link lost" "$(cat "$work/host/out.log" "$work/join/out.log" | grep -c 'link lost')" "0"
wait_for 10 stopped || echo "  (a window did not quit; killed)"

echo "the friend quits while the menu is open"
pids=""
start host2 --listen "$((port + 100))"
start join2 --connect "127.0.0.1:$((port + 100))"
if ! wait_for 20 linked host2 || ! wait_for 20 linked join2; then
  echo "  FAIL  the two windows did not link"
  exit 1
fi
send host2 "1 sleep 500
2 track 5000
3 frames 5
4 link"
send join2 "1 sleep 2000
2 quit"
wait_for 20 acked host2 4
send host2 "5 quit"
check "the link ends once the loop runs" "$(field host2 4 linked)" "0"
check "as the friend's goodbye" "$(grep -c 'peer disconnected' "$work/host2/out.log")" "1"
wait_for 10 stopped || echo "  (a window did not quit; killed)"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
