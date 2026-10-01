#!/bin/sh
# Build a user-local libnds toolchain on top of an installed devkitARM, for
# machines that have devkitARM (/opt/devkitpro/devkitARM) but not the nds-dev
# packages, without root, pacman or Docker.
#
#   setup_libnds.sh <prefix>          e.g. ~/.cache/dingbat-dkp
#
# <prefix> becomes a DEVKITPRO tree: devkitARM is symlinked from
# /opt/devkitpro, and ndstool, calico, libnds, maxmod and the default ARM7
# binaries are built from devkitPro's GitHub sources into it. Then:
#
#   DEVKITPRO=<prefix> DEVKITARM=<prefix>/devkitARM \
#   PATH=<prefix>/tools/bin:<prefix>/devkitARM/bin:<prefix>/portlibs/nds/bin:$PATH \
#   make -C <some nds-examples project>
#
# Needs: devkitARM, cmake, autoconf/automake, a host C++ compiler, curl.
# Not built: dswifi (its CMake config fails out of tree), libfilesystem, libfat.
set -e
P=${1:?usage: setup_libnds.sh <prefix>}
mkdir -p "$P"
P=$(cd "$P" && pwd)
DKP=${DKP_SYSTEM:-/opt/devkitpro}
src="$P/src"
mkdir -p "$src" "$P/tools/bin" "$P/portlibs/nds/bin"

fetch() { # owner/repo
  d="$src/$(basename "$1")"
  [ -d "$d" ] && return 0
  mkdir -p "$d"
  curl -sfL "https://codeload.github.com/$1/tar.gz/HEAD" | tar xz -C "$d" --strip-components 1
}
raw() { # owner/repo/ref/path out
  curl -sfL "https://raw.githubusercontent.com/$1" -o "$2"
}

# DEVKITPRO skeleton: system devkitARM and host tools, private cmake + portlibs.
ln -sfn "$DKP/devkitARM" "$P/devkitARM"
for f in "$DKP"/tools/bin/*; do ln -sf "$f" "$P/tools/bin/"; done
rm -rf "$P/cmake"
cp -R "$DKP/cmake" "$P/cmake"
raw devkitPro/pacman-packages/master/cmake/nds/NDS.cmake "$P/cmake/NDS.cmake"
raw devkitPro/pacman-packages/master/cmake/nds/NintendoDS.cmake "$P/cmake/Platform/NintendoDS.cmake"
raw devkitPro/pacman-packages/master/cmake/nds/arm-none-eabi-cmake "$P/portlibs/nds/bin/arm-none-eabi-cmake"
for arch in nds armv5te armv4t; do
  mkdir -p "$P/portlibs/$arch/bin"
  cat > "$P/portlibs/$arch/bin/arm-none-eabi-pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_DIR= PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
export PKG_CONFIG_LIBDIR=\${DEVKITPRO}/portlibs/$arch/lib/pkgconfig
[[ "\$1" == '--version' ]] && exec pkg-config --version
exec pkg-config --static "\$@"
EOF
done
chmod +x "$P"/portlibs/*/bin/*

export DEVKITPRO="$P" DEVKITARM="$P/devkitARM"
export PATH="$P/tools/bin:$P/devkitARM/bin:$P/portlibs/nds/bin:$PATH"

# ndstool (host)
fetch devkitPro/ndstool
(cd "$src/ndstool" && ./autogen.sh >/dev/null 2>&1 && ./configure --prefix="$P/tools" >/dev/null && make -j8 >/dev/null && make install >/dev/null)
# calico (runtime: crt0, linker scripts, ARM7/ARM9 system code)
fetch devkitPro/calico
(cd "$src/calico" && catnip install >/dev/null)
# libnds
fetch devkitPro/libnds
make -C "$src/libnds" -j8 install >/dev/null
# maxmod (needed by the default ARM7 "maine" build ds_rules links)
fetch devkitPro/maxmod
(cd "$src/maxmod" && catnip install >/dev/null)
# default ARM7 binaries: ds7_maine.elf (ds_rules default) and ds7_sphynx.elf (minimal)
fetch devkitPro/default-arm7
(cd "$src/default-arm7" && catnip install maine sphynx >/dev/null)

echo "libnds toolchain ready in $P"
ls "$P/calico/bin" "$P/libnds/lib" "$P/tools/bin/ndstool"
