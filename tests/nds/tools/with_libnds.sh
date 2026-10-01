#!/bin/sh
# with_libnds.sh <prefix> <command...>
# Run a command (usually `make -C <nds project>`) against the toolchain that
# setup_libnds.sh built in <prefix>.
P=$(cd "${1:?usage: with_libnds.sh <prefix> <command...>}" && pwd)
shift
export DEVKITPRO="$P" DEVKITARM="$P/devkitARM"
export PATH="$P/tools/bin:$P/devkitARM/bin:$P/portlibs/nds/bin:$PATH"
exec "$@"
