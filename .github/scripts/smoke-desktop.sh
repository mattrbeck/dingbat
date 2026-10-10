#!/usr/bin/env bash
# Run a release binary on the runner before it can be published: it must
# start, open a window with an OpenGL 3.3 context, load a ROM, present 600
# frames and quit by itself, and the game frame it read back from the GL
# back buffer (--capture) must match tests/golden/desktop-blendprobe.png.
#
#   .github/scripts/smoke-desktop.sh ./dingbat           (Linux: under xvfb-run)
#   .github/scripts/smoke-desktop.sh ./dingbat_dist      (macOS)
#   .github/scripts/smoke-desktop.sh smoke/dingbat.exe   (Windows: Git Bash,
#                                     Mesa's opengl32.dll beside the exe)
#
# Match = same size, every channel of every pixel within 4 levels. Not
# "not blank": a black, torn, flipped, mis-scaled or wrongly colored frame
# fails, and so does a color one 5-bit step (8.2 levels) off in the core. Not
# exact bytes either: the present shader's float math (the 5-bit texture's
# conversion, color correction) rounds differently per renderer. Mesa's
# llvmpipe, on the Linux runner and as Windows' opengl32.dll, gives the
# golden file exactly; the macOS runner and an Apple GPU are 1-2 levels off
# on the blended patches. blendprobe.gba's picture is still from frame ~300
# on, so how many frames the runner emulated per present cannot move it. A
# mismatch leaves the capture at smoke-blendprobe.png for the workflow to
# upload.
#
# Run from the repo root. Default settings but muted, SDL's dummy audio
# driver (a runner has no sound device), and a scratch settings folder.
set -euo pipefail

bin=${1:?usage: smoke-desktop.sh BINARY}
rom=tests/roms/blendprobe.gba
want=tests/golden/desktop-blendprobe.png
out=smoke-blendprobe.png    # relative: Git Bash rewrites absolute paths in arguments
limit=120                   # seconds; a GUI exe that shows a message box never exits

# Python 3 is python3 on Linux and macOS, python on the Windows runner
py=""
for p in python3 python; do
  if "$p" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2> /dev/null; then py=$p; break; fi
done
[ -n "$py" ] || { echo "::error::no Python 3"; exit 1; }

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# ~/.config/dingbat on Linux and macOS, %APPDATA%\dingbat on Windows
mkdir -p "$scratch/home/.config/dingbat" "$scratch/appdata/dingbat"
printf -- '---\nmute: true\n' > "$scratch/home/.config/dingbat/dingbat.yml"
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

"$py" -I - "$out" "$want" <<'EOF'
# The capture against the golden file: stb_image_write's 8-bit RGB PNGs,
# decoded with the standard library alone.
import struct, sys, zlib

def rgb(path):
    data = open(path, 'rb').read()
    pos, idat = 8, b''
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, color = struct.unpack('>IIBB', body[:10])
            assert (depth, color) == (8, 2), 'not 8-bit RGB'
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    raw, stride = zlib.decompress(idat), w * 3
    prev, rows = bytearray(stride), []
    for y in range(h):
        at = y * (stride + 1)
        f, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        for x in range(stride):
            a = line[x - 3] if x >= 3 else 0
            b = prev[x]
            c = prev[x - 3] if x >= 3 else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, b''.join(rows)

(gw, gh, got), (ww, wh, want) = rgb(sys.argv[1]), rgb(sys.argv[2])
if (gw, gh) != (ww, wh):
    print(f'::error::captured {gw}x{gh}, {sys.argv[2]} is {ww}x{wh}')
    sys.exit(1)
deltas = [abs(p - q) for p, q in zip(got, want)]
worst, off = max(deltas), sum(d > 0 for d in deltas)
print(f'{gw}x{gh}: {off} of {len(deltas)} channels differ, by at most {worst}')
if worst > 4:
    print(f'::error::the captured frame differs from {sys.argv[2]} by up to {worst} levels')
    sys.exit(1)
EOF
echo "capture matches $want"
