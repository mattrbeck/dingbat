#!/bin/sh
# Build the wifi test ROM (src/wifi_link: C on both CPUs, no library) into
# roms/. Needs an arm-none-eabi gcc (devkitARM's in /opt/devkitpro is used
# when none is on PATH) and python3.
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
CF="-Os -ffreestanding -fno-builtin -nostdlib -Wall -Wextra"

for name in wifi_link; do
  src="$here/src/$name"
  ${X}as -march=armv5te -o "$tmp/crt0.o" "$here/src/common2d/crt0.s"
  ${X}gcc -march=armv5te -marm $CF -c -o "$tmp/arm9.o" "$src/arm9.c"
  ${X}gcc -march=armv5te -marm -nostdlib -T "$here/src/common2d/link.ld" \
    -o "$tmp/arm9.elf" "$tmp/crt0.o" "$tmp/arm9.o" -lgcc
  ${X}objcopy -O binary "$tmp/arm9.elf" "$tmp/arm9.bin"
  ${X}as -march=armv4t -o "$tmp/crt7.o" "$src/crt7.s"
  ${X}gcc -march=armv4t -marm $CF -c -o "$tmp/arm7.o" "$src/arm7.c"
  ${X}gcc -march=armv4t -marm -nostdlib -T "$src/link7.ld" -Wl,--no-warn-rwx-segments \
    -o "$tmp/arm7.elf" "$tmp/crt7.o" "$tmp/arm7.o" -lgcc
  ${X}objcopy -O binary "$tmp/arm7.elf" "$tmp/arm7.bin"
  python3 "$here/tools/mknds.py" -9 "$tmp/arm9.bin" -7 "$tmp/arm7.bin" \
    --title "$(echo "$name" | tr a-z A-Z)" -o "$roms/$name.nds"
done
