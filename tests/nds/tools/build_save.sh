#!/bin/sh
# Build the no-library save test ROM (src/save_write) into roms/. Same
# toolchain as build_2d.sh; the ARM7 side is fb_both's spin loop.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
roms="${DINGBAT_NDS_ROMS:-$HOME/.cache/dingbat-nds/roms}"   # test ROMs stay out of the repo
mkdir -p "$roms"
if command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  X=arm-none-eabi-
else
  X=/opt/devkitpro/devkitARM/bin/arm-none-eabi-
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

${X}as -march=armv4t -o "$tmp/arm7.o" "$here/src/fb_both/arm7.s"
${X}ld -Ttext=0x037F8000 -e _start -o "$tmp/arm7.elf" "$tmp/arm7.o"
${X}objcopy -O binary "$tmp/arm7.elf" "$tmp/arm7.bin"
${X}as -march=armv5te -o "$tmp/crt0.o" "$here/src/common2d/crt0.s"

name=save_write
${X}gcc -march=armv5te -marm -Os -ffreestanding -fno-builtin -nostdlib \
  -Wall -c -o "$tmp/$name.o" "$here/src/$name/arm9.c"
${X}gcc -march=armv5te -marm -nostdlib -T "$here/src/common2d/link.ld" \
  -o "$tmp/$name.elf" "$tmp/crt0.o" "$tmp/$name.o" -lgcc
${X}objcopy -O binary "$tmp/$name.elf" "$tmp/$name.9.bin"
python3 "$here/tools/mknds.py" -9 "$tmp/$name.9.bin" -7 "$tmp/arm7.bin" \
  --title "SAVEWRITE" -o "$roms/$name.nds"
echo "$roms/$name.nds"
