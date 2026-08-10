#!/bin/bash
# Runs any command with the campaign environment loaded, from the worktree root.
#   tools/gbscx/r.sh tools/gbppu/gamall.sh /tmp/g_base
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
exec "$@"
