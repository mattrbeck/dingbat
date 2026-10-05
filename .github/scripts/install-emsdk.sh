#!/usr/bin/env bash
# install-emsdk.sh <version>: Emscripten in ~/emsdk, put on the job's PATH.
# The workflow caches ~/emsdk (actions/cache, keyed on the version), so this
# installs only on a miss. mymindstorm/setup-emsdk did it before, but its own
# cache ("actions-cache-folder") talks to a cache service GitHub has retired
# ("Cache service responded with 400"), so every run downloaded the SDK.
set -euo pipefail

version=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir="$HOME/emsdk"

if [ ! -x "$dir/upstream/emscripten/emcc" ]; then
  "$here/retry.sh" 3 bash -c \
    "rm -rf '$dir' && git clone --depth 1 https://github.com/emscripten-core/emsdk.git '$dir'"
  "$here/retry.sh" 3 "$dir/emsdk" install "$version"
fi
# Writes ~/emsdk/.emscripten (absolute paths, the same every run) and is
# cheap, so it runs on a hit too.
"$dir/emsdk" activate "$version" >/dev/null

{
  echo "$dir"
  echo "$dir/upstream/emscripten"
} >> "${GITHUB_PATH:-/dev/null}"
{
  echo "EMSDK=$dir"
  echo "EM_CONFIG=$dir/.emscripten"
} >> "${GITHUB_ENV:-/dev/null}"
"$dir/upstream/emscripten/emcc" --version | head -1
