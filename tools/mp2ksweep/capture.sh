#!/usr/bin/env bash
# Capture per-title audio and pass dumps for tools/mp2ksweep/wavs.py.
#
# Usage: capture.sh <sweep binary> <tag> <work dir> <ROM name...>
#        capture.sh <sweep binary> <tag> <work dir> --list <file of ROM names>
#
# For each ROM: <work dir>/<ROM name without .gba>/ gets name.txt and, for the
# tag, wT.hle.wav / wT.real.wav, jT.json (the harness's stdout: its JSON line,
# plus any DINGBAT_POSDUMP lines) and pT.txt (the pass dump; builds before
# 2026-09-15 have none). Run several builds with different tags into the same
# work dir to compare them. 900 frames each, 8 at a time; the ROM is copied
# next to the outputs and deleted after, so no save file lands in the archive.
set -euo pipefail

bin=$(cd "$(dirname "${1:?sweep binary}")" && pwd)/$(basename "$1")
tag=${2:?tag}
work=${3:?work dir}
shift 3
roms=${MP2K_ROMS:-$HOME/Documents/emu/gba/archive/roms}
frames=${MP2K_FRAMES:-900}

names=()
if [ "${1:-}" = --list ]; then
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < "${2:?list file}"
else
  names=("$@")
fi

mkdir -p "$work"
run_one() {
  local n=$1 d="$work/${1%.gba}"
  mkdir -p "$d"
  printf '%s\n' "$n" > "$d/name.txt"
  cp "$roms/$n" "$d/rom_$tag.gba"
  rm -f "$d/rom_$tag.sav"
  ( cd "$d" && DINGBAT_PASSDUMP="p$tag.txt" DINGBAT_SWEEP_WAV="w$tag" "$bin" "rom_$tag.gba" "$frames" > "j$tag.json" 2>/dev/null ) || true
  rm -f "$d/rom_$tag.gba" "$d/rom_$tag.sav"
}

i=0
for n in "${names[@]}"; do
  run_one "$n" &
  i=$((i + 1))
  if [ $((i % 8)) -eq 0 ]; then wait; fi
done
wait
echo "captured ${#names[@]} title(s) as $tag in $work"
