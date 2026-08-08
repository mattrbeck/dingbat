#!/usr/bin/env bash
# Collect the three downloaded build artifacts into a flat directory of
# release-ready files, with a checksum manifest.
#
# Used by BOTH the rolling "latest" release (every push to main) and the
# tagged one, so the two cannot end up shipping differently named or
# differently assembled files.
#
# Usage: stage-release.sh <artifacts-dir> <out-dir>
#
# <artifacts-dir> is what actions/download-artifact@v4 produces when given no
# name: one subdirectory per artifact, named after it.
set -euo pipefail

ARTS="${1:?artifacts dir}"
OUT="${2:?output dir}"

rm -rf "$OUT"
mkdir -p "$OUT"

cp "$ARTS/dingbat-linux-x64/dingbat-linux-x64.tar.gz" "$OUT/dingbat-linux-x64.tar.gz"
cp "$ARTS/dingbat-macos/dingbat-macos.dmg"            "$OUT/dingbat-macos.dmg"
cp "$ARTS/dingbat-windows-x64/dingbat.exe"            "$OUT/dingbat-windows-x64.exe"

# Checksums are generated from inside the directory so the manifest lists bare
# filenames — `shasum -c SHA256SUMS.txt` then works wherever a user unpacks it.
cd "$OUT"
shasum -a 256 -- * > SHA256SUMS.txt

echo "staged $(ls -1 | wc -l | tr -d ' ') files in $OUT:"
cat SHA256SUMS.txt
