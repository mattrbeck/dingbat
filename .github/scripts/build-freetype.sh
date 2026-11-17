#!/bin/sh
# Build FreeType from its release source as a static library only and install
# it under PREFIX (PREFIX/include/freetype2, PREFIX/lib/libfreetype.a): the
# Windows and Linux desktop builds rasterise the UI's text with it
# (frontend/ui_fonts.nim) and link it statically, so the binaries carry no
# FreeType dependency. macOS draws its text with CoreText and needs none.
#
#   .github/scripts/build-freetype.sh PREFIX            native
#   .github/scripts/build-freetype.sh PREFIX --mingw    Windows x64, mingw-w64
#
# The release is pinned by version and SHA-256 (FREETYPE_VERSION and
# FREETYPE_SHA256 together pick another). No zlib, bzip2, PNG, Brotli,
# HarfBuzz or HVF, and only the modules the UI's TrueType fonts use: the
# TrueType driver, SFNT tables, glyph names, the auto-hinter and the
# anti-aliasing renderer. Any further arguments go to cmake.
set -eu

VER=${FREETYPE_VERSION:-2.15.0}
SHA256=${FREETYPE_SHA256:-93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5}
PREFIX=${1:?usage: build-freetype.sh PREFIX [--mingw] [cmake args...]}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
src="$work/freetype-$VER"

"$here/retry.sh" 3 curl -fsSL -o "$work/freetype.tar.xz" \
  "https://download.savannah.gnu.org/releases/freetype/freetype-$VER.tar.xz"
if command -v sha256sum > /dev/null; then
  got=$(sha256sum "$work/freetype.tar.xz" | cut -d' ' -f1)
else
  got=$(shasum -a 256 "$work/freetype.tar.xz" | cut -d' ' -f1)
fi
if [ "$got" != "$SHA256" ]; then
  echo "freetype-$VER.tar.xz: SHA-256 $got, expected $SHA256" >&2
  exit 1
fi
tar xJf "$work/freetype.tar.xz" -C "$work"

cat > "$src/include/freetype/config/ftmodule.h" <<'EOF'
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
EOF

cross=""
if [ "${1:-}" = "--mingw" ]; then
  shift
  cross="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc
    -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres"
fi

# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" $cross \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DFT_DISABLE_ZLIB=TRUE -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_PNG=TRUE \
  -DFT_DISABLE_HARFBUZZ=TRUE -DFT_DISABLE_BROTLI=TRUE -DFT_DISABLE_HVF=TRUE "$@"
cmake --build "$work/build" --parallel
cmake --install "$work/build"
rm -rf "$work"
test -f "$PREFIX/lib/libfreetype.a"
test -f "$PREFIX/include/freetype2/ft2build.h"
