#!/bin/sh
# Cross-compile dingbat for Windows inside the dingbat-win-cross container.
# Output is a single self-contained dist/windows/dingbat.exe (SDL2 and the
# C++ runtime are statically linked).
set -eu

# In CI the checkout is owned by a different uid than the container's root;
# git refuses to operate on it (and nimble shells out to git) without this
git config --global --add safe.directory /src 2>/dev/null || true

# nimble resolves every dependency by querying its git remote for tags, so this
# one command depends on github.com AND gitlab.com being up (a gitlab 502 on
# stb_image-Nim has already failed a build). Retry the whole resolve; it is
# idempotent, and already-installed packages make the retry cheap.
i=1
while :; do
  nimble install --depsOnly -y && break
  if [ "$i" -ge 3 ]; then
    echo "nimble install --depsOnly failed after $i attempts" >&2
    exit 1
  fi
  echo "nimble install --depsOnly failed (attempt $i), retrying in 15s..." >&2
  sleep 15
  i=$((i + 1))
done

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
