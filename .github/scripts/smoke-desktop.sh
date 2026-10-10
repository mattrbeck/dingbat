#!/usr/bin/env bash
# Run a release binary on the runner before it can be published: it must
# start, open a window with an OpenGL 3.3 context, load a ROM, present 600
# frames and quit by itself, and the game frame it read back from the GL
# back buffer (--capture) must be byte-identical to
# tests/golden/desktop-blendprobe.png.
#
#   .github/scripts/smoke-desktop.sh ./dingbat           (Linux: under xvfb-run)
#   .github/scripts/smoke-desktop.sh ./dingbat_dist      (macOS)
#   .github/scripts/smoke-desktop.sh smoke/dingbat.exe   (Windows: Git Bash,
#                                     Mesa's opengl32.dll beside the exe)
#
# Exact bytes rather than "not blank": the core, the present shader and the
# PNG writer are the same code on every platform, so one file serves all
# three. Color correction is off for it: its float math rounds differently
# on Apple's GPU and Mesa's llvmpipe (up to 2 levels on a quarter of the
# pixels), while a nearest-neighbour 3x scale of the core's colors does not.
# blendprobe.gba's picture is still from frame ~300 on, so how many frames
# the runner emulated per present cannot move it. A mismatch leaves the
# capture at smoke-blendprobe.png for the workflow to upload.
#
# Run from the repo root. Muted, SDL's dummy audio driver (a runner has no
# sound device), and a scratch settings folder.
set -euo pipefail

bin=${1:?usage: smoke-desktop.sh BINARY}
rom=tests/roms/blendprobe.gba
want=tests/golden/desktop-blendprobe.png
out=smoke-blendprobe.png    # relative: Git Bash rewrites absolute paths in arguments
limit=120                   # seconds; a GUI exe that shows a message box never exits

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# ~/.config/dingbat on Linux and macOS, %APPDATA%\dingbat on Windows
mkdir -p "$scratch/home/.config/dingbat" "$scratch/appdata/dingbat"
printf -- '---\nmute: true\ncolor_correction: false\n' > "$scratch/home/.config/dingbat/dingbat.yml"
cp "$scratch/home/.config/dingbat/dingbat.yml" "$scratch/appdata/dingbat/"
export HOME="$scratch/home"
if command -v cygpath > /dev/null; then
  APPDATA=$(cygpath -w "$scratch/appdata")
  export APPDATA
fi
export SDL_AUDIO_DRIVER=dummy

rm -f "$out"
# --capture=N:PATH, one argument: as two, PATH would be the ROM.
"$bin" "--capture=600:$out" "$rom" &
pid=$!
for ((t = 0; t < limit; t++)); do
  kill -0 "$pid" 2> /dev/null || break
  sleep 1
done
if kill -0 "$pid" 2> /dev/null; then
  kill "$pid" || true
  echo "::error::$bin did not quit within ${limit}s"
  exit 1
fi
status=0
wait "$pid" || status=$?
echo "$bin exited $status after ~${t}s"
if [ "$status" -ne 0 ]; then
  echo "::error::$bin exited $status"
  exit 1
fi
if [ ! -s "$out" ]; then
  echo "::error::$bin wrote no capture"
  exit 1
fi
if ! cmp -s "$out" "$want"; then
  echo "::error::the captured frame differs from $want"
  exit 1
fi
echo "capture matches $want"
