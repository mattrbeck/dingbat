#!/bin/sh
# Build the no-library ROMs (src/fb_*, src/gx_tri) into roms/.
# Needs only GNU binutils for arm-none-eabi (Homebrew arm-none-eabi-binutils
# or devkitARM) and python3.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
if command -v arm-none-eabi-as >/dev/null 2>&1; then
  X=arm-none-eabi-
else
  X=/opt/devkitpro/devkitARM/bin/arm-none-eabi-
fi
out="$here/roms"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for name in fb_hello fb_both gx_tri; do
  src="$here/src/$name"
  ${X}as -march=armv5te -o "$tmp/$name.9.o" "$src/arm9.s"
  ${X}ld -Ttext=0x02000000 -e _start -o "$tmp/$name.9.elf" "$tmp/$name.9.o"
  ${X}objcopy -O binary "$tmp/$name.9.elf" "$tmp/$name.9.bin"
  ${X}as -march=armv4t -o "$tmp/$name.7.o" "$src/arm7.s"
  ${X}ld -Ttext=0x037F8000 -e _start -o "$tmp/$name.7.elf" "$tmp/$name.7.o"
  ${X}objcopy -O binary "$tmp/$name.7.elf" "$tmp/$name.7.bin"
  python3 "$here/tools/mknds.py" -9 "$tmp/$name.9.bin" -7 "$tmp/$name.7.bin" \
    --title "$(echo "$name" | tr a-z A-Z)" -o "$out/$name.nds"
done
