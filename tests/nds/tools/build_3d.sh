#!/bin/sh
# build_3d.sh [name...]
# Build the 3D test ROMs (tests/nds/src/3d_*/main.c + 3d_common, no
# library) into $DINGBAT_NDS_ROMS/3d (default ~/.cache/dingbat-nds/roms). Needs an arm-none-eabi gcc (devkitARM's
# in /opt/devkitpro or ~/.cache/dingbat-dkp, or any bare-metal one; libgcc
# provides the soft-float helpers) and python3. The ARM7 side is fb_both's
# spin loop; the ARM9 code starts at 0x02000000 with common2d's crt0.
# A variant directory's main.c may #include another ROM's main.c.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
roms="${DINGBAT_NDS_ROMS:-$HOME/.cache/dingbat-nds/roms}"   # test ROMs stay out of the repo
mkdir -p "$roms"
if command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  X=arm-none-eabi-
elif [ -x /opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc ]; then
  X=/opt/devkitpro/devkitARM/bin/arm-none-eabi-
else
  X=$HOME/.cache/dingbat-dkp/devkitARM/bin/arm-none-eabi-
fi
out="$roms/3d"
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ $# -gt 0 ]; then names="$*"; else
  names=$(cd "$here/src" && ls 3d_*/main.c | sed 's|/main.c||')
fi

${X}as -march=armv4t -o "$tmp/arm7.o" "$here/src/fb_both/arm7.s"
${X}ld -Ttext=0x037F8000 -e _start -o "$tmp/arm7.elf" "$tmp/arm7.o"
${X}objcopy -O binary "$tmp/arm7.elf" "$tmp/arm7.bin"
${X}as -march=armv5te -o "$tmp/crt0.o" "$here/src/common2d/crt0.s"
CFLAGS="-march=armv5te -mtune=arm946e-s -marm -O2 -ffreestanding -fno-builtin -nostdlib -Wall"
${X}gcc $CFLAGS -c -o "$tmp/t3d.o" "$here/src/3d_common/t3d.c"

for name in $names; do
  ${X}gcc $CFLAGS -I"$here/src/3d_common" -c -o "$tmp/$name.o" "$here/src/$name/main.c"
  ${X}gcc -march=armv5te -marm -nostdlib -Wl,--no-warn-rwx-segments -T "$here/src/common2d/link.ld" \
    -o "$tmp/$name.elf" "$tmp/crt0.o" "$tmp/$name.o" "$tmp/t3d.o" -lgcc
  ${X}objcopy -O binary "$tmp/$name.elf" "$tmp/$name.9.bin"
  python3 "$here/tools/mknds.py" -9 "$tmp/$name.9.bin" -7 "$tmp/arm7.bin" \
    --title "$(echo "$name" | tr a-z A-Z | cut -c1-12)" -o "$out/$name.nds"
  echo "$out/$name.nds"
done
