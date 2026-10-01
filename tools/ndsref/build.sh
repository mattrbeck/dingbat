#!/bin/sh
# Builds tools/ndsref/ndsref (needs a C compiler and zlib, nothing else).
set -e
here=$(cd "$(dirname "$0")" && pwd)
${CC:-cc} -O2 -Wall -Wextra -Wno-unused-parameter -o "$here/ndsref" "$here/ndsref.c" -lz -lm
echo "built $here/ndsref"
