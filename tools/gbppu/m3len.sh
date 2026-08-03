#!/bin/bash
# Print the mode-3 length trace for one gambatte ROM (needs ./dt_m3len, built
# with -d:gb_m3_len). Usage: tools/gbppu/m3len.sh <dev> <rom-path>
cd "$(dirname "$0")/../.."
dev="$1"; rom="$2"
printf '%s\thex\t0\t%s\n' "$dev" "$rom" > /tmp/one.tsv
./dt_m3len --mode=gambatte --list=/tmp/one.tsv 2>&1 | grep -E '^M3IN|^M3LEN'
