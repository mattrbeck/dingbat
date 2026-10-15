#!/bin/bash
# Records pgo/dingbat_driver.profdata, the profile build.sh lays the
# dingbat driver out by: an instrumented driver plays the [new] section of
# GAMES with the HLE and the official BIOS, and the counts are merged.
# Refresh it when the core has moved a long way (a stale profile still
# helps: clang ignores the functions that changed). Committing a new
# profile changes the train's results key, so the next train plays a
# baseline.
#
#   tools/playtest/pgo/refresh.sh [SHA1...]   default: GAMES below
set -e
cd "$(dirname "$0")/../../.."
P=tools/playtest/pgo
# ten games spread over the corpus (every 16th ready script on 2026-10-14)
GAMES=${*:-"0218e3be69334cac752d5ad5b3763a26252cb88b 2525cc23524068dfb3a2b4e0ce7b736f95023e82
3ccbbd45f8553c36463f13b938e833f652b793e4 4f6ae177d236657a075e3366ed4f90c97b03f10d
6472695d69661490f78245e2982e1e676c080be7 80c024df6d40e499776665d7f0c494a252973048
9d327c030c3e2d9007990518594f70c3340ac56f af2b2206777651c7993c1ae9008d07c31430207e
c4d93a58f0f82c526dec8a3fdbda170336303689 da677e595c41a0c72c4e3feb3a7e716f17cacd77"}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
echo "== instrumented dingbat_driver"
nim c -d:test_harness -d:release --path:src --hints:off --nimcache:"$W/cache" \
   --passC:-fprofile-instr-generate --passL:-fprofile-instr-generate \
   -o:"$W/dingbat_driver" tools/playtest/drivers/dingbat_driver.nim
mkdir "$W/prof"
export LLVM_PROFILE_FILE="$W/prof/%p.profraw"
for g in $GAMES; do
  for c in dingbat dingbat-bios; do echo "$g $c"; done
done | xargs -P 4 -n 2 sh -c 'echo "   $0 $1"; python3 '"$P"'/play.py '"$W"'/dingbat_driver "$1" "$0"'
xcrun llvm-profdata merge -o "$P/dingbat_driver.profdata" "$W"/prof/*.profraw
echo "wrote $P/dingbat_driver.profdata ($(ls "$W/prof" | wc -l | tr -d ' ') runs)"
