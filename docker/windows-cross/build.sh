#!/bin/sh
# Cross-compile dingbat for Windows inside the dingbat-win-cross container.
# Output is a single self-contained dist/windows/dingbat.exe (SDL2 and the
# C++ runtime are statically linked).
set -eu

nimble install --depsOnly -y

mkdir -p dist/windows

# Icon + version info resource, linked into the exe
res=$(mktemp /tmp/dingbat_res.XXXXXX.o)
x86_64-w64-mingw32-windres --include-dir=docker/windows-cross \
    docker/windows-cross/dingbat.rc -O coff -o "$res"

nim c -d:mingw -d:release --cpu:amd64 --passL:"$res" \
    -o:dist/windows/dingbat.exe src/dingbat.nim
rm -f "$res"
x86_64-w64-mingw32-strip dist/windows/dingbat.exe

echo "Built:"
ls -l dist/windows
